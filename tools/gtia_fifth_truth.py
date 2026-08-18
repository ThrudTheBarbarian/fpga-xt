#!/usr/bin/env python3
"""Build a TRUTH-TABLE probe: what beats what when the FIFTH PLAYER meets the
playfield, in every priority scheme.

Measured on hardware 2026-08-18: with PRIOR $14 the reference draws the fifth
player straight over a playfield that hides ordinary players, and it wins
OUTRIGHT (COLPF3 exactly, not COLPF2|COLPF3).  Neither "the fifth player is
PF3" nor "the fifth player keeps player priority" predicts that in scheme $04,
where the playfield outranks every player -- so the rule has to be MEASURED
rather than reasoned about, across all four schemes and every playfield source.

The scene makes one question askable at a time:

    ANTIC mode E, four horizontal bands of 24 scanlines, whose 2-bit pixels are
        00 -> BAK      01 -> PF0      10 -> PF1      11 -> PF2
    four missiles, solid, parked in a column that crosses every band
    one player, solid, in a second column, as the control

Read the colour in the MISSILE column per band and you have one row of the
table; sweep PRIOR and you have all of it.  Distinct hues per register make the
winner unambiguous by hue alone, which is the only channel safe against
Altirra's GTIA-mode fringing.

    python3 tools/gtia_fifth_truth.py [out.xex] [prior]

Colours: COLPF0 $1A, COLPF1 $3A, COLPF2 $5A, COLPF3 $7A (the fifth player),
COLPM0 $9A (the control player), COLBK $0A.  So the hue IS the source:
1=PF0 3=PF1 5=PF2 7=PF3/fifth 9=player 0=background.
"""
import sys

PROG, DL, SCR = 0x2000, 0x2400, 0x2500
PMBASE_PAGE = 0x38
PM     = PMBASE_PAGE << 8
MISSD  = PM + 0x300
P0DAT  = PM + 0x400
BAND   = 24                      # scanlines per band
NBAND  = 4
NLINES = BAND * NBAND            # 96

HPOSP0, HPOSM0 = 0xD000, 0xD004
SIZEP0, SIZEM  = 0xD008, 0xD00C
PRIOR, GRACTL  = 0xD01B, 0xD01D
COLPM0, COLPF0 = 0xD012, 0xD016
COLPF1, COLPF2, COLPF3, COLBK = 0xD017, 0xD018, 0xD019, 0xD01A
DMACTL, PMBASE = 0xD400, 0xD407
SDMCTL, SDLSTL, GPRIOR = 0x022F, 0x0230, 0x026F
PCOLR0 = 0x02C0
COLOR0, COLOR1, COLOR2, COLOR3, COLOR4 = 0x02C4, 0x02C5, 0x02C6, 0x02C7, 0x02C8

HP0, HM0 = 0x50, 0x70            # player column, missile column: both over the playfield
C_PM0, C_PF0, C_PF1, C_PF2, C_PF3, C_BK = 0x9A, 0x1A, 0x3A, 0x5A, 0x7A, 0x0A
PRIOR_VAL = 0x14


def lda(v): return bytes([0xA9, v & 0xFF])
def sta(a): return bytes([0x8D, a & 0xFF, a >> 8])
def jmp(a): return bytes([0x4C, a & 0xFF, a >> 8])


def program(prior):
    import os
    # OVER=1 parks the missiles ON the player's column, which is the other half of
    # the table: does the fifth player beat a PLAYER, or only the playfield?
    hm = HP0 if os.environ.get("OVER") == "1" else HM0
    c = b""
    c += lda(DL & 0xFF) + sta(SDLSTL) + lda(DL >> 8) + sta(SDLSTL + 1)
    c += lda(0x3E) + sta(SDMCTL) + sta(DMACTL)      # normal PF + P/M DMA + single-line + DL DMA
    c += lda(prior) + sta(GPRIOR) + sta(PRIOR)
    c += lda(PMBASE_PAGE) + sta(PMBASE)
    c += lda(0x03) + sta(GRACTL)
    c += lda(0x00) + sta(SIZEP0) + sta(SIZEM)       # normal width
    c += lda(HP0) + sta(HPOSP0)
    for i in range(4):                              # four missiles packed into one column
        c += lda(hm + 2 * i) + sta(HPOSM0 + i)
    # hardware AND shadow: the OS VBLANK copies the shadows over the registers
    c += lda(C_PM0) + sta(PCOLR0) + sta(COLPM0)
    c += lda(C_PF0) + sta(COLOR0) + sta(COLPF0)
    c += lda(C_PF1) + sta(COLOR1) + sta(COLPF1)
    c += lda(C_PF2) + sta(COLOR2) + sta(COLPF2)
    c += lda(C_PF3) + sta(COLOR3) + sta(COLPF3)
    c += lda(C_BK)  + sta(COLOR4) + sta(COLBK)
    c += jmp(PROG + len(c))
    return c


def dlist():
    d = bytes([0x70, 0x70, 0x70])
    d += bytes([0x4E, SCR & 0xFF, SCR >> 8])        # mode E + LMS
    d += bytes([0x0E]) * (NLINES - 1)
    d += bytes([0x41, DL & 0xFF, DL >> 8])
    return d


def screen():
    # mode E: 2 bits per pixel, 40 bytes per line.  One value per band.
    fill = [0x00, 0x55, 0xAA, 0xFF]                 # BAK, PF0, PF1, PF2
    out = b""
    for r in range(NLINES):
        out += bytes([fill[(r // BAND) % NBAND]]) * 40
    return out


def seg(addr, data):
    end = addr + len(data) - 1
    return bytes([addr & 0xFF, addr >> 8, end & 0xFF, end >> 8]) + data


def main():
    out   = sys.argv[1] if len(sys.argv) > 1 else "/tmp/fifth.xex"
    prior = int(sys.argv[2], 0) if len(sys.argv) > 2 else PRIOR_VAL
    x = b"\xff\xff"
    x += seg(PROG, program(prior))
    x += seg(DL, dlist())
    x += seg(SCR, screen())
    x += seg(MISSD, b"\xff" * 256)                  # all four missiles, every scanline
    x += seg(P0DAT, b"\xff" * 256)                  # the control player
    x += seg(0x02E0, bytes([PROG & 0xFF, PROG >> 8]))
    open(out, "wb").write(x)
    print("wrote %s (%d bytes), PRIOR $%02X" % (out, len(x), prior))
    print("  bands top->bottom: BAK, PF0, PF1, PF2;  hue 1=PF0 3=PF1 5=PF2 7=fifth 9=player")
    return 0


if __name__ == "__main__":
    sys.exit(main())
