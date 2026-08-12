#!/usr/bin/env python3
"""Drive the QEMU serial console for the CasperOS smoke test.

The system-level selftest writes to /var/log/casper-selftest.log inside the
guest (read by smoke-test.sh via loop mount). This script only verifies the
lvy login flow (null password) works.

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
            buf = (buf + d)[-100000:]
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

# --- wait for the login prompt, then verify the null-password login --------
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

# run the selftest via lvy's passwordless sudo; output goes to a file that
# smoke-test.sh reads via loop mount (no tty/readline involvement)
send("sudo -n bash -s < /usr/local/bin/casper-selftest.sh > /var/log/casper-selftest.log 2>&1")
print("### SELFTEST LAUNCHED")
deadline = time.time() + 90
while time.time() < deadline:
    recv_into()
    time.sleep(0.5)
print("### DONE")
