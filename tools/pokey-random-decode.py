#!/usr/bin/env python3
"""Convert a POKEY RANDOM byte into its cycle offset since the SKCTL release.

The ACID800 suite uses RANDOM as a CYCLE-EXACT timestamp: it releases the poly
counters from SKCTL init, then reads $D20A at a known instruction cycle. So a
wrong value is not merely "wrong" -- it tells you exactly how many machine
cycles early or late our timing is.

Model (pinned on HW, see hdl/pokey_audio.sv): AUDCTL[7] selects the 9-bit poly,
x^9 + x^5 + 1, right-shifting with feedback q[0]^q[5], seeded all-ones,
RANDOM = bits [8:1].

    tools/pokey-random-decode.py 4A 95        -> got $4A, expected $95: +1 cycle
"""
import sys

def seq9(steps=2000):
    q, out = 0x1FF, []
    for _ in range(steps):
        out.append((q >> 1) & 0xFF)
        nb = ((q >> 0) & 1) ^ ((q >> 5) & 1)
        q = ((q >> 1) | (nb << 8)) & 0x1FF
    return out

S = seq9()

def steps_for(v):
    return [i for i, x in enumerate(S) if x == v]

def main():
    if len(sys.argv) < 2:
        sys.stderr.write(__doc__)
        return 2
    got = int(sys.argv[1], 16)
    g = steps_for(got)
    print(f"got $%02X  -> sequence steps {g[:6]}" % got)
    if len(sys.argv) > 2:
        exp = int(sys.argv[2], 16)
        e = steps_for(exp)
        print(f"expected $%02X -> sequence steps {e[:6]}" % exp)
        # nearest pairing tells the cycle error
        best = min(((abs(a - b), a - b, a, b) for a in g for b in e), default=None)
        if best:
            _, delta, a, b = best
            sign = "LATE (we advanced too far)" if delta > 0 else "EARLY (not far enough)"
            print(f"\nnearest pairing: ours step {a}, hardware step {b}")
            print(f"=> our read is {abs(delta)} machine cycle(s) {sign}")
    return 0

if __name__ == "__main__":
    sys.exit(main())
