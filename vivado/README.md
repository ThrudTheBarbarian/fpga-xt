# vivado/ — Zynq-7020 build flow

Build infrastructure for the Zynq pivot (see
[../docs/zynq-architecture.md](../docs/zynq-architecture.md)). Same
remote-SSH pattern as [`../efinity/`](../efinity/) — Vivado runs on the
Ubuntu build box, this directory holds the driver scripts.

## Files

- `run.sh` — SSH+rsync driver. Usage:
  ```sh
  ./run.sh [flow] [top] [part]
  ```
  - `flow` ∈ `{synth, impl, bit}` (default: `synth`)
  - `top` (default: `sally_synth_top` for Phase 0 fmax probe)
  - `part` (default: `xc7z020-2clg400`, the Z-Turn part)
- `build.tcl` — non-project-mode Vivado Tcl driver. Reads source files,
  runs synthesis (and impl/bit if requested), writes checkpoints + reports.
- `constraints/` — XDC constraint files.
  - `sally_synth_probe.xdc` — 165 MHz clock target on `sally_synth_top.clk`
    for the Phase 0 fmax probe.
- `build/` — local mirror of remote build artefacts (gitignored).

## First Phase 0 invocation

Once Vivado is installed on the remote and `VIVADO_PATH` is correct:

```sh
./run.sh synth sally_synth_top xc7z020-2clg400
```

Inspect `build/post_synth_timing.rpt` for WNS at the 165 MHz target.
A negative WNS means SALLY didn't close 165 MHz on Zynq-7020 -2; the
margin tells us what fmax it actually achieves.

## Phase 0 expectations

- **Source elaboration**: most `hdl/*.sv` files should elaborate cleanly
  under Vivado without changes. The Efinix-specific HyperRAM PHY files
  (`hyperram_phy.sv`, `hyperram_shim.sv`) are excluded by `build.tcl`'s
  filter — Zynq uses the PS DDR3 controller, not HyperRAM.
- **fmax**: expect ~130–160 MHz on Zynq-7020 -2 vs Ti60's ~165 MHz. See
  the "Fabric speed — 28 nm vs 16 nm" section in zynq-architecture.md.
- **Utilisation**: SALLY stack should use a few thousand LUTs, well
  under 85K available. The post-synth utilisation report tells us how
  much headroom we have for the rest of the design + xt-blitter.

## Env var overrides

```sh
VIVADO_PATH=/opt/xilinx/2025.2.1/Vivado ./run.sh synth
REMOTE=otherbox ./run.sh synth
REMOTE_DIR=zynq-experiments ./run.sh synth
```
