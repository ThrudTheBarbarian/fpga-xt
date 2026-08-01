# emu — the software 6502/ANTIC

The software half of the investigation in
`docs/Design/software-emulation-investigation.md`. **This is an investigation,
not a replacement**: the fabric path (`xt6502f`, `antic_gtia`, the timing
machine) stays exactly where it is, as both the fallback and the comparison
baseline.

## Licensing

atari800 and Altirra are GPL; this repo is permissive-only. Nothing here is
derived from either. It is written against the Altirra *Hardware Reference
Manual* (a document, not code), the MOS datasheet, and this repo's own
`hdl/xt6502f/xt6502f.sv`. `libatari800` and AltirraSDL stay usable as
**measurement and oracle only**.

## Build and test

```sh
make test     # the gate: harte + klaus + irq + pokey + dma
make harte    # Tom Harte, all 256 opcodes;  ./build/harte 6b 8b  for named ones
make klaus    # Klaus Dormann functional test
make irq      # interrupt timing, from ACID800 cpu_clisei
make pokey    # POKEY RANDOM LFSR — the ANTIC timing tests' cycle clock
make dma      # ANTIC's DMA schedule vs ACID800's own table;  -v to see diffs
```

Both reuse the vectors already vendored for the fabric core
(`sim/harte/vec/`, `sim/test_data/`), so the software and fabric cores answer to
literally the same tests.

## Status

* **6502: all 256 opcodes pass Harte** (277,600 cases) and **Klaus passes**
  (success trap `$3469`). Harte is checked on the **exact cycle-by-cycle bus
  trace** — address, data and direction of every cycle — not just final state.
  Final state alone would accept a core that gets the right answer with the
  wrong bus behaviour, and the bus behaviour is the whole point: ANTIC's DMA
  and `/RDY` interact with the dummy reads and the RMW double write.
* Speed: Klaus runs 96.2M 6502 cycles in 0.24 s ≈ **400M cycles/s**, ~224x
  realtime for the CPU alone on an M-series Mac.
* **Interrupt timing: passes**, from ACID800 `cpu_clisei`'s three scenarios plus
  NMI edge/one-shot. Harte ties the interrupt lines inactive, so this is ground
  it cannot cover.
* **POKEY RANDOM LFSR: passes.** Not a sound model — the ANTIC timing tests use
  `RANDOM` as a one-cycle-resolution clock, so this is their prerequisite.
* **ANTIC DMA schedule: 50/50** against the table ACID800's `antic_dmapattern`
  carries as data — every mode 2–15 at narrow and normal width, on a row's first
  scanline and its later ones.
* ANTIC rendering + GTIA: next.

## The shape, and why

**One bus callback per machine cycle.** Every `rd`/`wr` in `xt6502.c` is one
cycle, issued in the order the NMOS part issues it. There is no cycle counter to
keep in step with anything, because the bus calls *are* the clock.

That is the point of moving this into software. ANTIC runs **inside** the read
callback: when it wants the bus it advances the world before handing the CPU its
byte, and a halted CPU is simply a callback that takes longer to return. So
there is no CDC, no two rasters with an arbitrary relative phase, no
level-vs-edge strobe hazard, and no `/RDY` sampled at a commit slot inside a
56-slot subcycle window — the four defects the fabric path has are not fixed
here, they are inexpressible here.

Conventions for the undocumented opcodes (the `$EE` magic constant for ANE/LXA,
`reg & (H+1)` with the page-cross high-byte quirk for SHA/SHX/SHY/TAS) match
`xt6502f.sv` deliberately, so the two cores agree by construction. That is what
makes any future disagreement between them *diagnostic* rather than just another
difference to chase.

## Files

| file | what |
|---|---|
| `xt6502.h` / `xt6502.c` | the cycle-exact CPU |
| `test/harte.c` | Harte vectors, exact bus traces |
| `test/klaus.c` | Klaus Dormann functional test |
| `test/irq.c` | interrupt timing (ACID800 `cpu_clisei`, as C) |
| `pokey_rand.{h,c}` | POKEY's polynomial counters + `RANDOM` |
| `antic_dma.{h,c}` | ANTIC's per-scanline DMA schedule |
| `acid_dmatable.h` | generated from ACID800's own DMA table |
