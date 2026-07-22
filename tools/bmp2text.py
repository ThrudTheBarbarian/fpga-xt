#!/usr/bin/env python3
"""Decode a graboverlay BMP of the XL plane into the text on screen.

The plane is 320x192 = 40x24 cells of 8x8, and the glyphs come from the OS ROM
character set, so this is an exact match rather than OCR: threshold each cell
to 1bpp and look the bitmap up in the font.

The XL OS maps $D800-$FFFF from rom[$1800..], so the $E000 character set is at
rom offset $1800 + ($E000-$D800) = $2000.

    bmp2text.py shot.bmp [rom]
"""
import sys, struct

import os
ROM = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "rsrc", "atari-xl.rom")

# Internal (screen) code -> ATASCII, then to printable ASCII.
def scr2asc(c):
    c &= 0x7F
    if c <= 0x3F:   out = c + 0x20
    elif c <= 0x5F: out = c - 0x40
    else:           out = c
    return chr(out) if 0x20 <= out <= 0x7E else ' '


def load_font(path=ROM):
    rom = open(path, 'rb').read()
    base = 0x2000
    glyphs = {}
    for i in range(128):
        rows = tuple(rom[base + i * 8 + r] for r in range(8))
        glyphs.setdefault(rows, i)
        inv = tuple((~r) & 0xFF for r in rows)      # inverse video
        glyphs.setdefault(inv, i | 0x80)
    return glyphs


def read_bmp(path):
    d = open(path, 'rb').read()
    if d[:2] != b'BM':
        raise SystemExit(f"{path}: not a BMP")
    off = struct.unpack_from('<I', d, 10)[0]
    w, h = struct.unpack_from('<ii', d, 18)
    bpp = struct.unpack_from('<H', d, 28)[0]
    if bpp != 24:
        raise SystemExit(f"{path}: expected 24bpp, got {bpp}")
    rowb = w * 3
    pad = (4 - (rowb & 3)) & 3
    px = [[0] * w for _ in range(h)]
    for y in range(h):
        src = off + y * (rowb + pad)
        ty = h - 1 - y                              # BMP is bottom-up
        for x in range(w):
            b, g, r = d[src + x*3], d[src + x*3 + 1], d[src + x*3 + 2]
            px[ty][x] = r + g + b
    return w, h, px


def decode(path, font):
    w, h, px = read_bmp(path)
    cols, rows = w // 8, h // 8
    # Background is whatever is most common; a set pixel differs from it.
    hist = {}
    for row in px:
        for v in row:
            hist[v] = hist.get(v, 0) + 1
    bg = max(hist, key=hist.get)
    out = []
    for cy in range(rows):
        line = []
        for cx in range(cols):
            bits = []
            for r in range(8):
                b = 0
                for c in range(8):
                    if px[cy*8 + r][cx*8 + c] != bg:
                        b |= 0x80 >> c
                bits.append(b)
            code = font.get(tuple(bits))
            line.append(scr2asc(code) if code is not None else ' ')
        out.append(''.join(line).rstrip())
    return out


if __name__ == "__main__":
    font = load_font(sys.argv[2] if len(sys.argv) > 2 else ROM)
    for ln in decode(sys.argv[1], font):
        if ln.strip():
            print(ln)
