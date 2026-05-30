---
title: "DDR3 memory map"
description: "PL-visible DDR3 regions reached over AXI HP — banked SALLY window, framebuffers, sprite arena, and bandwidth budgets."
---


The Z-Turn full SOM ships with 1 GB DDR3L attached to the PS DDR
controller. The PL accesses it through AXI HP slave ports (HP0..HP3),
each visible to the PL as a 64-bit 32-bit-addressable AXI master
endpoint.

This document tracks **PL-visible** DDR3 regions: any block the PL
fabric reads from or writes to via an HP port. Each region's base
address is a parameter on its owning module, so the address values
below are defaults — they can be overridden at instantiation time.

## Allocation map

```
0x0000_0000 ┬────────────────────────────────────────────────────┐
            │ (reserved — PS-side: FreeRTOS / Vitis BSP / heap)  │
0x1C00_0000 ├────────────────────────────────────────────────────┤
            │ 68000 "T" realm — RAM + ROM, 64 MB                 │
            │ (Atari ST / STe / TT; emulated on the ARM PS)      │
0x2000_0000 ├────────────────────────────────────────────────────┤
            │ SALLY code-bank pages (DDR3_BANKED_BASE). $D5C0    │
            │ selects a 16 KB page → CPU $6000-$9FFF; 256        │
            │ pages = 4 MB.                                      │
0x2040_0000 ├────────────────────────────────────────────────────┤
            │ SALLY data-bank pages (DDR3_DATA_BASE). $D5C1      │
            │ selects a 16 KB-strided page (12 KB used) → CPU    │
            │ $A000-$CFFF; 256 pages; xtc heap maps on demand.   │
            │ Both via sally_mem's banked-window cache.          │
0x3000_0000 ├────────────────────────────────────────────────────┤
            │ Main framebuffer (FB_BASE) — compositor plane 0:   │
            │ desktop / GEM / blitter output, RGBA-8888,         │
            │ 1920×1080, stride 8192 B, ~8.44 MB; plane_fetch.   │
0x3100_0000 ├────────────────────────────────────────────────────┤
            │ XL window surface A (XL_BASE_A) — ANTIC writeback, │
            │ 320×192 RGBA-8888 (~240 KB); compositor plane 1.   │
0x3110_0000 ├────────────────────────────────────────────────────┤
            │ XL window surface B (XL_BASE_B) — 2nd buffer, 1 MB │
            │ apart; front_sel flips it on ANTIC vblank.         │
0x3200_0000 ├────────────────────────────────────────────────────┤
            │ (reserved — blitter scratch / extra planes /       │
            │ desktop double-buffer — TBD)                       │
0x3400_0000 ├────────────────────────────────────────────────────┤
            │ Sprite arena (ARENA_BASE) — 64 MB; sprite_engine   │
            │ image fetch (AXI master still dangled — see TODO). │
0x3800_0000 ├────────────────────────────────────────────────────┤
            │ (reserved — GEM heap, asset cache, font glyphs;    │
            │ provisional, ~128 MB up to the 1 GB ceiling)       │
0x4000_0000 └────────────────────────────────────────────────────┘
              (0x4000_0000 = top of 1 GB DDR3)
```

The SALLY banked windows (`0x2000_0000` / `0x2040_0000`), the main framebuffer (`FB_BASE = 0x3000_0000`), the XL window surfaces (`XL_BASE_A/B = 0x3100_0000` / `0x3110_0000`), and the sprite arena (`ARENA_BASE = 0x3400_0000`) are all bound to HDL parameters. The 68k region and the GEM heap are **provisional** — chosen to fit the 1 GB ceiling, not yet wired. (The sprite arena's image-fetch AXI master is still dangled — see [Sprite engine](/project/sprite-engine/) and the TODO bug.)

## Framebuffer layout (1080p RGBA-8888)

| Field | Value |
|-------|-------|
| Pixel format | RGBA-8888 (32 bpp) — see [internal_colour_format.md memory] |
| Active resolution | 1920 × 1080 (CEA-861 1080p60) |
| Row stride | **8192 bytes** (1024 × 64-bit AXI HP beats = 64 × 16-beat AXI3 bursts; 1920 px × 4 B = 7680 B used, 512 B padding per row) |
| Frame size | 1080 × 8192 = **8 437 760 bytes** (~8.44 MB) |
| Pixel address | `addr = fb_base + (y * 8192) + (x * 4)` — both terms are shifts (`y << 13 + x << 2`), zero adder logic |

Why 8192-byte stride rather than the natural 7680: AXI3 limits each
burst to 16 beats (UG585 — PS AXI HP is AXI3-flavoured). With a
1024-beat-per-row stride, one line cleanly decomposes into 64 × 16-beat
bursts; 7680 would require 60 × 16-beat plus a partial. The 512 B/row
overhead (= 0.5 MB per frame) is irrelevant in 1 GB DDR3.

## Bandwidth budgets

Per HP port (Zynq-7020 AXI HP at 150 MHz × 64-bit):
- Theoretical peak: **1.2 GB/s**
- Sustained (DDR3 arbitration + row activation): **~0.9 GB/s**

Per scan-out at 1080p60, 32 bpp:
- 1920 × 1080 × 4 B × 60 Hz = **498 MB/s** continuous
- Per scanline: 1920 × 4 = 7680 B used (8192 B stride)
- Per scanline time: 1/(60 × 1125) = **14.81 µs**
- 16-beat AXI3 burst at 150 MHz: ~17–20 cycles each
- 60 bursts/line × ~18 cycles = ~1080 cycles = **7.2 µs/line** — half
  the budget, leaves headroom for blitter writes on the same HP port.

## Module ownership

| Region | Owner module(s) | AXI HP port |
|--------|-----------------|-------------|
| SALLY banked window (0x2000_0000) | `sally_mem` (banked-window cache inside) | HP0 (existing `m_axi_*`) |
| Main framebuffer (0x3000_0000) | compositor `plane_fetch` (read) + `xt_blitter` (write) | HP0 read / HP1 blitter |
| XL window surface A/B (0x3100_0000 / 0x3110_0000) | `antic_writeback` (write) + compositor `plane_fetch` (read) | HP3 |
| Sprite arena (0x3400_0000) | `sprite_engine` image fetch (master dangled) | HP0 (planned) |

Each owner declares its base address as a module parameter; the
defaults above are what `fpga_xt_top` instantiates.
