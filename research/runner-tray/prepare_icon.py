#!/usr/bin/env python3
"""Write a 16x16 opaque RGBA PNG using only Python stdlib (remote runner)."""
import struct
import zlib
from pathlib import Path

def chunk(kind, payload):
    return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload) & 0xffffffff)

width = height = 16
pixels = b"".join(b"\x00" + b"\x00\x80\xff\xff" * width for _ in range(height))
png = b"\x89PNG\r\n\x1a\n"
png += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
png += chunk(b"IDAT", zlib.compress(pixels))
png += chunk(b"IEND", b"")
Path("assets").mkdir(exist_ok=True)
Path("assets/tray.png").write_bytes(png)
