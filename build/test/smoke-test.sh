#!/usr/bin/env bash
# CasperOS KVM boot smoke test — boots the finished image under QEMU/KVM with
# 32-bit OVMF firmware (exactly what the tablet has), verifies the default
# (6.12) kernel via GRUB and the fallback (5.15) kernel via direct boot with
# the exact cmdline GRUB would pass, runs an assertion battery over the
# serial console, and captures screenshots.
#
# Usage: smoke-test.sh --img <file.img> --out <dir>
set -euo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"

IMG=""; OUT="/tmp/casper-test"
while [ $# -gt 0 ]; do
    case "$1" in --img) IMG="$2"; shift 2;; --out) OUT="$2"; shift 2;; *) shift;; esac
done
[ -n "$IMG" ] && [ -f "$IMG" ] || { echo "usage: $0 --img FILE" >&2; exit 1; }
command -v qemu-system-x86_64 >/dev/null || { echo "qemu-system-x86_64 missing" >&2; exit 1; }
[ -e /dev/kvm ] || echo "WARN: no KVM — running TCG (much slower)"

rm -rf "$OUT" && mkdir -p "$OUT"
cp --sparse=always "$IMG" "$OUT/test.img"

# ── 32-bit OVMF firmware (Bay Trail = IA32 UEFI) ───────────────────────────
FCODE=""; FVARS=""
for f in /usr/share/OVMF/OVMF_CODE.ia32.fd /usr/share/OVMF/OVMF32_CODE_4M.secboot.fd; do
    [ -f "$f" ] && FCODE="$f"
done
for f in /usr/share/OVMF/OVMF_VARS.ia32.fd /usr/share/OVMF/OVMF32_VARS_4M.fd; do
    [ -f "$f" ] && FVARS="$f"
done
if [ -z "$FCODE" ]; then
    echo "no OVMF ia32 firmware — downloading Debian bookworm ovmf-ia32"
    curl -fsSL -o /tmp/ovmf-ia32.deb \
        http://deb.debian.org/debian/pool/main/e/edk2/ovmf-ia32_2022.11-6+deb12u2_all.deb
    mkdir -p /tmp/ovmf-i32x && dpkg-deb -x /tmp/ovmf-ia32.deb /tmp/ovmf-i32x
    FCODE=$(find /tmp/ovmf-i32x -name 'OVMF32_CODE*.fd' | head -1)
    FVARS=$(find /tmp/ovmf-i32x -name 'OVMF32_VARS*.fd' | head -1)
fi
[ -n "$FCODE" ] || { echo "FATAL: no IA32 OVMF firmware found" >&2; exit 1; }
[ -n "$FVARS" ] || FVARS="$FCODE"
echo "firmware: $FCODE + $FVARS"

# ── test.img manipulation (loop-mount the root partition) ──────────────────
LOOP=""
mnt_test_img() {
    LOOP=$(losetup -f)
    losetup -P "$LOOP" "$OUT/test.img"
    mkdir -p "$OUT/mnt"
    mount "${LOOP}p2" "$OUT/mnt"
}
umnt_test() {
    umount "$OUT/mnt" 2>/dev/null || true
    losetup -d "$LOOP" 2>/dev/null || true
}

screendump() { # port file
    exec 3<>/dev/tcp/127.0.0.1/"$1" 2>/dev/null || return 1
    echo "screendump $2" >&3
    sleep 1
    exec 3>&-
}

# PPM check: report size + mean brightness; exit 0 if it shows content
ppm_visible() {
    python3 - "$1" <<'PYEOF'
import sys
p = sys.argv[1]
try:
    with open(p, "rb") as f:
        hdr = b""
        while True:
            c = f.read(1)
            if not c:
                break
            hdr += c
            if hdr.endswith(b"\n") and hdr.count(b"\n") == 3:
                break
        parts = [t for t in hdr.split() if t not in (b"",) and not t.startswith(b"#")]
        w, h = int(parts[1]), int(parts[2])
        data = f.read(w * h * 3)
    s = 0; n = 0
    for i in range(0, len(data), 3 * 131):
        s += data[i] + data[i+1] + data[i+2]; n += 3
    mean = s / n if n else 0
    print(f"{p}: {w}x{h} mean={mean:.1f}")
    sys.exit(0 if mean > 5 else 1)
except Exception as e:
    print(f"{p}: error {e}")
    sys.exit(1)
PYEOF
}

# ── static grub.cfg assertions on the actual image ─────────────────────────
static_checks() {
    mnt_test_img
    local cfg="$OUT/mnt/boot/grub/grub.cfg"
    {
        if grep -q 'vmlinuz-5\.15.*i2c_designware.disable_pm=1' "$cfg"; then
            echo "STATIC_OK 5.15 entry carries legacy I2C params"
        else
            echo "STATIC_FAIL 5.15 entry missing legacy I2C params"
        fi
        if grep -q 'vmlinuz-6\.' "$cfg" && ! grep -q 'vmlinuz-6\..*i2c_designware' "$cfg"; then
            echo "STATIC_OK 6.12 entry has no legacy I2C params"
        else
            echo "STATIC_FAIL 6.12 entry wrongly carries legacy I2C params"
        fi
        if grep -q 'gnulinux-5\.15' "$cfg"; then
            echo "STATIC_OK 5.15 GRUB entry present"
        else
            echo "STATIC_FAIL no 5.15 GRUB entry"
        fi
    } > "$OUT/static-results.txt"
    cat "$OUT/static-results.txt"
    umnt_test
}

# boot 1 (default): append console=ttyS0 to the 6.12 entry
prep_boot1() {
    mnt_test_img
    awk '
        { if (!done && $0 ~ /linux[ \t]+\/boot\/vmlinuz-6\./ && $0 !~ /console=ttyS0/) { print $0 " console=ttyS0,115200"; done=1; next } print }
    ' "$OUT/mnt/boot/grub/grub.cfg" > "$OUT/mnt/boot/grub/grub.cfg.new"
    mv "$OUT/mnt/boot/grub/grub.cfg.new" "$OUT/mnt/boot/grub/grub.cfg"
    umnt_test
}

# boot 2 (fallback): write a minimal grub.cfg that boots the 5.15 kernel
# directly, using the exact postprocessed cmdline from the real grub.cfg.
# (The device user reaches this entry via Shift → Advanced options; here we
# test GRUB + kernel + initramfs + params without menu navigation.)
prep_boot2() {
    mnt_test_img
    local cfg="$OUT/mnt/boot/grub/grub.cfg" line uuid cmdline
    line=$(awk '/linux[ \t]+\/boot\/vmlinuz-5\.15/ {print; exit}' "$cfg")
    [ -n "$line" ] || { echo "FATAL: no 5.15 linux line in grub.cfg"; umnt_test; exit 1; }
    echo "$line" | grep -q 'i2c_designware.disable_pm=1' \
        || { echo "FATAL: 5.15 grub.cfg line missing legacy I2C params"; umnt_test; exit 1; }
    uuid=$(echo "$line" | grep -oE 'UUID=[0-9a-f-]{36}' | head -1 | cut -d= -f2)
    cmdline=$(echo "$line" | awk '{for(i=1;i<=NF;i++) if ($i ~ /^root=/) { print substr($0, index($0,$i)); exit }}')
    cmdline="$cmdline console=ttyS0,115200 earlyprintk=serial,ttyS0,115200"
    [ -n "$uuid" ] || { echo "FATAL: no root UUID in 5.15 grub line"; umnt_test; exit 1; }
    {
        echo 'set timeout=0'
        echo 'set default=0'
        echo 'serial --speed=115200 --unit=0'
        echo 'terminal_input serial'
        echo 'terminal_output serial'
        echo "menuentry 'CasperOS 5.15 test' {"
        echo '    insmod part_gpt'
        echo '    insmod ext2'
        echo "    search --no-floppy --fs-uuid --set=root $uuid"
        echo "    linux /boot/vmlinuz-5.15.165-0515165-generic $cmdline"
        echo '    initrd /boot/initrd.img-5.15.165-0515165-generic'
        echo '}'
    } > "$OUT/mnt/boot/grub/grub.cfg"
    umnt_test
    echo "5.15 boot cmdline: $cmdline"
}

# ── assertion battery (run as lvy over serial via bash -s) ─────────────────
cat > "$OUT/selftest.sh" <<'SELFTEST'
echo ===SELFTEST-START===
echo ---UNAME
uname -r
echo ---CMDLINE
cat /proc/cmdline
echo ---EFI
ls /sys/firmware/efi >/dev/null 2>&1 && echo UEFI_OK || echo UEFI_MISSING
echo ---SERVICES
for s in NetworkManager earlyoom zramswap casper-touchscreen-watchdog casper-cpu-governor power-profiles-daemon; do
    echo "svc $s = $(systemctl is-active $s 2>/dev/null)"
done
echo ---SWAP
cat /proc/swaps
echo ---THP
cat /sys/kernel/mm/transparent_hugepage/enabled
echo ---DCONF
ls /etc/dconf/db/local >/dev/null 2>&1 && echo DCONF_DB_OK
grep -c screen-keyboard-enabled /etc/dconf/db/local.d/00-casper-desktop
cat /etc/dconf/db/local.d/10-casper-extensions
ls /var/lib/gdm3/.config/monitors.xml /home/lvy/.config/monitors.xml 2>/dev/null
grep -c '<rotation>right</rotation>' /var/lib/gdm3/.config/monitors.xml
echo ---PLYMOUTH
grep -i theme /etc/plymouth/plymouthd.conf
echo ---BOOTFILES
ls /boot/vmlinuz-* /boot/initrd.img-*
ls /boot/grub/i386-efi >/dev/null 2>&1 && echo GRUB_IA32_OK || echo GRUB_IA32_MISSING
find /boot/efi -name '*.efi' | head -5
file /boot/efi/EFI/BOOT/BOOTIA32.EFI 2>/dev/null || true
echo ---GOV_JOURNAL
journalctl -q -u casper-cpu-governor.service -b --no-pager --no-hostname | tail -5
echo ---JOURNAL_ERR
journalctl -q --no-pager -p err -b --no-hostname | tail -8
echo ---ANALYZE
systemd-analyze time | tail -1
echo ===SELFTEST-END===
SELFTEST

# ── boot one configuration ─────────────────────────────────────────────────
run_boot() {
    local name="$1" monport="$2"
    echo "=== boot: $name ==="
    "prep_$name"
    cp -f "$FVARS" "$OUT/vars-$name.fd" 2>/dev/null || cp -f "$FCODE" "$OUT/vars-$name.fd"
    # qemu64: conservative CPU model — the 5.15 kernel must boot on it
    # (a modern host CPU exposes features 5.15 may not know about)
    qemu-system-x86_64 \
        -enable-kvm -machine q35 -m 2048 -cpu qemu64 \
        -drive file="$OUT/test.img",format=raw,if=ide \
        -drive if=pflash,format=raw,readonly=on,file="$FCODE" \
        -drive if=pflash,format=raw,file="$OUT/vars-$name.fd" \
        -chardev socket,id=ser,path="$OUT/ser-$name.sock",server=on,wait=off \
        -serial chardev:ser \
        -monitor tcp:127.0.0.1:"$monport",server=on,wait=off \
        -display none -vga std -no-reboot \
        > "$OUT/qemu-$name.log" 2>&1 &
    local qpid=$!

    sleep 15
    screendump "$monport" "$OUT/early-$name.ppm" 2>/dev/null || true

    python3 "$SRC/test/qemu-serial.py" "$OUT/ser-$name.sock" 900 \
        > "$OUT/serial-$name.log" 2>&1 || true

    screendump "$monport" "$OUT/gdm-$name.ppm" 2>/dev/null || true
    sleep 2
    kill "$qpid" 2>/dev/null || true
    wait "$qpid" 2>/dev/null || true
    if grep -q '### LOGIN OK' "$OUT/serial-$name.log"; then
        echo "--- $name selftest output:"
        awk '/===SELFTEST-START===/,/===SELFTEST-END===/' "$OUT/serial-$name.log" | grep -v 'SELFTEST-\(START\|END\)' || true
    fi
    echo "--- $name serial tail:"
    tail -12 "$OUT/serial-$name.log" 2>/dev/null || true
    echo "--- $name screenshots:"
    ppm_visible "$OUT/gdm-$name.ppm" 2>/dev/null || true
    ppm_visible "$OUT/early-$name.ppm" 2>/dev/null || true
    echo "=== boot $name done"
}

static_checks
run_boot boot1 45454
run_boot boot2 45455

# ── verdicts ───────────────────────────────────────────────────────────────
pass=0; fail=0
chk() { if [ "$1" = "1" ]; then pass=$((pass+1)); echo "  PASS: $2"; else fail=$((fail+1)); echo "  FAIL: $2"; fi; }
grepq() { grep -q "$1" "$2" && echo 1 || echo 0; }
grepqi() { grep -qi "$1" "$2" && echo 1 || echo 0; }

echo ""
echo "══════════════════════ static grub.cfg checks ══════════════════════"
chk "$(grepq 'STATIC_OK 5.15 entry carries' "$OUT/static-results.txt")" "5.15 GRUB entry has legacy I2C params"
chk "$(grepq 'STATIC_OK 6.12 entry has no' "$OUT/static-results.txt")" "6.12 GRUB entry clean of legacy params"
chk "$(grepq 'STATIC_OK 5.15 GRUB entry present' "$OUT/static-results.txt")" "5.15 GRUB entry exists"

echo ""
echo "══════════════════════ 6.12 (default kernel, via GRUB) ═════════════"
s1="$OUT/serial-boot1.log"
chk "$(grepq '### LOGIN OK' "$s1")" "login on serial console (null password)"
chk "$(grepq 'UEFI_OK' "$s1")" "booted via (32-bit OVMF) UEFI"
chk "$(grepq '^6\.12' "$s1")" "kernel 6.12"
chk "$(grepq 'GRUB_IA32_OK' "$s1")" "i386-efi GRUB modules on /boot"
chk "$(grepq 'BOOTIA32.EFI' "$s1")" "BOOTIA32.EFI on ESP"
chk "$(grepq 'intel_idle.max_cstate=1' "$s1")" "intel_idle.max_cstate=1 in cmdline"
chk "$(grepq 'mitigations=off' "$s1")" "mitigations=off in cmdline"
chk "$(grepq 'i2c_designware.disable_pm' "$s1" && echo 0 || echo 1)" "NO legacy I2C params on 6.12"
chk "$(grepq 'zram' "$s1")" "zram swap active"
for svc in NetworkManager earlyoom zramswap casper-touchscreen-watchdog casper-cpu-governor; do
    chk "$(grepq "svc $svc = active" "$s1")" "service $svc active"
done
chk "$(grepq 'DCONF_DB_OK' "$s1")" "dconf system db compiled"
chk "$(grepq 'screen-keyboard-enabled' "$s1")" "OSK enabled in dconf defaults"
chk "$(grepq 'enabled-extensions' "$s1")" "extensions list baked in dconf"
chk "$(grepq '<rotation>right</rotation>' "$s1")" "landscape rotation baked (GDM)"
chk "$(grepqi 'casper-splash' "$s1")" "plymouth theme = casper-splash"
chk "$(ppm_visible "$OUT/gdm-boot1.ppm" >/dev/null 2>&1 && echo 1 || echo 0)" "GDM screenshot shows content (not black)"

echo ""
echo "══════════════════════ 5.15.165 (fallback kernel, via GRUB) ════════"
s2="$OUT/serial-boot2.log"
chk "$(grepq '### LOGIN OK' "$s2")" "login on serial console (null password)"
chk "$(grepq '^5\.15' "$s2")" "kernel 5.15.165"
chk "$(grepq 'i2c_designware.disable_pm=1' "$s2")" "legacy I2C params in cmdline"
chk "$(grepq 'i2c_hid.use_polling_mode=1' "$s2")" "polling mode param in cmdline"
chk "$(grepq 'intel_idle.max_cstate=1' "$s2")" "common params still applied"
chk "$(ppm_visible "$OUT/gdm-boot2.ppm" >/dev/null 2>&1 && echo 1 || echo 0)" "GDM screenshot shows content (not black)"

echo ""
echo "  PASS: $pass   FAIL: $fail"
[ "$fail" = 0 ] || echo "SOME CHECKS FAILED — inspect $OUT/"
exit "$fail"
