#!/usr/bin/env python3
"""antic_wsync: separate ASSERT-delay from RELEASE-delay on /RDY.

Questions this answers before burning a bitstream:
  1. The combinational shape (assert=0, release=0, immune writes, release@103)
     reproduces the failure measured on it: d2=$1B (1 cycle early) with every
     other byte correct — validating the model against hardware.
  2. Which (assert_d, release_d, immune, release_cycle) combos pass ALL of
     d0/d2/d3/d5 (the asserted ones), and of those, which keep the plain-STA
     resume position identical to the known-booting combinational config?
     Answer: assert_d == release_d >= 1 with release@103 — one registered
     /RDY stage on both edges, which is what wsync_gen.sv implements.

WSYNC latch semantics (validated last session): any $D40A write SETS,
release pulse CLEARS, clear beats a same-cycle set.  /RDY here is derived
from the latch with an asymmetric delay:
    ready_out(t) = OR of latch_ready(t-release_d .. t-assert_d)  (assert_d>=release_d)
so the FALL (stall) is delayed by assert_d machine cycles and the RISE
(resume) by release_d.
"""
import wsyncmodel as m

LINE = m.LINE
POLY = m.POLY
EXPECT = m.EXPECT          # {0:0x95, 2:0x0D, 3:0x44, 5:0x34}

# Real ANTIC refresh: 9 stolen cycles, stride 4, starting at line cycle 25.
REFRESH = (25, 9, 4)

def run(release_cyc, assert_d, release_d, immune, phase=0,
        refresh=REFRESH, want_trace=False):
    rs, rn, stride = refresh
    line = phase
    poly = None; sk = False
    latch_ready = True                     # True = ready (latch clear)
    hist = [True] * 8                      # hist[0] = current, hist[k] = k cycles ago
    samples = []
    trace = []

    def rdy_ready():
        lo, hi = min(assert_d, release_d), max(assert_d, release_d)
        window = hist[lo:hi + 1]
        if assert_d >= release_d:
            return any(window)             # fall delayed more than rise
        return all(window)

    def stolen(l):
        if not rn: return False
        d = (l - rs) % LINE
        return d < rn * stride and d % stride == 0

    def tick(set_write):
        nonlocal line, poly, sk, latch_ready
        line = (line + 1) % LINE
        if poly is not None: poly += 1
        elif sk: poly = 0; sk = False
        if set_write:        latch_ready = False
        if line == release_cyc: latch_ready = True   # clear beats set
        hist.insert(0, latch_ready)
        del hist[8:]

    for ins in m.program():
        for c in m.I[ins]:
            # stall before a cycle RDY is allowed to stall
            while (not rdy_ready() and (c in ('R', 'RAND') or not immune)) \
                  or stolen(line):
                tick(False)
            w = (c == 'WSYNC')
            if c == 'RAND':
                samples.append((poly, line, POLY[poly] if poly is not None else None))
            elif c == 'SKCTL':
                sk = True
            if want_trace and w:
                trace.append(line)
            tick(w)
    return (samples, trace) if want_trace else samples

def show(tag, s):
    ok = all(s[k][2] == v for k, v in EXPECT.items())
    cells = '  '.join(f'd{i}={v:02X}@{l}' if v is not None else f'd{i}=??'
                      for i, (p, l, v) in enumerate(s))
    print(f'{tag}: {cells}  {"PASS" if ok else "fail"}')
    return ok

if __name__ == '__main__':
    print('--- current shipping HW: comb RDY, release@103, writes immune ---')
    for phase in range(3):
        s = run(103, 0, 0, True, phase=phase)
        show(f'phase{phase}', s)

    print()
    print('--- sweep: release_cyc x assert_d x release_d x immune ---')
    # boot-safety reference: the line on which d0 (read right after a plain
    # STA WSYNC) lands in the current booting config
    ref = run(103, 0, 0, True)
    ref_d0_line = ref[0][1]
    print(f'(boot-safety reference: d0 read lands on line cycle {ref_d0_line})')
    for rel_cyc in range(98, 110):
        for ad in range(0, 4):
            for rd in range(0, 4):
                for immune in (True, False):
                    ok_all = []
                    for phase in range(0, 6):
                        s = run(rel_cyc, ad, rd, immune, phase=phase)
                        ok_all.append(all(len(s) == 6 and s[k][2] == v
                                          for k, v in EXPECT.items()))
                    if all(ok_all):
                        s = run(rel_cyc, ad, rd, immune)
                        boot = 'BOOT-SAME' if s[0][1] == ref_d0_line else \
                               f'd0@{s[0][1]} (ref {ref_d0_line})'
                        print(f'release@{rel_cyc} assert_d={ad} release_d={rd} '
                              f'immune={int(immune)}  {boot}')
