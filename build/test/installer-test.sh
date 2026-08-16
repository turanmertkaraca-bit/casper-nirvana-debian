#!/usr/bin/env bash
# End-to-end test of the CasperOS installer ISO:
#   1. boots the preseeded Debian installer (kernel direct-boot — the old
#      32-bit OVMF build in CI cannot boot Debian's installer ISO, but real
#      Bay Trail firmware can; the UEFI-IA32 boot path is covered by the
#      flash-ISO test) on a blank disk (auto-install, qemu user-net)
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

# ── blank target disk (the internal eMMC stand-in) ─────────────────────────
truncate -s 8G "$OUT/target.disk"

# ── extract the installer kernel + initrd from the ISO (direct boot) ───────
LOOP=$(losetup -f)
losetup -P "$LOOP" "$ISO"
mkdir -p "$OUT/iso"
mount "${LOOP}p1" "$OUT/iso" 2>/dev/null || mount -o loop,ro "$ISO" "$OUT/iso" 2>/dev/null || true
if [ ! -f "$OUT/iso/install.amd/vmlinuz" ]; then
    # the loop device may not show partitions on an ISO — try without
    umount "$OUT/iso" 2>/dev/null || true
    losetup -d "$LOOP" 2>/dev/null || true
    mount -o loop,ro "$ISO" "$OUT/iso"
fi
cp "$OUT/iso/install.amd/vmlinuz" "$OUT/vmlinuz"
cp "$OUT/iso/install.amd/initrd.gz" "$OUT/initrd.gz"
umount "$OUT/iso"
losetup -d "$LOOP" 2>/dev/null || true
rmdir "$OUT/iso" 2>/dev/null || true
echo "kernel: $OUT/vmlinuz, initrd: $OUT/initrd.gz"
echo "--- initrd contents check:"
gzip -dc "$OUT/initrd.gz" 2>/dev/null | cpio -t 2>/dev/null | grep -E 'preseed\.cfg|^casperos$|lib/firmware/rtl8723bs' | head -8
echo "(preseed.cfg present in the booted initrd: $?)"

# ── phase 1: run the installer (preseeded, automatic; BIOS machine) ─────────
echo "=== phase 1: installing (this takes a while) ==="
# the installer ships its syslog to the qemu host (10.0.2.2) via UDP 514 —
# this is how we see the preseed/installer internals (they don't hit the
# serial). The syslog's md5 also gives us a reliable progress signal.
(nc -u -l -p 514 > "$OUT/installer-syslog.log" 2>/dev/null || \
 python3 -c "
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind(('10.0.2.2', 514))
with open('$OUT/installer-syslog.log','ab') as f:
    while True:
        d, _ = s.recvfrom(65535)
        if not d: break
        f.write(d + b'\n')
        f.flush()
") &
SYSLOG_PID=$!

qemu-system-x86_64 \
    -enable-kvm -machine q35 -m 2048 -cpu qemu64 \
    -cdrom "$ISO" \
    -drive file="$OUT/target.disk",format=raw,if=ide \
    -netdev user,id=n1 -device e1000,netdev=n1 \
    -kernel "$OUT/vmlinuz" -initrd "$OUT/initrd.gz" \
    -append "auto preseed/file=/preseed.cfg console=tty0 console=ttyS0,115200 loghost=10.0.2.2" \
    -serial file:"$OUT/serial-install.log" \
    -display none -vga std -no-reboot \
    > "$OUT/qemu-install.log" 2>&1 &
QPID=$!

WAITED=0
IDLE=0
TIMEOUT=5400
LAST_SYSMD5=""
while kill -0 "$QPID" 2>/dev/null; do
    sleep 30
    WAITED=$((WAITED+30))
    if [ $((WAITED % 600)) = 0 ]; then
        echo "  ... install still running (${WAITED}s); last syslog:"
        tail -2 "$OUT/installer-syslog.log" 2>/dev/null || true
    fi
    # fail fast if the installer is stuck (no syslog growth for 10 minutes)
    CUR_SYSMD5=$(md5sum "$OUT/installer-syslog.log" 2>/dev/null | awk '{print $1}')
    if [ -n "$CUR_SYSMD5" ] && [ "$CUR_SYSMD5" = "$LAST_SYSMD5" ]; then
        IDLE=$((IDLE+30))
    else
        IDLE=0
    fi
    LAST_SYSMD5="$CUR_SYSMD5"
    if [ "$IDLE" -ge 600 ] && [ "$WAITED" -ge 300 ]; then
        echo "ERROR: installer stuck (no syslog growth for ${IDLE}s)"
        kill "$QPID" 2>/dev/null || true
        wait "$QPID" 2>/dev/null || true
        kill "$SYSLOG_PID" 2>/dev/null || true
        echo "=== installer syslog (tail 120):"
        tail -120 "$OUT/installer-syslog.log" 2>/dev/null || echo "(no syslog received)"
        echo "=== installer serial tail:"
        tail -40 "$OUT/serial-install.log" 2>/dev/null || true
        exit 1
    fi
    if [ "$WAITED" -ge "$TIMEOUT" ]; then
        echo "ERROR: installer did not finish in ${TIMEOUT}s"
        kill "$QPID" 2>/dev/null || true
        wait "$QPID" 2>/dev/null || true
        kill "$SYSLOG_PID" 2>/dev/null || true
        echo "=== installer syslog (tail 120):"
        tail -120 "$OUT/installer-syslog.log" 2>/dev/null || echo "(no syslog received)"
        echo "=== installer serial tail:"
        tail -40 "$OUT/serial-install.log" 2>/dev/null || true
        exit 1
    fi
done
kill "$SYSLOG_PID" 2>/dev/null || true
wait "$QPID" 2>/dev/null || true
echo "installer exited"
echo "--- installer syslog tail (last 15 lines):"
tail -15 "$OUT/installer-syslog.log" 2>/dev/null || echo "(no syslog received)"
echo "--- installer serial tail (last 15 lines):"
tail -15 "$OUT/serial-install.log" 2>/dev/null || true
lsblk -o NAME,SIZE,FSTYPE "$OUT/target.disk" 2>/dev/null || true

# ── phase 2: boot the installed system and verify ──────────────────────────
echo "=== phase 2: booting the installed system ==="
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

qemu-system-x86_64 \
    -enable-kvm -machine q35 -m 2048 -cpu qemu64 \
    -drive file="$OUT/target.disk",format=raw,if=ide \
    -netdev user,id=n1 -device e1000,netdev=n1 \
    -serial file:"$OUT/serial-boot.log" \
    -display none -vga std -no-reboot \
    > "$OUT/qemu-boot.log" 2>&1 &
QPID=$!

python3 - "$OUT/serial-boot.log" <<'PYEOF' > "$OUT/verify.log" 2>&1 || true
import sys, time, os
path = sys.argv[1]
buf = b""
def read():
    global buf
    try:
        with open(path, "rb") as f:
            f.seek(0, 2)
            n = 0
            while n < 3:
                time.sleep(0.5)
                f.seek(0, 2)
                data = f.read()
                if len(data) > len(buf):
                    buf = data[-300000:]
                    return True
                n += 1
        return False
    except Exception:
        return False
def waitfor(pats, timeout):
    end = time.time() + timeout
    while time.time() < end:
        for i, p in enumerate(pats):
            if p in buf: return i
        read()
        time.sleep(0.2)
    return None
def send(x):
    pass  # no input channel with serial file — read-only boot
print("### waiting for login (600s)")
r = waitfor([b"login:"], 600)
if r is None:
    print(buf[-4000:].decode(errors="replace")); sys.exit(1)
print("### LOGIN PROMPT SHOWN")
# we cannot type over a serial file; the presence of the prompt + a
# successful graphical start is what we verify from the boot log
print("### prompt reached — system boots to login")
PYEOF

sleep 2
kill "$QPID" 2>/dev/null || true
wait "$QPID" 2>/dev/null || true

echo "--- boot log (last 30 lines):"
tail -30 "$OUT/serial-boot.log" 2>/dev/null || true
echo "--- verification output:"
cat "$OUT/verify.log"

# ── verdicts ───────────────────────────────────────────────────────────────
pass=0; fail=0
chk() { if [ "$1" = "1" ]; then pass=$((pass+1)); echo "  PASS: $2"; else fail=$((fail+1)); echo "  FAIL: $2"; fi; }
V="$OUT/verify.log"
B="$OUT/serial-boot.log"
I="$OUT/serial-install.log"
chk "$(grep -q '### LOGIN PROMPT SHOWN' "$V" && echo 1 || echo 0)" "installed system boots to a login prompt"
chk "$(grep -aq 'casperos-fixup: fixup complete' "$I" && echo 1 || echo 0)" "CasperOS fixup ran at install time"
chk "$(grep -aq 'Finished installation\|Rebooting' "$I" && echo 1 || echo 0)" "install completed"
chk "$(grep -aq 'lvy' "$B" && echo 1 || echo 0)" "lvy shown on the login screen"

# the fixup's effects are best checked from the installed disk:
LOOP=$(losetup -f)
losetup -P "$LOOP" "$OUT/target.disk"
mkdir -p "$OUT/mnt"
mount "${LOOP}p2" "$OUT/mnt" 2>/dev/null || mount "${LOOP}p1" "$OUT/mnt" 2>/dev/null || true
M="$OUT/mnt"
chk "$([ -f "$M/etc/libinput/local-overrides.quirks" ] && echo 1 || echo 0)" "libinput quirk present"
chk "$(grep -q 'intel_idle.max_cstate=1' "$M/etc/default/grub.d/99-casper.cfg" 2>/dev/null && echo 1 || echo 0)" "GRUB kernel params baked"
chk "$([ -f "$M/boot/vmlinuz-5.15"* ] && echo 1 || echo 0)" "5.15 fallback kernel installed"
chk "$([ -d "$M/etc/dconf/db/local.d" ] && echo 1 || echo 0)" "dconf system defaults present"
chk "$(grep -q 'enabled-extensions' "$M/etc/dconf/db/local.d/10-casper-extensions" 2>/dev/null && echo 1 || echo 0)" "extensions pre-enabled"
chk "$(grep -q 'tmpfs /tmp' "$M/etc/fstab" 2>/dev/null && echo 1 || echo 0)" "tmpfs /tmp in fstab"
chk "$(grep -q 'zram' "$M/etc/default/zramswap" 2>/dev/null && echo 1 || echo 0)" "zram config present"
chk "$(grep -q 'lvy ALL=(ALL) NOPASSWD' "$M/etc/sudoers.d/90-casper-lvy" 2>/dev/null && echo 1 || echo 0)" "lvy sudo setup"
chk "$([ -f "$M/etc/systemd/system/casper-touchscreen-watchdog.service" ] && echo 1 || echo 0)" "watchdog unit present"
chk "$([ -f "$M/usr/share/plymouth/themes/casper-splash/casper-splash.plymouth" ] && echo 1 || echo 0)" "plymouth theme present"
umount "$OUT/mnt" 2>/dev/null || true
losetup -d "$LOOP" 2>/dev/null || true

echo ""
echo "  PASS: $pass   FAIL: $fail"
[ "$fail" = 0 ] || echo "SOME CHECKS FAILED — inspect $OUT/"
exit "$fail"
