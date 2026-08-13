#!/usr/bin/env python3
"""Drive the QEMU serial console for the CasperOS smoke test.

Logs in as lvy (null password), then runs each selftest command through the
interactive login shell and captures everything that arrives. No prompt
matching — commands demonstrably execute via the serial shell, and we just
drain the output. All selftest commands are readable by lvy (ESP is mounted
umask=0133, lvy is in group adm).

Usage: qemu-serial.py <unix-sock> [login-timeout-s]
"""
import socket, sys, time

sock_path = sys.argv[1]
login_timeout = int(sys.argv[2]) if len(sys.argv) > 2 else 600

s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
deadline = time.time() + 120
while True:
    try:
        s.connect(sock_path)
        break
    except OSError:
        if time.time() > deadline:
            print("FATAL: cannot connect to serial socket")
            sys.exit(1)
        time.sleep(1)
s.settimeout(0.25)

buf = b""

def recv_into():
    global buf
    try:
        d = s.recv(8192)
        if d:
            buf = (buf + d)[-400000:]
            return True
    except socket.timeout:
        pass
    return False

def wait_for(pattern, timeout):
    pats = [pattern] if isinstance(pattern, (str, bytes)) else pattern
    pats = [p if isinstance(p, bytes) else p.encode() for p in pats]
    deadline = time.time() + timeout
    while time.time() < deadline:
        for i, p in enumerate(pats):
            if p in buf:
                return i
        recv_into()
        time.sleep(0.1)
    return None

def send(line):
    s.sendall((line + "\r").encode())

# --- login ---
r = wait_for(b"login:", login_timeout)
if r is None:
    print("FATAL: no login prompt — last serial output:")
    print(buf[-6000:].decode(errors="replace"))
    sys.exit(1)
send("lvy")
r = wait_for([b"Password:", b"Parola:", b"~$"], 30)
if r is None:
    print("FATAL: no password prompt / shell after username — last output:")
    print(buf[-4000:].decode(errors="replace"))
    sys.exit(1)
if r in (0, 1):
    send("")
    r = wait_for(b"~$", 30)
    if r is None:
        print("FATAL: login failed — last output:")
        print(buf[-4000:].decode(errors="replace"))
        sys.exit(1)
print("### LOGIN OK")

# --- run commands, capture everything, no prompt matching ------------------
commands = [
    "echo ===SELFTEST-START===",
    "uname -r",
    "cat /proc/cmdline",
    "ls /sys/firmware/efi >/dev/null 2>&1 && echo UEFI_OK || echo UEFI_MISSING",
    "for s in NetworkManager earlyoom zramswap casper-touchscreen-watchdog casper-cpu-governor power-profiles-daemon; do echo \"svc $s = $(systemctl is-active $s 2>/dev/null)\"; done",
    "cat /proc/swaps",
    "cat /sys/kernel/mm/transparent_hugepage/enabled",
    "ls /etc/dconf/db/local >/dev/null 2>&1 && echo DCONF_DB_OK",
    "grep -c screen-keyboard-enabled /etc/dconf/db/local.d/00-casper-desktop",
    "cat /etc/dconf/db/local.d/10-casper-extensions",
    "ls /var/lib/gdm3/.config/monitors.xml /home/lvy/.config/monitors.xml 2>/dev/null",
    "grep -c '<rotation>right</rotation>' /var/lib/gdm3/.config/monitors.xml",
    "grep -i theme /etc/plymouth/plymouthd.conf",
    "ls /boot/vmlinuz-* /boot/initrd.img-*",
    "ls /boot/grub/i386-efi >/dev/null 2>&1 && echo GRUB_IA32_OK || echo GRUB_IA32_MISSING",
    "find /boot/efi -name '*.efi' | head -5",
    "file /boot/efi/EFI/BOOT/BOOTIA32.EFI 2>/dev/null || true",
    "journalctl -q -u casper-cpu-governor.service -b --no-pager --no-hostname | tail -5",
    "journalctl -q --no-pager -p err -b --no-hostname | tail -8",
    "systemd-analyze time | tail -1",
    "echo ===SELFTEST-END===",
]
for cmd in commands:
    before = len(buf)
    send(cmd)
    deadline = time.time() + 6
    while time.time() < deadline:
        recv_into()
        time.sleep(0.2)
    print(f"### CMD: {cmd}")
    print(buf[before:].decode(errors="replace"))
print("### DONE")
