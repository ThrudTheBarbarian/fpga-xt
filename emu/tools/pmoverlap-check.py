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


def model(width, Y, write_cc):
    """Return the set of colour clocks player 0 lights on one scan line.

    THIS is the thing under test — replace it and re-run.  The version here is
    "an HPOS write repositions the player but never reloads its graphics shift
    register", which is DISPROVED (342/672).  It is left in as a worked example
    of the shape an answer takes.
    """
    lit, start = set(), 0x60
    if Y < write_cc:                       # comparator already passed: no restart
        for k in range(8):
            if (0x81 >> (7 - k)) & 1:
                lit |= set(range(start + width*k, start + width*k + width))
    else:
        consumed = (write_cc - start)//width + 1
        for n, k in enumerate(range(consumed, 8)):
            if (0x81 >> (7 - k)) & 1:
                lit |= set(range(Y + width*n, Y + width*n + width))
    return lit


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lst", default="../rsrc/acid800/Acid800/standalone/gtia_pmoverlap.lst")
    ap.add_argument("--write-cc", type=lambda s: int(s, 0), default=0x65)
    ap.add_argument("--verbose", action="store_true")
    a = ap.parse_args()

    mem = load(a.lst)
    if not mem:
        sys.exit("no table bytes parsed — wrong --lst path?")

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
                        print("  pass %2d sizep %d sp $%02X Y $%02X: want %X got %X"
                              % (p, SIZEP[p], sp, Y, want, got))
    print("pmoverlap: %d/%d cells match (%d wrong)" % (tot - bad, tot, bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
