---
title: "Hardware architecture"
description: "PL fabric module map, clock domains, and memory partitioning for the single-chip Zynq-7020 Atari-XT."
---


`fpga-xt` is a single-chip Atari-XT system on a Zynq-7020 FPGA.
The PL (FPGA fabric) hosts an extended SALLY 6502, the
ANTIC/GTIA/POKEY pipeline, a 2D blitter (`xt-blitter`), and the
HDMI scan-out path.  The PS (dual Cortex-A9) hosts the modern half:
FreeRTOS, SD filesystem, GEM helpers (USB-HID input comes from a
companion MCU).  System memory and
the framebuffer live in DDR3 reached through the PS's DDR
controller via AXI HP ports.

:::note
**Running on real Z-Turn hardware** — see [Current state](/project/current-state/) for the live implementation status.
:::

## The two machines behind "XT"

**Atari-XT** fuses two Atari lineages on one chip — the name takes its **X** from the
Atari 8-bit **X**E line and its **T** from the Atari S**T** / T**T** line. The hardware docs are segmented to match:

- **[The "X" — Atari 8-bit realm](/hardware/x/)** — the extended SALLY 6502 with the ANTIC / GTIA / POKEY pipeline, running classic Atari XL/XE software cycle-accurately in fabric.
- **[The "T" — Atari STe/TT realm](/hardware/t/)** — a planned m68k realm for STe / TT software.

## The Fabric That Binds
Both the above realms ride on **shared underlying hardware**: the FPGA fabric, the `xt-blitter`, the display compositor and HDMI / audio path, DDR3, and the dual-Cortex-A9 **[ARM PS](/hardware/arm/)** that hosts FreeRTOS, the compositing window manager, and the desktop. The ARM is the substrate that ties the realms together — not a third realm (or the name would be "XTA", though then I could call the compiler "XTA-C" :) - because the goal is that user-interaction should be directed towards the XT and/or ST/TT.


## PS ↔ PL boundary

The PS side:

- Boot (FSBL out of QSPI), then loads the PL bitstream
- FreeRTOS application; talks to xt_blitter through AXI-Lite
  register pokes (no kernel driver needed)
- HID keyboard / mouse via the STM32F411 companion MCU (the PS USB controller is not used for HID)
- SD card via the PS's SDIO controller; FatFs handles the
  filesystem
- I²C0 master for the SiI9022A HDMI transmitter (init at boot,
  occasional reconfig)

Between PS and PL:

- AXI-Lite — xt_blitter register access, ANTIC register access
- AXI HP (× 4) — xt_blitter framebuffer reads + writes; sprites;
  plane_fetch/line fetch; sally_mem banked-window reads
- Interrupts — VBI / scanline interrupts from ANTIC to the PS

There are no inter-chip wires, no external bus pins driven from
PL, and no co-processor / paired-FPGA hops.  Everything that
isn't an Atari peripheral signal (cart slot, SIO, joysticks,
PBI, audio in) is on-chip.

## Where to start reading

- [Zynq/memory-map](/hardware/memory-map/) for the Atari address-space
  decode + the `$Dxxx` hwreg layout
- [Zynq/register-map](/hardware/register-map/) for register-bit detail
- [6502/6502-embellishments](/hardware/cpu/) for the
  SALLY ISA extensions 
- [Zynq/pin-map](/hardware/pin-map/) for the PL pin assignments
