#!/usr/bin/env bash
# End-to-end test of the CasperOS installer ISO under QEMU with 32-bit OVMF:
#   1. boots the preseeded Debian installer on a blank disk (auto-install,
#      network via qemu user-net)
#   2. after the installer reboots, boots the INSTALLED system from that disk
#   3. verifies the CasperOS fixes are in place (login as lvy, cmdline,
#      services, kernels, dconf)
#
# Usage: sudo ./installer-test.sh <installer.iso> <outdir>
set -euo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
ISO="${1:?usage: installer-test.sh <installer.iso> <outdir>}"
OUT="${2:-/tmp/installer-test}"

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

# ── blank target disk (the internal eMMC stand-in) ─────────────────────────
truncate -s 8G "$OUT/target.disk"

# ── phase 1: run the installer (preseeded, automatic) ──────────────────────
echo "=== phase 1: installing (this takes a while) ==="
cp -f "$FVARS" "$OUT/vars-install.fd" 2>/dev/null || cp -f "$FCODE" "$OUT/vars-install.fd"
qemu-system-x86_64 \
    -enable-kvm -machine q35 -m 2048 -cpu qemu64 \
    -cdrom "$ISO" \
    -drive file="$OUT/target.disk",format=raw,if=ide \
    -netdev user,id=n1 -device e1000,netdev=n1 \
    -drive if=pflash,format=raw,readonly=on,file="$FCODE" \
    -drive if=pflash,format=raw,file="$OUT/vars-install.fd" \
    -chardev socket,id=ser,path="$OUT/ser-install.sock",server=on,wait=off \
    -serial chardev:ser \
    -display none -vga std -no-reboot \
    > "$OUT/qemu-install.log" 2>&1 &
QPID=$!

# wait for the installer to finish (it reboots; -no-reboot makes qemu exit)
wait "$QPID" 2>/dev/null || true
echo "installer exited (code $?)"
echo "--- installer serial tail:"
tail -c 4000 "$OUT/ser-install.sock" 2>/dev/null || true

# capture the installer log for diagnostics (via a quick re-run trick is
# not possible — instead the serial socket file is empty; use the log)
grep -a -iE 'Finished|preseed|error|failed' "$OUT/qemu-install.log" | tail -5 || true

# make sure the disk actually got partitioned + installed
lsblk -o NAME,SIZE,FSTYPE "$OUT/target.disk" 2>/dev/null || true

# ── phase 2: boot the installed system and verify ──────────────────────────
echo "=== phase 2: booting the installed system ==="
# add console=ttyS0 to the installed GRUB's default entry (test only)
LOOP=$(losetup -f)
losetup -P "$LOOP" "$OUT/target.disk"
mkdir -p "$OUT/mnt"
mount "${LOOP}p2" "$OUT/mnt" 2>/dev/null || mount "${LOOP}p1" "$OUT/mnt" 2>/dev/null || true
if [ -f "$OUT/mnt/boot/grub/grub.cfg" ]; then
    awk '
        { if (!done && $0 ~ /linux[ \t]+\/boot\/vmlinuz-/ && $0 !~ /console=ttyS0/) { print $0 " console=ttyS0,115200"; done=1; next } print }
    ' "$OUT/mnt/boot/grub/grub.cfg" > "$OUT/mnt/boot/grub/grub.cfg.new"
    mv "$OUT/mnt/boot/grub/grub.cfg.new" "$OUT/mnt/boot/grub/grub.cfg"
    echo "grub.cfg edited for serial"
else
    echo "WARN: no grub.cfg on the installed disk"
fi
umount "$OUT/mnt" 2>/dev/null || true
losetup -d "$LOOP" 2>/dev/null || true

cp -f "$FVARS" "$OUT/vars-boot.fd" 2>/dev/null || cp -f "$FCODE" "$OUT/vars-boot.fd"
qemu-system-x86_64 \
    -enable-kvm -machine q35 -m 2048 -cpu qemu64 \
    -drive file="$OUT/target.disk",format=raw,if=ide \
    -netdev user,id=n1 -device e1000,netdev=n1 \
    -drive if=pflash,format=raw,readonly=on,file="$FCODE" \
    -drive if=pflash,format=raw,file="$OUT/vars-boot.fd" \
    -chardev socket,id=ser,path="$OUT/ser-boot.sock",server=on,wait=off \
    -serial chardev:ser \
    -monitor tcp:127.0.0.1:45457,server=on,wait=off \
    -display none -vga std -no-reboot \
    > "$OUT/qemu-boot.log" 2>&1 &
QPID=$!

python3 - "$OUT/ser-boot.sock" <<'PYEOF' > "$OUT/verify.log" 2>&1 || true
import socket, sys, time
sock = sys.argv[1]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
deadline = time.time() + 120
while True:
    try:
        s.connect(sock); break
    except OSError:
        if time.time() > deadline: print("FATAL: no serial"); sys.exit(1)
        time.sleep(1)
s.settimeout(0.25)
buf = b""
def waitfor(pats, timeout):
    end = time.time() + timeout
    while time.time() < end:
        for i, p in enumerate(pats):
            if p in buf: return i
        try:
            d = s.recv(8192)
            if d: buf_ = d
            else: buf_ = b""
        except socket.timeout: buf_ = b""
        global buf
        if buf_:
            buf = (buf + buf_)[-300000:]
        time.sleep(0.1)
    return None
def send(x):
    s.sendall((x + "\r").encode())
print("### waiting for login (600s)")
r = waitfor([b"login:"], 600)
if r is None:
    print(buf[-4000:].decode(errors="replace")); sys.exit(1)
send("lvy")
r = waitfor([b"Password:", b"Parola:", b"~$"], 60)
if r is None:
    print(buf[-4000:].decode(errors="replace")); sys.exit(1)
if r in (0,1):
    send("")
    if waitfor([b"~$"], 60) is None:
        print(buf[-4000:].decode(errors="replace")); sys.exit(1)
print("### LOGIN OK")
for cmd in [
    "uname -r",
    "cat /proc/cmdline",
    "cat /proc/swaps",
    "systemctl is-active earlyoom NetworkManager 2>/dev/null | tr '\\n' ' '; echo",
    "ls /boot/vmlinuz-*",
    "ls /etc/dconf/db/local >/dev/null 2>&1 && echo DCONF_DB_OK",
    "cat /etc/dconf/db/local.d/10-casper-extensions 2>/dev/null | head -2",
    "grep -i theme /etc/plymouth/plymouthd.conf",
    "echo ===VERIFY-END===",
]:
    before = len(buf)
    send(cmd)
    time.sleep(2.5)
    seg = buf[before:].decode(errors="replace")
    print(f"### CMD: {cmd}")
    print(seg.strip())
PYEOF

sleep 2
kill "$QPID" 2>/dev/null || true
wait "$QPID" 2>/dev/null || true

echo "--- verification output:"
cat "$OUT/verify.log"

# ── verdicts ───────────────────────────────────────────────────────────────
pass=0; fail=0
chk() { if [ "$1" = "1" ]; then pass=$((pass+1)); echo "  PASS: $2"; else fail=$((fail+1)); echo "  FAIL: $2"; fi; }
V="$OUT/verify.log"
chk "$(grep -q '### LOGIN OK' "$V" && echo 1 || echo 0)" "login as lvy (null password)"
chk "$(grep -qE '^6\.12' "$V" && echo 1 || echo 0)" "installed kernel 6.12"
chk "$(grep -q 'intel_idle.max_cstate=1' "$V" && echo 1 || echo 0)" "CasperOS kernel params in cmdline"
chk "$(grep -q 'mitigations=off' "$V" && echo 1 || echo 0)" "mitigations=off"
chk "$(grep -q 'zram' "$V" && echo 1 || echo 0)" "zram swap active"
chk "$(grep -q '^active$' "$V" && echo 1 || echo 0)" "earlyoom + NetworkManager active"
chk "$(grep -q 'vmlinuz-5.15' "$V" && echo 1 || echo 0)" "5.15 fallback kernel installed"
chk "$(grep -q 'DCONF_DB_OK' "$V" && echo 1 || echo 0)" "dconf system db compiled"
chk "$(grep -q 'enabled-extensions' "$V" && echo 1 || echo 0)" "extensions pre-enabled"
chk "$(grep -qi 'casper-splash' "$V" && echo 1 || echo 0)" "plymouth theme set"

echo ""
echo "  PASS: $pass   FAIL: $fail"
[ "$fail" = 0 ] || echo "SOME CHECKS FAILED — inspect $OUT/"
exit "$fail"
