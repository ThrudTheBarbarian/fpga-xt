# task-0004 — ANTIC -> HDMI display path

## Goal
Let the legacy ANTIC video reach the HDMI pins so the Atari screen (and the
BASIC `READY` prompt) is visible.

## What this task delivered
A **display-source mux** at fpga_xt_top (parameter `LEGACY_VIDEO`):
  0 = fb_scanout -> sprite_engine (1080p60 DDR3 framebuffer; GEM/native) — default,
  1 = legacy ANTIC RGB path.
The rgb_* pin assignments now select between `spr_rgb_*` and `antic_rgb_*`.
Default 0 preserves the validated 1080p output.  Verified: fpga_xt_top
verilator-parses with no new errors (only the pre-existing missing-primitive
set: MMCME2_BASE/BUFG/IOBUF/sally_core).

## What is NOT done (the real remaining work — see TODO.txt)
Selecting mode 1 does NOT yet produce a correct picture.  Analysis:
- antic_top instantiates `hdmi_out` with its default 800x600 raster (it is
  not overridden), and in the Zynq build it's clocked by clk_pix=148.4 MHz —
  i.e. the ANTIC rgb output is NOT a valid 1080p60 signal.  It was "observed
  only" leftover from the Efinix-era native-HDMI path.
- `scan_out` does `atari_x = h_count >> 1` against a 384-wide line buffer, so
  it only spans 768 native px; beyond that it reads past the buffer.
- The two sources share clk_pix but have different rasters, so a raw pin mux
  of ANTIC is only meaningful once ANTIC emits 1080p60.

Decision (output is always 1080p60; legacy = pillarbox — see memory):
the legacy path needs a **1080p pillarbox upscaler**.  Two viable designs:

  A. Upscaler at the output raster: ANTIC's compositor output is captured
     into a small frame store (384 x ~240 palette indices in BRAM, ~92 KB).
     A new module reads it in fb_scanout's 1920x1080 raster, applying the
     integer H scale + centering (pillarbox bars) and V scale, through the
     palette to RGB, then the mux selects it.  Reuses the 1080p raster;
     ANTIC's hdmi_out/scan_out/line_buffer chain is bypassed for output.

  B. Render ANTIC into the DDR3 framebuffer: add an AXI-write path from the
     ANTIC compositor that writes scaled/positioned RGBA-8888 into the same
     DDR3 FB fb_scanout already displays.  No output mux needed (fb_scanout
     stays the single 1080p raster); "mode" = who writes the FB.

Recommended: A (keeps ANTIC self-contained, no new AXI master, BRAM-only).

## Verify (this task)
- `verilator --lint-only --top-module fpga_xt_top hdl/*.sv` — no new errors.
- Default LEGACY_VIDEO=0 leaves the output path byte-identical to before.

## Verify (the upscaler follow-on)
Needs a 1080p raster sim of the chain + win10 synth + hardware (HDMI monitor,
bring-up.md Phase 8): confirm the GR.0 screen renders pillarboxed at 1080p60.

## Synthesis
Closure on win10 (vivado/run-win10.sh).
