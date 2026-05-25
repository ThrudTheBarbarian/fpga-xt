# task-0009 — fb_scanout -> plane compositor top integration (phase 1b-ii)

## Goal
Put the plane compositor into fpga_xt_top's live video path, replacing the
single-plane fb_scanout, with a default config that reproduces today's
output (docs/video-architecture.md §11/§14).

## What changed in fpga_xt_top
- Removed the `fb_scanout` instance. New chain:
  `vbeam (raster) -> plane_fetch x1 (desktop, HP0) -> plane_compositor -> sprite_engine -> pads`.
- `vbeam` now instantiated at the top (1080p60 CEA-861 timing) — it used to
  live inside fb_scanout.
- `plane_fetch u_plane_fetch0`: desktop surface FB_BASE=0x3000_0000,
  stride 8192, src_w 1920, AXI HP0. `fetch_row = next display line`
  (`v_count+1`, wrap at 1080) — scale-1 desktop, so src_row == line.
- `plane_compositor` CMP_PLANES=2: plane 0 = desktop (enabled, full screen,
  scale 1, depth 0); plane 1 = Atari XL window, WIRED BUT DISABLED
  (`pl_enable=2'b01`, src_pixel tied 0) until phase 2 feeds it.
- `sprite_engine` now takes the compositor's pixel/de/hsync/vsync; raster
  taps come from vbeam.
- Removed: the `LEGACY_VIDEO` full-screen mux, the `legacy_upscale` instance,
  and the orphaned `SCANOUT_TEST_PATTERN` + `LEGACY_VIDEO` params (neither
  referenced by any build script). `legacy_upscale.sv` + its tb stay as a
  scaler reference.

## Verify
- `verilator --lint-only --top-module fpga_xt_top hdl/*.sv` — only the 10
  baseline missing-primitive errors (MMCME2_BASE/BUFG/IOBUF/sally_core); no
  new errors from the rewrite. No dangling fb_scanout / fb_rgb_* / lu_* refs.
- `make -C sim lint` + plane_compositor + plane_fetch — pass.

## Needs hardware/synth validation (no top-level sim)
- Desktop `fetch_row = v_count+1` prefetch phase at the frame boundary
  (line 0 / last-line) — confirm no 1-line wrap artifact on hardware.
- 2-clk skew between vbeam's h/v_count and the compositor pixel feeding
  sprite_engine: harmless for the passthrough scaffold, must be aligned when
  real sprite compositing lands.
- win10 synth (vivado/run-win10.sh) + HDMI: confirm the desktop renders
  identically to the old fb_scanout path.

## Next
Phase 2 (task #7): ANTIC -> DDR3 writeback -> enable compositor plane 1
(XL window) with origin/scale, and drive its fetch_row from the XL plane's
vertical mapping (prefetch for scaled planes).
