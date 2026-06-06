---
title: "GEM — VDI, AES & theming"
description: "Atari-XT's clean-room GEM environment: a true-colour scalable VDI, an AES object/window/menu layer, and a 9-slice theme engine."
---

Atari-XT provides a clean-room implementation of **GEM** — the graphics environment
familiar from the Atari ST/TT, here generalised to a modern true-colour display. It is the
toolkit the XT desktop and its applications are built on, and it is binary-compatible at the
call level with classic GEM so existing software can bind to it.

The implementation is **portable C** with a thin backend: the same core drives a software
surface on the host (for development) and the hardware blitter on the Cortex-A9. Two design
choices set it apart from 1980s GEM:

- **True colour, not an 8-bit LUT.** Every surface is RGBA-8888 (`0xRRGGBBAA`). The classic
  256-entry "pen" palette still exists and works, but the device reports itself as direct
  colour, so applications written for the Falcon's direct framebuffer — or anything modern —
  get full colour. Applications detect this the standard way: `v_opnvwk` returns ≥ 2 in
  `work_out[13]`, then [`vq_extnd`](/os/gem/vdi/#control)`(owflag=1)` returns `work_out[5] == 0`.
- **Scalable text and themed widgets.** Text is rendered through FreeType (any size, any
  rotation, anti-aliased), and every AES widget is drawn from a themed bitmap atlas rather
  than hard-coded lines — so the desktop looks like a modern UI, not a 16-colour one.

## The three layers

- **[VDI](/os/gem/vdi/)** — the Virtual Device Interface: the drawing layer. Lines, filled
  shapes, the curved GDPs, scalable/rotated/effected text, raster copies and scaling blits,
  the full attribute and inquiry sets, and device input. Includes the common NVDI/FSM
  extensions (Béziers, off-screen bitmaps, fractional text, outline extraction).
- **[AES](/os/gem/aes/)** — the Application Environment Services: the object/dialog/event/
  menu/window layer. The `OBJECT` tree, `form_do`/`form_alert`, the `evnt_multi` multiplexer
  and message pipe, menus, and themed windows.
- **[Theming](/os/gem/theme/)** — the 9-slice renderer and on-disk theme format that dress
  every widget. The reference theme is derived from Cappuccino's *Aristo2*.

## Calling conventions

The VDI keeps the classic five-array parameter block — opcode and parameters in
`contrl`/`intin`/`ptsin`, results in `intout`/`ptsout` — dispatched by one `vdi_call(pb)`.
That block *is* the doorbell ABI: on the emulated m68k the `TRAP-#2` handler calls
`vdi_call()` with the application's own arrays (binary-compatible with real GEM); the C
wrappers documented here fill the shared arrays and call the same dispatcher. 6502 and
XT-native clients use thin bindings into the same service. Colours are pen indices into a
256-entry palette; coordinates are raster coordinates with the origin at top-left.

## Scope

These pages are a reference to the calls that are **supported**. Deliberately out of scope:
the VT52 alpha-cursor terminal escapes (handled inside the m68k emulation, not here), the
Speedo/GDOS font-cache and driver-management calls (we rasterise on demand via FreeType), and
the printer/PostScript attributes (a print path is planned as a PDF device). Indexed-palette
and greyscale-only calls have no meaning on a true-colour surface and are not implemented.
