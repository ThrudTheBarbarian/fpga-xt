# M6 handoff — Route-A occlusion is HW-proven; the generic bind is what's left

_Written 2026-07-17. Resume point for M6 (the XL/emulator plane, and any hardware
plane, following its GEM window with correct occlusion)._

## TL;DR

The hard question — *can a hardware plane be occluded by an arbitrary-shaped
region of ordinary windows without a per-plane clip-rect-list?* — is answered
**YES**, proven in sim **and on hardware**. The compositor already had the
mechanism. What remains for M6 is the generic bind protocol wiring, which is
ordinary PS/gemd work, no more RTL for the core mechanism.

## The mechanism (Route A — the "alpha-hole")

Put the desktop/gemd plane **on top** with `alpha_en=1`; gemd paints **alpha=0**
where a plane-bound window's work area is; every ordinary window it composites on
top is opaque. `plane_compositor.sv`'s existing winner-over-runner alpha blend
then reveals the plane below exactly where `alpha==0` and hides it where an opaque
pixel was drawn — per pixel, any shape. **The occlusion shape lives in the desktop
plane's alpha channel, which gemd already composites per pixel.** No clip-rect-list.

Why it was already possible: `plane_compositor.sv` is N-plane with per-plane
**depth, origin, scale, clip** and a full DSP48 blend datapath (`a*(fg-bg)`,
`a==0→bg`, `a==0xFF→fg`). `plane_fetch` delivers a real alpha byte; RGBA8888 is
end-to-end.

## What landed (all committed on `main`)

| Commit | What |
|---|---|
| `b32c449` | `sim/tb_alpha_hole.sv` — proves the alpha-hole with an L-shaped occluder, exact edges. `make -C sim alpha_hole`. Permanent regression test. |
| `33a09f1` | Plane **depth + alpha_en are now a PS register** (`CMPCFG`, CTRL 0x18) instead of hardcoded literals in `fpga_xt_top`. |
| `24793e9` | `/OS/proc/plane-test` — **TEMPORARY** kernel hook that stages the HW proof. **Remove when M6 lands.** |
| (regmap) | `hdl/regmap/xt_gp0.json` + regenerated `xt_gp0_pkg.sv` / `xt_gp0_map.h` / docs. |

### CMPCFG register (the keeper)
- **GP0 addr `0x43C0_0318`** (CTRL block, whole word), `XT_CTRL_CMPCFG`.
- Layout: depth `[3:0]`=desktop `[7:4]`=overlay `[11:8]`=XL; alpha_en `[16]`=desktop `[17]`=overlay `[18]`=XL.
- **Resets to `0x210`** = the exact shipping arrangement (XL depth 2 opaque on top, overlay 1, desktop 0). **No regression** until the PS writes it.
- **Route-A flip = one word: `0x00010132`** (desktop depth 2 + alpha, overlay 3, XL 1).
- Crosses to `clk_pix` as a quasi-static 2-FF sync initialised to `0x210` (cdc-lint agrees; not a free-running bus).
- Also retired the latent `gp0_ctrl[5]` overlay-alpha/video-sleep collision (only `/OS/proc/video-sleep` used that bit).

### Bitstream
- Closed with `place_design -directive ExtraPostPlacementOpt` (clk_sally **0.000**,
  clk_sys +0.054, clk_pix +0.160). `ExtraTimingOpt` gave clk_sally −0.042,
  `Explore` −0.007 (broke clk_sys). **ExtraPostPlacementOpt is a useful clk_sally
  lever** for this thin-margin design.
- Parallel seed sweep in separate remote dirs (`fpga-xt-sweepA/B`) is how it was
  found; `AggressiveExplore` is a `phys_opt` directive, NOT a `place_design` one.

## The HW proof (what was seen on the monitor)

`/OS/proc/plane-test` fills the XL buffers, un-parks the XL plane at a centred
960×576 rect, paints the desktop plane (blue field + alpha=0 hole (660,340,600×400)
+ grey occluder over the hole's right half), and writes `CMPCFG=0x00010132`.
Procedure: **kill gemd+desktop first** (freeze the plane FB), then `cat
/OS/proc/plane-test`, then look at the monitor.

Result: the hole showed **live XL video** (ANTIC writeback is active, so it
colour-cycles — a live plane through the hole), the grey occluder **hid** it
(proving the desktop rides on top), and the board stayed alive (compositor
reconfig on `clk_pix` is stable). `fbgrab` only captures **plane 0** (the
composite goes straight to the HDMI pins), so this can only be seen on the
monitor, not grabbed.

## M6 proper (the generic bind) — DONE, board-verified 2026-07-17

All four items are in (see docs/OS/gemd-plan.md §M6 for the living description):

1. **`GEM_WIND_PLANE {wh, plane_id, scale}`** (opcode 13) — client API
   `wind_plane_bind(wh, plane_id, scale)`; `plane_id=0` unbinds; ids are the
   kernel's namespace (`XT_PLANE_XL=1`). One window per plane; close/client-death
   unbinds. *(`scale` joined the message: gemd must not know a plane's source
   dimensions, so the client says how big a source pixel is.)*
2. **`SYS_plane_window(plane, x, y, w, h, scale, en)`** (0x605) — kernel table
   `plane_id → GP0 placement block` in `gfxplane.c` (`plane_window_set`); clips
   signed x/y to the screen; owns the CMPCFG flip: first active plane writes
   Route-A **before** un-parking, last park lands **before** the reset arrangement
   returns. `SYS_xl_window` (0x603) stays as-is (frozen ABI; boot park uses it).
3. **gemd drives it**: the bind marks the awin, `draw_content` composites the work
   area as an alpha=0 hole, and `aes_set_plane_sync(gemd_plane_sync)` re-places the
   plane after EVERY composite (all geometry/z/visibility changes end in
   `wind_redraw_area`), change-detected. `xl_sync()` in `desktop.c` IS the bind now.
4. **`/OS/proc/plane-test` removed** (generator + 3 registrations in vfs_procfs.c).

Open corners (documented, deferred): two emulator windows overlapping *each other*
resolve by plane depth (the blend is top-2), not window z; a window overhanging the
LEFT screen edge shifts the plane picture (no source-offset register — the origin
clamps at 0).

**Board-verified (2026-07-17):** live XL video framed in the 6502 emulator window on
the textured wallpaper; drag, per-pixel occlusion by an ordinary window, edge clipping
and close/unpark all behave; the desktop is pixel-normal with no plane bound.

## Pointers
- Memory: `m6_routeA_alpha_hole.md`
- Plan: `docs/OS/gemd-plan.md` §"M6 is blocked BY DESIGN" (now unblocked — update it)
- RTL: `hdl/plane_compositor.sv`, `hdl/fpga_xt_top.sv` (compositor instance ~L1650,
  CMPCFG CDC ~L1631), `hdl/xt_gp0_regs.sv` (CMPCFG decode)
- Sim: `sim/tb_alpha_hole.sv` (`make -C sim alpha_hole`)
