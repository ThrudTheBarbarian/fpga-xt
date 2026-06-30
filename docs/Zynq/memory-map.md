# DDR3 memory map (Zynq-7020 PS DDR)

The Z-Turn full SOM ships with 1 GB DDR3L attached to the PS DDR
controller. The PL reaches it through the PS AXI slave ports — the four
64-bit **HP** ports (HP0..HP3) for the bandwidth/latency-critical masters,
plus one 32-bit **GP** slave port (S_AXI_GP0) for the low-rate banked-screen
copier. The PS reaches PL registers the other way, through the GP **master**
port (M_AXI_GP0). See [AXI port usage](#axi-port-usage) for the full map.

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
            │ OS heap (~480 MB, ONE contiguous pool). libc.so's own    │
            │ image is bootstrap-pinned at the base; then THE          │
            │ malloc/realloc/free (in libc.so, _sbrk above the image)  │
            │ serves all other .so/program images AND runtime data,    │
            │ freed on last ref (xtld_unload). FreeType caches, etc.   │
0x2000_0000 ├─────────────────────────────────────────────────────────┤
            │ SALLY banks (HDL params; 16 MB reserved):                │
            │   code-bank  0x2000_0000  $D5C0  256×16 KB (AXI tied off)│
            │   data-bank  0x2040_0000  $D5C1  256×16 KB (AXI tied off)│
            │   video bank 0x2080_0000  screen_bank chunk-stack:       │
            │     $D5C3/$D5C4  256×8 KB = 2 MB  via GP0  (WIRED)       │
            │   (free)     0x20A0_0000  6 MB spare in the reservation  │
            │              (4+4+2 = 10 MB used of 16 MB)               │
0x2100_0000 ├─────────────────────────────────────────────────────────┤
            │ spare (~240 MB) — 68k "T" realm (ST/STe/TT guest RAM,    │
            │ ~64 MB) when wired; remainder free.                      │
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
from 256 MB to 16 MB (code 4 MB + data 4 MB + video/screen 2 MB = ~10 MB used,
6 MB spare within the reservation), leaving the rest of `0x2100_0000`–
`0x2FFF_FFFF` spare.

## Heaps & allocators

One CPU heap (plus the PL-visible heap). The only wrinkle is bootstrap: the
loader can't `malloc` the library that *contains* `malloc`.

- **bootstrap allocator** — a tiny **one-shot** kernel allocator used *only* to
  load `libc.so`, pinning its image at the base of the OS heap (`0x0200_0000`).
- **`libc.so` malloc** — **the** `malloc`/`realloc`/`free` (in `libc.so`, over the
  kernel's exported `_sbrk`, which starts just above `libc.so`'s pinned image). It
  owns the whole `0x0200_0000`–`0x1FFF_FFFF` pool: **every other `.so`/program
  image *and* all runtime data**, freed on last reference (`xtld_unload`). After
  `libc.so` loads, the loader's `host.alloc`/`host.dealloc` simply *are* its
  `memalign`/`free` (fetched via `xtld_sym`). FreeType caches, app data. The kernel
  exports only the **syscall primitives** (`_sbrk`/`_write`/`_read`/…) `libc.so`
  imports — **not** a libc surface (that was a pre-`libc.so` plan, now retired).
  `libGEM.so` and programs `DT_NEEDED libc.so`.
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

## AXI port usage

The Zynq-7020 PS exposes (to the PL) two 32-bit GP master ports, two 32-bit GP
slave ports, four 64-bit HP slave ports, and one 64-bit coherent ACP port.
What's wired today (audited against `hdl/fpga_xt_top.sv` 2026-06-30):

| PS port | Width | Dir | Master / user | Region(s) served |
|---------|-------|-----|---------------|------------------|
| **M_AXI_GP0** | 32 | R+W | A9 → PL register bridge (`xt_gp0_regs`) | PL control regs (blitter / compositor / sprite / xtctl) — not DDR |
| M_AXI_GP1 | 32 | — | **unused** | — |
| **S_AXI_HP0** | 64 | **R** | `plane_fetch` | desktop/GEM plane read (`0x3000_0000`) |
| **S_AXI_HP1** | 64 | **R+W** | `xt_blitter` | glyph-atlas/asset read + plane/surface write |
| **S_AXI_HP2** | 64 | **R+W** | `antic_writeback` (W) + drag-overlay/sprite read-arbiter (R) | XL writeback write (`0x31xx`) + drag-overlay (`0x3200_0000`) & sprite-arena (`0x3400_0000`) read |
| **S_AXI_HP3** | 64 | **R** | `plane_fetch1` | XL triple-buffer read (`0x3100/10/20_0000`) |
| **S_AXI_GP0** | 32 | **R+W** | `screen_bank` (`m_axi_scrn`) | banked screen-RAM chunk-stack (`0x2080_0000`) |
| S_AXI_GP1 | 32 | — | **unused** (free) | — |
| S_AXI_ACP | 64 | — | **unused** (free) | coherent option — see architecture-review §3.1 |

Notes:
- **Direction is the PL master's view**: HP0/HP3 are read-only (scan-out fetch);
  HP1/HP2/GP0 are read+write.
- **`sally_mem`'s banked-window AXI master is tied off** (SALLY runs entirely from
  BRAM; DDR-backed code/data banking is not wired — `fpga_xt_top.sv` ~line 322).
  The `0x2000_0000` SALLY-bank region is therefore reserved-but-unused today.
- **GP0 (not an HP port) for screen_bank on purpose**: its copies are ~MB/s and
  non-latency-critical (CPU polls `$D5C5.ready`; the RGBA triple buffer keeps
  scan-out tear-free), so it must not sit on — or arbitrate with — the
  bandwidth/latency-critical HP masters. GP's ~600 MB/s is ~1000× headroom here.

## Region → owner

| Region | Owner module(s) | Port |
|--------|-----------------|------|
| SALLY banked window (`0x2000_0000`) | `sally_mem` banked cache | (AXI master tied off — unused) |
| Screen chunk-stack (`0x2080_0000`) | `screen_bank` | S_AXI_GP0 (R+W) |
| Desktop/GEM plane (`0x3000_0000`) | `plane_fetch` (read) + `xt_blitter` (write) | HP0 read / HP1 write |
| XL triple-buffer (`0x3100/10/20_0000`) | `antic_writeback` (write, 3 slots) + `plane_fetch1` (read) | HP2 write / HP3 read |
| Drag-overlay surface (`0x3200_0000`) | `plane_fetch_overlay` (read; PS sets base) | HP2 read (shared) |
| Wallpaper / WM backdrop (`0x3300_0000`) | GEM WM (PS) — desktop-plane snapshot | PS write / plane read |
| Sprite arena (`0x3400_0000`) | `sprite_engine` image fetch | HP2 read (shared) |
| PL-visible heap (`0x3800_0000`) | blitter (glyph atlas / asset reads) + GEM window surfaces + DMA | HP1 / various |

Each owner declares its base address as a module parameter; the
defaults above are what `fpga_xt_top` instantiates.
