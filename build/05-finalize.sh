#!/usr/bin/env bash
# Stage 5 — strip build residue, clear logs/machine-id, zero free space,
#           unmount, and report.
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
source "$SRC/lib.sh"

ROOT=""; IMG=""
while [ $# -gt 0 ]; do
    case "$1" in --root) ROOT="$2"; shift 2;; --img) IMG="$2"; shift 2;; *) shift;; esac
done

info "finalizing image"

# unbind the build dir and remove it
umount "$ROOT/build" 2>/dev/null || true
rm -rf "$ROOT/build"

# inside the image: strip everything not needed at runtime
rm -rf "$ROOT/var/lib/apt/lists" "$ROOT/var/cache/apt"
rm -f "$ROOT/root/k515"/*.deb 2>/dev/null || true
rmdir "$ROOT/root/k515" 2>/dev/null || true
find "$ROOT/var/log" -type f -delete 2>/dev/null || true
rm -f "$ROOT/root/.bash_history" "$ROOT/home/lvy/.bash_history"
: > "$ROOT/etc/machine-id"
rm -f "$ROOT/var/lib/systemd/random-seed"
rm -rf "$ROOT/tmp/"* 2>/dev/null || true

# ── initramfs gate: an initrd that cannot see the eMMC does not boot ──────
# MODULES=dep resolves the *build host's* storage driver (it reads the running
# /proc/mounts and /sys), so this image's initrds must carry the tablet's MMC
# stack. Nothing else in the build would notice if they did not — the failure
# is a kernel panic on the tablet, hours after a green build. lsinitramfs is
# the only check that sees inside the image. Runs before the zero-fill so a
# refused image does not cost the full write of the filesystem.
#
# NOTE: Debian's amd64 kernel builds the MMC/SDHCI stack as modules (=m), so
# for the 6.12 initrd these really are .ko files under
# usr/lib/modules/<ver>/kernel/drivers/mmc/. Ubuntu's mainline 5.15 builds
# ext4/jbd2 in (=y) — those legitimately have no .ko and are satisfied via
# modules.builtin. A genuine breakage is "neither a module nor builtin".
info "verifying the initrds can mount the tablet's eMMC root"
INITRD_FAIL=0
for initrd in "$ROOT"/boot/initrd.img-*; do
    [ -f "$initrd" ] || continue
    name=$(basename "$initrd")
    if ! listing=$(lsinitramfs "$initrd" 2>/dev/null); then
        echo "WARN: could not read $name with lsinitramfs — skipping its check" >&2
        continue
    fi
    # A driver is usable if it is EITHER a module file in the initrd OR built
    # into that kernel. Two traps this avoids:
    #
    #  1. The .ko FILE name is the kernel Makefile's obj-m name, which is not
    #     always the module name: drivers/mmc/host/Makefile has
    #     `obj-$(CONFIG_MMC_SDHCI_PCI) += sdhci-pci.o`, so the file is
    #     sdhci-pci.ko.xz while `modprobe sdhci_pci` is what you type. Matching
    #     only the underscore spelling reports every hyphenated driver missing.
    #  2. Built-in drivers have no .ko at all. mkinitramfs copies the kernel's
    #     modules.builtin into the initrd, so consult that too: Debian's amd64
    #     kernel has IOSF_MBI=y (builtin), and a config like that is correct,
    #     not broken.
    #
    # modules.builtin is read from the initrd itself rather than /boot so the
    # check stays valid for a kernel whose /lib/modules is not the running one.
    builtin=""
    exdir=""
    builtin_rel=$(printf '%s\n' "$listing" | grep -E '(^|/)modules\.builtin$' | head -1 || true)
    if [ -n "$builtin_rel" ] && command -v unmkinitramfs >/dev/null 2>&1; then
        exdir=$(mktemp -d) || die "mktemp failed"
        if unmkinitramfs "$initrd" "$exdir" >/dev/null 2>&1; then
            if [ -f "$exdir/${builtin_rel#/}" ]; then
                builtin="$exdir/${builtin_rel#/}"
            fi
        fi
    fi

    missing=""
    for mod in ext4 mmc_block sdhci sdhci_pci sdhci_acpi; do
        # Try both spellings: the module name (sdhci_pci) and the kernel's
        # object name (sdhci-pci), because they differ for these drivers.
        found=0
        for fname in "$mod" "${mod//_/-}"; do
            # modules are stored compressed (zstd/gzip/xz) — match the basename
            if grep -qE "(^|/)${fname//./\\.}\.ko(\.(xz|gz|zst))?$" <<<"$listing"; then
                found=1; break
            fi
        done
        if [ "$found" = 0 ] && [ -n "$builtin" ]; then
            for fname in "$mod" "${mod//_/-}"; do
                if grep -qE "/${fname//./\\.}\.ko$" "$builtin"; then
                    found=1; break
                fi
            done
        fi
        [ "$found" = 1 ] || missing="$missing $mod"
    done

    if [ -n "$missing" ]; then
        printf '::error::%s cannot load:%s — the tablet would not mount root\n' "$name" "$missing" >&2
        echo "FATAL: $name lacks:$missing" >&2
        INITRD_FAIL=1
    else
        ok "$name can mount the eMMC root (ext4 + sdhci/mmc_block present as module or builtin)"
    fi
    if [ -n "$exdir" ]; then rm -rf "$exdir"; fi
    exdir=""
done
[ "$INITRD_FAIL" = 0 ] || die "an initramfs cannot mount the eMMC root — refusing to ship this image"

# zero free space so the image compresses well
info "zeroing free space (for compression)"
dd if=/dev/zero of="$ROOT/.zerofile" bs=1M status=none 2>/dev/null || true
rm -f "$ROOT/.zerofile"

ROOTFS_BYTES=$(du -sx "$ROOT" 2>/dev/null | awk '{print $1*1024}')

# Space breakdown, so shrinking the image is measurable from CI without
# downloading the artifact. This must run while $ROOT is still mounted: after
# umount the same command reports the empty mountpoint, not the rootfs.
USAGE=""
while read -r kb path; do
    [ -n "$path" ] || continue
    rel=${path#"$ROOT"}
    USAGE="$USAGE$(printf 'USAGE %6s  %s' "$(numfmt --to=iec "$((kb * 1024))")" "${rel:-/}")\n"
done < <(du -kx --max-depth=1 "$ROOT" 2>/dev/null | sort -rn | head -9)


# unmount everything
sync
umount -R "$ROOT" 2>/dev/null || umount -l "$ROOT" 2>/dev/null || true
losetup -d "$(losetup -j "$IMG" | cut -d: -f1)" 2>/dev/null || true
sync

IMG_BYTES=$(stat -c %s "$IMG")
REPORT="$(dirname "$IMG")/casper-build-report.txt"
{
    echo "IMAGE_BYTES=$IMG_BYTES"
    echo "ROOTFS_BYTES=$ROOTFS_BYTES"
    echo "SIZE image=$(numfmt --to=iec "$IMG_BYTES") rootfs=$(numfmt --to=iec "$ROOTFS_BYTES")"
    printf '%b' "$USAGE"
    echo "IMG=$IMG"
} >> "$REPORT"

ok "image size: $(numfmt --to=iec-i "$IMG_BYTES")  (rootfs used: $(numfmt --to=iec-i "$ROOTFS_BYTES"))"
info "build report: $REPORT"
