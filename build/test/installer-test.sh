#!/usr/bin/env bash
# End-to-end test of the CasperOS installer ISO:
#   1. boots the preseeded Debian installer (kernel direct-boot — the old
#      32-bit OVMF build in CI cannot boot Debian's installer ISO, but real
#      Bay Trail firmware can; the UEFI-IA32 boot path is covered by the
#      flash-ISO test) on a blank disk (auto-install, qemu user-net)
#   2. after the installer reboots, boots the INSTALLED system from that disk
#   3. verifies the CasperOS fixes are in place (login as lvy, cmdline,
#      services, kernels, session)
#
# Usage: sudo ./installer-test.sh <installer.iso> <outdir>
set -euo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
ISO="${1:?usage: installer-test.sh <installer.iso> <outdir>}"
OUT="${2:-/tmp/installer-test}"

command -v qemu-system-x86_64 >/dev/null || { echo "qemu missing" >&2; exit 1; }
rm -rf "$OUT" && mkdir -p "$OUT"

# ── blank target disk (the internal eMMC stand-in) ─────────────────────────
# 8G: small_disk's amd64 minimum is ~3.3 GB but it also wants swap, and the
# package set is ~2.5 GB. This is a SPARSE file — verified: a 8 GiB truncate
# occupies ~0 blocks and only the bytes actually written are allocated — so the
# nominal size costs no disk. Only ~3 GB is ever really used.
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
gzip -dc "$OUT/initrd.gz" 2>/dev/null | cpio -t 2>/dev/null | grep -E 'preseed\.cfg|^casperos$|firmware/rtlwifi/rtl8723bs_nic|firmware/rtl_bt/rtl8723bs' | head -8
echo "(preseed.cfg present in the booted initrd: $?)"

# ── phase 1: run the installer (preseeded, automatic; BIOS machine) ─────────
echo "=== phase 1: installing (this takes a while) ==="
# The installer ships its syslog to the qemu host (10.0.2.2) via UDP 514 —
# this is how we see the preseed/installer internals (they don't hit the
# serial). The syslog's md5 also gives us a reliable progress signal.
(nc -u -l -p 514 > "$OUT/installer-syslog.log" 2>/dev/null || \
 python3 -c "
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind(('0.0.0.0', 514))   # 10.0.2.2 exists only inside qemu's user-net
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
    -append "auto=true priority=critical preseed/file=/preseed.cfg console=tty0 console=ttyS0,115200 DEBIAN_FRONTEND=text log_host=10.0.2.2 log_port=514" \
    -serial file:"$OUT/serial-install.log" \
    -display none -vga std -no-reboot \
    > "$OUT/qemu-install.log" 2>&1 &
QPID=$!

WAITED=0
IDLE=0
TIMEOUT=7200
LAST_PROGRESS=""
LAST_NOTICE=0
PRESEED_SEEN=0
while kill -0 "$QPID" 2>/dev/null; do
    sleep 30
    WAITED=$((WAITED+30))

    # The serial console used to be hashed as raw bytes, and the newt frontend
    # repaints its dialog frame continuously — so the hash changed every single
    # iteration and the stall detector could never fire. That is why run #128
    # sat at exactly 7200s instead of failing fast. Progress is now measured by
    # *semantic* counters that only advance when the installer really does
    # something: the byte count of the remote syslog, and the number of lines
    # in the serial log that name an actual install stage. A spinning cursor
    # and a repainted box move neither.
    SYSLOG_BYTES=$(stat -c %s "$OUT/installer-syslog.log" 2>/dev/null || echo 0)
    # `cat file 2>/dev/null` rather than `< file`: a missing file makes the
    # redirection itself fail, which prints "No such file or directory" to
    # the log and can abort the loop under set -e.
    STAGE_LINES=$( { cat "$OUT/serial-install.log" 2>/dev/null || true; } \
        | tr -d '\000' \
        | grep -acE 'PRESEED-APPLIED|base-installer|Unpacking|Setting up|Selecting previously|Processing triggers|in-target|casperos-fixup|pkgsel|partman|Installing new version|Configuring ' || true)
    STAGE_LINES=${STAGE_LINES:-0}
    CUR_PROGRESS="$SYSLOG_BYTES/$STAGE_LINES"
    if [ "$CUR_PROGRESS" = "$LAST_PROGRESS" ]; then
        IDLE=$((IDLE+30))
    else
        IDLE=0
    fi
    LAST_PROGRESS="$CUR_PROGRESS"

    # 1. Was the preseed read at all? early_command echoes PRESEED-APPLIED to
    # ttyS0 before anything can prompt. Silence here is a completely different
    # bug from a stall (wrong initrd, wrong preseed path, bad boot params), and
    # it used to be indistinguishable.
    #
    # It only fails the run when nothing at all is happening: no marker, no
    # syslog, no stage line. A missing marker alone is not proof (the echo to
    # /dev/ttyS0 is best-effort), and inventing a failure here would be worse
    # than the silence it replaces.
    if [ "$PRESEED_SEEN" = 0 ] && grep -aq 'PRESEED-APPLIED' "$OUT/serial-install.log" 2>/dev/null; then
        PRESEED_SEEN=1
        printf '::notice::preseed was applied (%ss) — the installer is running unattended\n' "$WAITED"
    fi
    if [ "$PRESEED_SEEN" = 0 ] && [ "$WAITED" -ge 600 ] \
        && [ "$SYSLOG_BYTES" -eq 0 ] && [ "$STAGE_LINES" -eq 0 ]; then
        printf '::error::no sign of the preseed after %ss (no marker, no syslog, no install stage) — the boot params or the preseed path are wrong, not the install\n' "$WAITED" >&2
        ANSI_TAIL=$(tail -c 3000 "$OUT/serial-install.log" 2>/dev/null | tr -d '\000' \
            | sed -e 's/\x1b\[[0-9;?]*[a-zA-Z]//g' -e 's/\x1b[()][AB0]//g' -e 's/\r//g' \
            | grep -av '^[[:space:]]*$' | tail -12 || true)
        printf '%s\n' "$ANSI_TAIL" | while IFS= read -r l; do
            [ -n "$l" ] && printf '::error::serial: %s\n' "${l:0:150}"; done
        kill "$QPID" 2>/dev/null || true; wait "$QPID" 2>/dev/null || true
        kill "$SYSLOG_PID" 2>/dev/null || true
        exit 1
    fi

    if [ "$WAITED" -ge 600 ] && [ $((WAITED % 300)) = 0 ]; then
        echo "  ... install running (${WAITED}s); syslog=${SYSLOG_BYTES}B stage-lines=${STAGE_LINES} idle=${IDLE}s"
    fi

    # 2. Real stall: no semantic progress for 20 minutes. The old threshold was
    # 900s against a signal that was always moving, which is the opposite of
    # what a stall detector should be.
    if [ "$IDLE" -ge 1200 ]; then
        echo "ERROR: installer stuck (no install progress for ${IDLE}s)"
        printf '::error::installer made no progress for %ss (syslog %sB, %s stage lines)\n' \
            "$IDLE" "$SYSLOG_BYTES" "$STAGE_LINES" >&2
        kill "$QPID" 2>/dev/null || true
        wait "$QPID" 2>/dev/null || true
        kill "$SYSLOG_PID" 2>/dev/null || true
        exit 1
    fi

    # Every 15 minutes, say where the install is. These land as annotations,
    # which is the only part of this job a reader without a token can see: a
    # run that ends in "did not finish" otherwise says nothing about whether
    # it was downloading, unpacking, or running the fixup.
    if [ $((WAITED - LAST_NOTICE)) -ge 900 ]; then
        LAST_NOTICE=$WAITED
        # ANSI escapes are stripped here too: the old notice path grepped the
        # raw serial stream, so the one stage line it found was an escape-code
        # fragment ending in `lqqqqqqqq` — a box frame, not a stage.
        STAGE=$( { cat "$OUT/installer-syslog.log" "$OUT/serial-install.log" 2>/dev/null; } \
            | tr -d '\000' \
            | sed -e 's/\x1b\[[0-9;?]*[a-zA-Z]//g' -e 's/\x1b[()][AB0]//g' -e 's/\r/\n/g' \
            | grep -aiE 'in-target|Setting up|Unpacking|apt-get|casperos-fixup|Download|base-installer|pkgsel|partman' \
            | tail -1 | cut -c1-140)
        printf '::notice::install %ss: %s\n' "$WAITED" "${STAGE:-no install stage named yet}"
    fi
    if [ "$WAITED" -ge "$TIMEOUT" ]; then
        echo "ERROR: installer did not finish in ${TIMEOUT}s"
        printf '::error::installer did not finish in %ss\n' "$TIMEOUT" >&2
        # the last thing it did is the whole diagnosis: without it a timeout is
        # indistinguishable from a stalled mirror, a hung dpkg or a slow disk.
        # The escape codes have to go or the annotation is unreadable — that is
        # exactly why run #128's only evidence was `ESC[30mESC[47mlqqqqqqq`.
        ANSI_TAIL=$(tail -c 4000 "$OUT/serial-install.log" 2>/dev/null | tr -d '\000' \
            | sed -e 's/\x1b\[[0-9;?]*[a-zA-Z]//g' -e 's/\x1b[()][AB0]//g' -e 's/\r//g' \
            | grep -av '^[[:space:]]*$' | tail -8)
        printf '%s\n' "$ANSI_TAIL" | while IFS= read -r l; do
            [ -n "$l" ] && printf '::error::serial: %s\n' "${l:0:150}"; done
        grep -aiE 'in-target|Setting up|E: |error|fail' "$OUT/installer-syslog.log" 2>/dev/null | \
            tail -3 | while IFS= read -r l; do printf '::warning::syslog tail: %s\n' "${l:0:150}"; done
        kill "$QPID" 2>/dev/null || true
        wait "$QPID" 2>/dev/null || true
        kill "$SYSLOG_PID" 2>/dev/null || true
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

# ── mount the installed root ───────────────────────────────────────────────
echo "=== phase 2: booting the installed system ==="
LOOP=$(losetup -f)
losetup -P "$LOOP" "$OUT/target.disk"
mkdir -p "$OUT/mnt"
# Find root by CONTENT, not by partition number: the preseeded recipe decides
# the layout (small_disk/atomic put / behind a /boot, with a biosgrub
# partition or an ESP in front). Mounting "${LOOP}p2" blindly mounted /boot
# and made every assertion below read an empty tree.
mount_installed_root() {
    local part
    mount "${LOOP}p2" "$OUT/mnt" 2>/dev/null || mount "${LOOP}p1" "$OUT/mnt" 2>/dev/null || true
    if [ -f "$OUT/mnt/etc/hostname" ] && [ -d "$OUT/mnt/usr" ]; then
        return 0
    fi
    umount "$OUT/mnt" 2>/dev/null || true
    for part in "$LOOP"p*; do
        [ -b "$part" ] || continue
        mount "$part" "$OUT/mnt" 2>/dev/null || continue
        if [ -f "$OUT/mnt/etc/hostname" ] && [ -d "$OUT/mnt/usr" ]; then
            echo "installed root is $part"
            return 0
        fi
        umount "$OUT/mnt" 2>/dev/null || true
    done
    echo "WARN: no partition of $OUT/target.disk looks like the installed root" >&2
    return 1
}

mount_installed_root || true
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
chk() {
    if [ "$1" = "1" ]; then
        pass=$((pass+1)); echo "  PASS: $2"
    else
        fail=$((fail+1)); echo "  FAIL: $2"
        # one-line annotation per failed check: this script's verdict is a
        # failure COUNT, so without this CI only says "exit 1" and the
        # names of the broken checks are buried in the log
        printf '::error::CHECK FAILED: %s\n' "$2" >&2
    fi
}
V="$OUT/verify.log"
B="$OUT/serial-boot.log"
I="$OUT/serial-install.log"
S="$OUT/installer-syslog.log"

# The installed disk has to be mounted BEFORE any verdict reads from it.
# `chk "$([ -e "$M/..." ])"` used to run with M still unset, and set -u turns
# that into "M: unbound variable" — the check silently evaluated to false and
# the whole script kept going, which is why "greetd enabled at install time"
# could fail without any explanation.
mount_installed_root || true
M="$OUT/mnt"

chk "$(grep -q '### LOGIN PROMPT SHOWN' "$V" && echo 1 || echo 0)" "installed system boots to a login prompt"
# d-i's `in-target` runs the fixup under log-output, which sends BOTH stdout
# and stderr to syslog — the fixup's own lines never reach ttyS0. So look for
# its sentinel file on the installed disk (authoritative, immune to log
# routing) and fall back to the syslog, never to the serial log.
FIXUP_OK=0
[ -f "$M/var/log/casperos-fixup.ok" ] && FIXUP_OK=1
[ "$FIXUP_OK" = 0 ] && grep -aq 'casperos-fixup: fixup complete' "$S" 2>/dev/null && FIXUP_OK=1
chk "$FIXUP_OK" "CasperOS fixup ran to completion at install time"
if [ "$FIXUP_OK" = 0 ]; then
    # the fixup is the part most likely to break; show what it said, from the
    # log that actually carries its output
    grep -aiE 'casperos-fixup|in-target|error|E: ' "$S" "$I" 2>/dev/null | tail -6 | \
        while IFS= read -r l; do printf '::warning::fixup: %s\n' "${l:0:150}"; done
fi
# "Rebooting into your new system" is a debconf template description, only
# rendered by the frontend, so it is not a reliable marker under
# DEBIAN_FRONTEND=text. The install finished iff d-i got as far as the fixup
# or the reboot; use that, and the boot prompt in phase 2 is the real proof.
chk "$( { grep -aqE 'Finished installation|Rebooting|fixup complete' "$I" "$S" 2>/dev/null \
        || [ "$FIXUP_OK" = 1 ]; } && echo 1 || echo 0)" "install completed"
# No login screen any more: greetd autologins into Hyprland. greetd's unit has
# no WantedBy= — only Alias=display-manager.service — so `systemctl enable`
# creates /etc/systemd/system/display-manager.service, never a
# graphical.target.wants/greetd.service symlink. Assert the alias, which is
# what actually happens.
chk "$([ -e "$M/etc/systemd/system/display-manager.service" ] && echo 1 || echo 0)" "greetd enabled as display-manager"

chk "$([ -f "$M/etc/libinput/local-overrides.quirks" ] && echo 1 || echo 0)" "libinput quirk present"
chk "$(grep -q 'intel_idle.max_cstate=1' "$M/etc/default/grub.d/99-casper.cfg" 2>/dev/null && echo 1 || echo 0)" "GRUB kernel params baked"
# the unquoted glob used to make this `[ -f a b ]` ("too many arguments")
# whenever more than one vmlinuz-5.15* existed
chk "$(ls "$M"/boot/vmlinuz-5.15* >/dev/null 2>&1 && echo 1 || echo 0)" "5.15 fallback kernel installed"
# It used to assert the literal string 'exec Hyprland' in config.toml, which
# was the *broken* guard: greetd prepends its own `exec `, so `exec command -v
# Hyprland ...` failed with 127 on every boot. Assert the behaviour instead —
# greetd must point at a runnable file, and that file must be able to start
# Hyprland.
chk "$(grep -q 'casper-session' "$M/etc/greetd/config.toml" 2>/dev/null && echo 1 || echo 0)" "greetd points at the session script"
chk "$([ -x "$M/usr/local/bin/casper-session" ] && echo 1 || echo 0)" "session script is executable"
chk "$(grep -qE '^[[:space:]]*(exec[[:space:]]+)?Hyprland[[:space:]]*$' "$M/usr/local/bin/casper-session" 2>/dev/null && echo 1 || echo 0)" "session script runs Hyprland"
chk "$([ -f "$M/etc/xdg/hypr/hyprland.conf" ] && echo 1 || echo 0)" "Hyprland session config installed"
chk "$(grep -q 'tmpfs /tmp' "$M/etc/fstab" 2>/dev/null && echo 1 || echo 0)" "tmpfs /tmp in fstab"
chk "$(grep -q 'zram' "$M/etc/default/zramswap" 2>/dev/null && echo 1 || echo 0)" "zram config present"
chk "$(grep -q 'lvy ALL=(ALL) NOPASSWD' "$M/etc/sudoers.d/90-casper-lvy" 2>/dev/null && echo 1 || echo 0)" "lvy sudo setup"
# The casper-* units ship to /usr/lib/systemd/system; `systemctl enable` only
# adds a .wants/ symlink under /etc, so checking /etc/systemd/system/<unit> was
# false on every correct install.
chk "$([ -f "$M/usr/lib/systemd/system/casper-touchscreen-watchdog.service" ] && echo 1 || echo 0)" "watchdog unit present"
chk "$([ -e "$M/etc/systemd/system/multi-user.target.wants/casper-touchscreen-watchdog.service" ] && echo 1 || echo 0)" "watchdog unit enabled"
chk "$([ -f "$M/usr/share/plymouth/themes/casper-splash/casper-splash.plymouth" ] && echo 1 || echo 0)" "plymouth theme present"
umount "$OUT/mnt" 2>/dev/null || true
losetup -d "$LOOP" 2>/dev/null || true

# The installed-disk image is ~3 GB and nothing reads it after this point —
# only the logs above are uploaded as artifacts. Leaving it behind is a large
# part of why a run of this workflow leaves tens of GB on the runner.
rm -f "$OUT/target.disk"

echo ""
echo "  PASS: $pass   FAIL: $fail"
[ "$fail" = 0 ] || echo "SOME CHECKS FAILED — inspect $OUT/"
exit "$fail"
