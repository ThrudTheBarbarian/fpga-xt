#!/usr/bin/env python3
"""REFERENCE for tb_pm_align: does a GTIA mode shift the playfield vs objects?

Our chip (sim/tb_pm_align.sv, antic2_fabric, the live module) says:

    PRIOR $01 ordinary     playfield edge at emitted px 176, player at 176
    PRIOR $41 GTIA mode 9  playfield edge at emitted px 180, player at 176

i.e. in mode 9 the playfield edge moves +4 hi-res px (2 colour clocks) while
the object stays put.  Real GTIA does delay the playfield in these modes, so
the question is whether the reference shifts by the same amount.

Identical scene, built over the bridge: mode F display list, screen of $00
bytes then $FF bytes (a playfield edge on a known hi-res pixel), one solid
player parked at HPOS 88.  Four passes: {ordinary, mode 9} x {player off, on}.
Coordinate-free comparison -- what matters is the CHANGE in the edge position
between the two PRIOR values, and whether the player moves with it.
"""
import sys, os, glob, collections

sys.path.insert(0, os.path.expanduser(
    '~/src/AltirraSDL/src/AltirraSDL/AltirraBridge/sdk/python'))
from altirra_bridge import AltirraBridge

W, H = 336, 224
DL, SCR = 0x3000, 0x4000
EDGEB = 10                      # first $FF byte -> edge at playfield px 80
HPOS_P0 = 48 + (EDGEB * 8) // 2  # = 88, so the player starts on that edge
LOG = open('altshift.log', 'w', buffering=1)

HPOSP0, SIZEP0, GRAFP0 = 0xD000, 0xD008, 0xD00D
COLPM0, COLPF1, COLPF2 = 0xD012, 0xD017, 0xD018
COLBK, PRIOR, GRACTL = 0xD01A, 0xD01B, 0xD01D
DMACTL, DLISTL = 0xD400, 0xD402
SDMCTL, SDLSTL, GPRIOR = 0x022F, 0x0230, 0x026F
PCOLR0, COLOR1, COLOR2, COLOR4 = 0x02C0, 0x02C5, 0x02C6, 0x02C8

C_BK, C_PF1, C_PF2, C_PM0 = 0x00, 0x0A, 0x60, 0x3A


def build_dl():
    dl = bytes([0x70, 0x70, 0x70, 0x4F, SCR & 0xFF, SCR >> 8])
    dl += bytes([0x0F]) * 100
    dl += bytes([0x41, DL & 0xFF, DL >> 8])
    return dl


def screen():
    row = bytes([0x00]) * EDGEB + bytes([0xFF]) * (40 - EDGEB)
    return row * 101


def runs_of(px, idx_of, y):
    out, start, cur = [], 0, None
    for x in range(W):
        o = (y * W + x) * 4
        i = idx_of.get((px[o + 2], px[o + 1], px[o]), -1)
        if cur is None:
            cur, start = i, 0
        elif i != cur:
            out.append((start, x - 1, cur))
            cur, start = i, x
    out.append((start, W - 1, cur))
    return out


def main():
    tok = sorted(glob.glob(os.environ.get('TMPDIR', '/tmp').rstrip('/') +
                           '/altirra-bridge-*.token'), key=os.path.getmtime)[-1]
    with AltirraBridge.from_token_file(tok) as a:
        a._sock.settimeout(60)
        try:
            a.config('artifact', 'none')
        except Exception as e:
            LOG.write('artifact %r\n' % (e,))
        pal = a.palette()
        idx_of = {}
        for i in range(256):
            idx_of.setdefault((pal[i * 3], pal[i * 3 + 1], pal[i * 3 + 2]), i)
        a.cold_reset()
        a.frame(200)

        for p in range(4):
            prior = 0x01 if p < 2 else 0x41
            graf = 0x00 if p % 2 == 0 else 0xFF
            bk = C_BK if p < 2 else 0x60

            a.memload(SCR, screen())
            a.memload(DL, build_dl())
            for addr, val in ((SDMCTL, 0x22), (GPRIOR, prior),
                              (PCOLR0, C_PM0), (COLOR1, C_PF1),
                              (COLOR2, C_PF2), (COLOR4, bk)):
                a.poke(addr, val)
            a.poke(SDLSTL, DL & 0xFF); a.poke(SDLSTL + 1, DL >> 8)
            for addr, val in ((DMACTL, 0x22), (DLISTL, DL & 0xFF),
                              (DLISTL + 1, DL >> 8), (PRIOR, prior),
                              (GRACTL, 0x00), (COLBK, bk), (COLPF1, C_PF1),
                              (COLPF2, C_PF2), (COLPM0, C_PM0),
                              (HPOSP0, HPOS_P0), (SIZEP0, 0x00), (GRAFP0, graf)):
                a.hwpoke(addr, val)
            a.frame(3)
            for addr, val in ((HPOSP0, HPOS_P0), (SIZEP0, 0x00),
                              (GRAFP0, graf), (PRIOR, prior)):
                a.hwpoke(addr, val)
            a.frame(1)
            a.rawscreen(path='/tmp/alt_shift.bin')
            px = open('/tmp/alt_shift.bin', 'rb').read()

            # a settled display row
            y = 74
            rr = [r for r in runs_of(px, idx_of, y) if r[1] - r[0] >= 2]
            LOG.write('pass %d: PRIOR $%02X %-11s player %s\n' % (
                p, prior, 'ordinary' if p < 2 else 'GTIA MODE 9',
                'OFF' if graf == 0 else 'ON'))
            for s, e, i in rr:
                LOG.write('    run px %3d..%3d  $%02X (len %d)\n' % (s, e, i, e - s + 1))
        LOG.write('DONE\n')


main()
