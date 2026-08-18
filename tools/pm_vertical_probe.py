#!/usr/bin/env python3
"""Build a STATIC probe for the VERTICAL EXTENT of players and missiles.

Found while clearing BallBlazer: with PRIOR $14 (fifth player, no GTIA mode) the
reference draws the fifth player down the whole frame while we draw only half of
it, and the players come up short at $14 and $04 as well.  Totals cannot say
whether that is a scale error, an offset, or a clip, so this probe makes the
vertical structure KNOWN instead of uniform:

    P0 data     16 lit scanlines, 16 blank, repeating   (blocks start at row 0)
    missiles    the same pattern shifted down 8 rows     (blocks start at row 8)

so the two interleave and cannot be confused.  A correct render reproduces the
block pattern at 1 table byte = 1 scanline (DMACTL bit 4 = single-line
resolution, which is what this sets and what BallBlazer uses).  Read the ROW SET
of each colour:

    blocks half as tall / twice as many   -> resolution bit mishandled
    blocks shifted                        -> table origin off
    pattern stops partway down            -> a clip or a short fetch

Read by HUE (player hue 3, missiles hue 5), never by run width: Altirra fringes
GTIA-mode pixels, and while this probe's default PRIOR is not a GTIA mode, the
same discipline keeps the comparison honest across all the PRIOR values.

    python3 tools/pm_vertical_probe.py [out.xex] [prior]

`prior` default $14 (fifth player, no GTIA mode -- where the difference showed).
Controls: $04 (no fifth player), $54 (the game's: fifth player + GTIA mode 9).
"""
import sys

PROG, DL, SCR = 0x2000, 0x2400, 0x2500
PMBASE_PAGE = 0x38                       # 2K-aligned -> single-line resolution
PM     = PMBASE_PAGE << 8
MISSD  = PM + 0x300
P0DAT  = PM + 0x400
NLINES = 96

HPOSP0, HPOSM0 = 0xD000, 0xD004
SIZEP0, SIZEM  = 0xD008, 0xD00C
PRIOR, GRACTL  = 0xD01B, 0xD01D
DMACTL, PMBASE = 0xD400, 0xD407
SDMCTL, SDLSTL, GPRIOR = 0x022F, 0x0230, 0x026F
PCOLR0, COLOR3, COLOR4 = 0x02C0, 0x02C7, 0x02C8
COLPM0, COLPF3, COLBK  = 0xD012, 0xD019, 0xD01A

HP0, HM0  = 0x50, 0x70
C_PLAYER  = 0x3A                         # hue 3
C_FIFTH   = 0x5A                         # hue 5 (COLPF3 = the fifth player)
C_BK      = 0x00
BLOCK     = 16                           # lit rows per block
PRIOR_VAL = 0x14


def lda(v): return bytes([0xA9, v & 0xFF])
def sta(a): return bytes([0x8D, a & 0xFF, a >> 8])
def jmp(a): return bytes([0x4C, a & 0xFF, a >> 8])


def program(prior):
    c = b""
    c += lda(DL & 0xFF) + sta(SDLSTL) + lda(DL >> 8) + sta(SDLSTL + 1)
    # $3E: normal playfield + missile DMA + player DMA + SINGLE-LINE + DL DMA
    c += lda(0x3E) + sta(SDMCTL) + sta(DMACTL)
    c += lda(prior) + sta(GPRIOR) + sta(PRIOR)
    c += lda(PMBASE_PAGE) + sta(PMBASE)
    c += lda(0x03) + sta(GRACTL)
    c += lda(0x00) + sta(SIZEP0) + sta(SIZEM)      # normal width: extent is the question
    c += lda(HP0) + sta(HPOSP0)
    c += lda(HM0) + sta(HPOSM0)
    # Write the HARDWARE register as well as the OS shadow.  Shadow-only left the
    # colour at whatever the VBLANK last copied, which is a silent way for a probe
    # to render nothing and be believed.
    c += lda(C_PLAYER) + sta(PCOLR0) + sta(COLPM0)
    c += lda(C_FIFTH) + sta(COLOR3) + sta(COLPF3)
    c += lda(C_BK) + sta(COLOR4) + sta(COLBK)
    c += jmp(PROG + len(c))
    return c


def dlist():
    d = bytes([0x70, 0x70, 0x70])
    d += bytes([0x4F, SCR & 0xFF, SCR >> 8])
    d += bytes([0x0F]) * (NLINES - 1)
    d += bytes([0x41, DL & 0xFF, DL >> 8])
    return d


def strips():
    """P0 lit in even blocks; missiles lit in the same blocks shifted down 8.

    SOLID=1 in the environment instead fills every one of the 256 table rows,
    which measures the VERTICAL COVERAGE WINDOW directly: whatever rows come out
    lit are exactly the rows the hardware fetches and renders P/M for."""
    import os
    p0 = bytearray(256)
    ms = bytearray(256)
    solid = os.environ.get("SOLID") == "1"
    for r in range(256):
        if solid or ((r // BLOCK) % 2) == 0:
            p0[r] = 0xFF
        if solid or ((((r - BLOCK // 2) // BLOCK) % 2) == 0 and r >= BLOCK // 2):
            ms[r] = 0x03                  # missile 0 = the low 2 bits of GRAFM
    return bytes(p0), bytes(ms)


def seg(addr, data):
    end = addr + len(data) - 1
    return bytes([addr & 0xFF, addr >> 8, end & 0xFF, end >> 8]) + data


def main():
    out   = sys.argv[1] if len(sys.argv) > 1 else "/tmp/pmv.xex"
    prior = int(sys.argv[2], 0) if len(sys.argv) > 2 else PRIOR_VAL
    p0, ms = strips()
    x = b"\xff\xff"
    x += seg(PROG, program(prior))
    x += seg(DL, dlist())
    # NOT a black playfield: in ANTIC mode $F a ZERO pixel takes COLPF2, not
    # COLBK, so the screen shows COLPF2's colour whatever COLBK says.  The probe
    # set COLBK and left COLPF2 at the OS default, which painted the playfield
    # band bright blue and made "objects over the playfield" hard to read.  Set
    # COLPF2 in program() if a dark band is wanted.
    x += seg(SCR, b"\x00" * (40 * NLINES))
    x += seg(MISSD, ms)
    x += seg(P0DAT, p0)
    x += seg(0x02E0, bytes([PROG & 0xFF, PROG >> 8]))
    open(out, "wb").write(x)
    print("wrote %s (%d bytes), PRIOR $%02X" % (out, len(x), prior))
    print("  expect hue-3 blocks of %d rows starting at table row 0," % BLOCK)
    print("  and hue-5 blocks of %d rows starting at table row %d" % (BLOCK, BLOCK // 2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
