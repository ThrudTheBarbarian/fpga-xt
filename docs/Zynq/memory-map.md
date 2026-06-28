# DDR3 memory map (Zynq-7020 PS DDR)

The Z-Turn full SOM ships with 1 GB DDR3L attached to the PS DDR
controller. The PL accesses it through AXI HP slave ports (HP0..HP3),
each visible to the PL as a 64-bit 32-bit-addressable AXI master
endpoint.

This document is the canonical DDR map: the **PL-visible** regions (any
block the PL fabric reads/writes via an HP port — planes, SALLY banks,
the PL-visible heap) **and** the PS-side OS layout (kernel, heaps). Each
fixed region's base address is a parameter on its owning module, so the
values below are defaults — overridable at instantiation.

## Allocation map

```
0x0000_0000 ┬─────────────────────────────────────────────────────────┐
            │ reserved — exception vectors / FSBL / OCM mirror (1 MB)  │
0x0010_0000 ├─────────────────────────────────────────────────────────┤
            │ OS kernel image (text/rodata/data/bss) + FreeRTOS        │
            │ heap_4 (task stacks, kernel objects) — ~31 MB           │
0x0200_0000 ├─────────────────────────────────────────────────────────┤
            │ OS heap (normal / CPU) — newlib malloc/realloc/free via  │
            │ _sbrk. Program images (loader), FreeType internals, app  │
            │ data. ~480 MB contiguous.                                │
0x2000_0000 ├─────────────────────────────────────────────────────────┤
            │ SALLY banks (HDL params): code-bank $D5C0 @0x2000_0000 + │
            │ data-bank $D5C1 @0x2040_0000 + video banks (future);     │
            │ 256 × 16 KB each ≈ 12 MB used, 16 MB reserved.           │
0x2100_0000 ├─────────────────────────────────────────────────────────┤
            │ spare (~240 MB) — hosts the 68k "T" realm (ST/STe/TT     │
            │ guest RAM, ~64 MB) when it's wired; remainder free for   │
            │ OS-heap extension or guest growth.                       │
0x3000_0000 ├─────────────────────────────────────────────────────────┤
            │ Compositor planes (PL-visible, WIRED) — verified vs HDL/ │
            │ PS 2026-06-28:                                           │
            │   FB_BASE   0x3000_0000  desktop/GEM (8.44 MB, 1-buf)    │
            │   XL slots  0x3100/0x3110/0x3120_0000  ANTIC TRIPLE-     │
            │             buffer, 320×192 RGBA (~240 KB each)          │
            │   DRAG_BASE 0x3200_0000  drag-overlay surface (16 MB)    │
            │   WALLPAPER 0x3300_0000  WM backdrop (16 MB)             │
            │   ARENA_BASE 0x3400_0000 sprite arena (64 MB)            │
0x3800_0000 ├─────────────────────────────────────────────────────────┤
            │ PL-visible heap (WIRED) — plv_alloc. Anything the PL     │
            │ reads by physical address as an *allocation* (not a      │
            │ fixed plane): GEM window backing surfaces, glyph         │
            │ atlases, asset caches, DMA buffers. ~128 MB.             │
0x4000_0000 └─────────────────────────────────────────────────────────┘
              (0x4000_0000 = top of 1 GB DDR3)
```

Ground-truth sources (verified 2026-06-28): SALLY banks `DDR3_BANKED_BASE` /
`DDR3_DATA_BASE` (hdl/sally_mem.sv:80-81); `FB_BASE` (hdl/xt_blitter.sv:171); the
XL **triple** buffer `XL_BASE_0/1/2` = `0x3100_0000`/`0x3110_0000`/`0x3120_0000`
(hdl/fpga_xt_top.sv:1054-1056, rotated by `antic_writeback`); `ARENA_BASE`
(hdl/sprite_engine.sv:46). The drag-overlay (`DRAG_BASE 0x3200_0000`) and wallpaper
(`WALLPAPER_BASE 0x3300_0000`) are **PS-allocated** (vitis/xtos/src/gem_lua.c:436/52),
the overlay plane's base written to the compositor at runtime. So the whole
`0x3000_0000`–`0x37FF_FFFF` window is occupied; `0x3800_0000`+ is free for
`plv_alloc`. The **68k "T" realm is provisional and
not yet wired** — it now lives in the `0x2100_0000` spare block (was `0x1C00_0000`),
which freed its 64 MB into the contiguous OS heap. SALLY's reservation was trimmed
from 256 MB to 16 MB (it only needs ~12 MB), leaving the rest of `0x2100_0000`–
`0x2FFF_FFFF` spare.

## Heaps & allocators

Two heaps, distinguished by **one question: does the PL read it?**

- **`os_alloc`** — the normal CPU heap (`0x0200_0000`–`0x1FFF_FFFF`, newlib
  `malloc`/`realloc`/`free` over `_sbrk`). Program images (so the loader's
  `xtld_unload` really frees), FreeType internals, app data, anything CPU-only.
- **`plv_alloc`** — the **PL-visible / wired** heap (`0x3800_0000`–`0x3FFF_FFFF`).
  Anything the PL reads by physical address: GEM window surfaces, the hardware
  glyph atlas (`SRC_BLIT`), asset caches, DMA buffers. **Never swapped or moved**
  (the compositor/blitter/DMA see physical addresses) — see the wired-page rule in
  [../OS/memory-protection.md](../OS/memory-protection.md) §4.

So "asset cache / font glyphs" are **not** named regions — they are `plv_alloc`
allocations. The fixed compositor planes (FB/XL/sprite) stay fixed because
`plane_fetch` reads them at a known HDL-parameter base; *dynamic* PL-read buffers
come from `plv_alloc`. CPU-only data (e.g. FreeType's font-file buffers and
`FT_Face`) comes from `os_alloc`; only the blitter-consumed glyph atlas is
`plv_alloc`.

On qemu (`-M xilinx-zynq-a9`, no PL) `plv_alloc` is just RAM at `0x3800_0000` and
the software backend (`gfx_soft`) renders straight into the `0x3000_0000` plane.

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
| Main framebuffer (0x3000_0000) | `fb_scanout` / compositor `plane_fetch` (read) + `xt_blitter` (write) | HP0 read / HP1 blitter |
| XL triple-buffer (0x3100_0000 / 0x3110_0000 / 0x3120_0000) | `antic_writeback` (write, rotates 3 slots) + compositor `plane_fetch1` (read) | HP3 |
| Drag-overlay surface (0x3200_0000) | `plane_fetch_overlay` (read; base written by PS at runtime) | HP2 |
| Wallpaper / WM backdrop (0x3300_0000) | GEM WM (PS) — snapshot of the desktop plane | (PS write / plane read) |
| Sprite arena (0x3400_0000) | `sprite_engine` image fetch (master dangled) | HP0 (planned) |
| PL-visible heap (0x3800_0000) | blitter (glyph atlas / asset reads) + GEM window surfaces + DMA | HP1 / various |

Each owner declares its base address as a module parameter; the
defaults above are what `fpga_xt_top` instantiates.
