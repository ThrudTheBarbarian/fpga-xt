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

## Conformance

Cycle-level ANTIC/GTIA/POKEY behaviour is validated against **Avery Lee's
Acid800 suite**, measured in two environments:

- **antic2-sim — 55 of 58 scored tests, zero failures**: the `antic2` core in
  the simulation harness (the remainder are three legitimately-skipped tests
  and keypress-waiting demo modules with no verdict). That covers WSYNC
  release edges (including a write landing *on* the release cycle), DLI/NMI
  recognition alignment, display-list timing, P/M DMA, and the POKEY timer,
  init-mode, and serial-output timing families.
- **antic2-hw — 55 of 58**: the same core on silicon, matching antic2-sim.  The whole Atari
  realm — antic2, GTIA, and both POKEYs — now runs **natively in the CPU's
  clock domain** (the unification's phase 6): one clock, one phi2 grid, no
  crossings on the CPU bus.  Register writes land in the cycle the program
  issued them in because there is no bridge to arrive late through; reads
  sample post-tick state directly.  That single change closed the
  DLI-timing, DMA-pattern, POKEY-noise and POKEY-timer families in one
  step, retired the per-boot score lottery (the chipset resets with the
  CPU, so every boot has the same cycle-zero alignment), and moved the
  display pipeline off the tightest clock — every native build has met
  timing on the first attempt.  The final piece was strobing register
  writes at the core's data slot rather than its commit slot, so the
  strobe can never race a tick under the phi2 divider's cycle-length
  jitter (the WSYNC read-modify-write edge case that caught).  The only
  tests not green on hardware are two serial-bus tests that need a
  physical SIO device neither environment has (the sim skips them for the
  same reason).

:::note
`antic2` is the fabric's pixel and timing authority, running in the CPU's
own clock domain; the remaining unification work retires the superseded
legacy pipeline. See `docs/antic-unification-plan.md` in the repo for the
phase plan and status, and `docs/a800/index.html` for the per-test
conformance dashboard (the phase-6 runs are 2026-08-10-4 through -6).
:::