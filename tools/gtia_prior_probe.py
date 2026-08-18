#!/usr/bin/env python3
"""Build a STATIC probe for WHICH PRIORITY CLASS EACH GTIA MODE-9 NIBBLE JOINS.

BallBlazer's intro runs PRIOR $54 -- GTIA mode 9 plus priority select 4, which
puts PF0/PF1 ABOVE the players and the players above PF2/PF3.  Its bitmap is
STATIC and the craft is two quad-width players sweeping across it, so whether a
playfield feature shows THROUGH the craft or is hidden BEHIND it is decided
entirely by which priority class that pixel's nibble belongs to.  That is the
remaining candidate for the missing windscreen.

An earlier scene tested PRIOR $54 with ONE uniform nibble and matched, which
proves nothing about the other fifteen values.  This one sweeps all sixteen:

    horizontal bands  -- 6 scanlines each, all 16 nibble values top to bottom
    one vertical bar  -- P0, quad width, solid, crossing every band

Read it by HUE, never by run width.  COLBK carries hue 6 so the whole playfield
is hue 6 whatever its luminance; the player is hue 3.  So inside the bar's x
range each band answers one question with one bit:

    hue 3 -> the PLAYER won that nibble
    hue 6 -> the PLAYFIELD won it

Hue is the only safe channel here: Altirra renders each GTIA-mode pixel as 2 px
of the true colour plus a 2 px fringe that perturbs LUMINANCE but preserves HUE,
so luminance populations and run widths cannot be compared against it at all.

    python3 tools/gtia_prior_probe.py [out.xex] [prior]

`prior` default $54 (the game's).  Controls worth running: $44 (mode 9, priority
select 0), $04 (priority select 4, no GTIA mode), $14, $C4.
"""
import sys

PROG, DL, SCR = 0x2000, 0x2400, 0x2500
PMBASE_PAGE = 0x38                       # 2K-aligned: single-line resolution
P0DAT = (PMBASE_PAGE << 8) + 0x400
NLINES = 96                              # 16 bands x 6 scanlines
BAND   = 6

HPOSP0, SIZEP0 = 0xD000, 0xD008
PRIOR, GRACTL  = 0xD01B, 0xD01D
COLBK          = 0xD01A
DMACTL, PMBASE = 0xD400, 0xD407
SDMCTL, SDLSTL, GPRIOR = 0x022F, 0x0230, 0x026F
PCOLR0, COLOR4 = 0x02C0, 0x02C8

HP0       = 0x60                         # mid-screen; 32 CC of solid player
C_PLAYER  = 0x3A                         # hue 3
C_BK      = 0x60                         # hue 6 -> the mode-9 playfield's hue
PRIOR_VAL = 0x54


def lda(v): return bytes([0xA9, v & 0xFF])
def sta(a): return bytes([0x8D, a & 0xFF, a >> 8])
def jmp(a): return bytes([0x4C, a & 0xFF, a >> 8])


def program(prior):
    c = b""
    c += lda(DL & 0xFF) + sta(SDLSTL) + lda(DL >> 8) + sta(SDLSTL + 1)
    # $3E: normal playfield + missile DMA + player DMA + single-line + DL DMA,
    # the same value BallBlazer writes.
    c += lda(0x3E) + sta(SDMCTL) + sta(DMACTL)
    c += lda(prior) + sta(GPRIOR) + sta(PRIOR)
    c += lda(PMBASE_PAGE) + sta(PMBASE)
    c += lda(0x03) + sta(GRACTL)
    c += lda(0x03) + sta(SIZEP0)                    # quad width
    c += lda(HP0) + sta(HPOSP0)
    c += lda(C_PLAYER) + sta(PCOLR0)
    c += lda(C_BK) + sta(COLOR4) + sta(COLBK)       # mode 9 takes hue from here
    c += jmp(PROG + len(c))                         # park: the picture is static
    return c


def dlist():
    d = bytes([0x70, 0x70, 0x70])
    d += bytes([0x4F, SCR & 0xFF, SCR >> 8])
    d += bytes([0x0F]) * (NLINES - 1)
    d += bytes([0x41, DL & 0xFF, DL >> 8])
    return d


def screen():
    # Row r is filled with nibble value (r // BAND): both nibbles of every byte,
    # so a whole band is one value and the player crosses all sixteen.
    out = b""
    for r in range(NLINES):
        v = (r // BAND) & 0x0F
        out += bytes([(v << 4) | v]) * 40
    return out


def seg(addr, data):
    end = addr + len(data) - 1
    return bytes([addr & 0xFF, addr >> 8, end & 0xFF, end >> 8]) + data


def main():
    out   = sys.argv[1] if len(sys.argv) > 1 else "/tmp/prior.xex"
    prior = int(sys.argv[2], 0) if len(sys.argv) > 2 else PRIOR_VAL
    x = b"\xff\xff"
    x += seg(PROG, program(prior))
    x += seg(DL, dlist())
    x += seg(SCR, screen())
    x += seg(P0DAT, b"\xff" * 256)                  # solid player, every scanline
    x += seg(0x02E0, bytes([PROG & 0xFF, PROG >> 8]))
    open(out, "wb").write(x)
    print("wrote %s (%d bytes), PRIOR $%02X" % (out, len(x), prior))
    print("  band n (6 rows) = nibble n; inside the bar: hue 3 = player won, hue 6 = playfield won")
    return 0


if __name__ == "__main__":
    sys.exit(main())
