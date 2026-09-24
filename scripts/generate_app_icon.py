#!/usr/bin/env python3
"""Generate FileMann's iOS AppIcon as a deterministic RGB PNG.

The source image previously committed for AppIcon was an indexed/palette PNG.
Some iOS/Asset Catalog paths can render such icons incorrectly. This generator
always writes an opaque 1024x1024 PNG using PNG color type 2 (24-bit RGB).
"""

from __future__ import annotations

import binascii
import struct
import zlib
from pathlib import Path

WIDTH = 1024
HEIGHT = 1024
OUTPUT = (
    Path(__file__).resolve().parents[1]
    / "FileMann"
    / "Assets.xcassets"
    / "AppIcon.appiconset"
    / "AppIcon-1024.png"
)

CYAN = (8, 184, 224)
BLUE = (30, 109, 232)
WHITE = (247, 252, 255)
FOLD = (173, 225, 246)
NAVY = (10, 65, 118)


def rounded_rect(x: int, y: int, left: int, top: int, right: int, bottom: int, radius: int) -> bool:
    if left + radius <= x <= right - radius and top <= y <= bottom:
        return True
    if left <= x <= right and top + radius <= y <= bottom - radius:
        return True

    cx = left + radius if x < left + radius else right - radius
    cy = top + radius if y < top + radius else bottom - radius
    dx = x - cx
    dy = y - cy
    return dx * dx + dy * dy <= radius * radius


def in_triangle(px: int, py: int, a: tuple[int, int], b: tuple[int, int], c: tuple[int, int]) -> bool:
    def sign(p1, p2, p3):
        return (
            (p1[0] - p3[0]) * (p2[1] - p3[1])
            - (p2[0] - p3[0]) * (p1[1] - p3[1])
        )

    p = (px, py)
    d1 = sign(p, a, b)
    d2 = sign(p, b, c)
    d3 = sign(p, c, a)
    has_neg = d1 < 0 or d2 < 0 or d3 < 0
    has_pos = d1 > 0 or d2 > 0 or d3 > 0
    return not (has_neg and has_pos)


def pixel(x: int, y: int) -> tuple[int, int, int]:
    # Full-bleed diagonal blue gradient.
    t_num = x + y
    t_den = 2 * (WIDTH - 1)
    color = tuple(
        (CYAN[i] * (t_den - t_num) + BLUE[i] * t_num) // t_den
        for i in range(3)
    )

    # File/document body.
    if rounded_rect(x, y, 210, 178, 770, 826, 105):
        color = WHITE

    # Folded corner.
    if in_triangle(x, y, (620, 178), (770, 328), (620, 328)):
        color = FOLD

    # Right transfer arrow.
    if rounded_rect(x, y, 300, 410, 650, 480, 35):
        color = NAVY
    if in_triangle(x, y, (650, 368), (746, 445), (650, 522)):
        color = NAVY

    # Left transfer arrow.
    if rounded_rect(x, y, 330, 585, 680, 655, 35):
        color = NAVY
    if in_triangle(x, y, (330, 543), (234, 620), (330, 697)):
        color = NAVY

    return color


def png_chunk(kind: bytes, payload: bytes) -> bytes:
    checksum = binascii.crc32(kind)
    checksum = binascii.crc32(payload, checksum) & 0xFFFFFFFF
    return (
        struct.pack(">I", len(payload))
        + kind
        + payload
        + struct.pack(">I", checksum)
    )


def build_png() -> bytes:
    raw = bytearray()
    for y in range(HEIGHT):
        raw.append(0)  # PNG filter: None
        for x in range(WIDTH):
            raw.extend(pixel(x, y))

    signature = b"\x89PNG\r\n\x1a\n"
    ihdr = struct.pack(
        ">IIBBBBB",
        WIDTH,
        HEIGHT,
        8,  # bit depth
        2,  # color type: truecolor RGB, no alpha/palette
        0,
        0,
        0,
    )
    return (
        signature
        + png_chunk(b"IHDR", ihdr)
        + png_chunk(b"IDAT", zlib.compress(bytes(raw), level=9))
        + png_chunk(b"IEND", b"")
    )


def verify_png(data: bytes) -> None:
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise RuntimeError("Generated AppIcon is not a PNG")
    width, height, depth, color_type, compression, filtering, interlace = struct.unpack(
        ">IIBBBBB", data[16:29]
    )
    if (width, height) != (1024, 1024):
        raise RuntimeError(f"Unexpected AppIcon dimensions: {width}x{height}")
    if depth != 8 or color_type != 2:
        raise RuntimeError(
            f"AppIcon must be opaque 24-bit RGB; depth={depth}, color_type={color_type}"
        )
    if compression != 0 or filtering != 0 or interlace != 0:
        raise RuntimeError("Unexpected PNG encoding parameters")


def main() -> None:
    data = build_png()
    verify_png(data)
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_bytes(data)
    print(
        f"Generated {OUTPUT}: {WIDTH}x{HEIGHT}, RGB, opaque, {len(data)} bytes"
    )


if __name__ == "__main__":
    main()
