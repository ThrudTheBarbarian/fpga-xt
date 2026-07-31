# Software 6502/ANTIC — feasibility investigation

**Status: investigation, opened 2026-07-31. NOT a commitment to rewrite.**

Move the 6502 and ANTIC/GTIA into software, rendering to an 8-bit
palette-index framebuffer in DDR which hardware converts to an RGBA32 surface
per vblank. **POKEY stays in hardware, register-driven.**

The question to answer is narrow: **is it feasible, and what is the performance
likely to be.** Nothing existing gets deleted or regressed on the way.

## Why

Almost every defect in the fabric ANTIC path is an artefact of the
implementation rather than of the Atari:

* two rasters (legacy `antic_top` and the rewrite `antic_gtia`) with arbitrary
  relative phase,
* multi-bit CDC between `clk_sys` and `clk_sally`,
* level-vs-edge strobe hazards,
* `/RDY` sampled at a commit slot inside a 56-slot subcycle window.

None of those concepts exist in an Atari, and none would exist in a sequential
software model where ANTIC and the CPU share one loop. The iteration cost is the
other half of the argument: today a hypothesis costs a bitstream plus a sweep
(~40 min); in software it is a rebuild and a run.

The output split is natural rather than a compromise — ANTIC/GTIA emit a
**palette index per colour clock**, so an 8-bit surface *is* the native format.
Index→RGBA32 through the palette LUT plus scaling is small RTL, and the plane
compositor, palette LUT and scaler already exist.

## Stages

1. **Prove a dedicated second A9.** Launch an app on the other core so it can be
   given over to the emulator. NOTE: that core was already earmarked for the
   m68k JIT (`docs/OS/` + the m68k core notes) — the contention needs a decision.
2. **Write the 6502/ANTIC shape.** Gate the 6502 on **Klaus + illegal opcodes**
   first; only then bring ACID800 in as input.
3. **Mac first**, integrating onto the A9 at staged points.

## Measured before starting

| measurement | Mac | A9 | ratio |
|---|---|---|---|
| `libatari800` headless frame loop | **267x realtime** (2.1 ns/Atari cycle) | ~**35x realtime** (scaled) | — |
| compute-only loop | 1.53 ns/iter | 9.35 ns/iter | 6.1x |
| 4 KB array loop | 1.04 | 7.83 | 7.5x |
| 64 KB array loop | 1.05 | 7.81 | 7.5x |

The A9 is only ~6–7.5x slower than an M-series Mac on branchy integer + array
code, and 64 KB performs identically to 4 KB, so its caches are working.
Budget is 558.7 ns per Atari machine cycle at 1.79 MHz. **Throughput is not the
obstacle.**

Harnesses live at `loader/test/freertos/progs/memprobe.c` (compute vs memory)
and `cycbench.c`. **`cycbench`'s 1.46x A9 figure is an outlier** — it cannot be
reconciled with the 6–7.5x core ratio and should not be quoted; cost this work
on a real emulator, not a hand-written per-cycle loop.

## Licensing

atari800 and Altirra are **GPL**; this repo is permissive-only. Write fresh
against the Altirra *Hardware Reference Manual* (a document, not code). Use
`libatari800` and AltirraSDL as **measurement and oracle only — never vendor**.
Build libatari800 headless in a scratch tree with
`./configure --target=libatari800 && make`; it boots on built-in Altirra ROMs so
it needs no external files.

## Baseline to preserve and beat

**ACID800: 32 of 63 at sallyrst `$06`, 27 at `$0A`**, ceiling 57 (five `mod_*`
never halt by design, `cpu_65c816` is a probe). Latest bitstream: build19.

Two specific discrepancies are worth pointing the software model at first,
because reproducing them would localise the fabric bug:

* `antic_wsync` **passes outright at `$06`** (`95 4B 0D 44 E2 34`) and fails only
  at `$0A`, on `d2`–`d5`. `d2` (INC WSYNC) is off by exactly one machine cycle.
* Both the WSYNC-release and VCOUNT-advance tune nibbles are **provably inert**
  against the NMI/VCOUNT cluster — see `hdl/antic_reg_file.sv`, which explains
  why (the test is WSYNC-anchored, so a uniform release shift cancels).
