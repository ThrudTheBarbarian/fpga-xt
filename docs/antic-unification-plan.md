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


## Phase 6 — one clock domain (the Atari realm on clk_sally)

Added 2026-08-10, from the antic-sally-interop campaign's conclusion and
Simon's steer ("antic was a simple chip... why are we so close to timing?").

Every seam the campaign patched — bus-arrival skew, the read/write sampling
asymmetry, the early POKEY write lane, the per-BOOT mesochronous phase
lottery in the marginal POKEY trio — is the tax on the CPU (clk_sally) and
chipset (clk_sys) living in different domains and talking through
mesochronous bridges.  The sim proves the endgame: `a8_core` is the same
antic2 RTL in ONE domain and scores 55/58 with zero seams.  (MiSTer's A800
takes the same shape: one clock, enable chains, no crossings — architecture
noted as reference only; its GPL source is never copied.)

Move antic2 + a2_video + both POKEYs onto clk_sally beside the fid core:

- **Timing headroom**: clk_sally is 10 ns against clk_sys's 7.5 — antic2's
  worst cones gain 2.5 ns before any constraint work.  The remaining
  pressure is undeclared MULTICYCLE paths: tick-gated logic forced to close
  in one clock while its data is stable for ~75.  With one domain the
  enables become plain clock enables and MCP constraints are safe to write
  per block (care: antic_pf_stream's fetch FSM and the mem handshake are
  clk-rate — never blanket the whole core).
- **The crossings that REMAIN**: the render/lb stream into the writeback
  (clk_sally -> clk_sys at the line-buffer boundary — a data stream where
  cycle semantics do not matter), the GP0 register file (already
  domain-agnostic strobes), and the BRAM ports (dual-clock BRAMs).
- **What DISSOLVES**: the hwreg write/read CDC (bus ops become native),
  the early POKEY lane + skid, the chipset delay lines, the RANDOM
  lookahead, the rw_* authority syncs, and the phase lottery itself.
- **Gate**: full acid sweep (target = the sim's 55 with serdirect/skstat na
  pending peri-RP serial), DespatchRider + OS boot, timing at WNS >= 0 on
  all clocks without directive roulette.


### Phase 6 status (2026-08-10)

**LANDED — the Atari realm runs on clk_sally.**

- **Chunk 1** (04ac8092): antic2_fabric native — same phi2_tick_fid as the
  fid core, native bus (reads combinational with 49 clk settle, writes
  strobed exactly-once), lb_stream_cdc carrying the render stream with the
  line number riding each start marker, native rdy/nmi/steal wires, the
  fabric resets WITH the CPU on SALLYRST (deterministic CPU-cycle-0-on-
  line-0 every launch — the phase lottery is structurally gone).  Deleted:
  rw_phi2_dl delay taps, split time bases, the snoop toggle crossing, the
  VCOUNT/NMIST mbit CDC, the rdy/nmi/steal 2-FF syncs, hwreg read-CDC for
  the native pages, the antic_gtia fallback branch.
- **Chunk 2** (75951a58): both POKEYs native beside the CPU — write/read
  strobes on the fid grid, native /IRQ, keyboard toggle-crossed in, POT
  shadows/POTGO/SEROUT bridged to the peri machinery left in antic_top,
  audio channels 2-FF'd into the I2S mixer.  Deleted: the early $D2xx
  lane, the write skid, the RANDOM lookahead.  The fire button now threads
  from joy_ovr to the fabric's TRIG0.  The turbo core loses POKEY by
  design (debug core; nothing on the crossed path decodes $D2xx).
- **Strobe instant** (ba04f4a6): chipset writes strobe at SUB_DATA, the
  sim's own contract — the commit slot's registered strobe could land ON
  the next tick under the fractional phi2 divider's 54..57-clk cycles and
  lost antic_wsync's release-cycle re-arm (d5, "$14 != $34").  tb_acid
  gained an `acid2j` target that runs the hardware's 55.866-clk jittered
  cadence for exactly this class of HW-vs-sim question.
- **Timing**: both builds met WNS >= 0 on ALL clocks first try, no
  directive roulette (clk_sys shed the fabric's worst cones; the fabric
  gained clk_sally's 10 ns).
- **ACID**: 50 pass (chunk 1, run 2026-08-10-4) -> 54 pass (chunk 2, run
  -5).  dlitiming/dmapattern/noise/timertiming went green with native
  POKEY; virtdma with the native last-bus.  Open: antic_wsync (the strobe
  fix above, in validation), serdirect/skstat (environmental — no serial
  bus device; na candidates pending Simon's call).
- **Still to retire**: the legacy antic_top machine (timing master +
  peri/i2s host today), its delayed time base, and the crossed-bus
  register lanes for the pages that remain clk_sys.

### Phase 6 worklist (scoped 2026-08-10)

1. **Clocking**: `u_antic2_fab` moves to clk_sally/rst_sally in fpga_xt_top;
   both POKEYs likewise (they live in antic_top, which is otherwise clk_sys —
   pull the POKEY pair + their phi2 divider up into a clk_sally subtree, or
   re-clock antic_top's POKEY slice; the audio ch outputs cross to
   pokey_i2s_tx as slow-changing sample values — a 2-FF sync per 4-bit
   channel is sufficient, samples change at audio rates).
2. **CPU bus, native**: the fid core's addr/data/rw/strobes drive
   antic2_fabric and POKEY directly on clk_sally.  DELETE: the hwreg write
   toggle crossing (for $D0/$D2/$D4 pages), hwreg_rd_cdc for those pages,
   the early POKEY lane + skid, the RANDOM lookahead, both chipset delay
   lines, the antic2 bus snoop crossing (the last-bus latch reads the native
   bus).  KEEP hwreg paths for the pages that stay clk_sys (blitter regs are
   already local; audit $D5xx/$D1xx consumers).
3. **Video stream**: lb_wr/lb_color/lb_line_start (clk_sally) into
   antic_wb_adapt (clk_sys): a shallow async FIFO (or dual-clock BRAM line
   buffer) at exactly this boundary — data stream, no cycle semantics.
   The compositor/writeback stay clk_sys.
4. **NMI/RDY/steal to the fid core**: become same-domain wires — the
   rwnmi/rwrdy/rwsteal syncs and the recognition-window sensitivity go away.
5. **VCOUNT/NMIST reads**: native (the hwreg_rd_cdc round-trip dies).
6. **BRAMs**: display shadow / charset ports serving antic2 move to
   clk_sally ports (dual-clock BRAM primitives where both domains touch).
7. **Constraints**: clk_sally gains the antic2 block — 10 ns budget; add
   scoped MCP for tick-gated groups where analysis allows (NOT
   antic_pf_stream's fetch FSM / mem handshake — clk-rate).  Retire the
   directive-roulette notes if WNS stabilizes.
8. **Gate**: acid sweep >= the sim's 55-with-2-na, DespatchRider + OS boot
   + `make boot`, READY/reset geometry grabs, timing WNS >= 0 first try.
