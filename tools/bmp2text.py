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

VERBOSE = False

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


def _decode_at(px, w, h, bg, font, dx, dy):
    """Decode with the character grid anchored at (dx, dy). Returns
    (lines, hits) where hits counts cells that matched a real glyph."""
    out, hits = [], 0
    cy = dy
    while cy + 8 <= h:
        line = []
        cx = dx
        while cx + 8 <= w:
            bits = []
            for r in range(8):
                b = 0
                row = px[cy + r]
                for c in range(8):
                    if row[cx + c] != bg:
                        b |= 0x80 >> c
                bits.append(b)
            code = font.get(tuple(bits))
            if code is not None:
                line.append(scr2asc(code))
                if any(bits):
                    hits += 1           # a BLANK cell matches everywhere; don't score it
            else:
                line.append(' ')
            cx += 8
        out.append(''.join(line).rstrip())
        cy += 8
    return out, hits


def decode(path, font):
    """The grid origin is NOT always (0,0).

    The plane is grabbed as a raw 320x192 window, and where the OS puts its
    text within that window depends on the display list — a blank-line count,
    a scroll, or a rewrite that starts the playfield a scanline early all shift
    every glyph off the assumed 8-pixel lattice, and then EVERY lookup misses
    and the decode comes back empty.  So find the anchor instead of assuming it:
    score all 64 offsets and keep the one that matches the most glyphs."""
    w, h, px = read_bmp(path)
    hist = {}
    for row in px:
        for v in row:
            hist[v] = hist.get(v, 0) + 1
    bg = max(hist, key=hist.get)

    best, best_hits, best_at = [], -1, (0, 0)
    for dy in range(8):
        for dx in range(8):
            lines, hits = _decode_at(px, w, h, bg, font, dx, dy)
            if hits > best_hits:
                best, best_hits, best_at = lines, hits, (dx, dy)
    if VERBOSE:
        sys.stderr.write(f"[bmp2text] grid origin {best_at}, {best_hits} glyphs\n")
    return best


if __name__ == "__main__":
    VERBOSE = "-v" in sys.argv
    args = [a for a in sys.argv[1:] if a != "-v"]
    font = load_font(args[1] if len(args) > 1 else ROM)
    for ln in decode(args[0], font):
        if ln.strip():
            print(ln)
