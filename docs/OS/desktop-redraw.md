# Desktop redraw & scroll — design notes

Working notes for de-jerking the GEM desktop: window redraw, text-editor scroll
speed, and window-drag lag. This doc keeps the supporting evidence, the hardware
scroll-parity analysis, and the 565-framebuffer decision; the ordered task list
lives in [NextSteps.md](../NextSteps.md).

## Goal

Make window redraw and scrolling feel smooth. The principle throughout: **move
in hardware everything that can be preserved; only ever hand the app the pixels
that are genuinely new.** A scroll should blt the preserved region and ask the
app to repaint only the exposed strip — never the whole viewport.

## Where we are today (evidence)

- **Scroll = full repaint.** There is no scroll-as-pixel-move path. A window
  marks itself dirty and its content callback (`win->redraw()` /`win->draw`)
  repaints the entire work area; the WM then full-recomposites
  (`gem_wm_draw`, `gem/wm.c:261-279`) or uses the rect-clipped recomposite
  (`gem_wm_draw_rect`, `gem/wm.c:285-316`) — the latter only during drag.
- **No GEM rectangle list.** The AES here is a subset: the `WF_` enum
  (`gem/aes/aes.h:125`) has no `WF_FIRSTXYWH`/`WF_NEXTXYWH`, `wind_get`
  (`gem/aes/window.c:108-115`) handles only `WORKXYWH`/`PREVXYWH`, and although
  `WM_REDRAW` exists as a constant (`gem/aes/aes.h:123`) apps never receive a
  clipped redraw message (demo loops handle `WM_CLOSED/MOVED/SIZED/TOPPED`
  only). The canonical "app walks its visible rect list ∩ dirty rect and
  repaints just the overlap" mechanism is not wired up.
- **Blitter wait is a 100 µs floor.** `xt_blitter_wait_idle`
  (`vitis/xtos/src/xt_blitter.c:36-55`) does `usleep(100)` per poll, so every
  blit pays ~100 µs minimum even if it finished in microseconds — and worse if
  `usleep` rounds up to an RTOS tick. Dominates when many small blits run
  (per-window composite, per-glyph).
- **Drag uses the HW overlay; per-move does NO blit.** `wm_pointer`
  (`vitis/xtos/src/gem_lua.c:452-482`): an overlay drag moves the window by
  writing the overlay X/Y registers (`xt_overlay_move`, `:469`) — no blit, no
  `wait_idle`. The recomposite happens once, on the first move (`:462`). So the
  busy-poll is NOT in the overlay-drag hot path. **Prime drag-lag suspect = a
  blocking `xil_printf` on every move** (`:470`, ~50 chars over UART ≈ ms each),
  plus the overlay committing at vblank (60 Hz cap). The busy-poll only matters
  if drag falls into the full-recompose fallback (`:472-476`, button held, no
  overlay active), where the full recomposite dominates anyway.

## Hardware reality for scroll (what the blitter can already do)

The DDR datapath is 64-bit = **2 pixels per beat**, packed by absolute-X parity
(even-X → low 32 bits, odd-X → high 32; `hdl/xt_blitter.sv:820,826-832`).
Block-blit iterates rows strictly forward (`cy <= cy+1`,
`hdl/xt_blitter.sv:1755,1901`). Consequences:

| Scroll | Parity | Works on today's HW? |
| --- | --- | --- |
| **Vertical** (dx=0, sy=N) | preserved (every row same X) | **Yes** — pure row-base offset, nothing needed |
| **Horizontal, even pixels** | preserved | **Yes** — pure byte offset; just relax the `sx==0` gate in `gfx_a9.c:180` |
| **Horizontal, odd pixels** | flipped | No — needs a one-pixel (32-bit) lane realign mux |

- It is **not** a bit/barrel shifter — pixels are byte-aligned, so a horizontal
  offset is just `+N*4` bytes. The only gap for odd-X horizontal copies is a
  32-bit lane mux (combine high-lane of read beat *i* with low-lane of beat
  *i+1*), gated on `(dst_x ^ src_x) & 1`. Cheap RTL, but rarely needed —
  editors can scroll by even pixel steps and dodge it entirely.
- **Overlap direction caveat:** forward iteration makes same-surface
  **scroll-up** (dst_y < src_y) safe; **scroll-down** (dst_y > src_y) would
  clobber — needs a reverse-direction BLOCK_BLIT flag, or a scratch bounce.
  Scroll-up (reading/typing downward, page-down) is the common case and is free.

## Task order

> **Open work / next steps** are tracked in [NextSteps.md](../NextSteps.md) — see "GEM (VDI + AES) / desktop" (the ordered desktop-redraw de-jerk tasks 1–6).

## Decision: 16-bit (565) framebuffer — SHELVED

Considered dropping the stored framebuffer from RGBA8888 to RGB565 to save
bandwidth. **Shelved — it does not address the jerkiness and carries real
cost.** Rationale:

- **Not bandwidth-bound.** Desktop compositor read is ~498 MB/s at 32bpp
  (1920×1080×60×4) → ~249 MB/s at 565. DDR3 here moves multiple GB/s; the
  compositor read is nowhere near the bottleneck. The jerkiness is
  architectural (full-repaint scroll, per-op `usleep`, full-recompose), none of
  which shrink with smaller pixels.
- **565 has no alpha**, and the blit pipeline depends on it: transparent-pixel
  wstrb masking, pattern-fill alpha, and font/glyph coverage blend. So backing
  stores **must** stay RGBA32 (keep alpha) → no memory or bandwidth saving
  there; only the scanned-out plane could go 565, saving just compositor read
  BW that isn't the bottleneck.
- **Cost lands in the most fragile module.** The blitter's address math
  (`<<2`/`<<13`), 2-px beat packing, and wstrb masking
  (`hdl/xt_blitter.sv:159-166,820`) are all hardwired RGBA32; a backing→plane
  blit would need an inline RGBA32→565 pack stage. The compositor already
  truncates 888→565 with no alpha blend (`hdl/plane_compositor.sv:195-215`), so
  the read side is the easy part — but the blitter surgery is not worth it for a
  non-bottleneck.

Revisit only if DDR footprint (not bandwidth) becomes the constraint.
