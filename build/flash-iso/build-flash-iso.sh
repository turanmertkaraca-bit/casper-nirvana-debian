#!/usr/bin/env bash
# Build the CasperOS auto-flash ISO (and ESP kit).
#
# The ISO boots on 32-bit UEFI (Bay Trail) and, from within the initramfs,
# finds casper-n220.img on the USB stick, flashes the internal disk, and
# reboots. Zero typing, zero keyboard.
#
# Usage: sudo ./build-flash-iso.sh [root-dir] [out.iso]
set -euo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="${1:-/tmp/flash-root}"
OUT="${2:-/tmp/casper-flash.iso}"
KIT="${3:-/tmp/casper-flash-esp.zip}"

[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
for t in mmdebstrap grub-mkrescue xorriso; do
    command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; exit 1; }
done

# debootstrap script shim for trixie
[ -e /usr/share/debootstrap/scripts/trixie ] || ln -sf sid /usr/share/debootstrap/scripts/trixie

rm -rf "$ROOT" /tmp/flash-iso-tree
mkdir -p "$ROOT"

info() { echo -e "\033[1;36m→\033[0m $*"; }
ok()   { echo -e "\033[1;32m✓\033[0m $*"; }

info "bootstrapping minimal trixie root"
mmdebstrap --variant=minbase --arch=amd64 \
    --components="main,contrib,non-free,non-free-firmware" \
    --include="ca-certificates,debian-archive-keyring,locales,linux-image-amd64,initramfs-tools,busybox,kmod" \
    --keyring=/usr/share/keyrings/debian-archive-keyring.gpg \
    --aptopt='APT::Install-Recommends "false";' \
    --aptopt='APT::Install-Suggests "false";' \
    trixie "$ROOT" "http://deb.debian.org/debian"
ok "bootstrap done"

info "configuring the custom initramfs"
mount -t proc proc "$ROOT/proc"
mount -t sysfs sysfs "$ROOT/sys"
mount --bind /dev "$ROOT/dev"
mount --bind /dev/pts "$ROOT/dev/pts"

cat > "$ROOT/etc/initramfs-tools/modules" <<'MODS'
exfat
vfat
fat
sd_mod
mmc_block
mmc_core
ext4
MODS

cp "$SRC/build/flash-iso/hook-casper-flash" "$ROOT/etc/initramfs-tools/hooks/casper-flash"
chmod 755 "$ROOT/etc/initramfs-tools/hooks/casper-flash"

info "building initramfs (custom /init)"
chroot "$ROOT" env DEBIAN_FRONTEND=noninteractive \
    /bin/sh -c 'V=$(ls /boot/vmlinuz-* | head -1); V=${V#/boot/vmlinuz-}; update-initramfs -c -k "$V"'

VMLINUZ=$(ls "$ROOT"/boot/vmlinuz-* | head -1)
INITRD=$(ls "$ROOT"/boot/initrd.img-* | head -1)
[ -n "$VMLINUZ" ] && [ -n "$INITRD" ] || { echo "kernel/initrd missing" >&2; exit 1; }
ok "initramfs: $(basename "$INITRD")"

# extract grub ia32 modules for the ESP kit before unmounting
KITDIR=/tmp/esp-kit
rm -rf "$KITDIR"; mkdir -p "$KITDIR"

info "assembling ISO tree"
ISODIR=/tmp/flash-iso-tree
mkdir -p "$ISODIR/boot/grub"
cp "$VMLINUZ" "$ISODIR/boot/vmlinuz"
cp "$INITRD" "$ISODIR/boot/initrd.img"
cat > "$ISODIR/boot/grub/grub.cfg" <<'GRUB'
set timeout=3
set default=0
menuentry "CasperOS Auto-Flash" {
    linux /boot/vmlinuz root=/dev/ram0 rw quiet console=ttyS0,115200 console=tty0
    initrd /boot/initrd.img
}
GRUB

umount -R "$ROOT" 2>/dev/null || umount -l "$ROOT"

info "building hybrid ISO (BIOS + UEFI x64 + UEFI IA32)"
grub-mkrescue -o "$OUT" "$ISODIR" -- -volid CASPER_FLASH -joliet on
ok "ISO: $OUT ($(stat -c %s "$OUT") bytes)"

info "building ESP kit (grub-ia32 with embedded config)"
# BOOTIA32.EFI that scans for /flash/vmlinuz+initrd on any partition
cat > /tmp/esp-kit-grub.cfg <<'GRUB'
set timeout=0
set default=0
search --no-floppy --set=root --file /flash/vmlinuz
insmod exfat
insmod vfat
insmod part_gpt
linux /flash/vmlinuz root=/dev/ram0 rw quiet console=ttyS0,115200 console=tty0
initrd /flash/initrd.img
GRUB
grub-mkimage -O i386-efi -c /tmp/esp-kit-grub.cfg \
    -o "$KITDIR/BOOTIA32.EFI" \
    ext2 exfat vfat part_gpt part_msdos iso9660 search search_fs_file linux normal font
cp "$VMLINUZ" "$KITDIR/vmlinuz"
cp "$INITRD" "$KITDIR/initrd.img"
cat > "$KITDIR/README.txt" <<'EOF'
CasperOS ESP flash kit — for tablets whose firmware cannot boot Ventoy.

1. On the USB stick's ESP partition (FAT32), replace /EFI/BOOT/BOOTIA32.EFI
   with the BOOTIA32.EFI from this kit. (Keep the other Ventoy files.)
2. Copy vmlinuz + initrd.img to the main (data) partition in a folder
   named "flash"  ->  /flash/vmlinuz  /flash/initrd.img
3. Put casper-n220.img (the raw image, not the .xz!) on the data partition.
4. Boot the tablet. It flashes the internal disk automatically.

Layout on the stick:
   ESP partition:   /EFI/BOOT/BOOTIA32.EFI   (this kit's file)
   Data partition:  /flash/vmlinuz, /flash/initrd.img, casper-n220.img
EOF
( cd "$KITDIR" && zip -qr "$KIT" BOOTIA32.EFI vmlinuz initrd.img README.txt )
ok "ESP kit: $KIT"

echo
echo "Done. Put casper-flash.iso (or the ESP kit) on the USB stick"
echo "alongside the raw casper-n220.img and boot it."
