#!/usr/bin/env bash
# CasperOS KVM boot smoke test — boots the finished image under QEMU/KVM with
# 32-bit OVMF firmware (exactly what the tablet has), verifies the default
# (6.12) AND fallback (5.15) kernels reach the graphical target, runs an
# assertion battery over the serial console, and captures screenshots.
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
# Debian 13's edk2 no longer builds IA32; bookworm's ovmf-ia32 does.
# Search order: installed copies → Debian bookworm pool (pinned URL).
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

# boot 1 (default): append console=ttyS0 to the 6.12 entry
prep_boot1() {
    mnt_test_img
    awk '
        { if (!done && $0 ~ /linux[ \t]+\/boot\/vmlinuz-6\./ && $0 !~ /console=ttyS0/) { print $0 " console=ttyS0,115200"; done=1; next } print }
    ' "$OUT/mnt/boot/grub/grub.cfg" > "$OUT/mnt/boot/grub/grub.cfg.new"
    mv "$OUT/mnt/boot/grub/grub.cfg.new" "$OUT/mnt/boot/grub/grub.cfg"
    umnt_test
}

# boot 2 (fallback): point GRUB at the 5.15 entry + console
prep_boot2() {
    mnt_test_img
    local id
    id=$(grep -oE 'gnulinux-5\.15[^'"'"']*' "$OUT/mnt/boot/grub/grub.cfg" | head -1)
    [ -n "$id" ] || { echo "FATAL: no 5.15 grub entry"; umnt_test; exit 1; }
    echo "5.15 entry id: $id"
    sed -i 's/^set default=.*/set default="'"$id"'"/' "$OUT/mnt/boot/grub/grub.cfg"
    awk '
        { if (!done && $0 ~ /linux[ \t]+\/boot\/vmlinuz-5\./ && $0 !~ /console=ttyS0/) { print $0 " console=ttyS0,115200"; done=1; next } print }
    ' "$OUT/mnt/boot/grub/grub.cfg" > "$OUT/mnt/boot/grub/grub.cfg.new"
    mv "$OUT/mnt/boot/grub/grub.cfg.new" "$OUT/mnt/boot/grub/grub.cfg"
    umnt_test
}

screendump() { # port file
    exec 3<>/dev/tcp/127.0.0.1/"$1" 2>/dev/null || return 1
    echo "screendump $2" >&3
    sleep 1
    exec 3>&-
}

# ── assertion battery (run as lvy over the serial console) ─────────────────
cat > "$OUT/cmds.txt" <<'CMDS'
echo ---UNAME
uname -r
echo ---CMDLINE
cat /proc/cmdline
echo ---EFI
ls /sys/firmware/efi >/dev/null 2>&1 && echo UEFI_OK || echo UEFI_MISSING
echo ---SERVICES
for s in NetworkManager earlyoom zramswap casper-touchscreen-watchdog casper-cpu-governor power-profiles-daemon; do systemctl is-active $s 2>/dev/null | xargs echo "svc $s ="; done
echo ---SWAP
cat /proc/swaps
echo ---THP
cat /sys/kernel/mm/transparent_hugepage/enabled
echo ---DCONF
ls /etc/dconf/db/local 2>/dev/null && echo DCONF_DB_OK
grep -c screen-keyboard-enabled /etc/dconf/db/local.d/00-casper-desktop
grep -c enabled-extensions /etc/dconf/db/local.d/10-casper-extensions
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
echo ---JOURNAL_ERR
journalctl --no-pager -p err -b --no-hostname | tail -10
echo ---ANALYZE
systemd-analyze time | tail -1
CMDS

# ── boot one configuration ─────────────────────────────────────────────────
run_boot() {
    local name="$1" monport="$2"
    echo "=== boot: $name ==="
    "prep_$name"
    cp -f "$FVARS" "$OUT/vars-$name.fd" 2>/dev/null || cp -f "$FCODE" "$OUT/vars-$name.fd"
    qemu-system-x86_64 \
        -enable-kvm -machine pc -m 2048 -cpu host \
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

    python3 "$SRC/test/qemu-serial.py" "$OUT/ser-$name.sock" "$OUT/cmds.txt" 900 \
        > "$OUT/serial-$name.log" 2>&1 || echo "serial driver exited non-zero"

    screendump "$monport" "$OUT/gdm-$name.ppm" 2>/dev/null || true
    sleep 2
    kill "$qpid" 2>/dev/null || true
    wait "$qpid" 2>/dev/null || true
    echo "=== boot $name done"
}

run_boot boot1 45454
run_boot boot2 45455

# ── verdicts ───────────────────────────────────────────────────────────────
pass=0; fail=0
chk() { if [ "$1" = "1" ]; then pass=$((pass+1)); echo "  PASS: $2"; else fail=$((fail+1)); echo "  FAIL: $2"; fi; }
grepq() { grep -q "$1" "$2" && echo 1 || echo 0; }

echo ""
echo "══════════════════════ 6.12 (default kernel) ══════════════════════"
s1="$OUT/serial-boot1.log"
chk "$(grepq '### LOGIN OK' "$s1")" "login on serial console"
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
chk "$(grepq "Casper Splash" "$s1")" "plymouth theme = Casper Splash"
chk "$([ -s "$OUT/gdm-boot1.ppm" ] && echo 1 || echo 0)" "GDM screenshot captured"

echo ""
echo "══════════════════════ 5.15.165 (fallback kernel) ══════════════════"
s2="$OUT/serial-boot2.log"
chk "$(grepq '### LOGIN OK' "$s2")" "login on serial console"
chk "$(grepq '^5\.15' "$s2")" "kernel 5.15.165"
chk "$(grepq 'i2c_designware.disable_pm=1' "$s2")" "i2c_designware.disable_pm=1 present"
chk "$(grepq 'i2c_hid.use_polling_mode=1' "$s2")" "i2c_hid.use_polling_mode=1 present"
chk "$(grepq 'intel_idle.max_cstate=1' "$s2")" "common params still applied"
chk "$([ -s "$OUT/gdm-boot2.ppm" ] && echo 1 || echo 0)" "GDM screenshot captured"

echo ""
echo "  PASS: $pass   FAIL: $fail"
[ "$fail" = 0 ] || echo "SOME CHECKS FAILED — inspect $OUT/"
exit "$fail"
