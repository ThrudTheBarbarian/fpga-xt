# task-0008 — per-plane DDR3 line fetch unit (video-arch phase 1b)

## Goal
Generalise fb_scanout's AXI-read + ping-pong line buffer into a reusable
per-plane source for the compositor (docs/video-architecture.md §4/§11): fetch
one DDR3 surface ROW into a line buffer, serve the compositor a pixel read by
source COLUMN.

## What this delivered
`hdl/plane_fetch.sv` (NEW) + `sim/tb_plane_fetch.sv`:

- Config: `surface_base / stride_bytes / src_w / enable` (clk_sys).
- AXI4 read master: 16-beat × 8-byte (2 px) bursts; `n_bursts = ceil(src_w/32)`;
  row base = `surface_base + fetch_row*stride_bytes`.
- clk_pix read: `rd_col -> rd_pixel` (RGBA8888, registered 1 clk).
- CDC: `line_start` (clk_pix->clk_sys) toggle+2FF+edge; `fetch_row` carried by
  a 2-FF sync (stable between line_starts) sampled after the synced edge.
- Pipeline: the row latched at line N's line_start is fetched into the WRITE
  half during line N; READ flips at line N+1 -> so drive `fetch_row` with the
  row that should DISPLAY next line (the compositor's src_row_next).

## Two bugs found + fixed during bring-up
1. **First beat dropped**: a registered `wr_en` lagged the data by a cycle, so
   beat 0 (pixels 0/1) was never written. Fix: `wr_en` is now combinational
   (`state==S_R && rvalid`), so each beat lands in its slot the cycle it
   arrives.
2. **Not actually double-buffered**: flipping the write pointer at S_DONE and
   the read pointer at line_start left them in the SAME phase (read hit the
   buffer being written). Fix: flip BOTH at line_start, initialised opposite
   (rd=0, wr=1) — read half is always the one the previous line's fetch
   completed.

## Verify
`make -C sim plane_fetch` — drives plane_fetch's AXI master against
axi_slave_mem (seeded surface, src_w=8, stride=64). Verifies the ping-pong
serves the correct row's pixels at every column, with the 1-line fetch/display
pipeline. PASS. Verilator-clean (one benign UNUSEDSIGNAL: rd_col[11]).

## Remaining (rest of phase 1b — task #9)
Top integration: instantiate N fetch units + plane_compositor in fpga_xt_top,
add `src_row_next_o` to the compositor to drive each fetch unit's `fetch_row`,
replace fb_scanout, delete the LEGACY_VIDEO mux. Default config = one
desktop plane reproducing today's output. Verilator-parse + win10 + hardware.

## Synthesis
Closure on win10 (vivado/run-win10.sh).
