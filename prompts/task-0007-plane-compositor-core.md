# task-0007 — multi-plane compositor core (video-arch phase 1)

## Goal
Build the core of the desktop compositor (docs/video-architecture.md §4): N
depth-ordered planes, each with an integer scale, origin, and clip rect,
composited onto the 1080p raster.

## What this delivered
`hdl/plane_compositor.sv` (NEW) + `sim/tb_plane_compositor.sv`:

- N_PLANES parameterised; flattened per-plane config buses
  (`enable / origin_x,y / scale / depth / clip_x0,y0,x1,y1`) + `bg_color`.
- **Rectangle + priority depth** (NOT a bitmap): per pixel, the covered plane
  with the highest `depth` wins; uncovered → background.
- **Integer accumulator scaler** (divider-free) → handles 2/3/4/5×, not just
  powers of two (fixing legacy_upscale's shift-only limit).
- **Clip rect** = visible client area; coverage + back-map both bounded by it.
- BRAM-free: per-plane source interface `{src_row_o, src_col_o} -> src_pixel_i`
  (registered 1 clk). A frame store (tb) or a line-buffer+fetch unit
  (phase 1b) both satisfy it. 1-cycle source latency matched by a 1-stage
  pipeline on the coverage/winner decision (output is 2 clk behind h_count).

## Verify
`make -C sim plane_compositor` — reduced raster (40x24 via vbeam), two planes
(full-screen blue background depth 0; 2x-scaled 8x8 window depth 1). Checks:
window pixels win over the background (depth), 2x block scaling, clip edges
(x1/y1 exclusive), interior mapping, background fill. PASS. Verilator-clean.

## Not done here (rest of phase 1 + beyond)
- **Phase 1b**: per-plane DDR3 fetch units (generalise fb_scanout's AXI read
  + ping-pong line buffer into N fillers that drive `src_pixel_i` from real
  surfaces, using `src_row_o` to pick the DDR3 row). Then replace fb_scanout
  in fpga_xt_top with the compositor; default config = one desktop plane,
  reproducing today's output. Delete the LEGACY_VIDEO mux.
- **Phase 2** (task #7): ANTIC -> DDR3 writeback -> wire XL as plane 1.
- **Phases 3-5**: unified sprite engine, v1 desktop.app, GP0 registers/driver.

## Synthesis
Closure on win10 (vivado/run-win10.sh).
