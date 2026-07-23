#!/usr/bin/env python3
"""Exact-RTL model of wsync_gen + the fid core's commit-slot sampling.

The fid core retires machine-cycle window K at SUB_COMMIT (~the next ANTIC
tick T_{K+1}), so what the CPU observes of /RDY is its value latched at the
phi2-FALL retime point of window K.  This script models that sampling exactly
and was validated against hardware: with the original mid-window asynchronous
latch set, its predictions for shapes comb/q1|q2/latch/latch|q2/q2 matched a
5-config on-board sweep byte-for-byte (20/20 result bytes).

That validated machinery then shows WHY no shape passed the full test with
the asynchronous set (the late-INC straddle and the delay slot cannot both be
right), and that REGISTERING the set path — a $D40A write anywhere in window
K drops the latch at tick K+1, a release on that same tick discarding it —
makes the q1 tap pass all six antic_wsync bytes:

    shape      d0 d1 d2 d3 d4 d5
    comb       95 4B 1B 44 92 0F   fail (the measured $1B != $0D)
    010 q1     95 4B 0D 44 E2 34   PASS  <- wsync_gen default
    001 q2     95 4B 0D 44 E2 34   PASS (same shape one window later)

Run: python3 tools/wsyncrtl.py   (needs tools/wsyncmodel.py on the path)
"""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import wsyncmodel as m

LINE = m.LINE
POLY = m.POLY
PROG = [c for ins in m.program() for c in m.I[ins]]
EXPECT = {0: 0x95, 2: 0x0D, 3: 0x44, 5: 0x34}   # the asserted bytes
RELEASE = 103
REFRESH = (25, 9, 4)     # 9 refresh steals, stride 4, from line cycle 25

def run(mask, comb=False, phase=0, registered_set=True):
    """Return d0..d5.  mask = OR over {4:latch, 2:q1, 1:q2} taps."""
    rs, rn, stride = REFRESH
    line = phase
    latch = True; q1 = q2 = True; pend = False
    poly = None; sk = False
    samples = []
    pc = 0; guard = 0
    while pc < len(PROG) and guard < 500000:
        guard += 1
        c = PROG[pc]
        # tick: history registers sample the pre-update latch (nonblocking),
        # then release / pending-write arbitrate — clear beats set.
        q2, q1 = q1, latch
        if line == RELEASE:
            latch = True
            pend = False
        elif pend:
            latch = False
            pend = False
        stolen = rn and ((line - rs) % LINE) < rn * stride \
                     and ((line - rs) % LINE) % stride == 0
        committed = False
        if not stolen:
            is_write = c in ('W', 'WSYNC', 'SKCTL')
            if comb:
                # unregistered output: the commit sample at T_{K+1} sees the
                # post-tick latch, including this window's own WSYNC write
                nxt = (line + 1) % LINE
                nlatch = True if nxt == RELEASE else \
                         (False if c == 'WSYNC' else latch)
                rdy = nlatch
            else:
                rdy = bool((mask & 4 and latch) or (mask & 2 and q1)
                           or (mask & 1 and q2))
            committed = is_write or rdy       # writes are /RDY-immune (NMOS)
        if committed:
            if c == 'RAND':
                samples.append(POLY[poly] if poly is not None else None)
            elif c == 'SKCTL':
                sk = True
            elif c == 'WSYNC':
                if registered_set:
                    pend = True               # applies at the next tick
                else:
                    latch = False             # legacy mid-window fall
            pc += 1
        line = (line + 1) % LINE
        if poly is not None: poly += 1
        elif sk: poly = 0; sk = False
    return samples

if __name__ == '__main__':
    names = {'comb': (0, True), '001 q2': (1, False), '010 q1': (2, False),
             '011 q1|q2': (3, False), '100 L': (4, False),
             '101 L|q2': (5, False), '110 L|q1': (6, False),
             '111 all': (7, False)}
    print('shape      d0 d1 d2 d3 d4 d5   verdict (all 8 line phases)')
    for name, (mask, comb) in names.items():
        ok = True
        for ph in range(8):
            r = run(mask, comb=comb, phase=ph)
            if len(r) != 6 or any(v is None for v in r) or \
               any(r[k] != v for k, v in EXPECT.items()):
                ok = False
        r = run(mask, comb=comb)
        cells = ' '.join(f'{v:02X}' if v is not None else '--' for v in r) \
                if len(r) == 6 else 'incomplete'
        print(f'{name:10s} {cells}   {"PASS" if ok else "fail"}')
