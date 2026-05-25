# task-0013 — ANTIC native raster sequencer (retire the 800×600 heartbeat)

**Status: SPECCED, not built.**  Design agreed 2026-05-25 (see
`docs/video-architecture.md` §5.1).  Do NOT start without re-reading §5.1 +
§5 + §10 of the spec.  Branch context: `video-compositor`.

## Why
In the compositor model ANTIC is a *window source*, not a display owner, yet
`antic_top` still drives its render/timing from the legacy 800×600 display
chain.  Two things are wrong:

1. **Dead display chain.**  `hdmi_out` (800×600 `vbeam`), `scan_out`, the
   native `line_buffer`, and the display `palette_lut` produce `antic_rgb_*`
   / `tmds_*` that are **consumed nowhere** (the pads come from the
   compositor → sprite chain).  Pure area waste.

2. **Mis-rated, phi2-unlocked heartbeat.**  The only live use of that vbeam is
   to generate `atari_row` (0..191), `line_start`, `vbi_start` for `nmi_gen`,
   the line-buffer swap, and the §5 writeback.  But it is clocked by the
   148.4375 MHz `clk_pix` while carrying 800×600@60 timing → ANTIC "frames" at
   ~224 Hz, ~140 kHz lines, **not locked to phi2** → VCOUNT/WSYNC/DLI/VBI
   cadence drift against the CPU.  A window still appears (the §3 double
   buffer decouples capture from the 1080p read), but the *emulation* timing
   is wrong (the OS times off VBI/RTCLOK).

## What to build
A **phi2-derived native raster timer** in `antic_top` (reuse the existing
`phi2_tick`, line ~340):

```
NTSC: scanline = 114 machine cycles ; frame = 262 lines
PAL : scanline = 114 machine cycles ; frame = 312 lines   (param)
  count phi2_tick: == 113 → emit line_start, atari_row++
  count lines:     == 261 → emit vbi_start, atari_row = 0
```

- Emit `atari_row` (0..191 nominal, ≤0..239 overscan), `line_start`,
  `vbi_start` from this timer — the SAME nets that `atari_row_sync_q2`,
  `line_start_pulse_bus`, `vbi_start_pulse_bus` carry today.  Then the §5
  writeback tap (`wb_atari_row` / `wb_row_flush` / `wb_frame_done`) and
  `nmi_gen` are unchanged — clean module boundary.
- No line-doubling, no letterbox (both were display artifacts of the 800×600
  band mapping in `vbeam`).
- Make NTSC/PAL line count a parameter; default NTSC (262).

### Coupled scope — the render *trigger* (do this properly, not half)
ANTIC's `dl_parser`/`compositor` currently fire off a **free-running
`kick_counter`** (`antic_top` ~line 957: dl_start at counter==0, cmp_start
1024 cycles later, wraps every ~262K `clk_bus` cycles) — a scaffold, NOT a
real per-scanline walk.  The native timer should drive **both** the
line/frame pulses **and** per-row compose:
- `dl_start` at start of frame (post-VBI), parse the display list;
- per scanline, trigger `compositor` for `meta_row_q` = current `atari_row`;
- `cmp_start_pulse` becomes "scanline begins" not "kick_counter==0x400".

This is the emulation-timing-sensitive part — verify against phi2 behaviour
(Klaus is unaffected: it's already phi2-based and doesn't touch ANTIC display).

### Deletions (after the timer works)
Remove `hdmi_out` (`hdmi_out_zynq.sv`), `scan_out`, the native `line_buffer`
instance, and the display `palette_lut` instance from `antic_top`; drop the
now-dead `antic_rgb_*` / `tmds_*` outputs and their top-level wires.  Keep the
writeback's OWN `palette_lut` (it resolves the tap independently).  Reclaims
LUTs + a couple of BRAMs.

## Verify
- `make -C sim lint` clean; `verilator --lint-only --top-module fpga_xt_top
  hdl/*.sv` → baseline-only.
- New `sim/tb_antic_raster` (or extend an existing antic tb): assert
  line_start every 114 phi2, vbi every 262 lines, atari_row wraps 0..N.
- ANTIC-dependent sims (smoke/pbi/snoop/read/pokey/pia_regs/hwreg_rd_cdc)
  stay green.  (`tb_dma_int` is pre-existing broken — missing `rp_tx`/
  `rp_bus_mock` mocks — ignore.)
- Confirm VCOUNT/VBI cadence is now phi2-rated (a focused sim or on-hardware).
- win10 synth: utilisation should DROP (deleted display chain).

## Progress

**Step 1 DONE** (commit b651179): `hdl/antic_raster.sv` + `sim/tb_antic_raster.sv`
+ Makefile target `antic_raster`. The phi2-paced timer is built, unit-tested
(114-phi2 line cadence, 262 line_starts/frame, one VBI/frame at scanline 248,
atari_row banding, VCOUNT=scanline>>1), and verilator-clean. NOT yet wired in.

**Finding — WSYNC is currently broken** (fixed for free by this rework):
`antic_top`'s `phi2_in_line_q` (cycle-105 WSYNC release) is reset by
`line_start_pulse_bus`, which today comes from the 800x600 vbeam at ~140 kHz
(~12 phi2 cycles), so the counter never reaches 105. The phi2 timer's
`phi2_in_line` (0..113) fixes it.

**Step 2 — wire antic_raster into antic_top (the consumer map, all in
hdl/antic_top.sv):** instantiate after the phi2 gen (~line 341), then repoint:
- `line_start_pulse_bus` (assign ~497) -> `ar_line_start`
  consumers: nmi_gen :1006, phi2_in_line_q reset :1025, lb_wr counter :1421,
  wb_row_flush :1600.
- `vbi_start_pulse_bus` (assign ~496) -> `ar_vbi_start`
  consumers: nmi_gen :1005, wb_frame_done :1601.
- `atari_row_sync_q2[7:0]` -> `ar_atari_row`  (nmi_gen :1009, wb_atari_row :1599)
- `vcount_sync_q2` -> `ar_vcount`  (antic_regs.vcount_in :532)
- `phi2_in_line_q` -> `ar_phi2_in_line`; delete the local counter (:1022-1028);
  `cycle_105_pulse` (:1029) uses `ar_phi2_in_line`.
Leave the now-dead vbeam CDC (:475-497) + hdmi_out in place for step 2; verify
with the antic_top tbs (smoke/snoop/read/pbi/pokey/pia_regs/hwreg_rd_cdc),
`make lint`, and the fpga_xt_top parse (baseline-only).

**Step 3 — delete the dead display chain** (separate commit): remove hdmi_out,
scan_out, native line_buffer, display palette_lut, the vbeam CDC FFs, and the
antic_rgb_*/tmds_* outputs from antic_top's port list (+ update fpga_xt_top and
the tbs that connect those ports). Frees the BRAM (display palette_lut) +
line_buffer + LUTs.

**Timing context (win10 synth, post divide-fix, commit 531c209):** clk_pix now
CLOSES (+0.136 ns; was -3.508 before the §4.2-accumulator fix). Remaining setup
failures are pre-existing: clk_sys -1.430 (sally_core, sally_mem hwreg, ANTIC
compositor), clk_sally -0.980. Utilisation is low (24% LUT, 37% BRAM) -> NOT
globally congestion-bound, so those are specific long paths; some won't be
touched by this rework and may need targeted closure later. Defer the closure
pass until after the rework re-measures.

## Notes
- This is decoupled from the committed phase-2 wiring (task-0012): the
  writeback/compositor consume the pulses regardless of source.  Until this
  lands, the 800×600 heartbeat stays and the window still appears (wrong
  internal rate, hidden by the double buffer).
- Real Atari scanline timing reference: NTSC 262 lines × 59.92 Hz; a scanline
  is 114 CPU cycles / 228 colour clocks.  ANTIC DMA "steals" cycles within a
  line — model the line *length* in phi2 cycles; per-cycle DMA stealing is a
  finer-grained concern (the existing `dma_master`/`dma_arbiter` already model
  the bus, this task is about the line/frame *cadence*).
