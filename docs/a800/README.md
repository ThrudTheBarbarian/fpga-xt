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

**Architecture + remaining timing cluster:** see
[single-phi2-and-timing.md](single-phi2-and-timing.md) — the fid-core single-phi2 fix,
the exact ANTIC horizontal contracts (WSYNC@105, VCOUNT@110, DLI@8, DMA schedule), the
`xexload --hold` / `DBG_TB` measurement tooling, and the precise diagnosis of each
remaining failure.
