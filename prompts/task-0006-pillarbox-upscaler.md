# task-0006 — 1080p pillarbox upscaler for legacy ANTIC video

## Goal
Make the legacy Atari display a valid 1080p60 picture (so the BASIC READY
screen is visible), pillarboxed/centred in the 1920x1080 raster.

## What this task delivered
`hdl/legacy_upscale.sv` (NEW) — a peer of sprite_engine that consumes
fb_scanout's 1080p raster and paints an Atari frame store, integer-scaled +
centred, with black pillarbox/letterbox bars.  Because it reuses fb_scanout's
proven 1080p raster, its output is inherently a valid 1080p60 signal — no
ANTIC re-raster needed.

- Frame store: ATARI_W x ATARI_H palette indices, dual-clock BRAM
  (wr_clk write / clk_pix read). Default 384x240.
- Scale: power-of-two (shift), divider-free.  Default 4x4 -> 1536x960 centred
  in 1920x1080 (192 px pillarbox, 60 px letterbox).  Tune H_SHIFT/V_SHIFT on
  hardware for final aspect.
- Palette: instantiates palette_lut (index -> RGB888), written at runtime via
  pal_we (to mirror the ANTIC palette).  Output truncated to RGB565.
- 2-stage pipeline covers the BRAM + palette read latency; sync (de/hsync/
  vsync) is piped to match; bars are black with de still active.

Integrated in fpga_xt_top: instantiated on fb_scanout's raster; the
LEGACY_VIDEO display mux now selects it (was the broken native 800x600 ANTIC
rgb).  rgb_pixclk is always fb_rgb_pixclk (both sources on clk_pix).

## Verify (this task)
- `make -C sim legacy_upscale` — new unit tb at a tiny raster (40x24, 4x4
  image): in-window pixels resolve to palette[frame_store[r][c]]; bars black
  with de active; window edges + 4x4 block uniformity. PASS.
- `verilator --lint-only --top-module legacy_upscale ...` — clean (no
  truncation/latch/undriven; only benign comparison width-expands).
- `fpga_xt_top` verilator-parses with no new errors after integration.

## NOT yet done — the ANTIC capture feed (split to its own task)
The frame store + palette write ports are TIED OFF in fpga_xt_top, so
LEGACY_VIDEO=1 currently shows a valid black 1080p frame.  To show the actual
Atari image, feed the upscaler:
1. Frame-store capture: tap the ANTIC compositor's per-pixel palette-index
   output (the line_buffer write: col + index) plus the current Atari row,
   and write frame_store[row][col]=index (wr_clk = clk_sys = ANTIC clk_bus).
   The row counter comes from ANTIC's vbeam/atari_row feedback. Double-buffer
   if tearing appears.
2. Palette mirror: CDC the ANTIC palette writes ($D483-$D486 -> antic_regs)
   into legacy_upscale's pal_we/pal_waddr/pal_wdata so its palette matches
   ANTIC's.
This is deep antic_top surgery; do it carefully so the existing ANTIC
pipeline (its own tbs) isn't disturbed.

## Verify (the capture feed)
Needs a 1080p raster sim of fb_scanout + legacy_upscale + the capture path,
then win10 synth + hardware (HDMI monitor): GR.0 screen renders pillarboxed
at 1080p60, READY visible.

## Synthesis
Closure on win10 (vivado/run-win10.sh).
