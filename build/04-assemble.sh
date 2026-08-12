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
[ -n "$LOOP" ] || die "no loop device for $IMG"

# ── mounts for the chroot ──────────────────────────────────────────────────
mount -t proc proc "$ROOT/proc"
mount -t sysfs sysfs "$ROOT/sys"
mount --bind /dev "$ROOT/dev"
mount --bind /dev/pts "$ROOT/dev/pts"
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
file "$ROOT/boot/efi/EFI/BOOT/BOOTIA32.EFI" | grep -q 'IA-32' || die "BOOTIA32.EFI is not an IA-32 binary!"
ok "ESP verified: only IA-32 (32-bit) EFI bootloader present"

# ── fstab by UUID ──────────────────────────────────────────────────────────
ROOTUUID=$(blkid -s UUID -o value "${LOOP}p2")
ESPUUID=$(blkid -s UUID -o value "${LOOP}p1")
cat > "$ROOT/etc/fstab" <<EOF
# CasperOS — generated at build time, mounted by UUID
UUID=$ROOTUUID  /          ext4  defaults,noatime,commit=60,errors=remount-ro  0 1
UUID=$ESPUUID   /boot/efi  vfat  umask=0077                                  0 1
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
