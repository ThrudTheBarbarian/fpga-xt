# Efinity build setup (notes for Claude)

The Mac has no native Efinity. All Efinity flows run on the Linux box
`ubuntu` (x86_64, passwordless SSH from this machine) via the wrapper
`efinity/run.sh`.

## Quick reference

```
./efinity/run.sh            # default flow: map (synthesis)
./efinity/run.sh map        # synthesis only
./efinity/run.sh pnr        # place + route (needs .isf — see below)
./efinity/run.sh pgm        # bitstream
./efinity/run.sh full       # map + pnr + pgm
```

What the wrapper does:
1. `rsync` `hdl/` to `ubuntu:~/fpga-antic-build/hdl/`
2. `ssh ubuntu`, source `~/efinity/2025.2/bin/setup.sh`, run `efx_run`
3. `rsync` `outflow/`, `work_syn/`, `work_pnr/`, `work_pgm/` back to
   `efinity/build/`

Logs/reports land in `efinity/build/outflow/antic_top.{log,err.log,
warn.log,map.rpt,map.v,res.csv}`. `efinity/build/` is gitignored
territory — don't commit it.

## Target

- Family: `Trion`
- Device: `T20F256`
- Timing model: `C4`
- Top module: `antic_top`

These are hard-coded in `run.sh`. Change there if the target ever moves.

## Files included in synthesis

The wrapper feeds every `hdl/*.sv` to `efx_run -v ...` *except* files
matching `*_mock.sv` — those are testbench-only and contain
sim-time-init constructs that synthesis rejects (e.g. `initial begin
for (int k = 0; ...) fb[k] = 0; end` trips Synplify's loop-bound
checker even though the loop is bounded by a parameter).

If you add a new sim-only file under `hdl/`, name it `*_mock.sv` so
the wrapper skips it, or move it under `sim/` (the wrapper only syncs
`hdl/`).

## What works today

- `map` (synthesis) — works end-to-end. ~1 second on `ubuntu`. Latest
  resource snapshot (M4):
  - 132 FFs, 141 LUTs, 0 BlockRAMs, 0 DSPs on T20F256.
  - Hierarchy: `antic_top` (top), `bus_snoop` (17 FFs, snoop pipeline),
    `antic_regs` (113 FFs, ANTIC register file).
  - `gtia_regs`, `byte_ram` (cpu_shadow), and the line-buffer / prefetch
    / scan-out modules don't appear in the report yet — their outputs
    aren't consumed downstream so synthesis trims them. They wake up as
    M5+ wires in the compositor + DL parser + palette LUT.
- `pnr` — **not yet runnable**. Needs an `.isf` (interface/pin
  configuration) file. Generate one with the Efinity GUI on `ubuntu`,
  or hand-write one starting from
  `~/efinity/2025.2/examples/helloworld-ru/helloworld2/`.
- `pgm` — needs pnr to have run.
- SDC (timing constraints) — none yet. Drop `.sdc` files into
  `efinity/constraints/` and the wrapper will sync them up; you'll
  also need to point the project at them (TODO: extend wrapper to
  pass `--pnr_opts` / use a project XML when constraints exist).

## Common gotchas

- **`PYTHONPATH: unbound variable`** — Efinity's `setup.sh` references
  `$PYTHONPATH` without a default, so the heredoc has to drop `set -u`
  around the `source`. Already handled in `run.sh`.
- **`error: the following arguments are required: design`** —
  `efx_run`'s positional `design` must come before any `-v` switches
  (argparse `nargs='+'` is greedy). Already handled.
- **`loop count limit of 20000 exceeded; condition is never false`**
  on a clearly-bounded `for` loop — Synplify mis-reads `for (int k =
  0; k < PARAM; k++)` when `PARAM` is a module parameter. Workarounds:
  use a `localparam` of the same value, hard-code the bound, or move
  the file out of synthesis (rename to `*_mock.sv`).
- **`Top module not specified. Using module 'vbeam' as top module`** —
  `efx_run`'s positional `design` arg is just a project NAME; it does
  NOT set the synth root module. Without an explicit root, Synplify
  picks one by heuristic and silently produces a netlist for the wrong
  thing (typically `vbeam`, since it has no callers and sorts early).
  The wrapper passes `--map_opts root=$TOP` to fix this. Note the
  `root=NAME` form (no leading dashes) — `--root=NAME` in `--map_opts`
  fails because efx_run's argparse pass-through gobbles flags that
  start with `-`.

## When the wrapper isn't enough

For interactive debugging, just SSH in and drive `efx_run` directly:

```
ssh ubuntu
source ~/efinity/2025.2/bin/setup.sh
cd ~/fpga-antic-build
efx_run antic_top -f map --family Trion -d T20F256 --timing_model C4 \
  --dir hdl -v hdl/antic_regs.sv hdl/antic_top.sv ...
```

The full list of flows is in `efx_run --help`: `map`, `interface`,
`pnr`, `pgm`, `compile`, `program`, `rtlsim`, `mapsim`, `pnrsim`,
`full`, `ptsimrtl`, `ptsimfc`, `sta_tclsh`, `setup_efxlib`.
