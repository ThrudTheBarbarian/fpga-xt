#!/usr/bin/env python3
"""Turn an `emu/build/acid` run into a dashboard run file, then regenerate the page.

The dashboard was built for FABRIC sweeps, which are transcribed by hand from a
screen grab.  The software emulator prints the same information to stdout, so
this reads that directly — the point being that a score bump can be recorded
without a hardware round-trip, and the two cores land side by side on the same
page for comparison.

    python3 docs/a800/from-emu.py [--note "..."] [--date YYYY-MM-DD] [--dry-run]

It runs `make acid` itself (never `./build/acid` straight, because a failed
build leaves the previous binary in place and would record a stale score),
writes runs/<date>[-<seq>].json with core "emu", and calls gen.py.

acid's output looks like:

      "Character mode DMACTL early test failed: stride=%d"
  antic_pfstarttiming      fail  65797 cycles
  antic_pmdma              PASS  182745 cycles

so a quoted line is the detail belonging to the NEXT test line.  Statuses map
  PASS -> pass,  fail -> fail,  skip -> na,  JAM/LOOP -> error.
`na` is excluded from the dashboard's pass/total, which is right for the tests
the suite itself declines to run (the 65C816 probe, the menu-loaded modules).
"""
import argparse, datetime, json, os, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
EMU  = os.path.join(REPO, "emu")

STATUS = {"PASS": "pass", "fail": "fail", "skip": "na", "JAM": "error",
          "LOOP": "error", "HANG": "error"}

LINE = re.compile(r"^  (\S+)\s+(PASS|fail|skip|JAM|LOOP|HANG)\s+(\d+) cycles\s*$")
DETAIL = re.compile(r'^\s+"(.*)"\s*$')


def run_acid():
    out = subprocess.run(["make", "acid"], cwd=EMU, capture_output=True, text=True)
    if out.returncode != 0:
        sys.stderr.write(out.stdout + out.stderr)
        sys.exit("from-emu: `make acid` failed — refusing to record a stale score")
    return out.stdout


def parse(text):
    results, detail = {}, None
    for line in text.splitlines():
        m = DETAIL.match(line)
        if m:
            detail = m.group(1)
            continue
        m = LINE.match(line)
        if not m:
            continue
        name, status, _ = m.groups()
        entry = {"s": STATUS[status]}
        if status == "fail" and detail:
            entry["d"] = detail
        results[name] = entry
        detail = None
    return results


def next_seq(date):
    seq = 1
    while os.path.exists(os.path.join(HERE, "runs", f"{date}-{seq}.json")):
        seq += 1
    return seq


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--note", default="")
    ap.add_argument("--date", default=None)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    results = parse(run_acid())
    if not results:
        sys.exit("from-emu: no test lines in acid's output")

    npass = sum(1 for v in results.values() if v["s"] == "pass")
    ntot  = sum(1 for v in results.values() if v["s"] != "na")
    print(f"from-emu: {npass}/{ntot} pass ({len(results)} tests seen)")
    if args.dry_run:
        return

    date = args.date or datetime.date.today().isoformat()
    seq  = next_seq(date)
    head = subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=REPO,
                          capture_output=True, text=True).stdout.strip()
    run = {"date": date, "seq": seq, "core": "emu", "bitstream": f"emu@{head}",
           "note": args.note, "results": results}
    path = os.path.join(HERE, "runs", f"{date}-{seq}.json")
    with open(path, "w") as f:
        json.dump(run, f, indent=1)
        f.write("\n")
    print("from-emu: wrote", os.path.relpath(path, REPO))

    subprocess.check_call([sys.executable, os.path.join(HERE, "gen.py")])


if __name__ == "__main__":
    main()
