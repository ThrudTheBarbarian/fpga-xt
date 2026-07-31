# Software ANTIC/GTIA — design checklist, derived from ACID800

The instruction for this work is to take the ACID800 tests into account **while**
writing ANTIC, not afterwards, so the design does not get painted into a corner.
The 31 `antic_*` / `gtia_*` tests in `rsrc/acid800/Acid800/standalone` are
effectively the specification, and each names the behaviour it pins down. This
is that list turned into a design checklist.

**Baseline to beat:** the fabric path scores **32/63 at sallyrst `$06`**, 27 at
`$0A`, against a ceiling of 57 (five `mod_*` never halt by design, `cpu_65c816`
is a probe). Whatever the software model scores is measured against that.

## The structural decision, made once, up front

ANTIC runs **inside the CPU's bus-cycle callback**. It is not a peer that gets
stepped alongside the CPU — it is the thing that owns the bus and hands the CPU
its cycles. Concretely, `emu_bus_read()` first advances ANTIC by one colour
clock; if ANTIC wants that cycle for DMA it takes it and advances again, and the
CPU's read simply happens later.

Everything below is a consequence of getting that one thing right, and the four
fabric defects (CDC, two-raster phase, level-vs-edge strobes, `/RDY` sampled in
a 56-slot window) cannot be expressed in it.

## Checklist

### DMA and the bus (the foundation — nothing else is testable until this is right)
- `antic_dmapattern` — the per-scanline cycle allocation: playfield fetches,
  character-name vs character-data, and which cycles are left to the CPU.
- `antic_virtdma`, `antic_pmdma` — missile/player DMA slots, and DMA that
  happens with no visible effect.
- `antic_linebuffering` — ANTIC's internal line buffer, i.e. fetch time vs
  display time are NOT the same instant. Design for this from the start; it is
  expensive to retrofit.
- `antic_wsync` — `/RDY` release timing. **Known-good in the fabric path**: the
  registered-set latch + q1-retimed `/RDY` + release at cycle 104. The software
  model must reproduce the *semantics*, and the WSYNC re-arm on the FIRST `$D40A`
  write of an RMW (`wsync_rmw_rearm`) matters because the RMW double write hits
  it twice.

### Vertical timing and interrupts
- `antic_vcount` — VCOUNT advances at **cycle 111** of the scanline (established
  in the fabric work, `antic_timing_fixes`).
- `antic_nmist`, `antic_blockednmi` — NMIST latching and what happens when NMIs
  are blocked/disabled around the boundary.
- `antic_dlitiming`, `antic_vscroldli` — DLI delivery is a **physical-scanline
  map fired at cycle 8**, not a display-list-row map. Blank-line DLIs are mapped
  differently and are a known fabric bug (`acid800_dli_cluster`) — get it right
  here first, and that alone may localise the RTL fault.

### Display list and addressing
- `antic_default`, `antic_dlistwrap`, `antic_addresswrap`, `antic_addrmirror` —
  DL fetch, the 1 KB DL wrap and the 4 KB playfield wrap, register mirroring.
- `antic_charcontrol`, `antic_hiresbug`, `antic_psuedomodee` (GTIA) — character
  control bits and the hi-res artefacts.
- `antic_hscrolbug`, `antic_vscroll`, `antic_pfstarttiming`, `antic_pfstoptiming`
  — scrolling and where the playfield actually starts and stops. The
  start/stop-timing pair is what punishes a model that treats the playfield as a
  fixed window.

### GTIA
- `gtia_default`, `gtia_addrmirror`, `gtia_consol` — registers and mirrors.
- `gtia_collision`, `gtia_collision2` — collision detection, per colour clock.
- `gtia_pmoverlap`, `gtia_pmresize`, `gtia_pmretrigger`, `gtia_vdelay`,
  `gtia_phantomdma` — player/missile edge cases. **The P/M GRAFP render bug is
  already fixed in the fabric path**; the cluster there was blocked on GTIA
  modes 9/10/11, so those modes need to work here.

### Output
ANTIC/GTIA emit **one palette index per colour clock**. The framebuffer is
therefore 8-bit indexed and that is the *native* format, not a compromise —
index→RGBA32 through the palette LUT plus scaling is small RTL, and the plane
compositor, palette LUT and scaler all already exist.

## Corner-cases to design in, not bolt on

These are the ones that are cheap now and expensive later:

1. **Fetch time ≠ display time.** The line buffer means a register written
   mid-scanline affects display from a different point than it affects fetch.
2. **The playfield window is computed, not fixed.** DMACTL width, HSCROL and the
   start/stop timing interact; a hard-coded 40-byte window fails four tests.
3. **WSYNC is a level released at a specific cycle**, and an RMW writes it
   twice.
4. **DLI is scanline-mapped and fires at a fixed cycle**, independent of the DL
   row structure.
5. **Collisions are per colour clock**, so the pixel pipeline has to exist before
   GTIA collision tests can pass — do not build a scanline-at-a-time renderer.

## Iteration

Mac host build and qemu only — **no JTAG loads**. The whole point is that a
hypothesis costs a rebuild and a run instead of a bitstream plus a sweep.
