#!/usr/bin/env python3
"""Build a TEAR PROBE as a standalone .xex: one tall player that jumps a known
distance every frame.

The BallBlazer tear is only identifiable by the offset equalling ONE FRAME of
motion, and that needs the per-frame motion to be known.  In the game it has to
be recovered from consecutive frames, which board grabs (seconds apart) cannot
give -- and every single-frame detector I tried was fooled by the intro's
slanted ramp edges, which step by a few pixels per scanline as a matter of
static geometry.

So make the motion enormous and known: a full-height player, quad width, solid
graphics, whose HPOS advances by STEP colour clocks once per frame.  Then:

    no tear  -> ONE vertical bar, constant x down the whole screen
    tear     -> the bar is broken into segments offset by EXACTLY STEP colour
                clocks, and the break row is the tear row

Nothing else in the picture, so there is no slanted geometry to confuse a
measurement, and the offset is self-calibrating -- STEP is chosen here, not
inferred.  P/M graphics come from ANTIC's DMA so every scanline is drawn without
the CPU touching GRAFP.

    python3 tools/tear_probe_scene.py [out.xex] [step_cc]
"""
import sys

PROG, DL, SCR = 0x2000, 0x2400, 0x2500
PMBASE_PAGE = 0x38
PM = PMBASE_PAGE << 8
P0DAT = PM + 0x400
NLINES = 96
HPOS_VAR = 0x80                          # zero page: the player's current HPOS

HPOSP0, SIZEP0 = 0xD000, 0xD008
PRIOR, GRACTL  = 0xD01B, 0xD01D
VCOUNT         = 0xD40B
DMACTL, PMBASE = 0xD400, 0xD407
SDMCTL, SDLSTL, GPRIOR = 0x022F, 0x0230, 0x026F
PCOLR0, COLOR4 = 0x02C0, 0x02C8

STEP = 40                                # colour clocks per frame


def lda_i(v): return bytes([0xA9, v & 0xFF])
def lda_a(a): return bytes([0xAD, a & 0xFF, a >> 8])
def lda_z(a): return bytes([0xA5, a & 0xFF])
def sta_a(a): return bytes([0x8D, a & 0xFF, a >> 8])
def sta_z(a): return bytes([0x85, a & 0xFF])
def adc_i(v): return bytes([0x69, v & 0xFF])
def jmp(a):   return bytes([0x4C, a & 0xFF, a >> 8])
def bne(off): return bytes([0xD0, off & 0xFF])
def beq(off): return bytes([0xF0, off & 0xFF])


def program(step, vc=0):
    c = b""
    c += lda_i(DL & 0xFF) + sta_a(SDLSTL) + lda_i(DL >> 8) + sta_a(SDLSTL + 1)
    c += lda_i(0x3E) + sta_a(SDMCTL) + sta_a(DMACTL)      # playfield + P/M DMA
    c += lda_i(0x00) + sta_a(GPRIOR) + sta_a(PRIOR)       # plain priority
    c += lda_i(PMBASE_PAGE) + sta_a(PMBASE)
    c += lda_i(0x03) + sta_a(GRACTL)
    c += lda_i(0x03) + sta_a(SIZEP0)                      # quad width
    c += lda_i(0x0F) + sta_a(PCOLR0)                      # bright
    c += lda_i(0x00) + sta_a(COLOR4)                      # black background
    c += lda_i(0x40) + sta_z(HPOS_VAR) + sta_a(HPOSP0)

    # Once per frame, at the TOP of the frame, advance HPOS by `step`. Waiting on
    # VCOUNT==0 puts the write in vertical blank, so a correctly composed frame
    # shows the bar at ONE x -- any break is the display path, not this program.
    # Wait for VCOUNT == vc, write, then wait for VCOUNT != vc.  Making the
    # trigger a parameter turns this into a CALIBRATION: move the write to a
    # known VCOUNT and see where the tear lands.  If the tear row tracks vc,
    # the render is doing exactly what the CPU asked and the question becomes
    # where VCOUNT's zero actually sits relative to surface row 0.
    loop = PROG + len(c)
    w0 = lda_a(VCOUNT) + bytes([0xC9, vc & 0xFF]) + bne(-7 & 0xFF)
    body = lda_z(HPOS_VAR) + bytes([0x18]) + adc_i(step) + sta_z(HPOS_VAR) + sta_a(HPOSP0)
    w1 = lda_a(VCOUNT) + bytes([0xC9, vc & 0xFF]) + beq(-7 & 0xFF)
    c += w0 + body + w1 + jmp(loop)
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
    out = sys.argv[1] if len(sys.argv) > 1 else "/tmp/tear.xex"
    step = int(sys.argv[2], 0) if len(sys.argv) > 2 else STEP
    vc   = int(sys.argv[3], 0) if len(sys.argv) > 3 else 0
    x = b"\xff\xff"
    x += seg(PROG, program(step, vc))
    x += seg(DL, dlist())
    x += seg(SCR, b"\x00" * (40 * NLINES))       # black playfield: bar only
    x += seg(P0DAT, b"\xff" * 256)               # solid player, every scanline
    x += seg(0x02E0, bytes([PROG & 0xFF, PROG >> 8]))
    open(out, "wb").write(x)
    print("wrote %s (%d bytes), step = %d CC/frame, write at VCOUNT=$%02X" % (out, len(x), step, vc))
    print("  no tear -> one bar at a constant x; tear -> segments offset by %d CC" % step)


if __name__ == "__main__":
    main()
