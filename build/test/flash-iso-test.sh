#!/usr/bin/env bash
# End-to-end test of the CasperOS auto-flash ISO under QEMU with 32-bit
# OVMF firmware (exactly the tablet's boot path):
#   -cdrom casper-flash.iso   +  payload disk (vfat, holds casper-n220.img)
#                            +  blank target disk
# Asserts the target disk ends up byte-identical to the payload.
#
# Usage: sudo ./flash-iso-test.sh [flash.iso] [outdir]
set -euo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
ISO="${1:-/tmp/casper-flash.iso}"
OUT="${2:-/tmp/flash-test}"

[ -f "$ISO" ] || { echo "no ISO at $ISO" >&2; exit 1; }
command -v qemu-system-x86_64 >/dev/null || { echo "qemu missing" >&2; exit 1; }

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

# ── payload disk: 300MB, msdos partition table + exfat partition ───────────
# (exFAT = the real Ventoy stick format; vfat is quirky in this minimal env)
truncate -s 300M "$OUT/payload.disk"
LOOP=$(losetup -f)
losetup "$LOOP" "$OUT/payload.disk"
parted -s "$LOOP" mklabel msdos mkpart primary fat32 1MiB 100%
partprobe "$LOOP" 2>/dev/null || true
sleep 1
P1="${LOOP}p1"
[ -e "$P1" ] || P1="${LOOP}1"
mkfs.vfat -F 32 -n PAYLOAD "$P1" >/dev/null
# write into the FAT without mounting (mtools)
dd if=/dev/urandom of="$OUT/casper-n220.img" bs=1M count=200 status=none
mcopy -i "$P1" "$OUT/casper-n220.img" ::casper-n220.img
echo "payload partition contents (host, via mdir):"
mdir -i "$P1" | tail -5
losetup -d "$LOOP"
echo "payload disk size: $(stat -c %s "$OUT/payload.disk")"

# ── blank target disk ──────────────────────────────────────────────────────
truncate -s 2G "$OUT/target.disk"

# ── boot the ISO with both disks attached ──────────────────────────────────
qemu-system-x86_64 \
    -enable-kvm -machine q35 -m 1024 -cpu qemu64 \
    -cdrom "$ISO" \
    -drive file="$OUT/payload.disk",format=raw,if=ide \
    -drive file="$OUT/target.disk",format=raw,if=ide \
    -drive if=pflash,format=raw,readonly=on,file="$FCODE" \
    -drive if=pflash,format=raw,file="$OUT/vars.fd" \
    -chardev socket,id=ser,path="$OUT/ser.sock",server=on,wait=off \
    -serial chardev:ser \
    -monitor tcp:127.0.0.1:45456,server=on,wait=off \
    -display none -vga std -no-reboot \
    > "$OUT/qemu.log" 2>&1 &
QPID=$!

python3 "$SRC/test/qemu-wait.py" "$OUT/ser.sock" "flash complete" 600 \
    > "$OUT/serial.log" 2>&1 || true

# capture what the display shows (init messages land on tty0)
exec 3<>/dev/tcp/127.0.0.1/45456 2>/dev/null || true
echo "screendump $OUT/screen.ppm" >&3 2>/dev/null || true
sleep 1
exec 3>&- 2>/dev/null || true

sleep 2
kill "$QPID" 2>/dev/null || true
wait "$QPID" 2>/dev/null || true

echo "--- serial log:"
cat "$OUT/serial.log"
echo "--- screen capture: $(ppm_visible "$OUT/screen.ppm" 2>/dev/null || echo none)"

# ── verdicts ───────────────────────────────────────────────────────────────
pass=0; fail=0
chk() { if [ "$1" = "1" ]; then pass=$((pass+1)); echo "  PASS: $2"; else fail=$((fail+1)); echo "  FAIL: $2"; fi; }
chk "$(grep -q 'casper-flash: payload found' "$OUT/serial.log" && echo 1 || echo 0)" "payload located on source disk"
chk "$(grep -q 'flashing /dev/sdb' "$OUT/serial.log" && echo 1 || echo 0)" "target selected (the other disk)"
chk "$(grep -q 'flash complete' "$OUT/serial.log" && echo 1 || echo 0)" "flash completed"
chk "$(grep -q 'FATAL' "$OUT/serial.log" && echo 0 || echo 1)" "no fatal errors"

# target first 200MB must be byte-identical to the payload
dd if="$OUT/target.disk" bs=1M count=200 status=none 2>/dev/null | sha256sum | cut -d' ' -f1 > "$OUT/target.sha"
sha256sum "$OUT/casper-n220.img" | cut -d' ' -f1 > "$OUT/expected.sha"
chk "$(cmp -s "$OUT/target.sha" "$OUT/expected.sha" && echo 1 || echo 0)" "target disk matches payload image"

echo ""
echo "  PASS: $pass   FAIL: $fail"
[ "$fail" = 0 ] || echo "SOME CHECKS FAILED — inspect $OUT/"
exit "$fail"
