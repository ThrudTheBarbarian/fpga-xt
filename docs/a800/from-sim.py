#!/usr/bin/env python3
"""Turn an antic2 SIMULATION sweep into a dashboard run file, then regenerate.

The third way of running this suite.  `fid` sweeps come off the board and are
transcribed from a screen grab; `emu` runs come from the software model via
from-emu.py; this reads the output of the iverilog testbench sweep, so the RTL
rewrite lands on the same page as the other two and can be read against them.

    python3 docs/a800/from-sim.py <sweep-log> [--note "..."] [--date YYYY-MM-DD]
                                  [--seq N] [--core antic2] [--dry-run]

It takes a LOG rather than running the sweep itself, which is the opposite of
from-emu.py and deliberate: a full sim sweep is hours, runs in the background,
and must not be re-run just to record it.  The corollary is that this cannot
guarantee the log is current -- say in --note which commit it came from.

The testbench prints one verdict line per test:

    ACID antic_nmist: PASS
    ACID antic_vscroldli: FAIL (reached _testFailed $1e0d)
    ACID cpu_65c816: SKIP (reached _testSkipped $1e3a)
    ACID mod_disp80: RAN (returned to the loader park $FF60)
    ACID pokey_skstat: TIMEOUT (pc $fe21, never reached _testEnd $1d93)

and the sweep wrapper may add `<name>: NO-RESULT (shell timeout)`.

STATUS MAPPING, and why:

    PASS     -> pass
    FAIL     -> fail        the test asserted and we lost
    SKIP     -> na          the test DECLINED to run (hardware it wants is absent)
    RAN      -> na          it ended without asserting anything -- no verdict
    TIMEOUT  -> error       ours; ran to the guard
    NO-RESULT-> error       the wrapper's shell limit, not the harness's guard

`na` is excluded from the dashboard's pass/total.  That is right for SKIP and
RAN alike: neither is a claim about the hardware, and counting either as a
failure would understate the core while counting them as passes would flatter
it.  The two are kept apart in the DETAIL string so the page still says which
happened.

Tests absent from the log render as not-run (grey) -- a PARTIAL sweep records
honestly as partial rather than inheriting stale verdicts from an older run.
"""
import argparse, datetime, json, os, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
RUNS = os.path.join(HERE, "runs")

VERDICT = re.compile(r"^ACID (\S+): (PASS|FAIL|SKIP|RAN|TIMEOUT)\b(.*)$")
NORESULT = re.compile(r"^(\S+): (NO-RESULT|NO VERDICT LINE|MEM-GEN FAILED)\b(.*)$")

STATUS = {"PASS": "pass", "FAIL": "fail", "SKIP": "na", "RAN": "na",
          "TIMEOUT": "error"}


def parse(text):
    results = {}
    for line in text.splitlines():
        line = line.strip()
        m = VERDICT.match(line)
        if m:
            name, verdict, rest = m.groups()
            entry = {"s": STATUS[verdict]}
            rest = rest.strip().strip("()")
            # Keep the detail for everything that is not a plain pass: for a
            # FAIL it names the assert, and for SKIP/RAN it is the whole reason
            # the test is not being counted.
            if verdict != "PASS":
                entry["d"] = f"{verdict}" + (f": {rest}" if rest else "")
            results[name] = entry
            continue
        m = NORESULT.match(line)
        if m:
            name, kind, rest = m.groups()
            results[name] = {"s": "error", "d": (kind + " " + rest.strip()).strip()}
    return results


def next_seq(date):
    n = 0
    for f in os.listdir(RUNS):
        if f.startswith(date) and f.endswith(".json"):
            n += 1
    return n + 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("log", help="sweep output containing the ACID verdict lines")
    ap.add_argument("--note", default="")
    ap.add_argument("--date", default=datetime.date.today().isoformat())
    ap.add_argument("--seq", type=int, default=None)
    ap.add_argument("--core", default="antic2")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()

    with open(a.log) as f:
        results = parse(f.read())
    if not results:
        sys.exit("from-sim: no ACID verdict lines in that log -- nothing recorded")

    tally = {}
    for r in results.values():
        tally[r["s"]] = tally.get(r["s"], 0) + 1
    counted = tally.get("pass", 0) + tally.get("fail", 0) + tally.get("error", 0)
    print(f"from-sim: {len(results)} tests  "
          + "  ".join(f"{k}={v}" for k, v in sorted(tally.items()))
          + f"   (counted {tally.get('pass',0)}/{counted}, na excluded)")

    seq = a.seq if a.seq is not None else next_seq(a.date)
    out = {"date": a.date, "seq": seq, "core": a.core,
           "bitstream": "simulation", "note": a.note, "results": results}
    path = os.path.join(RUNS, f"{a.date}-{seq}.json")
    if a.dry_run:
        print(f"from-sim: would write {path}")
        return
    with open(path, "w") as f:
        json.dump(out, f, indent=2, sort_keys=True)
        f.write("\n")
    print(f"from-sim: wrote {path}")
    subprocess.run([sys.executable, os.path.join(HERE, "gen.py")], check=True)


if __name__ == "__main__":
    main()
