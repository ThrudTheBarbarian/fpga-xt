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

## What's LEFT — M6 proper (the generic bind)

1. **`WIND_PLANE { wh, plane_id }`** — client→gemd wire message: "show `plane_id`
   in this window; `plane_id=0` unbinds." Generic from day one (XL=1, m68k=2, …).
   gemd stores (window→plane_id); close/minimise unbinds.
2. **`SYS_plane_window(plane_id, x, y, w, h, scale, enable)`** — generalise the
   XL-specific `SYS_xl_window` (0x603) into a kernel table `plane_id → GP0 block
   base` (XLCTL is `0x43C0_0500`; m68k gets its own block). PS-only per plane.
3. **gemd drives it**: on any geometry change of a plane-bound window (move/size/
   scroll/z/work-area), gemd writes `CMPCFG=0x00010132` once (desktop on top +
   alpha), calls `SYS_plane_window` with the window's screen rect, and **paints
   alpha=0 into the desktop plane over the window's visible work area** (its normal
   compositing already draws occluders opaquely on top → per-pixel occlusion for
   free). `enable=0` when minimised/fully occluded.
4. **Remove the temp `/OS/proc/plane-test` hook** (`vfs_procfs.c`,
   `pf_gen_plane_test` + the 3 dispatch registrations) once (3) works.

Open corner (documented, deferred): two emulator windows overlapping *each other*
resolve by plane depth (the blend is top-2), not window z. Rare; fine for v1.

Also revisit: `xl_sync()` in `desktop.c` is currently a deliberate no-op — it
becomes the `WIND_PLANE` bind for the XL window.

## Pointers
- Memory: `m6_routeA_alpha_hole.md`
- Plan: `docs/OS/gemd-plan.md` §"M6 is blocked BY DESIGN" (now unblocked — update it)
- RTL: `hdl/plane_compositor.sv`, `hdl/fpga_xt_top.sv` (compositor instance ~L1650,
  CMPCFG CDC ~L1631), `hdl/xt_gp0_regs.sv` (CMPCFG decode)
- Sim: `sim/tb_alpha_hole.sv` (`make -C sim alpha_hole`)
