#!/usr/bin/env python3
"""Drive the QEMU serial console: log in as lvy (null password), then run a
command script via `bash -s` (non-interactive — no readline/prompt races)
and print the output between START/END markers.

Usage: qemu-serial.py <unix-sock> <script-file> [login-timeout-s]
"""
import socket, sys, time

sock_path, script_file = sys.argv[1], sys.argv[2]
login_timeout = int(sys.argv[3]) if len(sys.argv) > 3 else 600

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
            buf = (buf + d)[-300000:]
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

def drain(secs=1.0):
    deadline = time.time() + secs
    while time.time() < deadline:
        if not recv_into():
            time.sleep(0.1)

# --- login (interactive; works: login/Parola prompts are readline-free) ---
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

# --- run the script non-interactively (bash -s reads stdin until ^D) -------
send("bash -s")
drain(0.5)
with open(script_file, "rb") as f:
    data = f.read()
# canonical-mode tty buffers are limited (~4KB) — send in small chunks
for i in range(0, len(data), 400):
    s.sendall(data[i:i+400])
    time.sleep(0.05)
s.sendall(b"\x04")  # Ctrl-D: EOF for bash -s
print("### SCRIPT SENT, waiting for output...")

r = wait_for(b"===SELFTEST-END===", 300)
if r is None:
    print("FATAL: no selftest output — last serial output:")
    print(buf[-12000:].decode(errors="replace"))
    sys.exit(1)

# extract the output between the markers (markers come from the script)
start_marker = buf.rfind(b"===SELFTEST-START===")
end_marker = buf.rfind(b"===SELFTEST-END===")
if start_marker >= 0 and end_marker > start_marker:
    out = buf[start_marker + len(b"===SELFTEST-START==="):end_marker]
    print(out.decode(errors="replace"))
else:
    # fall back to printing everything after the login
    print(buf[-40000:].decode(errors="replace"))
drain()
print("### DONE")
