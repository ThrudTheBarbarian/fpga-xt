# task-0011 — ANTIC->DDR3 writeback orchestrator (video-arch phase 2, part 2)

## Goal
Turn the row-DMA core (axi_line_writer) into a usable ANTIC->DDR3 writeback:
palette-resolve ANTIC's per-pixel colour codes to RGBA, accumulate a scanline,
DMA it to a double-buffered DDR3 XL surface, and flip buffers on vblank.

## What this delivered
`hdl/antic_writeback.sv` (NEW) + `sim/tb_antic_writeback.sv`:

- Render tap inputs (clk_bus): `pix_valid / pix_pair / color_lo / color_hi /
  atari_row / row_flush / frame_done`, plus the clk_bus palette writes
  (`pal_we / pal_idx / pal_rgb`).
- Internal `palette_lut` (mirrors ANTIC's) resolves each 8-bit Atari colour
  code -> RGB888; a 4-state resolve FSM (R_SETUP covers the palette's 1-cycle
  read latency) writes RGBA = {RGB, FF} into axi_line_writer's row buffer at
  cols 2*pair / 2*pair+1.
- `row_flush` DMAs the completed row to `wb_base + atari_row*stride`.
- Double-buffer: writeback targets the BACK buffer; `front_sel` (the buffer
  the compositor reads) flips on `frame_done` (vblank).

## Verify
`make -C sim antic_writeback` — synthetic pixel-pair stream + palette, flush a
row, peek the DDR3 surface; then `frame_done` flips the buffer and the next
row lands in the other surface. PASS; verilator-clean.

## Bugs found + fixed during bring-up
- Palette read latency: the resolve FSM sampled `pal_rdata` one cycle early
  (got the previous pixel's colour). Added an R_SETUP state.
- (TB) busy-wait race: `flush_row` checked `lw_busy` before it rose (the flush
  goes row_flush->lw_flush->busy, one cycle later than a direct flush), so the
  check ran mid-DMA and saw only beat 0. Fixed to wait for busy to RISE then
  fall. The RTL was correct — the row DMA + addresses were right all along.

## Remaining phase-2 work (the antic_top tap-exposure + top wiring — task #7)
1. Expose the render tap from antic_top (lb_wr_strobe_bus_q, lb_wr_pair_bus_q,
   {resolved_color_hi,lo}, atari_row, line_start_pulse_bus, vbi_start_pulse_bus,
   + the clk_bus palette signals) as output ports.
2. Instantiate antic_writeback at the top (HP3 AXI write master); wire its
   front_sel to select compositor plane 1's surface base.
3. Enable compositor plane 1 (XL window) with origin + integer scale; add the
   second plane_fetch + the scaled vertical prefetch (deferred from 1b-ii).

## Synthesis
Closure on win10 (vivado/run-win10.sh).
