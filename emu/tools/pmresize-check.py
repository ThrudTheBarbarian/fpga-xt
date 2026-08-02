#!/usr/bin/env python3
"""Score a proposed mid-draw SIZEP model against ALL of gtia_pmresize's tables.

Same idea as pmoverlap-check.py, and for the same reason: the test compiles its
expected values in, so a candidate can be scored against every one of them in a
second instead of a 35-second emulator run.  7 transitions x 16 player positions
= 112 cells.

Geometry, from the test's own runtest (gtia_pmresize.lst line 263 on):
  HPOSP0 = X, swept $48..$57 -- the loop variable is the PLAYER POSITION, not
    the write time, which is fixed
  SIZEP0 = the OLD size, written near the top of the line
  GRAFP0 = $AA, so with gtia.c's `grafp >> (7 - bit)` the LIT bits are 0,2,4,6
  SIZEP0 = the NEW size, written by `sty sizep0` at machine cycles 42..46 --
    the resize under test.  A machine cycle is two colour clocks, so that is
    somewhere around colour clock $54..$5C; the exact clock is what --write-cc
    sweeps, exactly as pmoverlap's was.
  readout: players 1-3 sit at $61,$62,$63 and missiles 0-3 at $64..$67, and
    their collisions are rolled into one byte MSB-first and then ASLed -- so
    bit 7 is $61, bit 1 is $67, bit 0 always clear.

The seven transitions are (old, new) SIZEP values; 2 is the "1xalt" the test
names separately, and it scales the same as 0.
"""
import argparse, re, sys

TABS = [0x2397, 0x23A7, 0x23B7, 0x23C7, 0x23D7, 0x23E7, 0x23F7]
PAIRS = [(3, 0), (3, 1), (1, 3), (0, 1), (0, 3), (1, 2), (3, 2)]
NAMES = ["4x-to-1x", "4x-to-2x", "2x-to-4x", "1x-to-2x", "1x-to-4x",
         "2x-to-1xalt", "4x-to-1xalt"]
PROBE = [0x61, 0x62, 0x63, 0x64, 0x65, 0x66, 0x67]
GRAFP = 0xAA


def scale(s):
    return {1: 2, 3: 4}.get(s & 3, 1)


def load(path):
    mem = {}
    for m in re.finditer(r'^\s*\d+\s+(2[0-9A-F]{3})((?:\s+[0-9A-F]{2})+)',
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


@_reg("phase_kept")
def m_phase_kept(hpos, old, new, wcc):
    """WHAT gtia.c DOES TODAY.  The divider runs at the CURRENT width and the
    phase counter is NOT reset by the SIZEP write, so a phase already past the
    new width rolls on the next clock.  47/112 at $62.

    THE WRITE CLOCK IS $62, and this model PINS it: 4x-to-1x is 16/16 there and
    0/16 two clocks either side.  It reproduces that whole row byte for byte --
    80 80 40 40 40 40 A0 A0 A0 A0 50 50 50 50 A8 A8 -- which is what says the
    geometry and the readout decode here are right, and that what remains is the
    MODEL and not the harness.

    WHERE IT STANDS, per transition at $62:
        4x-to-1x    16/16      1x-to-2x      7/16
        4x-to-2x    12/16      1x-to-4x      7/16
        2x-to-4x     2/16      2x-to-1xalt   3/16
                               4x-to-1xalt   0/16
    So SHRINKING is nearly right and WIDENING is not: 2x-to-4x, 1x-to-2x and
    1x-to-4x are the three that widen, and the two 1x-to-N rows score 7/16 at
    EVERY write clock from $5E to $64 -- they do not depend on the write time at
    all, which means their error is not a timing one.

    And "1xalt" (SIZEP 2) is not the same as 1x (SIZEP 0) even though both scale
    by one: 4x-to-1x is 16/16 while 4x-to-1xalt is 0/16 with an identical scale.
    The test names the difference itself and mentions a "1xalt lockup"."""
    lit, bit, ph, live = set(), 0, 0, False
    for cc in range(0x40, 0xA0):
        w = scale(old if cc < wcc else new)
        if cc == hpos:
            live, bit, ph = True, 0, 0
        elif live:
            ph += 1
            if ph >= w:
                ph = 0
                bit += 1
                if bit >= 8:
                    live = False
        if live and (GRAFP >> (7 - bit)) & 1:
            lit.add(cc)
    return lit


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lst",
                    default="../rsrc/acid800/Acid800/standalone/gtia_pmresize.lst")
    ap.add_argument("--write-cc", type=lambda s: int(s, 0), default=0x62)
    ap.add_argument("--verbose", action="store_true")
    ap.add_argument("--model", default=None, choices=sorted(MODELS))
    ap.add_argument("--sweep", action="store_true",
                    help="score every write-cc from $50 to $68")
    a = ap.parse_args()

    mem = load(a.lst)
    if not mem:
        sys.exit("no table bytes parsed — wrong --lst path?")

    names = [a.model] if a.model else sorted(MODELS)
    for name in names:
        if a.sweep:
            for w in range(0x50, 0x69):
                score(mem, MODELS[name], "%s @$%02X" % (name, w), a, w)
        else:
            score(mem, MODELS[name], name, a, a.write_cc)
    return 0


def score(mem, model, label, a, wcc):
    bad = tot = 0
    for t, (old, new) in enumerate(PAIRS):
        for i in range(16):
            want = mem.get(TABS[t] + i)
            if want is None:
                continue
            hpos = 0x48 + i
            lit = model(hpos, old, new, wcc)
            got = 0
            for b, cc in enumerate(PROBE):
                if cc in lit:
                    got |= 0x80 >> b
            tot += 1
            if got != want:
                bad += 1
                if a.verbose and bad <= 60:
                    print("    %-12s hpos $%02X: want %02X got %02X"
                          % (NAMES[t], hpos, want, got))
    print("  %-22s %3d/%d cells" % (label, tot - bad, tot))


if __name__ == "__main__":
    sys.exit(main())
