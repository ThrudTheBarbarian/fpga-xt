#!/usr/bin/env python3
"""Score a proposed P/M geometry model against ALL of gtia_pmoverlap's tables.

The test is 12 passes x 2 missile positions x 28 player positions = 672 cells,
and its expected values are compiled into the .lst.  Any model of "what a
mid-line HPOS write does to a player that is already drawing" can be checked
against every one of them here, in a second, without touching the emulator.

That matters because a model fitted to a handful of rows will look right and be
wrong: the "shift register is never reloaded" reading matches pass 3's first
four rows exactly and misses 342 of the 672.

Usage:  python3 tools/pmoverlap-check.py [--lst PATH] [--write-cc N] [--verbose]

Geometry the test sets up, for anyone writing a new model() below:
  GRAFP0 = $81   - only bit 7 and bit 0 lit, the player's two EDGE pixels
  GRAFM  = $AA   - each missile 2 clocks with only the first lit
  SIZEM  = $00
  HPOSP0 = $60 written at colour clock $14, then Y written mid-line
  missiles at scanpos .. scanpos+3, scanpos toggling by 4 between the two halves
  even scanpos (bit 2 clear) -> the table byte's HIGH nibble, else the LOW
  table index = Y xor $60, Y running $64..$7f
"""
import argparse, re, sys

TABS  = [0x3000,0x3020,0x3040,0x3060,0x3080,0x30A0,
         0x30C0,0x30E0,0x3100,0x3120,0x3140,0x3160]
SIZEP = [3]*6 + [1]*4 + [0]*2
MSTART= [0x60,0x68,0x70,0x78,0x80,0x88, 0x60,0x68,0x70,0x78, 0x60,0x68]
WIDTH = {3: 4, 1: 2, 0: 1}


def load(path):
    mem = {}
    for m in re.finditer(r'^\s*\d+\s+(3[01][0-9A-F]{2})((?:\s+[0-9A-F]{2})+)',
                         open(path).read(), re.M):
        base = int(m.group(1), 16)
        for i, b in enumerate(m.group(2).split()):
            mem.setdefault(base + i, int(b, 16))
    return mem


MODELS = {}


def _reg(name):
    def d(f):
        MODELS[name] = f
        return f
    return d


@_reg("restart")
def m_restart(width, Y, write_cc):
    """Every HPOS match retriggers the object from bit 0, cancelling the
    emission in progress.  THIS IS WHAT gtia.c DOES TODAY.  624/672."""
    lit, active, bit, ph = set(), False, 0, 0
    for cc in range(0x50, 0xB0):
        hp = 0x60 if cc < write_cc else Y
        if cc == hp:
            active, bit, ph = True, 0, 0
        elif active:
            ph += 1
            if ph >= width:
                ph, bit = 0, bit + 1
                if bit >= 8:
                    active = False
        if active and bit < 8 and (0x81 >> (7 - bit)) & 1:
            lit.add(cc)
    return lit


@_reg("union")
def m_union(width, Y, write_cc):
    """A match starts a NEW emission and leaves any already running alone, so a
    player moved mid-line can appear twice.  634/672 — the best so far, and the
    reason to believe it: pass 10 wants BOTH the original emission's lit bit at
    $67 AND the new one's at $64, which no single-emission model can give."""
    lit, starts = set(), []
    for cc in range(0x50, 0xB0):
        hp = 0x60 if cc < write_cc else Y
        if cc == hp:
            starts.append(cc)
        for s in starts:
            k = (cc - s) // width
            if 0 <= k < 8 and (0x81 >> (7 - k)) & 1:
                lit.add(cc)
    return lit


@_reg("union_realign")
def m_union_realign(width, Y, write_cc):
    """union, PLUS: the HPOS write re-aligns every running emission's divider
    phase to the new position.  660/672 — the best known, and the two effects
    are independent: union alone is 634, realign is what takes pass 3 from 33
    misses to 3.

    The realign is what pass 3's period-FOUR repeat in Y demands.  Its wanted
    values cycle 7,3,1,0 as Y advances, which is a bit boundary moving with
    Y mod width — the running emission's boundaries shift to line up with the
    newly written position while its bit counter keeps counting.

    Residual 12: pass 3 sp $78 at Y $7d..$7f (we light, hardware does not) and
    pass 7 sp $6c at odd Y (we light one clock too many).  Both are us lighting
    MORE than hardware, so whatever is missing SUPPRESSES rather than adds."""
    em, lit = [], set()
    for cc in range(0x50, 0xB0):
        hp = 0x60 if cc < write_cc else Y
        for e in em:
            e[1] += 1
            if e[1] >= width:
                e[1], e[0] = 0, e[0] + 1
        if cc == write_cc:
            d = (Y - cc) % width or width
            for e in em:
                e[1] = width - d
        if cc == hp:
            em.append([0, 0])
        for e in em:
            if e[0] < 8 and (0x81 >> (7 - e[0])) & 1:
                lit.add(cc)
    return lit


@_reg("realign_capped")
def m_realign_capped(width, Y, write_cc):
    """union_realign, but an emission stops at its ORIGINAL end -- start plus
    eight pixel-widths -- so the re-align may move its internal boundaries but
    cannot lengthen the run.  Tests the residual's shape directly: "we light
    one clock too many" is a run ending one clock late, not a whole extra run."""
    em, lit = [], set()
    for cc in range(0x50, 0xB0):
        hp = 0x60 if cc < write_cc else Y
        for e in em:
            e[1] += 1
            if e[1] >= width:
                e[1], e[0] = 0, e[0] + 1
        if cc == write_cc:
            d = (Y - cc) % width or width
            for e in em:
                e[1] = width - d
        if cc == hp:
            em.append([0, 0, cc])
        for e in em:
            if cc >= e[2] + 8 * width:
                continue
            if e[0] < 8 and (0x81 >> (7 - e[0])) & 1:
                lit.add(cc)
    return lit


@_reg("realign_killold")
def m_realign_killold(width, Y, write_cc):
    """union_realign, but the OLD emission STOPS the moment the new one
    triggers -- one shift register per player, so a re-trigger reloads it and
    what stayed on screen is only what had already been emitted.  Tests the
    "whatever is missing SUPPRESSES" reading of union_realign's residual."""
    em, lit = [], set()
    for cc in range(0x50, 0xB0):
        hp = 0x60 if cc < write_cc else Y
        for e in em:
            e[1] += 1
            if e[1] >= width:
                e[1], e[0] = 0, e[0] + 1
        if cc == write_cc:
            d = (Y - cc) % width or width
            for e in em:
                e[1] = width - d
        if cc == hp:
            em = [[0, 0]]                 # reload: the old run is gone
        for e in em:
            if e[0] < 8 and (0x81 >> (7 - e[0])) & 1:
                lit.add(cc)
    return lit


@_reg("realign_stopatwrite")
def m_realign_stopatwrite(width, Y, write_cc):
    """union_realign, but a running emission is cut at the HPOS WRITE rather
    than at the new trigger -- the write itself ends the old run."""
    em, lit = [], set()
    for cc in range(0x50, 0xB0):
        hp = 0x60 if cc < write_cc else Y
        for e in em:
            e[1] += 1
            if e[1] >= width:
                e[1], e[0] = 0, e[0] + 1
        if cc == write_cc:
            em = []
        if cc == hp:
            em.append([0, 0])
        for e in em:
            if e[0] < 8 and (0x81 >> (7 - e[0])) & 1:
                lit.add(cc)
    return lit


@_reg("noreload")
def m_noreload(width, Y, write_cc):
    """Repositions but never reloads the shift register.  330/672 — DISPROVED,
    kept because it fits pass 3's first four rows exactly and is exactly the
    kind of subset-fit that looks like an answer."""
    lit, start = set(), 0x60
    if Y < write_cc:
        for k in range(8):
            if (0x81 >> (7 - k)) & 1:
                lit |= set(range(start + width*k, start + width*k + width))
    else:
        for n, k in enumerate(range((write_cc - start)//width + 1, 8)):
            if (0x81 >> (7 - k)) & 1:
                lit |= set(range(Y + width*n, Y + width*n + width))
    return lit


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lst", default="../rsrc/acid800/Acid800/standalone/gtia_pmoverlap.lst")
    ap.add_argument("--write-cc", type=lambda s: int(s, 0), default=0x64)
    ap.add_argument("--verbose", action="store_true")
    ap.add_argument("--model", default=None, choices=sorted(MODELS))
    a = ap.parse_args()

    mem = load(a.lst)
    if not mem:
        sys.exit("no table bytes parsed — wrong --lst path?")

    names = [a.model] if a.model else sorted(MODELS)
    for name in names:
        score(mem, MODELS[name], name, a)
    return 0


def score(mem, model, name, a):
    bad = tot = 0
    for p in range(12):
        w = WIDTH[SIZEP[p]]
        for sp in (MSTART[p], MSTART[p] ^ 4):
            for Y in range(0x64, 0x80):
                byte = mem.get(TABS[p] + (Y ^ 0x60))
                if byte is None:
                    continue
                want = (byte >> 4) if (sp & 4) == 0 else (byte & 0xF)
                lit = model(w, Y, a.write_cc)
                got = 0
                for b, m in enumerate((sp, sp+1, sp+2, sp+3)):
                    if m in lit:
                        got |= 8 >> b
                tot += 1
                if got != want:
                    bad += 1
                    if a.verbose and bad <= 20:
                        print("    pass %2d sizep %d sp $%02X Y $%02X: want %X got %X"
                              % (p, SIZEP[p], sp, Y, want, got))
    print("  %-9s %3d/%d cells" % (name, tot - bad, tot))


if __name__ == "__main__":
    sys.exit(main())
