#!/usr/bin/env python3
"""Generate the CasperOS plymouth background (dark gradient, 1366x768)."""
import struct, zlib, os, sys

W, H = 1366, 768
OUT = sys.argv[1] if len(sys.argv) > 1 else "background.png"

def px(x, y):
    # subtle vertical gradient: #0a0d16 top -> #131826 bottom
    t = y / (H - 1)
    r = int(10 + (19 - 10) * t)
    g = int(13 + (24 - 13) * t)
    b = int(22 + (38 - 22) * t)
    return (r, g, b)

rows = b""
for y in range(H):
    rows += b"\x00" + bytes(v for x in range(W) for v in px(x, y))

def chunk(tag, data):
    c = struct.pack(">I", len(data)) + tag + data
    return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

png = (b"\x89PNG\r\n\x1a\n"
       + chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0))
       + chunk(b"IDAT", zlib.compress(rows, 9))
       + chunk(b"IEND", b""))

with open(OUT, "wb") as f:
    f.write(png)
print(f"wrote {OUT} ({W}x{H}, {os.path.getsize(OUT)} bytes)")
