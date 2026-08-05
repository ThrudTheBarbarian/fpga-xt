# ACID800 conformance dashboard

Tracks how the fpga-xt fabric 6502 + ANTIC/GTIA/POKEY/PIA fare against
[ACID800](https://www.virtualdub.org/altirra.html) — Avery Lee's Altirra hardware-conformance
suite. The goal is measuring progress on the **fidelity core** as we fix fundamental emulation bugs.

Open **`index.html`** in a browser. Down the left is one link per dated sweep (a second run on the
same day becomes `#2`, `#3`, …); click one to see that run's full grid. The main area shows a box
per test — green ✓ pass, red ✗ fail, grey – not-run — **grouped by function** (CPU, ANTIC, GTIA,
POKEY, PIA, MMU, Modules). Hover a box for the failure detail.

## Layout

```
docs/a800/
  tests.json          test catalog: ordered, grouped, human titles (edit to add/reorder)
  runs/<date>[-<seq>].json   one file per sweep (see schema below)
  gen.py              generator → index.html  (run: python3 docs/a800/gen.py)
  index.html          generated, self-contained (works from file:// and as an Artifact)
  README.md           this file
```

## Run file schema

`runs/2026-07-20-2.json`:

```json
{
  "date": "2026-07-20",
  "seq": 2,
  "core": "fid",
  "bitstream": "fid-first-class",
  "note": "first fid sweep",
  "results": {
    "cpu_decimal":  {"s": "pass"},
    "antic_vcount": {"s": "fail", "d": "VCOUNT #3 wrong: $02 != $03"}
  }
}
```

`s` ∈ `pass` | `fail` | `error` | `na`. `d` is the on-screen failure detail (optional). Tests
absent from `results` render as not-run. `na` (e.g. the `mod_*` display-only modules, or 65C816
detection on a non-816) is excluded from the pass/total count.

## How a sweep is produced

The tests live on the SD card at `/media/6502/acid/*.xex`. For each test:
`xexload <name>.xex` runs it on the fabric CPU (fidelity core by default), then `graboverlay`
captures the result screen; the on-screen `...Pass` / `...FAIL.` line is transcribed into the run
JSON. Add the new `runs/*.json`, run `python3 docs/a800/gen.py`, commit.

Test sources (readable `.lst` mads listings) are under
`rsrc/acid800/Acid800/standalone/<name>.lst` — the assertion that failed maps straight to the
detail string shown in the dashboard.

## Software-emulator runs

`core: "emu"` runs come from `emu/` — the software 6502/ANTIC investigation — not
from hardware, and are recorded with:

```sh
python3 docs/a800/from-emu.py --note "what changed"
```

That builds via `make acid` (never the stale binary), parses the score straight
out of its stdout, writes `runs/<date>-<seq>.json`, and regenerates the page.
They are **not** directly comparable with a fabric sweep: there is no OS ROM, and
POKEY there is the RANDOM LFSR, the timers and the serial output path only. They
are on the same page so the two cores can be read against each other.

## Simulation runs (the ANTIC rewrite)

`core: "antic2"` runs come from the iverilog testbench in `sim/` — the ANTIC
rewrite, before it exists in a bitstream — and are recorded with:

```sh
python3 docs/a800/from-sim.py <sweep-log> --note "what changed, and at which commit"
```

Unlike from-emu.py it takes a LOG rather than running the sweep, because a full
sim sweep is hours and runs in the background; it must not be re-run just to be
recorded. The corollary is that it cannot check the log is current, so **say
which commit it came from in the note**.

The harness reports four outcomes beyond pass/fail, and they are not
interchangeable:

| verdict | dashboard | meaning |
|---|---|---|
| `SKIP` | `na` | the test DECLINED to run — hardware it wants is absent |
| `RAN` | `na` | it ended without asserting anything — no verdict |
| `TIMEOUT` | `error` | ran to the harness guard |
| `NO-RESULT` | `error` | the sweep wrapper's shell limit, not the guard |

`SKIP` and `RAN` are both excluded from pass/total: neither is a claim about the
hardware. Counting them as failures would understate the core; counting them as
passes would flatter it. They stay distinct in the hover detail.

**One asymmetry worth knowing when reading `antic2` against `emu`:**
`pokey_skstat` and `pokey_serdirect` open with `jsr dskinv` as a "is a drive
present" gate. The software model PASSES them because it models a drive
(`emu/sio.c`); the testbench has no SIO device, so they SKIP. That is a missing
**device**, not a defect in ANTIC or POKEY.

**Architecture + remaining timing cluster:** see
[single-phi2-and-timing.md](single-phi2-and-timing.md) — the fid-core single-phi2 fix,
the exact ANTIC horizontal contracts (WSYNC@105, VCOUNT@110, DLI@8, DMA schedule), the
`xexload --hold` / `DBG_TB` measurement tooling, and the precise diagnosis of each
remaining failure.
