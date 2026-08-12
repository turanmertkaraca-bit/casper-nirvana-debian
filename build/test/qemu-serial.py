#!/usr/bin/env python3
"""Drive the QEMU serial console: log in as lvy (no password), run commands,
and print the results. Used by smoke-test.sh.

Usage: qemu-serial.py <unix-sock> <cmds-file> [login-timeout-s]
"""
import socket, sys, time

sock_path, cmds_file = sys.argv[1], sys.argv[2]
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
            buf = (buf + d)[-200000:]
            return True
    except socket.timeout:
        pass
    return False

def wait_for(pattern, timeout):
    p = pattern if isinstance(pattern, bytes) else pattern.encode()
    deadline = time.time() + timeout
    while time.time() < deadline:
        if p in buf:
            return True
        recv_into()
        time.sleep(0.1)
    return False

def send(line):
    s.sendall((line + "\r").encode())

def drain():
    deadline = time.time() + 1.5
    while time.time() < deadline:
        if not recv_into():
            time.sleep(0.1)

def run(cmd, timeout=60):
    print(f"### CMD: {cmd}")
    buf_before = len(buf)
    send(cmd)
    if not wait_for([b"~$ ", b"~# ", b"~$", b"~#"], timeout):
        print("### TIMEOUT waiting for prompt; last output:")
        print(buf[-4000:].decode(errors="replace"))
        return
    # print output since the command echo
    out = buf[buf_before:]
    text = out.decode(errors="replace")
    # strip the echoed command itself
    if text.startswith(cmd):
        text = text[len(cmd):]
    print(text.strip())

# --- login ---
ok = wait_for(b"login:", login_timeout)
if not ok:
    print("FATAL: no login prompt — last serial output:")
    print(buf[-6000:].decode(errors="replace"))
    sys.exit(1)
send("lvy")
ok = wait_for(b"Password:", 20)
if not ok:
    print("FATAL: no password prompt")
    sys.exit(1)
send("")
ok = wait_for(b"~$", 30)
if not ok:
    print("FATAL: login failed")
    sys.exit(1)
print("### LOGIN OK")

with open(cmds_file) as f:
    for line in f:
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        run(line)
drain()
print("### DONE")
