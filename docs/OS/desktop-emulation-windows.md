# GEM desktop with live emulation windows + textured chrome

Goal: boot to a GEM desktop showing icons (XL, later ST); double-click an icon
opens a **moveable window whose content is the live emulation surface**. Replace
today's stand-in skeleton windows with **blitter texture-mapped chrome** loaded
from SD-card resources.

## Architecture — the emulation surface is a hardware plane, not a blit

The XL emulation is already a **compositor plane** (`plane_compositor`, 3 planes:
desktop depth-0, drag-overlay depth-1, **XL depth-2**), with per-plane
`origin_x/y`, `scale`, `depth`, and a `clip` rect — the compositor picks the
front-most plane whose clip covers each output pixel. So a "live emulation window"
is just: **the XL plane's origin/scale/clip = the GEM window's content rect.** The
GEM window draws only the *chrome* (titlebar/border) on the desktop plane; the
emulation shows through the content area via the HW plane. No per-frame copy.

Today `origin/scale/clip` are derived in `fpga_xt_top` from the scale knob
(`gp0_ctrl[3:1]`, auto-centered `(1920−320·s)/2`). Wiring-in = drive them from GP0
so the A9/WM can point the plane at any rect.

**z-order caveat:** a HW plane can't be occluded by a window drawn on the desktop
plane (the XL plane is depth-2, above the desktop). For a single emulation window
that's fine (it's effectively always-on-top within its clip). Multiple overlapping
emulation windows, or a desktop window on top of the emulation, need either more
planes or compositing the emulation into a backing store — out of scope for now.

## What already exists (reuse, don't rebuild)

- **Compositor**: positionable/scalable/clipped/z-ordered planes (`plane_compositor.sv`).
- **XL plane**: runtime origin/scale/clip regs (`xl_org_x_r` … in `fpga_xt_top`).
- **GP0 `0x5xx` block**: reserved "XL-CONTROL" (`hdl/xt_gp0_regs.sv`), generated map.
- **AES**: event/form/menu/object/window (`gem/aes/`) + `aes_desktop_demo.c`.
- **WM**: `gem_wm` — windows, drag, HW-sprite cursor, wallpaper-backed desktop.
- **Blitter**: any-DDR `SRC_BLIT` coverage/texture blit (glyph path) + BLOCK_BLIT.
- **PNG decode**: lodepng + the `screen.wallpaper` SD→DDR loader (`main.c`).

## Milestones

- **M1 — XL plane positionable via GP0. ✓ DONE + HW-validated.** `0x5xx` XLCTL regs
  (`XL_WIN_X/Y/W/H/SCALE/EN`) → `xt_gp0_regs` decode + `xl_win_we` commit →
  `cdc_flag_data` to clk_pix → mux into the XL plane's origin/scale/clip vs the legacy
  centred placement. Driver `xt_xl_window()`, Lua `screen.xlwindow(x,y,w,h[,s])` /
  `screen.xloff()`. `screen.xlwindow` repositions/rescales/clips the live emulation
  to any rect on HW.
- **M2 — textured window chrome (A9, no RTL).** 9-slice chrome (corners + edges +
  title fill + close/resize glyphs) from a PNG atlas on SD; loader (lodepng → a DDR
  chrome surface, like the wallpaper); replace `gem_wm` `draw_frame`'s `vr_recfl`
  skeleton with blitter blits of the 9 slices, stretched/tiled to the window rect.
  **De-risk:** a window with real chrome instead of the blue-bar skeleton.
- **M3 — live-surface GEM window. ✓ DONE + HW-validated.** Any window binds to a HW
  emulation plane via `gem_wm_bind_emu(win, GEM_EMU_XL|ST, scale)`: it resizes so its
  content rect is the emulation@scale, the WM skips the content blit, and the A9
  (`emu_track`) points the XL plane at the content rect and keeps it tracking on
  drag/close. Titlebar **^/v arrows** step the scale 1..5 live. Lua `vdi.xlbind([scale])`
  / `vdi.xlunbind()`. (Target enum is ST-ready; ST plane not wired.) Chrome from M2.
- **M4 — desktop at boot.** AES desktop with XL/ST icons (objects); double-click
  (evnt_multi) → open the M3 window. Fix the **VDI-workstation leak** (direct `vdi.*`
  after `wintest` draw into a window backing, not the desktop) so the desktop and its
  icons render correctly. ST icon present but inert until the m68k host lands.

## Open decisions (gate M2)

1. **Chrome art source** — generate placeholder chrome PNGs procedurally (gradients +
   simple corners) to unblock, or hand-authored art dropped on the SD?
2. **Chrome model** — 9-slice (corners fixed, edges stretched/tiled, centre = content
   hole) is the standard; confirm vs simple title-bar-only.
3. **SD layout** — where the chrome atlas + icons live (e.g. `/OS/Theme/…`).
