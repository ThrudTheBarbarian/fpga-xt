# GEM — XTOS desktop / windowing

Portable C implementation of a GEM-style VDI/AES + window manager for XTOS.
See `../docs/OS/creation.md` for the plan and the decided architecture.

## Idea

The GEM core (VDI, AES, window manager, theming, layout) is **platform-neutral
C**. It only ever calls the low-level primitives in `gfx.h` — `fill_rect`,
`blit`, `line`, `text` onto an RGBA-8888 surface. Two backends provide those:

| backend     | file        | use                                             |
|-------------|-------------|-------------------------------------------------|
| software    | `gfx_soft.c`| the **SDL host testbed** — fast iterate + mouse |
| HW blitter  | `gfx_a9.c`  | the Zynq A9 target (later)                       |

So the desktop, window manager, theming and (via SDL's mouse) the full event /
interaction layer are developed and tested on the host first; moving to the
board is a backend swap, and the RP2354 mouse a late input-backend swap.

Pixel format is `0xRRGGBBAA` everywhere (matches the on-DDR XL framebuffer).

## Build & run (host)

    brew install sdl2      # macOS  (Debian: apt install libsdl2-dev)
    make                   # -> build/gem_sdl
    make run               # opens the testbed window; ESC / close to quit

## Files

- `gfx.h`       — surface + backend primitive interface (the only platform seam)
- `gfx_soft.c`  — software primitives (reference behaviour for the HW backend)
- `sdl_main.c`  — host harness: owns the SDL window + texture upload only

## Next

Milestone 1 = static XL framed in a window on a desktop, drawn through the VDI
doorbell. Building toward it: minimal VDI → window manager (backing-store
windows, `WM_REDRAW`) → theming (`OS/Themes`, 24-bit artwork) → A9 backend.
