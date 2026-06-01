---
title: "Sprite engine"
description: "The hardware sprite compositor that overlays RGBA-8888 sprites on the 1080p plane-compositor output during scan-out — built and integrated, with the DDR3 image-fetch master still dangled."
---

:::note[Built and integrated — image fetch not yet wired]
`sprite_engine.sv` is implemented and wired into the scan-out chain in
`fpga_xt_top`: the descriptor/control registers ($D4Ax + $D4Dx), the
dual-port line cache, the per-scanline AXI line fetcher, and the `clk_pix`
compositor pixel pipeline are all present and timing-closed. It sits
**after the plane compositor**, between `plane_compositor`'s RGB565 output
and the SiI9022A pads.

Two things still gate visible sprites:

1. **The AXI image-fetch master is dangled** at the top level
   (`m_axi_arready` tied to 0), so no arena pixels are read yet and the
   stage passes the compositor output straight through. When the fetcher is
   wired, it joins the other `clk_sys` plane reads on **HP0 via the BD
   SmartConnect** — *not* a dedicated HP port (HP2 is SALLY's banked-DDR
   window; see `docs/video/video-architecture.md` §10).
2. **The SALLY-side register read-back mux isn't wired**, so descriptor
   writes take effect but reads are observable in simulation only.

This page documents the engine as built. Where it describes intent that
isn't wired yet, it says so.
:::

## Motivation

The legacy Atari ANTIC/GTIA pipeline renders into DDR3, and the 1080p60
[plane compositor](/hardware/video/) mixes that (and any LVGL/desktop
planes) into the final frame. The sprite engine adds a hardware overlay on
top of the composited image so modern UI elements, game sprites, and
animated backgrounds can be drawn without CPU-driven framebuffer blits.

It eliminates CPU overhead for per-frame compositing, decouples sprite
animation from the Atari display-list timing, and provides collision
detection as a free side-effect of the scan-out pipeline. Pixel data lives
in **PS DDR3** and is fetched over an AXI HP port during scan-out.

## Internal format: RGBA-8888

Everything inside the engine is **RGBA-8888** (32-bit), matching the
[project-wide internal colour format](/hardware/palette/) — the RGB565 of
the HDMI pins is a scan-out-only detail. The compositor blends 8-bit-alpha
sprite pixels over the incoming framebuffer pixel and truncates back to
RGB565 only at the SOM output.

Sprites may be stored in the arena in either of two formats, chosen
per-sprite by a control bit:

| `format` | Arena pixel | Row stride (4096 cols) | Pixel byte address |
|---------:|-------------|------------------------|--------------------|
| 0 | 16-bit RGBA-5:5:5:1 | 8 KB (`1 << 13`) | `ARENA_BASE + (row << 13) + (col << 1)` |
| 1 | 32-bit RGBA-8888 | 16 KB (`1 << 14`) | `ARENA_BASE + (row << 14) + (col << 2)` |

The line fetcher up-converts 16-bit (5551) source pixels to RGBA-8888 at
line-cache write time (the 1-bit alpha expands to 0 / 255), so the cache
and compositor are always 32-bit. Sprites of different formats must occupy
non-overlapping arena regions — software picks a base offset per format
pool.

## Sprite arena

All sprite pixel data lives in a fixed **64 MB** region of PS DDR3 at
`ARENA_BASE = 0x3400_0000` (see [memory map](/hardware/memory-map/)). The
arena is **4096 columns** wide; the row stride is a power of two (8 KB or
16 KB depending on format), so the address is a shift-and-add — no hardware
multiplier. Sprites are power-of-two squares placed at arbitrary
`(arena_x, arena_y)`; the arena has no allocator, so software manages
placement (a linear allocator or a build-time layout).

## High-level architecture

```
DDR3 (PS, 1 GB)
  ANTIC render → writeback ─┐
  desktop / LVGL FB ────────┤→ plane_fetch ×N → plane_compositor ─┐
  sprite arena (0x3400_0000)┘                                     │ RGB565
                                                                  ▼
  sprite arena ─→ sprite line fetcher (AXI HP0) → line cache → sprite_engine ─→ RGB565+sync → SiI9022A
                                                              (overlay / blend)
```

The fetcher shares HP0 with the other plane reads. The compositor takes the
plane-compositor's RGB565 pixel as its background and blends visible sprite
pixels over it.

### Clock domains

| Domain | Frequency | Purpose |
|--------|-----------|---------|
| `clk_fetch` (= `clk_sys`) | 150 MHz | line fetcher, AXI burst control, register writes |
| `clk_pix` | 148.4375 MHz | pixel scan-out and the sprite compositor |

The line-cache BRAMs are dual-port: port A (`clk_fetch`) writes the next
scanline's data while port B (`clk_pix`) reads the current scanline — no CDC
FIFO needed. The `vbeam` taps (`line_start`, `v_count`) cross `clk_pix →
clk_fetch` via a toggle + 2-FF synchroniser with a settled `vcount` bus.
Register writes arrive on `clk_fetch`, already past the SALLY→ANTIC hwreg
CDC.

## Sprite descriptor

Each of the 16 sprites has a descriptor plus a one-byte control register.

| Field | Bits | Range | Where | Description |
|-------|------|-------|-------|-------------|
| `enable` | 1 | 0/1 | $D4Ax bit 0 | Sprite on/off |
| `h_flip` | 1 | 0/1 | $D4Ax bit 1 | Mirror horizontally |
| `v_flip` | 1 | 0/1 | $D4Ax bit 2 | Mirror vertically |
| `2x_w` | 1 | 0/1 | $D4Ax bit 3 | Double width on screen |
| `2x_h` | 1 | 0/1 | $D4Ax bit 4 | Double height on screen |
| `format` | 1 | 0/1 | $D4Ax bit 5 | 0 = 16-bit 5551 source, 1 = 32-bit 8888 |
| `priority` | 5 | 0..31 | descriptor | Higher draws on top |
| `log2_size` | 4 | e.g. 7..10 | descriptor | Sprite is `2^N × 2^N` pixels |
| `arena_x` | 12 | 0..4095 | descriptor | Column of top-left in the arena |
| `arena_y` | 12 | 0..4095 | descriptor | Row of top-left in the arena |
| `screen_x` | 12 signed | −2048..2047 | descriptor | Screen X of top-left |
| `screen_y` | 12 signed | −2048..2047 | descriptor | Screen Y of top-left |

Negative `screen_x` / `screen_y` let sprites scroll partly off-screen; the
fetcher clips to the visible 1920×1080 rectangle. Priority is software-
assigned and not re-ordered in hardware — the compositor's priority encoder
picks the highest-priority sprite that covers the current pixel and has a
non-transparent alpha.

## Register interface (SALLY view)

Sprite registers occupy two nibble-pages in the ANTIC chiplet-extension
space. **Note:** `$D4Bx` / `$D4Cx` are the **blitter** — the sprite engine
deliberately avoids them, using `$D4Ax` and `$D4Dx`.

### `$D4Ax` — per-sprite control byte (indexed by sprite ID)

`$D4A0`..`$D4AF` are sprites 0..15. Each byte:

| Bit | Write | Read-back |
|----:|-------|-----------|
| 0 | enable | enable |
| 1 | h_flip | h_flip |
| 2 | v_flip | v_flip |
| 3 | 2× width | 2× width |
| 4 | 2× height | 2× height |
| 5 | format (0=5551, 1=8888) | format |
| 6 | — | 0 |
| 7 | write-1 clears this sprite's sticky any-collision flag | any-collision (sticky) |

### `$D4Dx` — indexed descriptor, collision, global control

```
$D4D0  SPRITE_SEL   (R/W)  Select sprite 0..15 for B0–B7 access
$D4D1  B0           (R/W)  priority[4:0]
$D4D2  B1           (R/W)  log2_size[3:0]
$D4D3  B2           (R/W)  arena_y[7:0]
$D4D4  B3           (R/W)  {arena_x[11:8], arena_y[11:8]}
$D4D5  B4           (R/W)  arena_x[7:0]
$D4D6  B5           (R/W)  screen_y[7:0]
$D4D7  B6           (R/W)  {screen_x[11:8], screen_y[11:8]}
$D4D8  B7           (W)    screen_x[7:0] — writing COMMITS B0..B7 into desc[SPRITE_SEL]
$D4D9  COL_SEL      (R/W)  Select sprite for collision access
$D4DA  COL_LO       (R / W1C)  collision[COL_SEL][7:0]   (write-1-to-clear)
$D4DB  COL_HI       (R / W1C)  collision[COL_SEL][15:8]
$D4DF  GLOBAL_CTRL  (R/W)  bit 0 = global enable (0 = sprites off, passthrough)
```

Bytes B0–B6 are shadow registers; the write to **B7 (`$D4D8`)** latches all
eight into the selected descriptor atomically. Descriptor read-back
(`$D4D1`–`$D4D8`) reflects the committed descriptor of `SPRITE_SEL`. (As
noted at the top, the SALLY read-back mux into these registers is not wired
yet — reads currently resolve in simulation only.)

Bit *N* of the 16-bit `{COL_HI, COL_LO}` read of `COL_SEL` is 1 if that
sprite overlapped sprite *N* anywhere this frame; write 1 to clear. The
per-sprite "any collision" sticky bit is also surfaced in `$D4Ax` bit 7.

## Line fetcher

The fetcher runs one scanline ahead of the compositor on `clk_fetch`. On
each `line_start` it walks the sprites, and for every enabled sprite whose
vertical extent intersects the next scanline it computes the arena row
address, clips the horizontal span to the visible width, and issues AXI
bursts into the line cache:

- `arsize = 3'b011` (8 bytes/beat, 64-bit bus), `arburst = INCR`,
  `arlen = 8'd7` (8 beats = 64 bytes per burst).
- Bursts are 8-byte-aligned at issue; pixel-precise horizontal scroll is
  handled by a 2-bit `skip_pixels` counter that suppresses the first 0..3
  (16-bit) or 0..1 (32-bit) cache writes.
- A per-scanline **burst budget** (`FETCH_BUDGET_BURSTS = 200`, ≈ 12.8 KB)
  caps fetch traffic. When it's exhausted the remaining (lower-priority)
  sprites skip *that* scanline only; the budget resets next line, so they
  reappear — no bus storm, no frame corruption, and the cost is at most one
  invisible scanline.

## Compositor

The compositor processes one pixel per `clk_pix`. Per sprite it bounds-
checks the current `(h_count, v_count)` against the descriptor (honouring
flip and 2× scaling), reads that sprite's cached pixel, then a priority-
reduction tree selects the winning non-transparent sprite. The winner's
RGBA-8888 pixel is alpha-blended over the framebuffer pixel (expanded
RGB565 → RGB888) and truncated back to RGB565 for the SOM pins; `de` /
`hsync` / `vsync` are pipelined alongside so the timing signals exit
aligned. A cross-product pass sets the sticky collision matrix for every
pair of sprites that are both opaque at the same pixel.

## Rough budgets

These are design-time estimates, not measured post-route numbers — read the
build report for actuals.

- **Line cache** — one 32-bit entry per cached sprite pixel, dual-port.
  16 sprites × up to 1024 px × 4 B ≈ 64 KB ≈ 16 × RAMB36 (the move to
  RGBA-8888 doubles this vs the original 16-bit plan; size scales with the
  real maximum sprite width).
- **Logic** — descriptor flops + the 16-way bounds/priority/collision
  comparators + the blend pipeline; a few thousand FFs and ~2k LUTs, 0 DSPs
  (blend multipliers map to LUTs).
- **Bandwidth** — at `clk_sys` 150 MHz a scanline has ~2400 bus cycles;
  the ~200-burst budget is ~12.8 KB, i.e. ~3200 RGBA-8888 pixels or ~6400
  5551 pixels per line. The fetch shares HP0 with the plane reads, so the
  budget is deliberately conservative.

## Open items / future work

1. **Wire the fetch master** onto HP0 via the BD SmartConnect (currently
   dangled) and the **SALLY register read-back mux** — the two remaining
   steps to make sprites visible on hardware.
2. **Palettised sprites** — an 8-bit index into a palette instead of direct
   RGBA, halving (or quartering) arena bandwidth at the cost of a palette
   read in the compositor.
3. **Sprite rotation** — needs a line buffer + interpolation; for the first
   cut, software pre-rotates into the arena.
4. **Blitter → arena** — point the [xt-blitter](/hardware/video/) at the
   sprite arena so the CPU (or the PS, over its own AXI port for LVGL) can
   render sprite surfaces without DMA.

(Horizontal/vertical flip and 2× scaling, listed as future work in the
original draft, are implemented — see the `$D4Ax` control byte.)
