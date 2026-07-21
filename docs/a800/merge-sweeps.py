#!/usr/bin/env python3
"""Merge several acid-sweep TSVs into one, keeping the best-measured result.

Why this exists: `xexload -h` on the board fails to load a significant fraction
of the time, and gets worse the longer a sweep runs. Those failures show up as
`error` (load never took) or `na` (loaded but never reached _testEnd) — they are
FAILURES TO MEASURE, not verdicts.

A `pass` or `fail` row, by contrast, is definitive: the CPU halted at the
_testEnd breakpoint and we read the Y register (00 = pass, 80 = fail). So
merging is sound as long as a definitive result always beats a non-result, and
we never silently reconcile two *conflicting* definitive results.

Usage:
    docs/a800/merge-sweeps.py runA.tsv runB.tsv [...] > merged.tsv
"""

import sys

RANK = {"pass": 3, "fail": 3, "na": 2, "error": 1}


def main():
    if len(sys.argv) < 2:
        sys.stderr.write(__doc__)
        return 2

    best = {}      # name -> (status, detail)
    order = []
    conflicts = []

    for path in sys.argv[1:]:
        with open(path) as fh:
            for line in fh:
                line = line.rstrip("\n")
                if not line.strip():
                    continue
                cols = line.split("\t")
                name = cols[0].strip()
                status = cols[1].strip() if len(cols) > 1 else "error"
                detail = cols[2].strip() if len(cols) > 2 else ""
                if name not in best:
                    best[name] = (status, detail)
                    order.append(name)
                    continue
                prev, prev_detail = best[name]
                # a definitive result disagreeing with another definitive result
                # is a real problem (flaky hardware / nondeterminism) - surface it
                if RANK.get(status, 0) == 3 and RANK.get(prev, 0) == 3 and status != prev:
                    conflicts.append(f"{name}: {prev} vs {status}")
                if RANK.get(status, 0) > RANK.get(prev, 0):
                    best[name] = (status, detail or prev_detail)

    for name in order:
        status, detail = best[name]
        if detail:
            print(f"{name}\t{status}\t{detail}")
        else:
            print(f"{name}\t{status}")

    counts = {}
    for name in order:
        counts[best[name][0]] = counts.get(best[name][0], 0) + 1
    sys.stderr.write(f"merge-sweeps: {len(order)} tests {counts}\n")
    if conflicts:
        sys.stderr.write("merge-sweeps: CONFLICTING definitive results (investigate,"
                         " do NOT trust these rows):\n")
        for c in conflicts:
            sys.stderr.write(f"  {c}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
