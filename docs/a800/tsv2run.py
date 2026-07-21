#!/usr/bin/env python3
"""tsv2run.py — turn the on-board ACID800 sweep TSV into a runs/<date>-<seq>.json.

The board-side sweep (tools/acid-sweep.sh) writes /tmp/acid-sweep.tsv:

    name <TAB> result [ <TAB> detail ]

with result in {pass, fail, na, error}. This converter reads that TSV (pulled to
the Mac) and writes docs/a800/runs/<date>-<seq>.json in the dashboard's run
schema (see docs/a800/README.md):

    { "date", "seq", "core", "bitstream", "note",
      "results": { "<test>": {"s": <status>, "d": <detail?>}, ... } }

The board can only read the Y register (pass/fail), NOT the on-screen assertion
text, so a normal pass/fail row carries no detail. To keep the dashboard's
hover-details, we CARRY FORWARD the `d` string from the most recent prior run
for any test whose new status matches the prior status and whose TSV row
provides no detail of its own.

Usage:
    docs/a800/tsv2run.py acid-sweep.tsv \
        [--date YYYY-MM-DD] [--seq N] [--core fid] \
        [--bitstream "..."] [--note "..."]

Then: python3 docs/a800/gen.py   (regenerate index.html) and commit.
"""
import argparse
import datetime
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
RUNS_DIR = os.path.join(HERE, "runs")
TESTS_JSON = os.path.join(HERE, "tests.json")

VALID = {"pass", "fail", "na", "error"}
RUN_RE = re.compile(r"^(\d{4}-\d{2}-\d{2})-(\d+)\.json$")


def load_test_order():
    """Return the canonical test-name order from tests.json."""
    with open(TESTS_JSON) as f:
        cat = json.load(f)
    return [t["name"] for t in cat["tests"]]


def parse_tsv(path):
    """Parse the sweep TSV -> {name: {"s": status, "d": detail-or-None}}."""
    results = {}
    with open(path) as f:
        for lineno, raw in enumerate(f, 1):
            line = raw.rstrip("\n")
            if not line.strip():
                continue
            cols = line.split("\t")
            name = cols[0].strip()
            status = cols[1].strip() if len(cols) > 1 else ""
            detail = cols[2].strip() if len(cols) > 2 and cols[2].strip() else None
            if status not in VALID:
                sys.stderr.write(
                    f"tsv2run: {path}:{lineno}: bad status {status!r} for {name!r}\n")
                continue
            results[name] = {"s": status, "d": detail}
    return results


def latest_prior_run():
    """Return the results dict of the newest existing runs/<date>-<seq>.json,
    or {} if there are none."""
    best_key = None
    best_path = None
    if not os.path.isdir(RUNS_DIR):
        return {}
    for fn in os.listdir(RUNS_DIR):
        m = RUN_RE.match(fn)
        if not m:
            continue
        key = (m.group(1), int(m.group(2)))
        if best_key is None or key > best_key:
            best_key = key
            best_path = os.path.join(RUNS_DIR, fn)
    if best_path is None:
        return {}
    with open(best_path) as f:
        prior = json.load(f)
    sys.stderr.write(f"tsv2run: carrying details forward from {os.path.basename(best_path)}\n")
    return prior.get("results", {})


def next_seq(date):
    """Smallest unused seq for `date` (1-based)."""
    seqs = []
    if os.path.isdir(RUNS_DIR):
        for fn in os.listdir(RUNS_DIR):
            m = RUN_RE.match(fn)
            if m and m.group(1) == date:
                seqs.append(int(m.group(2)))
    return (max(seqs) + 1) if seqs else 1


def main():
    ap = argparse.ArgumentParser(description="ACID800 sweep TSV -> run JSON")
    ap.add_argument("tsv", help="path to the pulled acid-sweep.tsv")
    ap.add_argument("--date", help="run date YYYY-MM-DD (default: today)")
    ap.add_argument("--seq", type=int, help="run sequence (default: next free for the date)")
    ap.add_argument("--core", default="fid", help="CPU core label (default: fid)")
    ap.add_argument("--bitstream", default="", help="bitstream label")
    ap.add_argument("--note", default="", help="free-form run note")
    args = ap.parse_args()

    date = args.date or datetime.date.today().isoformat()
    if not re.match(r"^\d{4}-\d{2}-\d{2}$", date):
        sys.exit(f"tsv2run: bad --date {date!r} (want YYYY-MM-DD)")
    seq = args.seq if args.seq is not None else next_seq(date)

    order = load_test_order()
    order_set = set(order)
    tsv = parse_tsv(args.tsv)
    prior = latest_prior_run()

    # warn about names that don't line up with the catalog
    for name in tsv:
        if name not in order_set:
            sys.stderr.write(f"tsv2run: WARNING {name!r} not in tests.json (still emitted)\n")
    for name in order:
        if name not in tsv:
            sys.stderr.write(f"tsv2run: WARNING {name!r} missing from TSV (will render not-run)\n")

    # emit in catalog order first, then any extras the TSV had
    emit_order = [n for n in order if n in tsv] + [n for n in tsv if n not in order_set]

    results = {}
    carried = 0
    for name in emit_order:
        r = tsv[name]
        s = r["s"]
        d = r["d"]
        if d is None:
            # carry the prior detail forward only when the status is unchanged,
            # so a now-passing test never inherits a stale failure string.
            p = prior.get(name)
            if p and p.get("s") == s and p.get("d"):
                d = p["d"]
                carried += 1
        entry = {"s": s}
        if d is not None:
            entry["d"] = d
        results[name] = entry

    out = {
        "date": date,
        "seq": seq,
        "core": args.core,
        "bitstream": args.bitstream,
        "note": args.note,
        "results": results,
    }

    os.makedirs(RUNS_DIR, exist_ok=True)
    out_path = os.path.join(RUNS_DIR, f"{date}-{seq}.json")
    with open(out_path, "w") as f:
        json.dump(out, f, indent=2)
        f.write("\n")

    npass = sum(1 for e in results.values() if e["s"] == "pass")
    ntot = sum(1 for e in results.values() if e["s"] in ("pass", "fail", "error"))
    sys.stderr.write(
        f"tsv2run: wrote {out_path}  ({npass}/{ntot} pass, "
        f"{carried} details carried forward)\n")
    print(out_path)


if __name__ == "__main__":
    main()
