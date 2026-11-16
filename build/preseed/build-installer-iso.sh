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
    # Never hardcode debian-13.X.Y-...: the filename changes with every point
    # release, and a stale name turns into a 404 that curl -f reports as
    # exit 22 - which is exactly how this build used to die in one second.
    # SHA256SUMS lists whatever the current point release actually is.
    NETBASE="https://cdimage.debian.org/debian-cd/current/amd64/iso-cd"
    SUMS=$(curl -fsSL --retry 3 "$NETBASE/SHA256SUMS") \
        || { echo "could not fetch $NETBASE/SHA256SUMS" >&2; exit 1; }
    NETNAME=$(printf '%s\n' "$SUMS" | awk '$2 ~ /-netinst\.iso$/ {print $2; exit}')
    [ -n "$NETNAME" ] \
        || { echo "no *-netinst.iso listed in $NETBASE/SHA256SUMS" >&2; exit 1; }
    WANT=$(printf '%s\n' "$SUMS" | awk -v n="$NETNAME" '$2 == n {print $1; exit}')
    info "current netinst: $NETNAME"
    NETINST="$WORK/$NETNAME"
    curl -fsSL --retry 3 -o "$NETINST" "$NETBASE/$NETNAME" \
        || { echo "download failed: $NETBASE/$NETNAME" >&2; exit 1; }
    GOT=$(sha256sum "$NETINST" | cut -d' ' -f1)
    [ "$GOT" = "$WANT" ] \
        || { echo "sha256 mismatch for $NETNAME (got $GOT, expected $WANT)" >&2; exit 1; }
    ok "netinst verified against SHA256SUMS"
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

# ── 4. bundle RTL8723BS firmware + preseed + fix payload INTO the initrd ───
# (the initrd is always available — no /cdrom mount dependency for preseed)
info "injecting firmware + preseed + payload into the installer initrd"
FW="$WORK/fw"
mkdir -p "$FW"
# resolve the firmware-realtek pool path from the trixie non-free-firmware
# index; the firmware is a nicety (installer Wi-Fi) — never fatal
FWREL=""
curl -fsSL --retry 3 -o "$FW/nff.gz" \
    http://deb.debian.org/debian/dists/trixie/non-free-firmware/binary-all/Packages.gz 2>/dev/null || true
[ -s "$FW/nff.gz" ] && \
    gzip -dc "$FW/nff.gz" 2>/dev/null | \
    awk '/^Package: firmware-realtek$/{f=1} f&&/^Filename:/{print $2; exit}' > "$FW/fwrel.txt" || true
FWREL=$(cat "$FW/fwrel.txt" 2>/dev/null)
if [ -z "$FWREL" ]; then
    FWREL="pool/non-free-firmware/f/firmware-nonfree/firmware-realtek_20250410-2_all.deb"
fi
if curl -fsSL --retry 3 -o "$FW/firmware-realtek.deb" "http://deb.debian.org/debian/$FWREL"; then
    dpkg-deb -x "$FW/firmware-realtek.deb" "$FW/x"
    mkdir -p "$WORK/initrd-overlay/lib/firmware/rtl8723bs" "$WORK/initrd-overlay/lib/firmware/rtl_bt"
    cp -a "$FW/x/lib/firmware/rtl8723bs/." "$WORK/initrd-overlay/lib/firmware/rtl8723bs/" 2>/dev/null || true
    cp -a "$FW/x/lib/firmware/rtl_bt/rtl8723bs_*" "$WORK/initrd-overlay/lib/firmware/rtl_bt/" 2>/dev/null || true
    echo "firmware staged: $(ls "$WORK/initrd-overlay/lib/firmware/rtl8723bs/" 2>/dev/null | wc -l) rtl8723bs files"
else
    echo "WARNING: firmware-realtek download failed — installer Wi-Fi may not work on the tablet"
fi
# preseed + fix payload at the initrd root
cp -a "$SRC/build/preseed/preseed.cfg" "$WORK/initrd-overlay/preseed.cfg"
cp -a "$WORK/payload/casperos" "$WORK/initrd-overlay/casperos"

INITRD_GZ=$(ls "$WORK/iso/install.amd/initrd.gz")
mkdir -p "$WORK/ird"
cd "$WORK/ird"
gzip -dc "$INITRD_GZ" | cpio -id --quiet 2>/dev/null || true
echo "initrd extracted: $(find . -maxdepth 2 -type d | head -5 | tr '\n' ' ')"
# merge the overlay INTO the extracted initrd — never replace anything
mkdir -p lib/firmware
cp -a "$WORK/initrd-overlay/lib/firmware/." lib/firmware/
cp -a "$WORK/initrd-overlay/preseed.cfg" ./preseed.cfg
cp -a "$WORK/initrd-overlay/casperos" ./casperos
find . | cpio -o -H newc --quiet 2>/dev/null | gzip -9 > "$INITRD_GZ"
echo "initrd rebuilt: $(ls lib/firmware/rtl8723bs 2>/dev/null | wc -l) rtl8723bs files, preseed.cfg present"

# ── 5. preseed the ISO's own BIOS/x64 boot entries (preseed lives in initrd) ─
info "preseeding the ISO's own boot entries"
PRESEED_ARGS="auto preseed/file=/preseed.cfg console=tty0 console=ttyS0,115200"
GRUB_CFG="$WORK/iso/boot/grub/grub.cfg"
if [ -f "$GRUB_CFG" ]; then
    awk -v A="$PRESEED_ARGS" '
        { if (!done && $0 ~ /linux[ \t]+\/install\.amd\/vmlinuz/ && $0 !~ /preseed\/file=/) { print $0 " " A; done=1; next } print }
    ' "$GRUB_CFG" > "$GRUB_CFG.new" && mv "$GRUB_CFG.new" "$GRUB_CFG"
fi
for f in "$WORK/iso/isolinux/txt.cfg" "$WORK/iso/isolinux/gtk.cfg"; do
    [ -f "$f" ] || continue
    awk '{ if (!done && $0 ~ /^[[:space:]]*append/ && $0 !~ /preseed\/file=/) { print $0 " preseed/file=/preseed.cfg auto"; done=1; next } print }' \
        "$f" > "$f.new" && mv "$f.new" "$f"
done

# ── 6. drop the preseed + payload into the ISO tree ────────────────────────
cp -a "$SRC/build/preseed/preseed.cfg" "$WORK/iso/preseed.cfg"
cp -a "$WORK/payload/casperos" "$WORK/iso/casperos"

die() { echo -e "\033[1;31m✗\033[0m $*" >&2; exit 1; }

# ── 7. 32-bit UEFI boot — the reason stock netinst won't start on this tablet ─
# Debian's amd64 netinst ships ONLY EFI/BOOT/BOOTX64.EFI. Bay Trail firmware is
# IA32-only: it looks for EFI/BOOT/BOOTIA32.EFI, finds nothing, and falls back
# to the firmware menu. That is the entire "it won't boot from Ventoy" symptom.
# Ventoy >= 1.0.30 chainloads EFI/BOOT/BOOTIA32.EFI straight out of the ISO
# tree, so the file has to exist for the stick to work at all.
info "building 32-bit UEFI (IA32) boot loaders"

if ! command -v grub-mkstandalone >/dev/null 2>&1 || [ ! -d /usr/lib/grub/i386-efi ]; then
    info "installing GRUB ia32/x64 EFI tooling on the build host"
    apt-get update -qq || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        grub-efi-ia32-bin grub-efi-amd64-bin dosfstools >/dev/null 2>&1 || true
fi
command -v grub-mkstandalone >/dev/null 2>&1 \
    || die "grub-mkstandalone missing — install grub-efi-ia32-bin on the build host"
[ -d /usr/lib/grub/i386-efi ] \
    || die "no /usr/lib/grub/i386-efi — install grub-efi-ia32-bin on the build host"

EFI_CFG="$WORK/efi-grub.cfg"
cat > "$EFI_CFG" <<'EFICFG'
set timeout=30
insmod iso9660
insmod part_gpt
insmod part_msdos
insmod fat
insmod search_fs_file
insmod linux
insmod normal

menuentry "CasperOS installer - automatic, text mode (lowest RAM)" {
    search --no-floppy --file --set=root /install.amd/vmlinuz
    linux /install.amd/vmlinuz auto preseed/file=/preseed.cfg console=tty0 console=ttyS0,115200 ---
    initrd /install.amd/initrd.gz
}

menuentry "CasperOS installer - interactive text mode" {
    search --no-floppy --file --set=root /install.amd/vmlinuz
    linux /install.amd/vmlinuz console=tty0 console=ttyS0,115200 ---
    initrd /install.amd/initrd.gz
}
EFICFG

EFI_MODS="iso9660 part_gpt part_msdos fat search search_fs_file search_label linux echo normal all_video gfxterm font serial"
mkdir -p "$WORK/efi/EFI/BOOT"

build_efi() {   # $1 = grub target, $2 = module dir, $3 = output file
    grub-mkstandalone -O "$1" -d "$2" \
        --modules="$EFI_MODS" --install-modules="$EFI_MODS" \
        -o "$3" "boot/grub/grub.cfg=$EFI_CFG"
}

build_efi i386-efi /usr/lib/grub/i386-efi "$WORK/efi/EFI/BOOT/BOOTIA32.EFI" \
    || die "could not build BOOTIA32.EFI"
ok "BOOTIA32.EFI built ($(stat -c %s "$WORK/efi/EFI/BOOT/BOOTIA32.EFI") bytes)"

# The 64-bit loader is built from the same config so ONE FAT image serves both
# firmwares - each looks up its own arch's filename and nothing else.
if [ -d /usr/lib/grub/x86_64-efi ]; then
    if build_efi x86_64-efi /usr/lib/grub/x86_64-efi "$WORK/efi/EFI/BOOT/BOOTX64.EFI"; then
        ok "BOOTX64.EFI built"
    else
        echo "note: x86_64 loader not built (32-bit boot is unaffected)"
    fi
fi

# ── 8. FAT image holding the EFI loaders (the El Torito EFI payload) ────────
EFI_IMG="$WORK/efi.img"
rm -f "$EFI_IMG"
dd if=/dev/zero of="$EFI_IMG" bs=1M count=16 status=none
mkfs.vfat -F 16 -n CASPEREFI "$EFI_IMG" >/dev/null || die "mkfs.vfat failed (need dosfstools)"
mkdir -p "$WORK/efimnt"
mount -o loop "$EFI_IMG" "$WORK/efimnt" || die "could not mount the FAT EFI image"
mkdir -p "$WORK/efimnt/EFI/BOOT"
cp -a "$WORK/efi/EFI/BOOT/." "$WORK/efimnt/EFI/BOOT/"
cp -a "$EFI_CFG" "$WORK/efimnt/EFI/BOOT/grub.cfg"
sync
umount "$WORK/efimnt"

# Also in the ISO tree itself: this is the exact path Ventoy chainloads.
# Reuse Debian's own EFI directory if it shipped one under a different case —
# creating a second /EFI next to an existing /efi makes the ISO9660 level
# collide and mkisofs aborts.
EFI_TREE=""
for cand in "$WORK/iso/EFI/BOOT" "$WORK/iso/efi/boot" "$WORK/iso/Efi/Boot"; do
    [ -d "$cand" ] && { EFI_TREE="$cand"; break; }
done
[ -n "$EFI_TREE" ] || EFI_TREE="$WORK/iso/EFI/BOOT"
mkdir -p "$EFI_TREE" "$WORK/iso/boot/grub"
cp -a "$WORK/efi/EFI/BOOT/BOOTIA32.EFI" "$EFI_TREE/BOOTIA32.EFI"
[ -f "$WORK/efi/EFI/BOOT/BOOTX64.EFI" ] && \
    cp -a "$WORK/efi/EFI/BOOT/BOOTX64.EFI" "$EFI_TREE/BOOTX64.EFI"
cp -a "$EFI_IMG" "$WORK/iso/boot/grub/efi.img"

# ── 9. rebuild the ISO with BOTH firmware paths ────────────────────────────
# BIOS: reuse Debian's own El Torito loader from the extracted tree, so the
# stick still boots on machines without UEFI. EFI: our image, which carries
# the ia32 loader the tablet needs.
BIOS_IMG=""
BIOS_KIND=""
if [ -f "$WORK/iso/boot/grub/i386-pc/eltorito.img" ]; then
    BIOS_IMG="boot/grub/i386-pc/eltorito.img"; BIOS_KIND="grub"
elif [ -f "$WORK/iso/isolinux/isolinux.bin" ]; then
    BIOS_IMG="isolinux/isolinux.bin"; BIOS_KIND="isolinux"
fi

OUT_TMP="$OUT.tmp"
if [ "$BIOS_KIND" = "grub" ]; then
    info "rebuilding ISO: BIOS (GRUB eltorito) + IA32/x64 EFI"
    xorriso -as mkisofs -r -J -joliet-long -l \
        -b "$BIOS_IMG" -no-emul-boot -boot-load-size 4 -boot-info-table --grub2-boot-info \
        -eltorito-alt-boot -e boot/grub/efi.img -no-emul-boot \
        -V "CasperOS 13 amd64" \
        -o "$OUT_TMP" "$WORK/iso" 2>&1 | tail -3 \
        || die "xorriso rebuild failed (BIOS grub + EFI)"
elif [ "$BIOS_KIND" = "isolinux" ]; then
    info "rebuilding ISO: BIOS (isolinux) + IA32/x64 EFI"
    xorriso -as mkisofs -r -J -joliet-long -l \
        -b "$BIOS_IMG" -c isolinux/boot.cat -no-emul-boot -boot-load-size 4 -boot-info-table \
        -eltorito-alt-boot -e boot/grub/efi.img -no-emul-boot \
        -V "CasperOS 13 amd64" \
        -o "$OUT_TMP" "$WORK/iso" 2>&1 | tail -3 \
        || die "xorriso rebuild failed (isolinux + EFI)"
else
    info "rebuilding ISO: EFI only (netinst shipped no BIOS loader)"
    xorriso -as mkisofs -r -J -joliet-long -l \
        -eltorito-alt-boot -e boot/grub/efi.img -no-emul-boot \
        -V "CasperOS 13 amd64" \
        -o "$OUT_TMP" "$WORK/iso" 2>&1 | tail -3 \
        || die "xorriso rebuild failed (EFI only)"
fi
mv -f "$OUT_TMP" "$OUT"

# ── 10. assert the tablet can actually boot the result ─────────────────────
B32=$(xorriso -indev "$OUT" -find / -name 'BOOTIA32.EFI' 2>/dev/null | tr -d "'" | head -1)
[ -n "$B32" ] || die "BOOTIA32.EFI missing from the finished ISO — 32-bit UEFI would fail"
xorriso -osirrox on -indev "$OUT" -extract "$B32" /tmp/bootia32-check.efi >/dev/null 2>&1 \
    || die "could not extract BOOTIA32.EFI ($B32) from the finished ISO"
MACHINE=$(bash "$SRC/build/tools/pe-machine.sh" /tmp/bootia32-check.efi 2>/dev/null) || MACHINE="unreadable"
[ "$MACHINE" = "014c" ] \
    || die "BOOTIA32.EFI has PE machine 0x$MACHINE, expected 0x014c (IA-32)"
rm -f /tmp/bootia32-check.efi
ok "verified: EFI/BOOT/BOOTIA32.EFI present and PE32 (IA-32)"
ok "installer ISO: $OUT ($(stat -c %s "$OUT") bytes)"
