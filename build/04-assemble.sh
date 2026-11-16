#!/usr/bin/env bash
# Stage 4 — bind mounts, run stage 3 in the chroot, install 32-bit UEFI GRUB
#           (explicitly, both removable + vendor paths — Bay Trail firmware
#           only understands IA32 EFI), write fstab by UUID, generate grub.cfg
#           and post-process it (per-kernel params + root= UUID fix).
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
source "$SRC/lib.sh"

ROOT=""; IMG=""; BUILD=""
while [ $# -gt 0 ]; do
    case "$1" in --root) ROOT="$2"; shift 2;; --img) IMG="$2"; shift 2;; --build) BUILD="$2"; shift 2;; *) shift;; esac
done

LOOP=$(losetup -j "$IMG" | cut -d: -f1)
if [ -z "$LOOP" ]; then
    # stage 1's loop device is expected to still exist; re-attaching is
    # harmless (both partitions are already formatted) and far better than
    # dying here, which is what used to happen silently
    warn "no loop device for $IMG - re-attaching"
    losetup -P "$(losetup -f)" "$IMG" || die "could not attach a loop device to $IMG"
    LOOP=$(losetup -j "$IMG" | cut -d: -f1)
fi
[ -n "$LOOP" ] || die "still no loop device for $IMG"
info "loop: $LOOP (root ${LOOP}p2, ESP ${LOOP}p1)"

# ── mounts for the chroot ──────────────────────────────────────────────────
# Each mount is named: a bare command failing under set -e reports only
# "exit 1", which says nothing about which mount is the problem.
mount -t proc  proc  "$ROOT/proc"     || die "mount proc failed"
mount -t sysfs sysfs "$ROOT/sys"      || die "mount sysfs failed"
mount --bind /dev "$ROOT/dev"         || die "bind-mount /dev failed"
mount --bind /dev/pts "$ROOT/dev/pts" || die "bind-mount /dev/pts failed"
mkdir -p "$ROOT/boot/efi"
mount "${LOOP}p1" "$ROOT/boot/efi" || die "failed to mount ESP (${LOOP}p1)"
mkdir -p "$ROOT/build"
mount --bind "$BUILD" "$ROOT/build"
ok "chroot mounts ready (proc, sys, dev, ESP, build)"

# ── stage 3: configure inside the image ────────────────────────────────────
info "running configuration stage inside the image (long)"
chroot "$ROOT" /bin/bash /build/03-configure.sh
ok "configuration done"

# ── 32-bit UEFI GRUB — THE critical install ────────────────────────────────
info "installing i386-efi GRUB (32-bit UEFI — mandatory on Bay Trail)"
# vendor path
chroot "$ROOT" grub-install --target=i386-efi --efi-directory=/boot/efi \
    --boot-directory=/boot --bootloader-id=CasperOS --no-nvram
# removable path (what most 32-bit firmwares actually scan)
chroot "$ROOT" grub-install --target=i386-efi --efi-directory=/boot/efi \
    --boot-directory=/boot --removable --no-nvram
# belt & braces: some firmware only looks for BOOTIA32.EFI in vendor dirs
cp -f "$ROOT/boot/efi/EFI/BOOT/BOOTIA32.EFI" "$ROOT/boot/efi/EFI/CasperOS/BOOTIA32.EFI" 2>/dev/null || true

ok "grub installed. EFI binaries on ESP:"
ls -la "$ROOT/boot/efi/EFI/BOOT/" "$ROOT/boot/efi/EFI/CasperOS/" 2>/dev/null | grep -iE 'efi|^/' || true

# assert: NO x86_64 EFI binaries anywhere
if find "$ROOT/boot/efi" -iname '*.efi' | grep -qiE 'x64|grubx64'; then
    die "x86_64 EFI binaries found on ESP — 32-bit UEFI would not boot"
fi

# The old check here was `file ... | grep -qiE '80386|IA-32'`, which depends on
# file(1)'s wording and failed on the CI host with a binary that is in fact
# i386. Read the PE machine field instead (014c = IA-32) and print what was
# actually found, so a real failure is distinguishable from a wording change.
BOOT32="$ROOT/boot/efi/EFI/BOOT/BOOTIA32.EFI"
[ -f "$BOOT32" ] || die "grub-install did not write EFI/BOOT/BOOTIA32.EFI — 32-bit UEFI would not boot"
MACHINE=$(bash "$BUILD/tools/pe-machine.sh" "$BOOT32" 2>/dev/null) || MACHINE="unreadable"
info "BOOTIA32.EFI machine=0x$MACHINE  [file(1): $(file -b "$BOOT32" 2>/dev/null || echo n/a)]"
[ "$MACHINE" = "014c" ] || die "BOOTIA32.EFI has PE machine 0x$MACHINE, expected 0x014c (IA-32)"

# every EFI binary that ships on the ESP has to be 32-bit, not just this one
while IFS= read -r efi; do
    m=$(bash "$BUILD/tools/pe-machine.sh" "$efi" 2>/dev/null) || m="unreadable"
    [ "$m" = "014c" ] || die "${efi#$ROOT} has PE machine 0x$m, expected 0x014c (IA-32)"
done < <(find "$ROOT/boot/efi" -iname '*.efi')
ok "ESP verified: every EFI binary is IA-32 (32-bit)"

# ── fstab by UUID ──────────────────────────────────────────────────────────
ROOTUUID=$(blkid -s UUID -o value "${LOOP}p2")
ESPUUID=$(blkid -s UUID -o value "${LOOP}p1")
cat > "$ROOT/etc/fstab" <<EOF
# CasperOS — generated at build time, mounted by UUID
UUID=$ROOTUUID  /          ext4  defaults,noatime,commit=60,errors=remount-ro  0 1
UUID=$ESPUUID   /boot/efi  vfat  umask=0022                                  0 1
tmpfs           /tmp       tmpfs defaults,noatime,size=512M,mode=1777         0 0
EOF
ok "fstab written (root $ROOTUUID, ESP $ESPUUID)"

# ── grub.cfg: generate, post-process, validate ─────────────────────────────
info "generating grub.cfg"
chroot "$ROOT" update-grub >/dev/null 2>&1 || chroot "$ROOT" update-grub

HOST_ROOT_UUID=$(blkid -s UUID -o value "$(findmnt -n -o SOURCE /)")
info "post-processing grub.cfg (root= UUID fix + per-kernel params)"
bash "$BUILD/tools/grub-casper-postprocess.sh" \
    "$ROOT/boot/grub/grub.cfg" "$HOST_ROOT_UUID" "$ROOTUUID"

chroot "$ROOT" grub-script-check /boot/grub/grub.cfg || die "grub.cfg failed validation"
ok "grub.cfg valid"

info "--- default kernel entry ---"
grep -A1 '^menuentry .*linux' "$ROOT/boot/grub/grub.cfg" | grep -E 'menuentry|linux' | head -4 || true
info "--- 5.15 entry (should carry legacy I2C params) ---"
grep -B1 'vmlinuz-5\.15' "$ROOT/boot/grub/grub.cfg" | grep -E 'menuentry|linux' | head -4 || true
