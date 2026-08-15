#!/usr/bin/env bash
# CasperOS auto-flash ISO builder.
#
#   build-flash-iso.sh env <root>                       build the flash env
#                                                     (chroot + initramfs)
#   build-flash-iso.sh iso <root> <out.iso> [payload]  assemble a bootable
#                                                     flash ISO (optionally
#                                                     embedding the image)
#   build-flash-iso.sh kit <root> <out.zip>            build the ESP kit
#
# The ISO boots on 32-bit UEFI (Bay Trail) and, from within the initramfs,
# finds casper-n220.img — on the USB stick OR embedded in the ISO itself —
# flashes the internal disk, and reboots. Zero typing, zero keyboard.
set -euo pipefail
SRC="$(cd "$(dirname "$0")/../.." && pwd)"
CMD="${1:-}"

[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
for t in mmdebstrap grub-mkrescue xorriso; do
    command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; exit 1; }
done

info() { echo -e "\033[1;36m→\033[0m $*"; }
ok()   { echo -e "\033[1;32m✓\033[0m $*"; }

# ── env: bootstrap the flash environment ───────────────────────────────────
do_env() {
    local ROOT="${2:?usage: env <root>}"
    [ -e /usr/share/debootstrap/scripts/trixie ] || ln -sf sid /usr/share/debootstrap/scripts/trixie

    rm -rf "$ROOT"
    mkdir -p "$ROOT"
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
ahci
ata_piix
sd_mod
sr_mod
mmc_block
mmc_core
sdhci
sdhci-pci
exfat
vfat
fat
nls_cp437
nls_ascii
ext4
isofs
MODS

    cp "$SRC/build/flash-iso/hook-casper-flash" "$ROOT/etc/initramfs-tools/hooks/casper-flash"
    chmod 755 "$ROOT/etc/initramfs-tools/hooks/casper-flash"

    info "building initramfs (custom /init)"
    chroot "$ROOT" env DEBIAN_FRONTEND=noninteractive \
        /bin/sh -c 'V=$(ls /boot/vmlinuz-* | head -1); V=${V#/boot/vmlinuz-}; update-initramfs -c -k "$V"'

    umount -R "$ROOT" 2>/dev/null || true
    umount -l "$ROOT" 2>/dev/null || true
    [ -e "$ROOT/boot/initrd.img" ] || true
    ok "flash environment ready in $ROOT"
}

# ── iso: assemble a bootable flash ISO from an env root ────────────────────
do_iso() {
    local ROOT="${2:?usage: iso <root> <out.iso> [payload]}"
    local OUT="${3:?usage: iso <root> <out.iso> [payload]}"
    local PAYLOAD="${4:-}"

    local VMLINUZ INITRD
    VMLINUZ=$(ls "$ROOT"/boot/vmlinuz-* | head -1)
    INITRD=$(ls "$ROOT"/boot/initrd.img-* | head -1)
    [ -n "$VMLINUZ" ] && [ -n "$INITRD" ] || { echo "kernel/initrd missing in $ROOT" >&2; exit 1; }

    local ISODIR=/tmp/flash-iso-tree
    rm -rf "$ISODIR"
    mkdir -p "$ISODIR/boot/grub"
    cp "$VMLINUZ" "$ISODIR/boot/vmlinuz"
    cp "$INITRD" "$ISODIR/boot/initrd.img"
    cat > "$ISODIR/boot/grub/grub.cfg" <<'GRUB'
set timeout=3
set default=0
menuentry "CasperOS Auto-Flash" {
    linux /boot/vmlinuz root=/dev/ram0 rw quiet console=tty0 console=ttyS0,115200
    initrd /boot/initrd.img
}
GRUB
    if [ -n "$PAYLOAD" ]; then
        info "embedding payload: $PAYLOAD"
        ln -f "$PAYLOAD" "$ISODIR/casper-n220.img"
        ok "embedded casper-n220.img ($(stat -c %s "$ISODIR/casper-n220.img") bytes)"
    fi

    info "building hybrid ISO (BIOS + UEFI x64 + UEFI IA32)"
    # -iso_level 3: allows multi-extent files > 4GB (the embedded image)
    grub-mkrescue -o "$OUT" "$ISODIR" -- -volid CASPER_FLASH -joliet on -iso_level 3
    rm -rf "$ISODIR"
    ok "ISO: $OUT ($(stat -c %s "$OUT") bytes)"
}

# ── kit: ESP kit (grub-ia32 with embedded config) ──────────────────────────
do_kit() {
    local ROOT="${2:?usage: kit <root> <out.zip>}"
    local OUT="${3:?usage: kit <root> <out.zip>}"

    local VMLINUZ INITRD
    VMLINUZ=$(ls "$ROOT"/boot/vmlinuz-* | head -1)
    INITRD=$(ls "$ROOT"/boot/initrd.img-* | head -1)

    local KITDIR=/tmp/esp-kit
    rm -rf "$KITDIR"; mkdir -p "$KITDIR"

    cat > /tmp/esp-kit-grub.cfg <<'GRUB'
set timeout=0
set default=0
search --no-floppy --set=root --file /flash/vmlinuz
insmod exfat
insmod fat
insmod part_gpt
linux /flash/vmlinuz root=/dev/ram0 rw quiet console=tty0 console=ttyS0,115200
initrd /flash/initrd.img
GRUB
    grub-mkimage -O i386-efi -p /boot/grub -c /tmp/esp-kit-grub.cfg \
        -o "$KITDIR/BOOTIA32.EFI" \
        ext2 exfat fat part_gpt part_msdos iso9660 search search_fs_file linux normal
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
    ( cd "$KITDIR" && zip -qr "$OUT" BOOTIA32.EFI vmlinuz initrd.img README.txt )
    rm -rf "$KITDIR"
    ok "ESP kit: $OUT"
}

case "$CMD" in
    env) do_env "$@" ;;
    iso) do_iso "$@" ;;
    kit) do_kit "$@" ;;
    *) echo "usage: $0 {env|iso|kit} ..." >&2; exit 1 ;;
esac
