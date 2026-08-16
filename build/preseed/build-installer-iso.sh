#!/usr/bin/env bash
# Build the CasperOS installer ISO — Debian's own netinst installer,
# preseeded for a fully automatic CasperOS install:
#   - tr locale/Turkey, user lvy, whole-disk install
#   - RTL8723BS Wi-Fi firmware bundled into the installer initrd
#   - all CasperOS fixes applied automatically after the base install
#
# Usage: sudo ./build-installer-iso.sh [out.iso] [netinst.iso-or-empty]
set -euo pipefail
SRC="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${1:-/tmp/casper-install.iso}"
NETINST="${2:-}"

[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
for t in xorriso curl; do
    command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; exit 1; }
done

info() { echo -e "\033[1;36m→\033[0m $*"; }
ok()   { echo -e "\033[1;32m✓\033[0m $*"; }

WORK=/tmp/casper-installer
rm -rf "$WORK" && mkdir -p "$WORK/iso" "$WORK/payload/casperos"

# ── 1. fetch the Debian netinst ISO ────────────────────────────────────────
if [ -z "$NETINST" ] || [ ! -f "$NETINST" ]; then
    info "downloading Debian 13 amd64 netinst ISO"
    NETINST="$WORK/debian-netinst.iso"
    curl -fsSL --retry 3 -o "$NETINST" \
        https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/debian-13.6.0-amd64-netinst.iso
fi
info "netinst: $NETINST ($(stat -c %s "$NETINST") bytes)"

# ── 2. extract the ISO ─────────────────────────────────────────────────────
info "extracting netinst ISO"
xorriso -osirrox on -indev "$NETINST" -extract / "$WORK/iso" >/dev/null 2>&1
chmod -R u+w "$WORK/iso"

# ── 3. bundle the CasperOS fix payload ─────────────────────────────────────
info "bundling the fix payload"
P="$WORK/payload/casperos"
cp -a "$SRC/build/preseed/casperos-fixup.sh" "$P/"
cp -a "$SRC/build/configs" "$P/configs"
cp -a "$SRC/build/packages.list" "$P/"
cp -a "$SRC/build/tools/grub-casper-postprocess.sh" "$P/"
chmod +x "$P/casperos-fixup.sh" "$P/grub-casper-postprocess.sh"

# ── 4. bundle the RTL8723BS firmware into the installer initrd ─────────────
# (so the tablet's Wi-Fi works during the install itself)
info "injecting RTL8723BS firmware into the installer initrd"
FW="$WORK/fw"
mkdir -p "$FW"
curl -fsSL --retry 3 -o "$FW/firmware-realtek.deb" \
    http://deb.debian.org/debian/pool/non-free-firmware/f/firmware-nonfree/$( \
        curl -fsSL --retry 3 http://deb.debian.org/debian/pool/non-free-firmware/f/firmware-nonfree/ | \
        grep -oE 'firmware-realtek_[0-9][^" ]*_all\.deb' | sort -V | tail -1)
dpkg-deb -x "$FW/firmware-realtek.deb" "$FW/x"
mkdir -p "$WORK/initrd-overlay/lib/firmware/rtl8723bs" "$WORK/initrd-overlay/lib/firmware/rtl_bt"
cp -a "$FW/x/lib/firmware/rtl8723bs/." "$WORK/initrd-overlay/lib/firmware/rtl8723bs/" 2>/dev/null || true
cp -a "$FW/x/lib/firmware/rtl_bt/rtl8723bs_*" "$WORK/initrd-overlay/lib/firmware/rtl_bt/" 2>/dev/null || true
ls "$WORK/initrd-overlay/lib/firmware/rtl8723bs/" | head -3

INITRD_GZ=$(ls "$WORK/iso/install.amd/initrd.gz")
mkdir -p "$WORK/ird"
cd "$WORK/ird"
gzip -dc "$INITRD_GZ" | cpio -id --quiet 2>/dev/null || true
echo "initrd extracted: $(find . -maxdepth 2 -type d | head -5 | tr '\n' ' ')"
# drop the overlay's firmware into place (force — the cpio may leave odd states)
rm -rf "$WORK/ird/lib"
cp -a "$WORK/initrd-overlay/lib" "$WORK/ird/"
find . | cpio -o -H newc --quiet 2>/dev/null | gzip -9 > "$INITRD_GZ"
echo "initrd rebuilt with firmware: $(ls "$WORK/ird/lib/firmware/rtl8723bs" 2>/dev/null | wc -l) rtl8723bs files"

# ── 5. preseed the boot entries ────────────────────────────────────────────
info "preseeding boot entries"
PRESEED_ARGS="auto preseed/file=/cdrom/preseed.cfg console=tty0 console=ttyS0,115200"
# EFI boot (grub.cfg at ISO root for UEFI)
GRUB_CFG="$WORK/iso/boot/grub/grub.cfg"
if [ -f "$GRUB_CFG" ]; then
    sed -i "0,/^[[:space:]]*linux[[:space:]]/s//\tlinux\t/" "$GRUB_CFG" 2>/dev/null || true
    awk '
        { if (!done && $0 ~ /linux[ \t]+\/install\.amd\/vmlinuz/ && $0 !~ /preseed\/file=/) { print $0 " '"$PRESEED_ARGS"'"; done=1; next } print }
    ' "$GRUB_CFG" > "$GRUB_CFG.new" && mv "$GRUB_CFG.new" "$GRUB_CFG"
fi
# BIOS boot (isolinux)
for f in "$WORK/iso/isolinux/txt.cfg" "$WORK/iso/isolinux/gtk.cfg"; do
    [ -f "$f" ] || continue
    awk '
        { if (!done && $0 ~ /^[[:space:]]*append/ && $0 !~ /preseed\/file=/) { print $0 " preseed/file=/cdrom/preseed.cfg auto"; done=1; next } print }
    ' "$f" > "$f.new" && mv "$f.new" "$f"
done

# ── 6. drop the preseed + payload into the ISO tree ────────────────────────
cp -a "$SRC/build/preseed/preseed.cfg" "$WORK/iso/preseed.cfg"
cp -a "$WORK/payload/casperos" "$WORK/iso/casperos"

# ── 7. rebuild the ISO by REPLAYING the original boot setup ────────────────
# (a fresh mkisofs rebuild breaks the El Torito EFI entry; replay preserves
#  the original ISO's boot configuration exactly and just swaps files)
info "rebuilding the installer ISO (boot replay)"
xorriso -indev "$NETINST" -outdev "$OUT" \
    -boot_image any replay \
    -update "$WORK/iso/install.amd/initrd.gz" /install.amd/initrd.gz \
    -update "$WORK/iso/boot/grub/grub.cfg" /boot/grub/grub.cfg \
    -update "$WORK/iso/isolinux/txt.cfg" /isolinux/txt.cfg \
    -update "$WORK/iso/isolinux/gtk.cfg" /isolinux/gtk.cfg \
    -map "$WORK/iso/preseed.cfg" /preseed.cfg \
    -map "$WORK/payload/casperos" /casperos \
    2>&1 | tail -3
ok "installer ISO: $OUT ($(stat -c %s "$OUT") bytes)"
