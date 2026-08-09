# One ANTIC — unification plan

Goal: a single ANTIC/GTIA core serving both the ACID sim harness and the
bitstream, so a fix validated in one place is the behaviour of the other.

## Where we are

Three-plus implementations coexist (~13k lines across `hdl/antic*` +
`gtia*` + `a2_video` + `a8_core`):

- **`antic2` + `a2_video`** (sim): the ACID-validated core — 55/58, zero
  failing tests. Single clock, one module owns pixels *and* CPU-visible
  timing. Ahead on fidelity: player phantom capture, mid-line playfield
  edge latch, VCOUNT rollover window, mid-line player resize, P/M DMA.
- **`antic_gtia` + `antic_scanline`** (fabric, owns pixels): same GTIA
  stage and 2,638 lines of sub-modules *already shared* with antic2, but
  its own DL/fetch/NMI machinery and cycle grid (NMIST/NMI at 8/9 where
  antic2 pins 6/7), compensated on HW by the GP0 `tune` nibble. This is
  also `a8_core`'s `USE_ANTIC2=0` path — not a separate core.
- **`antic_timing`** (fabric, owns CPU-visible timing): a third,
  flat re-derivation on clk_sally — VCOUNT/NMIST/nmi_n/rdy_n authority
  and the fid core's cycle-type grid. The pixels/timing **split brain**
  (arbitrary phase between the two beams) is documented in fpga_xt_top.
- **`antic_top`**: the chipset wrapper (POKEY ×2, PIA, XT registers,
  DMA master, peripheral bridges) plus a dead legacy raster
  (`LEGACY_RASTER=0`) whose timing divider (`antic_raster`) still paces
  everything via `phi2_level_o`.

The output contract is already identical: `a2_video` and
`antic_scanline` emit the same `lb_wr`/`lb_color`/`lb_line_start`
protocol, so antic2 drops onto `antic_wb_adapt` → `antic_writeback`
(the XL surface) **with no adapter**.

## Survivor

`antic2`/`a2_video`. It carries the ACID validation, subsumes both
fabric roles in one clock domain by construction (ending the split
brain), and the fabric-only capabilities it lacks are integration
plumbing, not ANTIC behaviour.

## Port deltas to bridge (the whole hard part)

| antic2 has | fabric wants | bridge |
|---|---|---|
| `mem_req`/`mem_valid` handshake | bare addr → registered data | trivial: tie `mem_valid` to req delayed 1 (the fabric BRAM/mux answers in 1) |
| `nmi` 1-cycle pulse | `nmi_n` level (nmi_gen stretches 256) | pulse-stretcher in the shell |
| `wsync_take`/`dma_steal` | `rdy_n` level + steal shape | derive as `a8_core` already does (`halt_n = !dma_steal`) |
| no `tune` port | GP0 `CTRL_RWTUNE` bisect | add pass-through tune (default 0) to antic2_seq's constants — keeps the HW bisect tool alive through the swap |
| $D4xx only (`addr[3:0]`) | $D480-$D49E XT registers | XT regs stay in `antic_regs` (antic_top); decode split — antic2 never sees $D48x |

## Phases

**Phase 0 — remove the dead code.** `antic_expander`, `antic_pf_serial`,
`gtia_stream` + their testbenches/Makefile targets (443 lines − the
still-used `antic_line_buf`). No functional change.

**Phase 1 — fabric shell.** New `antic2_fabric.sv`: wraps
`antic2` + `a2_video`, exposes `antic_gtia`-shaped ports (cs pair,
nmi_n/rdy_n levels, bare mem port, tune, lb_*). Sim-buildable alone;
unit tb reuses tb_acid's dut wiring. No fabric change yet.

**Phase 2 — pixel swap, parameter-gated.** `fpga_xt_top` instantiates
the shell in place of `u_antic_gtia` behind `USE_ANTIC2_FABRIC`
(default off). Build both ways; A/B on the board: XL window renders,
ACID-in-fabric runs, textured-background fidelity checks
(hw_test_fidelity memory). `antic_timing` remains the CPU-timing
authority — pixels only.

**Phase 3 — timing authority.** Route antic2's VCOUNT/NMIST/nmi_n/rdy_n
through the existing CDC to the fid core, replacing `antic_timing`'s.
The one core now owns both roles — the split brain and its arbitrary
phase offset are gone. Gate: ACID-in-fabric full suite + OS boot
(`make boot` validation) + the DLI/WSYNC-sensitive titles.
Retire `antic_timing` (706 lines).

**Phase 4 — retire the duplicates.** Drop `USE_ANTIC2`(sim mux) from
`a8_core` (antic2 unconditionally), delete `antic_gtia`,
`antic_scanline`, `antic_dl`, `antic_pf_fetch`, `antic_pm_fetch`,
`antic_nmi`, `antic_reg_file` when reference-free (~1,700 lines), and
the `LEGACY_RASTER` remnants in `antic_top` (compositor, dl_parser,
gtia_pm_collide, color_resolver, nmi_gen, wsync_gen where unused).
`antic_raster` stays (it is the phi2 pace-maker) unless Phase 3 makes
antic2 the divider too.

**Phase 5 — regression net.** The retired cores' unit tbs either move
to the antic2 shell or are deleted with their module; tb_acid stays the
conformance authority; the fabric ACID runs become the same score by
construction.

## Risks

- The fabric grid ran NMIST/NMI at 8/9 with `tune` compensation; antic2
  pins 6/7 against ACID. If HW disagrees with sim about absolute cycle
  anchors (clock-domain pacing), the tune port bridges while it's
  bisected — do not retune antic2's constants, find the pacing offset.
- clk_sys hold and clk_pix margins are already thin (clk_pix closed at
  +0.019 on build 4); the swap changes the largest block on clk_sys.
  Every phase gates on WNS ≥ 0 across all clocks.
- `antic_top`'s XT register block and bus snoop stay authoritative for
  $D48x — the decode split must be airtight or XL apps that poke XT
  registers regress.

## Status

- Phase 0: **done**.
- Phase 1: **done** — `hdl/antic2_fabric.sv` elaborates
  (`make antic2_fabric_lint` in sim/).  antic2 gained `vcount_o`/`nmist_o`
  observability ports for the fabric CDC; `rdy_n` follows the fabric's
  convention (1 = held, despite the suffix — antic_reg_file.sv:95); the
  NMI stretcher is parameterized (default 8 ticks) pending the phase-2
  consumer audit; `tune` is accepted but inert; antic2's one $display
  (antic2.sv:692) wants a translate_off guard before synthesis.
- Phase 2: **wired, default off** — `fpga_xt_top` carries a
  `USE_ANTIC2_FABRIC` localparam generate-muxing `antic2_fabric` against
  `u_antic_gtia` on identical nets; both branches verilator-lint clean.
  The consumer audit confirmed the shell's conventions (fid rdy =
  `~rwrdy_s[1]` under rw-authority; nmi_n edge-detected per clk after a
  2-FF — the 8-tick stretch is ample; antic2's $display was already
  SYNTHESIS-guarded).  Known gap: `bus_byte_stb` carries ANTIC-page
  register writes only, not every snooped data phase.  **The flip and
  its board A/B are Simon's** — XL window render, ACID-in-fabric,
  textured-background fidelity.
- Phases 3-5: not started.
