# Architecture

`fpga-xt` is a single-chip Atari-XT system on a Xilinx Zynq-7020.
The PL (FPGA fabric) hosts an internal SALLY 6502, the
ANTIC/GTIA/POKEY pipeline, a 2D blitter (`xt-blitter`), and the
HDMI scan-out path.  The PS (dual Cortex-A9) hosts the modern half:
FreeRTOS, USB HID, SD filesystem, GEM helpers.  System memory and
the framebuffer live in DDR3 reached through the PS's DDR
controller via AXI HP ports.

System-level overview, BoM, and the migration history live in
[zynq-architecture.md](zynq-architecture.md).  This document
focuses on the PL fabric: what modules exist, what bus / clock
domain they live in, and how memory is partitioned.

## PL module map

```
                      ┌─────────────────────────┐
                      |   SALLY (Arlet 6502 +   |
                      | Stage A/B/C extensions) |
                      │   hdl/sally/cpu.v       │
                      └────────┬────────────────┘
                               │ addr/data/rw/stack_op/s_high  (clk_sally)
                      ┌────────▼────────────────┐
                      │   sally_mem             │  64 KB main BRAM + 4 KB hidden
                      │                         │  stack BRAM + hwreg dispatch +
                      │                         │  banked window backed by DDR3
                      └─┬───────────────┬───────┘
       AXI HP (clk_sys) │               │ dual-port BRAM
                        ▼               ▼
                  ┌─────────────┐  ┌──────────────────────┐
                  │   DDR3      │  │  ANTIC               │  display-list
                  │   via PS    │  │   - dl_parser        │  parsing,
                  │   AXI HP    │  │   - compositor       │  per-scanline
                  └──────┬──────┘  │   - dma_master       │  composition
                         │         └──────────┬───────────┘  (clk_sys)
              AXI HP     │                    │ line buffer
                         │         ┌──────────▼───────────┐
                         │         │   fb_scanout         │  ping-pong line
                         │◀────────┤   - AXI HP fetch     │  fetch + RGB565
                         │         │   - line buf BRAM    │  drive (clk_pix)
                         │         └──────────┬───────────┘
                         │                    │ RGB565 + sync
                         │         ┌──────────▼───────────┐
                         │         │ SiI9022A (off-chip)  │  TMDS → HDMI
                         │         └──────────────────────┘
                         │
                  ┌──────▼────────────────┐
                  │   xt_blitter          │  command-queue BRAM, 2D fill /
                  │   - cmd_fifo (1K)     │  blit / scale / alpha / pattern /
                  │   - dma master/slave  │  rotate / text — AXI master
                  │   - alpha pipeline    │  reads source, writes framebuffer
                  └───────────────────────┘  (clk_sys)
```

POKEY for audio output and the PCM1808 I²S receiver for audio input
sit alongside; they're independent of the display path.

## Clock domains

| Clock        | Rate          | Purpose                                       |
|--------------|--------------:|-----------------------------------------------|
| `clk_sally`  | 100 MHz       | SALLY core, sally_mem, banked_axi_reader      |
| `clk_sys`    | 150 MHz       | ANTIC pipeline, xt_blitter, AXI HP fetch      |
| `clk_pix`    | 148.4375 MHz  | fb_scanout, RGB565 drive to SiI9022A          |

CDC handoffs:

- SALLY → ANTIC register writes via async FIFO (`cdc_fifo_1w1r`).
- ANTIC → SALLY status (`nmi_n`, `irq_n`, `halt_n`, `rdy_n`):
  2-FF synchroniser.
- ANTIC DMA reads from sally_mem via the second BRAM port (dual-port
  BRAM crosses the domain with no synchroniser).  ANTIC reads the flat
  64 KB BRAM directly and has no banking of its own — there is no
  SALLY → ANTIC bank-select crossing.
- Line buffer fb_scanout → SiI9022A: same-domain (`clk_pix`).

## ANTIC display-fetch modes

ANTIC reads display-list and screen-RAM bytes from `sally_mem`'s
dual-port BRAM.  Two modes for how that read interacts with the
SALLY-side bus:

- **Snoop mode** (default) — ANTIC reads through the second BRAM port
  on the same clock as the compositor; `dma_master` is wired but
  not asserted.  No `/HALT` to SALLY, no bus contention.  At our
  current `CLOCK_MULT` operating point, `sally_clock` bypasses
  `/HALT` and this is the only mode that gets used.
- **DMA mode** (legacy compat) — ANTIC asserts `/HALT` one cycle
  ahead of its DMA cycles, drives the address bus, samples data,
  releases `/HALT`.  Available for cycle-exact compatibility but
  not currently exercised.

Selection is via the ANTIC register `MODE_SNOOP`.

## Memory layout

| Region                | Where                        | Size      | Notes                                         |
|-----------------------|------------------------------|----------:|-----------------------------------------------|
| Main RAM (64 KB)      | sally_mem BRAM (16× RAMB36)  | 64 KB     | Single-port write, dual-port read (ANTIC DMA) |
| Hidden stack BRAM     | sally_mem BRAM (1× RAMB36)   | 4 KB      | 12-bit SP; `$0100-$01FF` aliases the top 256  |
| HW register page      | sally_mem hwreg dispatch     | —         | `$D000-$D7FF` decoded combinatorially         |
| Banked window         | DDR3 via banked_axi_reader   | up to 1 GB| Code page `$6000-$9FFF` via `$D5C0` (16 KB); data page `$A000-$CFFF` via `$D5C1` (12 KB). Both 8-bit (256 pages); relocated off zero page (BASIC VNTP) into the CCTL I/O gap. |
| Framebuffer (RGB565)  | DDR3 via xt_blitter / fb_scanout | ~2 MB  | 1080p double-buffered                         |
| xt_blitter cmd queue  | xt_blitter BRAM (5× RAMB36)  | 1024 cmds | 192-bit-wide command words                    |
| fb_scanout line buf   | fb_scanout BRAM              | 2× 2 KB   | Ping-pong, one scan line each                 |
| Pattern / font BRAMs  | xt_blitter / antic           | small     | 32-bit-wide read ports                        |

The full 64 KB main BRAM is dual-port — SALLY drives one port
(`clk_sally`), ANTIC's DMA reads the other (`clk_sys`).  Writes are
single-port (CPU-side); ANTIC never writes back to main RAM, only
reads.

Reads through `sally_mem` go through a small priority mux:
hwreg → external-cart (when present) → MPD window → banked DDR3 →
hidden stack → main BRAM.  See [`hdl/sally_mem.sv`](../hdl/sally_mem.sv)
header comments for the read-path priority detail.

## PS ↔ PL boundary

The PS hosts:

- Boot (FSBL out of QSPI), then loads the PL bitstream
- FreeRTOS application; talks to xt_blitter through AXI-Lite
  register pokes (no kernel driver needed)
- USB host (HID keyboard / mouse) via XUSBPS
- SD card via the PS's SDIO controller; FatFs handles the
  filesystem
- I²C0 master for the SiI9022A HDMI transmitter (init at boot,
  occasional reconfig)

Between PS and PL:

- AXI-Lite — xt_blitter register access, ANTIC register access
- AXI HP (× 2) — xt_blitter framebuffer reads + writes;
  fb_scanout line fetch; sally_mem banked-window reads
- Interrupts — VBI / scanline interrupts from ANTIC to the PS

There are no inter-chip wires, no external bus pins driven from
PL, and no co-processor / paired-FPGA hops.  Everything that
isn't an Atari peripheral signal (cart slot, SIO, joysticks,
PBI, audio in) is on-chip.

## Where to start reading

- [Zynq/memory-map.md](Zynq/memory-map.md) for the Atari address-space
  decode + the `$Dxxx` hwreg layout
- [Zynq/register-map.md](Zynq/register-map.md) for register-bit detail
- [6502/6502-embellishments.md](6502/6502-embellishments.md) for the
  SALLY ISA extensions (Stage A / B / C)
- [Zynq/pin-map.md](Zynq/pin-map.md) for the PL pin assignments
