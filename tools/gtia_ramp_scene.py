#!/usr/bin/env python3
"""Build a STATIC GTIA-mode LUMINANCE RAMP as a standalone .xex.

BallBlazer's pre-title screen (the one that shows for ~2 s before the logo
text) is a GTIA-mode picture of three vertical pillars, and ours does not match
the reference: the outermost stripe of each outer pillar comes out the same
colour as the value-0 background, and the middle pillar -- which the reference
draws from the DIM end of the ramp -- collapses from four distinct shades into
two, in pairs.  Both symptoms say the same thing: ADJACENT NIBBLE VALUES ARE
NOT LANDING ON DISTINCT COLOURS, and the dim end is where it shows.

Chasing that in the game means racing a 2-second screen.  This scene holds
still and removes every variable except the one under test: ANTIC mode $F, one
GTIA mode, and every nibble value 0..15 laid out in order across the line, five
times.  Whatever the palette is, a correct render has SIXTEEN distinct colours
per row in ascending order, each exactly 4 px wide at 320.  Ours can then be
compared against Altirra running the SAME .xex.

    python3 tools/gtia_ramp_scene.py [out.xex] [mode]

`mode` is 9, 10 or 11 (default 9) -- GPRIOR bits 7:6 = 01/10/11.  Mode 9 is
BallBlazer's, and the one to run first.

Then: `6502 run /OS/share/<name>.xex` on the board, `graboverlay`, and the same
file under AltirraSDL for the reference.
"""
import sys

PROG, DL, SCR = 0x2000, 0x2400, 0x2500
NLINES = 96                                  # ANTIC F lines: one scanline each

PRIOR, COLBK  = 0xD01B, 0xD01A
DMACTL        = 0xD400
SDMCTL, SDLSTL, GPRIOR = 0x022F, 0x0230, 0x026F
COLOR4        = 0x02C8                       # shadow of COLBK

MODEBITS = {9: 0x40, 10: 0x80, 11: 0xC0}


def lda_i(v): return bytes([0xA9, v & 0xFF])
def sta_a(a): return bytes([0x8D, a & 0xFF, a >> 8])
def jmp(a):   return bytes([0x4C, a & 0xFF, a >> 8])


def program(modebits):
    c = b""
    c += lda_i(DL & 0xFF) + sta_a(SDLSTL) + lda_i(DL >> 8) + sta_a(SDLSTL + 1)
    c += lda_i(0x22) + sta_a(SDMCTL) + sta_a(DMACTL)      # playfield DMA, no P/M
    # COLBK carries the HUE in mode 9 and the whole colour in the others, so a
    # non-zero hue is what makes a luminance ramp visible at all.  $60 = the
    # game's family of purples/reds; the value is arbitrary, the ramp is not.
    c += lda_i(0x60) + sta_a(COLOR4) + sta_a(COLBK)
    c += lda_i(modebits) + sta_a(GPRIOR) + sta_a(PRIOR)
    c += jmp(PROG + len(c))                                # park: the picture is static
    return c


def dlist():
    d = bytes([0x70, 0x70, 0x70])
    d += bytes([0x4F, SCR & 0xFF, SCR >> 8])
    d += bytes([0x0F]) * (NLINES - 1)
    d += bytes([0x41, DL & 0xFF, DL >> 8])
    return d


def screen():
    # One byte = two GTIA pixels (high nibble first).  40 bytes = 80 pixels =
    # five passes of 0..15, so a mis-mapped value shows up five times a line and
    # cannot be read as noise.
    line = bytes([((2 * i) & 0x0F) << 4 | ((2 * i + 1) & 0x0F) for i in range(40)])
    return line * NLINES


def seg(addr, data):
    end = addr + len(data) - 1
    return bytes([addr & 0xFF, addr >> 8, end & 0xFF, end >> 8]) + data


def main():
    out  = sys.argv[1] if len(sys.argv) > 1 else "/tmp/gtia_ramp.xex"
    mode = int(sys.argv[2]) if len(sys.argv) > 2 else 9
    if mode not in MODEBITS:
        print("mode must be 9, 10 or 11"); return 1
    x = b"\xff\xff"
    x += seg(PROG, program(MODEBITS[mode]))
    x += seg(DL, dlist())
    x += seg(SCR, screen())
    x += seg(0x02E0, bytes([PROG & 0xFF, PROG >> 8]))
    open(out, "wb").write(x)
    print("wrote %s (%d bytes), GTIA mode %d" % (out, len(x), mode))
    print("  correct: 16 distinct colours per row, ascending, 4 px each at 320")
    return 0


if __name__ == "__main__":
    sys.exit(main())
