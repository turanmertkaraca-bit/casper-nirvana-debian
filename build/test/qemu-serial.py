#!/usr/bin/env python3
"""Drive the QEMU serial console for the CasperOS smoke test.

The selftest runs as a systemd oneshot inside the VM and prints its output
to ttyS0 between ===SELFTEST-START=== / ===SELFTEST-END=== markers. We
capture that, then verify the lvy login flow works, then print everything.

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
            buf = (buf + d)[-500000:]
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

# --- 1. capture the boot-time selftest output ------------------------------
r = wait_for(b"===SELFTEST-START===", login_timeout)
if r is None:
    print("FATAL: no selftest output — last serial output:")
    print(buf[-8000:].decode(errors="replace"))
    sys.exit(1)
r = wait_for(b"===SELFTEST-END===", 180)
if r is None:
    print("FATAL: selftest did not finish — last serial output:")
    print(buf[-8000:].decode(errors="replace"))
    sys.exit(1)
start = buf.rfind(b"===SELFTEST-START===")
end = buf.rfind(b"===SELFTEST-END===")
out = buf[start + len(b"===SELFTEST-START==="):end]
print("### SELFTEST OUTPUT ###")
print(out.decode(errors="replace"))
print("### SELFTEST OUTPUT END ###")

# --- 2. verify the lvy login flow (null password) --------------------------
send("\r")  # make sure getty is on a fresh line
r = wait_for(b"login:", 90)
if r is None:
    print("FATAL: no login prompt — last serial output:")
    print(buf[-4000:].decode(errors="replace"))
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
print("### DONE")
