---
title: "X — Atari 8-bit (XE)"
description: "The X realm — the SALLY 6502 with the ANTIC/GTIA/POKEY pipeline, running classic Atari XL/XE software in FPGA fabric."
---

The **"X"** in Atari-XT is the Atari 8-bit machine, named after the **X**E line. It is reproduced in FPGA fabric and runs unmodified Atari XL/XE software, but lifts the era's limits, for example expanded RAM is paged into the 6502 address space so programs can grow well beyond 64 KB, currently Sally maps 4MB of code-space and 3 MB of data-space.

With the current CPU implementation, SALLY runs at 100 MHz, or roughly 56× the speed of the original Atari X{L|E}, and with Snoop mode enabled for [ANTIC](/hardware/antic/), the effective speed-up in DMA-heavy modes is more like **~105×**. It can also run at 1× for backwards compatibility, with ANTIC stealing cycles for its own DMA. (The core path closes at ~120 MHz; production `clk_sally` is 100 MHz since the design grew around the blitter.)

The realm is the classic Atari chip set, cycle-accurate, mapped into the original I/O space:

#### Chipset

- **SALLY 6502** — the CPU, with the xt extensions that give a compiler a real stack and SP-relative addressing. See **[6502 / SALLY extensions](/hardware/cpu/)**.
- **[ANTIC](/hardware/antic/)** — the display-list DMA processor that drives the original video output.
- **GTIA** — colour, players/missiles, and priority.
- **POKEY** — keyboard scan, timers, and four-channel audio (covered under
  **[Audio](/hardware/audio/)**).

These chips composite into the shared 1080p desktop as a scalable window rather than owning the screen outright; the compositor and scan-out are **[shared hardware](/hardware/video/)**.

#### Peripherals

We need:
- joysticks (4 of them, 20 pins),
- SIO (8 control pins),
- the parallel port (which is mainly a buffered version of the actual bus
- the cartridge slot (ditto).
- USB host for keyboard/mouse

None of these are high-speed peripherals.

## Video path

```
             ┌─────────────────────┐                    
             │Sally (extended 6502)│                    
             │  [hdl/sally/cpu.v]  │                    
             └─────────────────────┘                    
                        │                               
                        │                               
                        ▼                               
        ┌──────────────────────────────┐                
        │64 KB single-cycle RAM        │                
        │+4 KB "deep" page-1 stack     │                
        │+  banked pages backed by DDR3│                
        └──────────────────────────────┘                
                        │                               
          ┌─────────────┴─────────────────┐             
          ▼                               ▼             
    ┌───────────┐            ┌────────────────────────┐ 
    │DDR3 via PS│            │ANTIC                   │ 
    │AXI HP     │            │- display list parse    │ 
    └───────────┘            │- pixel-fmt conversion  │ 
          │                  │- DMA master            │ 
          │                  └────────────────────────┘ 
          │                               │             
          ▼                               │             
┌──────────────────┐                      │             
│Blitter           │                      ▼             
│- cmd FIFO (1K)   │         ┌─────────────────────────┐
│- DMA master/slave│         │Compositor               │
│- alpha pipeline  │         │- AXI HP fetch           │
│- 2D pattern fill │────────▶│- line-buffer based      │
│- Line drawing    │         │- Plane-depth aware      │
│- Blended ops     │         └─────────────────────────┘
│- Scaled ops      │                      │             
└──────────────────┘                      │             
                                          │             
┌──────────────────────┐                  │             
│Sprite Engine         │                  │             
│- DMA master          │                  │             
│- 32MB of RGBA sprites│─────────────────▶│             
│- Priority handling   │                  │             
│- Automatic clipping  │                  ▼             
│- Automatic detection │        ┌───────────────────┐   
└──────────────────────┘        │HDMI out           │   
                                │- SiI9022A (on SoC)│   
                                └───────────────────┘
```

POKEY for audio output and the PCM1808 I²S receiver for audio input
sit alongside; they're independent of the display path.

## Clock domains

| Clock        | Rate          | Purpose                                       |
|--------------|--------------:|-----------------------------------------------|
| `clk_sally`  | 100 MHz       | SALLY core, sally_mem, banked_axi_reader      |
| `clk_sys`    | 133.3 MHz     | ANTIC pipeline, xt_blitter, plane_fetch AXI HP|
| `clk_pix`    | 148.4375 MHz  | plane_compositor + line-buffer read, RGB565 → SiI9022A |

Clock-crossing handoffs:

- SALLY → ANTIC register writes via async FIFO (`cdc_fifo_1w1r`).
- ANTIC → SALLY status (`nmi_n`, `irq_n`, `halt_n`, `rdy_n`):
  2-FF synchroniser.
- ANTIC DMA reads from sally_mem via the second BRAM port (dual-port
  BRAM crosses the domain with no synchroniser).  ANTIC reads the flat
  64 KB BRAM directly and has no banking of its own — there is no
  SALLY → ANTIC bank-select crossing.
- Line buffer (`plane_fetch`) → SiI9022A: same-domain (`clk_pix`).

## Memory use

| Region                | Where                        | Size      | Notes                                         |
|-----------------------|------------------------------|----------:|-----------------------------------------------|
| Main RAM (64 KB)      | sally_mem BRAM (16× RAMB36)  | 64 KB     | Single-port write, dual-port read (ANTIC DMA) |
| Hidden stack BRAM     | sally_mem BRAM (1× RAMB36)   | 4 KB      | 12-bit SP; `$0100-$01FF` aliases the top 256  |
| HW register page      | sally_mem hwreg dispatch     | —         | `$D000-$D7FF` decoded combinatorially         |
| Banked window         | DDR3 via banked_axi_reader   | up to 1 GB| Code page `$6000-$9FFF` via `$D5C0` (16 KB); data page `$A000-$CFFF` via `$D5C1` (12 KB). Both 8-bit (256 pages); relocated off zero page (BASIC VNTP) into the CCTL I/O gap. |
| Framebuffer (RGBA-8888) | DDR3 via xt_blitter (write) / plane_fetch (read) | ~8.44 MB | 1080p, compositor plane 0                |
| xt_blitter cmd queue  | xt_blitter BRAM (5× RAMB36)  | 1024 cmds | 192-bit-wide command words                    |
| Plane line buffer     | plane_fetch BRAM             | 2× 2 KB   | Ping-pong, one scan line per plane            |
| Pattern / font BRAMs  | xt_blitter / antic           | small     | 32-bit-wide read ports                        |

The full 64 KB main BRAM is dual-port — SALLY drives one port
(`clk_sally`), ANTIC's DMA reads the other (`clk_sys`).  Writes are
single-port (CPU-side); ANTIC never writes back to main RAM, only
reads.

Reads through `sally_mem` go through a small priority mux:
hwreg → external-cart (when present) → MPD window → banked DDR3 →
hidden stack → main BRAM.  See ``hdl/sally_mem.sv``
header comments for the read-path priority detail.

## In this realm

- **[6502 / SALLY extensions](/hardware/cpu/)** — the CPU and its xt embellishments.
- **[ANTIC](/hardware/antic/)** — the display-list DMA processor and its FPGA display-fetch modes.
- **[Register map](/hardware/register-map/)** — the Atari GTIA / ANTIC registers plus the rp-XT
  chiplet-extension registers.
- **[Palette (NTSC / PAL)](/hardware/palette/)** — the Atari hue/luma → RGB palette LUT and
  region switching.
