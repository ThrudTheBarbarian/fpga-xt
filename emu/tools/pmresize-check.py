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
# The HPOS sweep does NOT start at the same place for every test: tests 1 and 2
# run $48..$57 and tests 3-7 run $54..$63.  Read off each test's own `mva #$xx d4`
# rather than assumed -- assuming $48 throughout is why the last five transitions
# looked catastrophically wrong when only their input range was.
HPOS0 = [0x48, 0x48, 0x54, 0x54, 0x54, 0x54, 0x54]
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
    new width rolls on the next clock.  94/112 at $62.

    THE WRITE CLOCK IS $62, and this model PINS it: 4x-to-1x is 16/16 there and
    0/16 two clocks either side.  It reproduces that whole row byte for byte --
    80 80 40 40 40 40 A0 A0 A0 A0 50 50 50 50 A8 A8 -- which is what says the
    geometry and the readout decode here are right, and that what remains is the
    MODEL and not the harness.

    WHERE IT STANDS, per transition at $62:
        4x-to-1x    16/16      1x-to-2x     16/16
        4x-to-2x    12/16      1x-to-4x     16/16
        2x-to-4x    16/16      2x-to-1xalt   9/16
                               4x-to-1xalt   9/16
    FIVE of the seven are already exact, so the divider model itself is right and
    what is left is two specific effects.

    (An earlier reading of this table had 2x-to-4x at 2/16 and the two 1x-to-N
    rows at 7/16, and concluded that WIDENING was broken.  That was wrong, and it
    was an input error, not a model one: tests 1 and 2 sweep HPOS $48..$57 but
    tests 3-7 sweep $54..$63, and scoring all seven from $48 mis-fed the last
    five.  Nothing about widening was ever wrong.)

    What remains: 4x-to-2x misses 4, and "1xalt" (SIZEP 2) misses 7 in each of
    its two rows.  Alt is not the same as 1x (SIZEP 0) even though both scale by
    one, and the tables say what the difference is -- testpat6 and testpat7 both
    contain $FE, every one of the seven probes lit, which is the player emitting
    a lit bit CONTINUOUSLY.  That is the "1xalt lockup" the test's own runtest
    comment names, and it is phase-dependent: $FE appears at four of the sixteen
    positions in each row."""
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


@_reg("tap")
def m_tap(hpos, old, new, wcc):
    """The divider is a free-running 2-bit counter and SIZE SELECTS A TAP, rather
    than a comparator that rolls as soon as the phase reaches the width.

    phase_kept's only 4x-to-2x misses are at HPOS = 3 mod 4, and each wants the
    bit boundary ONE CLOCK LATER than an immediate roll gives: at hpos $4b the
    counter stands at 3 when the write lands, and hardware carries the old bit
    through $62 and starts the next at $63.  A comparator says "3 >= 2, roll
    now"; a tap says "the low bit is not zero yet, wait one".

        4x  roll when the counter wraps to 0
        2x  roll when the low bit is 0
        1x  roll every clock

    84/112 -- BETTER where it was aimed and WORSE overall, which makes it a
    useful disproof rather than a dead end.  Per transition against phase_kept's
    94:  4x-to-2x 12 -> 16 (fixed, as intended), but 2x-to-4x 16 -> 10,
    1x-to-2x 16 -> 13 and 1x-to-4x 16 -> 11.

    So the counter is NOT free-running: widening wants the new period to start
    at the WRITE (which is phase_kept, where a roll resets the phase), while
    4x-to-2x at phase 3 wants the boundary left where the OLD width would have
    put it.  Both are true at once and neither model expresses both, so the rule
    is a hybrid that has not been found yet.  The two cases differ in the phase
    at the write (2 vs 3) and in the new width (1 vs 2); which of those selects
    the behaviour is the open question."""
    lit, bit, ph, live = set(), 0, 0, False
    for cc in range(0x40, 0xA0):
        s = old if cc < wcc else new
        w = scale(s)
        if cc == hpos:
            live, bit, ph = True, 0, 0
        elif live:
            ph = (ph + 1) & 3
            roll = (ph == 0) if w == 4 else (ph & 1) == 0 if w == 2 else True
            if roll:
                bit += 1
                if bit >= 8:
                    live = False
        if live and (GRAFP >> (7 - bit)) & 1:
            lit.add(cc)
    return lit


@_reg("carry")
def m_carry(hpos, old, new, wcc):
    """On the resize clock the run rolls iff the phase's low bits are ALL ONES
    for the new width -- (ph & (w-1)) == (w-1) -- rather than iff the phase has
    reached the width.

    Not guessed: the roll/no-roll decision at the write clock was SEARCHED as 12
    free booleans, one per (phase, new width), against the five non-alt
    transitions.  A unique setting scores 80/80, and it reads:

        new width 1   roll at every phase
        new width 2   roll at ODD phases only
        new width 4   no roll at the phases that occur (0 and 1)

    which is exactly "the low log2(w) bits are about to carry".  phase_kept's
    rule, roll iff ph + 1 >= w, agrees everywhere except phase 2 at width 2 --
    the four cells it was missing.  Width 4 phases 2 and 3 never arise (a run
    widening to 4x comes from 1x or 2x, so its phase is 0 or 1), so the formula
    is consistent with every cell the test constrains and unconstrained beyond
    them; that is an inference, flagged as one."""
    lit, bit, ph, live = set(), 0, 0, False
    nw = scale(new)
    for cc in range(0x40, 0xA0):
        w = scale(old) if cc < wcc else nw
        if cc == hpos:
            live, bit, ph = True, 0, 0
        elif live:
            if cc == wcc:
                if (ph & (nw - 1)) == (nw - 1):
                    ph, bit = 0, bit + 1
                else:
                    ph += 1
            else:
                ph += 1
                if ph >= w:
                    ph, bit = 0, bit + 1
            if bit >= 8:
                live = False
        if live and (GRAFP >> (7 - bit)) & 1:
            lit.add(cc)
    return lit


@_reg("carry_lock")
def m_carry_lock(hpos, old, new, wcc):
    """`carry`, plus the 1xalt LOCKUP: SIZEP 2 stops the shifter dead when the
    two phase bits DISAGREE.

    Searched, not guessed, the same way as carry: four free booleans for "does
    phase p lock" and four for "does phase p roll", scored against the two alt
    rows.  A unique setting scores 32/32 and it is

        phase 00 -> roll     phase 01 -> LOCK
        phase 11 -> roll     phase 10 -> LOCK

    i.e. the run advances only while the counter's two bits AGREE, and once they
    disagree it never advances again.  That is why SIZEP 2 differs from SIZEP 0
    at all despite both dividing by one, and it is what the test's own runtest
    comment calls the "1xalt lockup" -- a locked run emits its current bit for
    the rest of the line, which is the $FE (every probe lit) that appears at four
    of the sixteen positions in each alt row."""
    lit, bit, ph, live, locked = set(), 0, 0, False, False
    nw = scale(new)
    alt = (new & 3) == 2
    for cc in range(0x40, 0xA0):
        w = scale(old) if cc < wcc else nw
        if cc == hpos:
            live, bit, ph, locked = True, 0, 0, False
        elif live and not locked:
            if cc == wcc:
                if alt and ((ph >> 1) & 1) != (ph & 1):
                    locked = True
                elif (ph & (nw - 1)) == (nw - 1):
                    ph, bit = 0, bit + 1
                else:
                    ph += 1
            else:
                ph += 1
                if ph >= w:
                    ph, bit = 0, bit + 1
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
            hpos = HPOS0[t] + i
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
