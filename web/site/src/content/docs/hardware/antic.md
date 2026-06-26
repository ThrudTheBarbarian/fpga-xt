---
title: "ANTIC"
description: "The ANTIC display-list DMA processor in FPGA fabric — how it fetches display-list and screen-RAM bytes from sally_mem, and the snoop / DMA fetch modes."
---

**ANTIC** is the display-list DMA processor that drives the legacy Atari raster. In the FPGA it
reads display-list and screen-RAM bytes from [`sally_mem`](/hardware/memory-map/)'s dual-port BRAM
and feeds the [compositor](/hardware/video/), which scales the result into the shared 1080p
desktop. It is part of the [X — Atari 8-bit realm](/hardware/x/) alongside the
[SALLY 6502](/hardware/cpu/), GTIA, and POKEY.

## Display-fetch modes

This is an FPGA implementation, we're not necessarily constrained by the
limits of 40-odd-years-old silicon. In the FPGA, ANTIC reads display-list and screen-RAM bytes from `sally_mem`'s
dual-port BRAM.  Two modes for how that read interacts with the
SALLY-side bus:

- **Snoop mode** (default) — ANTIC reads through the second BRAM port
  on the same clock as the compositor; `dma_master` is wired but
  not asserted.  No `/HALT` to SALLY, no bus contention.  At our
  current `CLOCK_MULT` operating point, `sally_clock` bypasses
  `/HALT` and this is the only mode that gets used.
- **DMA mode** (legacy compatibility) — ANTIC asserts `/HALT` one cycle
  ahead of its DMA cycles, drives the address bus, samples data,
  releases `/HALT`.  Available for cycle-exact compatibility but
  not currently exercised.

Selection is via the ANTIC `MODE` register, bit 0: `MODE_SNOOP`.

# Bandwidth

Note that in high-memory-use graphics modes (eg: BASIC "GRAPHICS 8"), ANTIC could 'steal' roughly 47% of the CPU memory-bus bandwidth by /HALT-ing the CPU so it could fetch memory for the screen.

With the current CPU implementation, SALLY runs at 100 MHz, or roughly 56× the speed of the original Atari X{L|E}, and with Snoop mode enabled the effective speed-up in DMA-heavy modes (e.g. GR.8) is more like **~105×**. (The CPU core path itself closes at ~120 MHz; production `clk_sally` backed off to 100 MHz as the design grew around the blitter — recoverable as a later floorplan/fmax task.)