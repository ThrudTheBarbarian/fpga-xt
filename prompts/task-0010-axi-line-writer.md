# task-0010 — ANTIC->DDR3 row writeback DMA (video-arch phase 2, part 1)

## Goal
The verifiable DMA core of the ANTIC->DDR3 writeback (docs/video-architecture.md
§5): stream one rendered pixel row to a DDR3 surface via AXI4 writes. Mirror
of plane_fetch (which reads rows; this writes them).

## What this delivered
`hdl/axi_line_writer.sv` (NEW) + `sim/tb_axi_line_writer.sv`:

- Producer fill port: `wr_en/wr_col/wr_pixel` (RGBA8888) fills an internal
  row buffer (combinational read on the write path; fill-then-flush, never
  concurrent).
- `flush` pulse + `flush_base` (DDR3 byte addr) + `flush_w` (pixels) DMAs the
  row: AXI4 INCR write, 8-byte beats (2 RGBA px/beat), multi-burst with a
  correct partial last burst (no over-write past the row). `busy` while active.

## Verify
`make -C sim axi_line_writer` — fills + flushes against axi_slave_mem, peeks
the bytes back. Covers a single partial burst (8 px -> 4 beats) and a
multi-burst (34 px -> 16+1 beats). PASS; verilator-clean.

## Remaining phase-2 work (the antic_top integration — task #7)
1. Tap the ANTIC compositor's per-row palette indices + a "row complete"
   trigger; palette-resolve to RGBA (reuse/mirror palette_lut) and feed the
   writer's fill port; flush per Atari row to the XL DDR3 surface.
2. Double-buffer: write buffer A while the compositor reads B; flip front_sel
   on ANTIC vblank; CDC front_sel to clk_pix so plane_fetch reads the right
   base.
3. Enable compositor plane 1 (XL window) with an origin + integer scale, and
   drive its plane_fetch fetch_row from the XL plane's vertical mapping
   (scaled prefetch — the piece deferred from phase 1b-ii).

## Synthesis
Closure on win10 (vivado/run-win10.sh).
