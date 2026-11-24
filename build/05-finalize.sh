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
# /proc/mounts and /sys), so this image's initrds must contain the tablet's MMC
# stack. Nothing else in the build would notice if they did not — the failure
# is a kernel panic on the tablet, hours after a green build. lsinitramfs is
# the only check that sees inside the image. Runs before the zero-fill so a
# refused image does not cost the full write of the filesystem.
info "verifying the initrds contain the tablet's storage stack"
INITRD_FAIL=0
for initrd in "$ROOT"/boot/initrd.img-*; do
    [ -f "$initrd" ] || continue
    name=$(basename "$initrd")
    if ! listing=$(lsinitramfs "$initrd" 2>/dev/null); then
        echo "WARN: could not read $name with lsinitramfs — skipping its check" >&2
        continue
    fi
    missing=""
    for mod in ext4 mmc_block sdhci sdhci_pci; do
        # modules are stored compressed (zstd/gzip/xz), so match the basename
        printf '%s\n' "$listing" | grep -qE "(^|/)${mod}\.ko(\.(xz|gz|zst))?$" \
            || missing="$missing $mod"
    done
    if [ -n "$missing" ]; then
        printf '::error::%s is missing modules:%s — the tablet would not mount root\n' "$name" "$missing" >&2
        echo "FATAL: $name lacks:$missing" >&2
        INITRD_FAIL=1
    else
        ok "$name contains ext4 + mmc_block + sdhci + sdhci_pci"
    fi
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
