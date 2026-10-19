#!/usr/bin/env python3
"""Generate the MaxCam app icon (1024x1024 PNG, RGB, no dependencies).

The asset catalog declares a single universal 1024x1024 iOS icon. Xcode fails
the build with "None of the input catalogs contained a matching ... app icon
set named AppIcon" when that entry has no backing image, so the icon is
generated rather than committed as an opaque binary blob.

Run from the repository root:
    python3 scripts/generate_app_icon.py
"""

import struct
import zlib
from pathlib import Path

SIZE = 1024
BACKGROUND = (10, 10, 12)
RING = (235, 235, 238)
DOT = (222, 42, 42)

OUTPUT = (
    Path(__file__).resolve().parent.parent
    / "MaxCam/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
)


def pixel(x: int, y: int) -> tuple[int, int, int]:
    """A record dot inside a lens ring on black, drawn with distance tests."""
    centre = SIZE / 2.0
    dx, dy = x - centre, y - centre
    distance = (dx * dx + dy * dy) ** 0.5
    if distance <= 300:
        return DOT
    if 360 <= distance <= 430:
        return RING
    return BACKGROUND


def build_png() -> bytes:
    rows = []
    for y in range(SIZE):
        row = bytearray([0])  # per-scanline filter type 0 (None)
        for x in range(SIZE):
            row += bytes(pixel(x, y))
        rows.append(bytes(row))
    raw = b"".join(rows)

    def chunk(tag: bytes, data: bytes) -> bytes:
        return (
            struct.pack(">I", len(data))
            + tag
            + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
        )

    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", SIZE, SIZE, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )


def main() -> None:
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_bytes(build_png())
    print(f"wrote {OUTPUT} ({OUTPUT.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
