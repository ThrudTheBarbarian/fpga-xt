#!/usr/bin/env python3
"""Build a STATIC GTIA-mode-9 + fifth-player scene as a standalone .xex.

BallBlazer's intro draws its goalposts with PRIOR = $54 -- GTIA MODE 9 (PRIOR
bits 7:6 = 01) with the FIFTH PLAYER enabled (bit 4), all four players and all
four missiles positioned from tables.  Read out of a saved Altirra state at the
moment the posts are on screen; there are no DLIs anywhere in that display list,
the per-scanline work is a VCOUNT-driven WSYNC kernel.

The posts themselves measure 12 colour clocks in the reference and ~14 on our
board, which is the thing this scene exists to pin down.  Chasing it in the game
means racing a randomly-chosen animation that lasts a couple of seconds; this
scene holds STILL, so a slow framebuffer grab on the board is fine, and the same
.xex runs under Altirra for the reference.  Nothing here is invented: every
register value is the one the game uses.

    P0  quad width, GRAFP $E0 (3 lit bits)  -> 3 bits x 4cc = 12 colour clocks
    P1  same, 48 colour clocks to the right -- the reference post separation
    M0-M3  packed 2 apart, fifth-player colour COLPF3

Emitting raw opcodes rather than assembling: the program is LDA #imm / STA abs
/ JMP, so an assembler would be a dependency for three opcodes.

    python3 tools/mode9_fifthplayer_scene.py [out.xex]

Then, for the reference, boot it under AltirraSDL; on the board it is
`6502 run /OS/share/<name>.xex`, and because the picture is static the grab can
take as long as it likes.
"""
import sys

PROG, DL, SCR = 0x2000, 0x2400, 0x2500
PMBASE_PAGE = 0x38                       # 2K-aligned: single-line resolution
PM = PMBASE_PAGE << 8                    # $3800
MISS, P0DAT, P1DAT = PM + 0x300, PM + 0x400, PM + 0x500
NLINES = 96

# hardware
HPOSP0, HPOSM0 = 0xD000, 0xD004
SIZEP0, SIZEM  = 0xD008, 0xD00C
PRIOR, GRACTL  = 0xD01B, 0xD01D
DMACTL, PMBASE = 0xD400, 0xD407
# OS shadows -- the VBLANK copies these over the hardware every frame
SDMCTL, SDLSTL, GPRIOR = 0x022F, 0x0230, 0x026F
PCOLR0, COLOR3, COLOR4 = 0x02C0, 0x02C7, 0x02C8

HP0, HP1 = 0x50, 0x80                    # 48 colour clocks apart
GRAF     = 0xE0                          # three lit bits, MSB first
# Playfield nibble.  A LIT playfield is the discriminator that separates "the
# whole plane is dark" from "the playfield draws but the players do not" -- with
# nibble 0 both look identical, which is exactly the ambiguity that cost a round
# trip to the board.
PF_NIB   = 0x8
# PRIOR.  $54 is the game's own value: GTIA mode 9 (bits 7:6=01) + fifth player
# (bit 4).  Overridable so the two features can be bisected against each other --
# $14 is fifth player WITHOUT mode 9, $44 is mode 9 WITHOUT the fifth player.
PRIOR_VAL = 0x54


def lda(v):  return bytes([0xA9, v & 0xFF])
def sta(a):  return bytes([0x8D, a & 0xFF, a >> 8])
def jmp(a):  return bytes([0x4C, a & 0xFF, a >> 8])


def program():
    c = b""
    # display list, via the shadow so the OS VBLANK re-asserts it
    c += lda(DL & 0xFF) + sta(SDLSTL) + lda(DL >> 8) + sta(SDLSTL + 1)
    # $3E: normal playfield + missile DMA + player DMA + single-line + DL DMA.
    # The same value BallBlazer writes.
    c += lda(0x3E) + sta(SDMCTL) + sta(DMACTL)
    c += lda(PRIOR_VAL) + sta(GPRIOR) + sta(PRIOR)      # see PRIOR_VAL
    c += lda(PMBASE_PAGE) + sta(PMBASE)
    c += lda(0x03) + sta(GRACTL)                       # players + missiles
    c += lda(0x03) + sta(SIZEP0) + sta(SIZEP0 + 1)     # quad, P0 and P1
    c += lda(0x00) + sta(SIZEM)
    c += lda(HP0) + sta(HPOSP0)
    c += lda(HP1) + sta(HPOSP0 + 1)
    for i, h in enumerate((0xA0, 0xA2, 0xA4, 0xA6)):   # missiles packed
        c += lda(h) + sta(HPOSM0 + i)
    c += lda(0x0F) + sta(PCOLR0) + sta(PCOLR0 + 1)     # bright players
    c += lda(0x3A) + sta(COLOR3)                       # fifth-player colour
    c += lda(0x00) + sta(COLOR4)                       # black background
    c += jmp(PROG + len(c))                            # hold the picture
    return c


def dlist():
    d = bytes([0x70, 0x70, 0x70])                      # 24 blank lines
    d += bytes([0x4F, SCR & 0xFF, SCR >> 8])           # LMS, ANTIC mode F
    d += bytes([0x0F]) * (NLINES - 1)
    d += bytes([0x41, DL & 0xFF, DL >> 8])             # JVB
    return d


def seg(addr, data):
    end = addr + len(data) - 1
    return bytes([addr & 0xFF, addr >> 8, end & 0xFF, end >> 8]) + data


def main():
    global PRIOR_VAL
    out = sys.argv[1] if len(sys.argv) > 1 else "/tmp/mode9.xex"
    if len(sys.argv) > 2: PRIOR_VAL = int(sys.argv[2], 0)
    x = b"\xff\xff"
    x += seg(PROG, program())
    x += seg(DL, dlist())
    pf = bytes([(PF_NIB << 4) | PF_NIB]) * (40 * NLINES)
    x += seg(SCR, pf)                                  # uniform lit playfield
    x += seg(MISS, b"\xff" * 256)                      # every missile lit
    x += seg(P0DAT, bytes([GRAF]) * 256)
    x += seg(P1DAT, bytes([GRAF]) * 256)
    x += seg(0x02E0, bytes([PROG & 0xFF, PROG >> 8]))  # RUNAD
    open(out, "wb").write(x)
    print("wrote %s (%d bytes)" % (out, len(x)))
    print("  P0 hpos $%02X, P1 hpos $%02X, quad width, GRAFP $%02X"
          % (HP0, HP1, GRAF))
    print("  PRIOR $%02X" % PRIOR_VAL)
    print("  expect each post = 3 lit bits x 4cc = 12 colour clocks")


if __name__ == "__main__":
    main()
