# DDR3 memory map (Zynq-7020 PS DDR)

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
0x0000_0000 ┬─────────────────────────────────────────────────────────┐
            │ (reserved — PS-side use: FreeRTOS / Vitis BSP / heap)   │
0x2000_0000 ├─────────────────────────────────────────────────────────┤
            │ SALLY code-bank pages (DDR3_BANKED_BASE). $82 selects a │
            │ 16 KB page into CPU $6000-$9FFF; 256 pages = 4 MB.      │
0x2040_0000 ├─────────────────────────────────────────────────────────┤
            │ SALLY data-bank pages (DDR3_DATA_BASE). {$84,$83}       │
            │ select a 16 KB-strided page (12 KB used) into CPU       │
            │ $A000-$CFFF; xtc heap maps pages on demand. Both backed │
            │ by sally_mem's banked_axi_reader.                       │
0x3000_0000 ├─────────────────────────────────────────────────────────┤
            │ Framebuffer A (RGBA-8888, 1920 × 1080, stride 8192 B,   │
            │ ~8.44 MB) — primary surface for native / GEM mode.      │
0x3080_0000 ├─────────────────────────────────────────────────────────┤
            │ Framebuffer B (RGBA-8888, same geometry) — back buffer  │
            │ for double-buffered rendering.                          │
0x3200_0000 ├─────────────────────────────────────────────────────────┤
            │ (reserved for blitter scratch / extra back buffers /    │
            │ legacy-mode upscaler input — TBD)                       │
0x4000_0000 ├─────────────────────────────────────────────────────────┤
            │ Sprite arena (64 MB allocation — see sprite-engine.md). │
0x4400_0000 ├─────────────────────────────────────────────────────────┤
            │ (reserved — GEM heap, asset cache, font glyphs, etc.)   │
0x4000_0000+│                                                          │
            └─────────────────────────────────────────────────────────┘
```

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
| SALLY banked window (0x2000_0000) | `sally_mem` (banked_axi_reader inside) | HP0 (existing `m_axi_*`) |
| Framebuffer A/B (0x3000_0000) | `fb_scanout` (read) + `xt_blitter` (write, future) | HP1 (new `m_axi_fb_*`) |
| Sprite arena (0x4000_0000) | `sprite_engine` (future) | HP2 |

Each owner declares its base address as a module parameter; the
defaults above are what `fpga_xt_top` instantiates.
