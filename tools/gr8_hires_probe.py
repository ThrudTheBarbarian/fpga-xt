#!/usr/bin/env python3
"""Build a STATIC GR.8 HI-RES probe as a standalone .xex.

BallBlazer's LucasFilm loading screen is ANTIC mode $F (GR.8 hi-res, 158 lines,
DMACTL $3E) with NO GTIA mode selected, and the reference resolves it at HI-RES
granularity -- 75% of the runs across the craft band are one colour clock wide.
Ours resolves the same screen at 0-9%, four times coarser, as though a GTIA mode
were still active.  (Measured 2026-08-18 over 78 reference frames and 34 board
frames; the two distributions do not overlap.)

This probe removes the game: ANTIC mode $F, PRIOR = 0, and a screen of
alternating bit patterns.  A correct hi-res render resolves single BITS.

    python3 tools/gr8_hires_probe.py [out.xex] [fill]

`fill` (default $AA) is the byte written to every screen cell:
    $AA  10101010 -> every other hi-res pixel   (finest detail)
    $CC  11001100 -> pairs                      (one colour clock)
    $F0  11110000 -> nibbles                    (two colour clocks)
Run all three: whichever is the first to come out SOLID is the resolution we
have actually got.
"""
import sys

PROG, DL, SCR = 0x2000, 0x2400, 0x2500
NLINES = 96

PRIOR, COLBK, COLPF1, COLPF2 = 0xD01B, 0xD01A, 0xD017, 0xD018
DMACTL        = 0xD400
SDMCTL, SDLSTL, GPRIOR = 0x022F, 0x0230, 0x026F
COLOR1, COLOR2, COLOR4 = 0x02C5, 0x02C6, 0x02C8


def lda_i(v): return bytes([0xA9, v & 0xFF])
def sta_a(a): return bytes([0x8D, a & 0xFF, a >> 8])
def jmp(a):   return bytes([0x4C, a & 0xFF, a >> 8])


def program():
    c = b""
    c += lda_i(DL & 0xFF) + sta_a(SDLSTL) + lda_i(DL >> 8) + sta_a(SDLSTL + 1)
    c += lda_i(0x22) + sta_a(SDMCTL) + sta_a(DMACTL)       # normal-width playfield
    c += lda_i(0x00) + sta_a(GPRIOR) + sta_a(PRIOR)        # NO GTIA mode -- the point
    c += lda_i(0x00) + sta_a(COLOR4) + sta_a(COLBK)        # black background
    c += lda_i(0x0E) + sta_a(COLOR1) + sta_a(COLPF1)       # lit pixel: luma from COLPF1
    c += lda_i(0x94) + sta_a(COLOR2) + sta_a(COLPF2)       # hue from COLPF2
    c += jmp(PROG + len(c))
    return c


def dlist():
    d = bytes([0x70, 0x70, 0x70])
    d += bytes([0x4F, SCR & 0xFF, SCR >> 8])
    d += bytes([0x0F]) * (NLINES - 1)
    d += bytes([0x41, DL & 0xFF, DL >> 8])
    return d


def seg(addr, data):
    end = addr + len(data) - 1
    return bytes([addr & 0xFF, addr >> 8, end & 0xFF, end >> 8]) + data


def main():
    out  = sys.argv[1] if len(sys.argv) > 1 else "/tmp/gr8.xex"
    fill = int(sys.argv[2], 0) if len(sys.argv) > 2 else 0xAA
    x = b"\xff\xff"
    x += seg(PROG, program())
    x += seg(DL, dlist())
    x += seg(SCR, bytes([fill]) * (40 * NLINES))
    x += seg(0x02E0, bytes([PROG & 0xFF, PROG >> 8]))
    open(out, "wb").write(x)
    print("wrote %s (%d bytes), fill $%02X" % (out, len(x), fill))
    print("  $AA correct -> 1 px runs; $CC -> 2 px; $F0 -> 4 px (at 320 across)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
