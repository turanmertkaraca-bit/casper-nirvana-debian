#!/usr/bin/env bash
# End-to-end test of the CasperOS self-contained flash ISO under QEMU with
# 32-bit OVMF firmware (the tablet's exact boot path):
#   -cdrom test.iso  (flash env with a 200MB casper-n220.img embedded)
#        + SD-card target (the internal eMMC stand-in)
# The flasher must find the embedded image on the CD, flash /dev/mmcblk0,
# and the SD card must end up byte-identical to the embedded image.
#
# Usage: sudo ./flash-iso-test.sh <flash-root> <outdir>
set -euo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="${1:?usage: flash-iso-test.sh <flash-root> <outdir>}"
OUT="${2:-/tmp/flash-test}"

command -v qemu-system-x86_64 >/dev/null || { echo "qemu missing" >&2; exit 1; }
command -v grub-mkrescue >/dev/null || { echo "grub-mkrescue missing" >&2; exit 1; }

rm -rf "$OUT" && mkdir -p "$OUT"

# ── 32-bit OVMF firmware ───────────────────────────────────────────────────
FCODE=""; FVARS=""
for f in /usr/share/OVMF/OVMF_CODE.ia32.fd /usr/share/OVMF/OVMF32_CODE_4M.secboot.fd; do
    [ -f "$f" ] && FCODE="$f"
done
for f in /usr/share/OVMF/OVMF_VARS.ia32.fd /usr/share/OVMF/OVMF32_VARS_4M.fd; do
    [ -f "$f" ] && FVARS="$f"
done
if [ -z "$FCODE" ]; then
    curl -fsSL -o /tmp/ovmf-ia32.deb \
        http://deb.debian.org/debian/pool/main/e/edk2/ovmf-ia32_2022.11-6+deb12u2_all.deb
    mkdir -p /tmp/ovmf-i32x && dpkg-deb -x /tmp/ovmf-ia32.deb /tmp/ovmf-i32x
    FCODE=$(find /tmp/ovmf-i32x -name 'OVMF32_CODE*.fd' | head -1)
    FVARS=$(find /tmp/ovmf-i32x -name 'OVMF32_VARS*.fd' | head -1)
fi
[ -n "$FCODE" ] || { echo "FATAL: no IA32 OVMF firmware" >&2; exit 1; }
[ -n "$FVARS" ] || FVARS="$FCODE"
cp -f "$FVARS" "$OUT/vars.fd" 2>/dev/null || cp -f "$FCODE" "$OUT/vars.fd"
echo "firmware: $FCODE"

# ── build the self-contained test ISO (env + embedded 200MB image) ─────────
VMLINUZ=$(ls "$ROOT"/boot/vmlinuz-* | head -1)
INITRD=$(ls "$ROOT"/boot/initrd.img-* | head -1)
[ -n "$VMLINUZ" ] && [ -n "$INITRD" ] || { echo "no kernel/initrd in $ROOT" >&2; exit 1; }
ISOTREE="$OUT/isotree"
mkdir -p "$ISOTREE/boot/grub"
cp "$VMLINUZ" "$ISOTREE/boot/vmlinuz"
cp "$INITRD" "$ISOTREE/boot/initrd.img"
cat > "$ISOTREE/boot/grub/grub.cfg" <<'GRUB'
set timeout=3
set default=0
menuentry "CasperOS Auto-Flash" {
    linux /boot/vmlinuz root=/dev/ram0 rw quiet console=tty0 console=ttyS0,115200
    initrd /boot/initrd.img
}
GRUB
dd if=/dev/urandom of="$OUT/dummy.img" bs=1M count=200 status=none
ln "$OUT/dummy.img" "$ISOTREE/casper-n220.img"
grub-mkrescue -o "$OUT/test.iso" "$ISOTREE" -- -volid CASPER_FLASH -joliet on -iso_level 3 >/dev/null 2>&1
echo "test ISO: $OUT/test.iso ($(stat -c %s "$OUT/test.iso") bytes)"

# ── blank SD-card target (stands in for the internal eMMC) ─────────────────
truncate -s 2G "$OUT/target.disk"

# ── boot: the ISO as CD + SD-card target ───────────────────────────────────
qemu-system-x86_64 \
    -enable-kvm -machine q35 -m 1024 -cpu qemu64 \
    -cdrom "$OUT/test.iso" \
    -device sdhci-pci \
    -drive if=none,id=sd,file="$OUT/target.disk",format=raw \
    -device sd-card,drive=sd \
    -drive if=pflash,format=raw,readonly=on,file="$FCODE" \
    -drive if=pflash,format=raw,file="$OUT/vars.fd" \
    -chardev socket,id=ser,path="$OUT/ser.sock",server=on,wait=off \
    -serial chardev:ser \
    -display none -vga std -no-reboot \
    > "$OUT/qemu.log" 2>&1 &
QPID=$!

python3 "$SRC/test/qemu-wait.py" "$OUT/ser.sock" "CASPER_FLASH_DONE" 600 \
    > "$OUT/serial.log" 2>&1 || true

sleep 2
kill "$QPID" 2>/dev/null || true
wait "$QPID" 2>/dev/null || true

echo "--- serial log:"
cat "$OUT/serial.log"

# ── verdicts ───────────────────────────────────────────────────────────────
pass=0; fail=0
chk() { if [ "$1" = "1" ]; then pass=$((pass+1)); echo "  PASS: $2"; else fail=$((fail+1)); echo "  FAIL: $2"; fi; }
S="$OUT/serial.log"
chk "$(grep -q 'payload found on /dev/sr0' "$S" && echo 1 || echo 0)" "payload located INSIDE the ISO (sr0)"
chk "$(grep -q 'flashing /dev/mmcblk0' "$S" && echo 1 || echo 0)" "target = internal SD/eMMC (mmcblk0)"
chk "$(grep -q 'CASPER_FLASH_DONE' "$S" && echo 1 || echo 0)" "flash completed"
chk "$(grep -q 'FATAL' "$S" && echo 0 || echo 1)" "no fatal errors"

# byte-identical check: expected sha from the ISO's embedded image
mount -o loop,ro "$OUT/test.iso" "$OUT/iso-mnt" 2>/dev/null || mkdir -p "$OUT/iso-mnt"
sha256sum "$OUT/iso-mnt/casper-n220.img" 2>/dev/null | cut -d' ' -f1 > "$OUT/expected.sha" || true
umount "$OUT/iso-mnt" 2>/dev/null || true
dd if="$OUT/target.disk" bs=1M count=200 status=none 2>/dev/null | sha256sum | cut -d' ' -f1 > "$OUT/target.sha"
chk "$(cmp -s "$OUT/expected.sha" "$OUT/target.sha" && echo 1 || echo 0)" "SD card matches the embedded image"

echo ""
echo "  PASS: $pass   FAIL: $fail"
[ "$fail" = 0 ] || echo "SOME CHECKS FAILED — inspect $OUT/"
exit "$fail"
