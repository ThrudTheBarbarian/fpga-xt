---
title: "Blitter (xt-blitter)"
description: "The xt-blitter — a command-queued 2D engine in fabric that fills, blits, scales, and alpha-blends into the DDR3 framebuffer over AXI."
---

`xt-blitter` is the shared 2D drawing engine. It runs in the `clk_sys` domain as an AXI master,
reading source pixels and writing the DDR3 framebuffer directly, so it off-loads fills, blits, and
scaled or blended draws from every CPU realm.

Work arrives through a command queue — a ~1024-deep FIFO in BRAM. Each command is latched as a
snapshot, so a producer can keep enqueuing while the engine drains the queue. Supported operations
include:

- **Rectangle fill** and **pattern fill** (RGBA-8888 pixels, with per-pixel alpha).
- **Block blit**, and **scaled blit** with nearest-neighbour or bilinear sampling.
- **Alpha blending** over the destination.
- **Line draw**, **rotate / affine** transforms (some paths still done in software), and
  **text / font raster**.

The blitter is driven by register writes — from the [X realm's](/hardware/x/) SALLY 6502 over the
hwreg bus (`$D4Bx` / `$D4Cx`), or from the [ARM PS](/hardware/arm/) over the AXI-Lite GP0 bridge.
The full register layout, command encoding, and how GEM VDI calls map onto it are documented in
**[VDI / blitter driver](/os/vdi-blitter/)**.
