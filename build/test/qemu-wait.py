#!/usr/bin/env python3
"""Connect to the QEMU serial socket, wait for a pattern, print the output.

Usage: qemu-wait.py <unix-sock> <pattern> <timeout-s>
"""
import socket, sys, time

sock_path, pattern = sys.argv[1], sys.argv[2].encode()
timeout = int(sys.argv[3]) if len(sys.argv) > 3 else 300

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
end = time.time() + timeout
while time.time() < end:
    try:
        d = s.recv(8192)
        if d:
            buf = (buf + d)[-300000:]
            if pattern in buf:
                print(buf.decode(errors="replace"))
                print("### PATTERN FOUND")
                sys.exit(0)
    except socket.timeout:
        pass
    time.sleep(0.1)

print(buf.decode(errors="replace"))
print("### PATTERN NOT FOUND")
sys.exit(1)
