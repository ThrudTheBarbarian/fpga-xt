# ANTIC timing machine (`antic_timing.sv`) — design

## Why (one paragraph)

The existing ANTIC is two machines pretending to be one: a *renderer*
(dl_parser parse-per-frame → row walker → compositor, clk_sys) with the
real chip's cycle-level observable behaviour bolted on as correction
layers — phantom DLI rows, VS/DLI carry flags, VSCROL latch ticks,
modeled DMA stealing, a 29-bit runtime calibration register, and CDC
delivery-latency compensation on every CPU-visible edge.  Every ACID800
test that probes a CPU↔ANTIC coincidence has cost one more mechanism,
and the mechanisms interact (the +3 WSYNC-resume residual is five
individually-correct stages summing to an error no knob can fix; see
docs/a800/HANDOFF.md §0h).  MiSTer's ANTIC is one 1.8k-line cycle-serial
state machine that *owns the bus schedule* — the semantics ACID tests
fall out of the structure.  This design splits our ANTIC the same way:
a small cycle-serial **timing machine** that is the sole authority for
everything the CPU can observe, and the existing pipeline demoted to
pure renderer.

## Scope

`antic_timing.sv` owns, per phi2 cycle:

* the **hcount (0-113) / vcount-line (0-261) counter chain** — the
  CPU-visible raster.  VCOUNT reads, the cycle-111 increment, line 248
  VBI, all derived here.
* the **display-list fetch FSM** — real DL byte fetches at the real
  cycles (opcode at cycle 1, address lo/hi at 6/7), a live DL PC with
  1K wrap, JMP/JVB, `mDLControlPrev` semantics across the VBI (carry
  falls out), and the *stuck control byte* when DMACTL kills DL DMA
  mid-frame (the live-DMACTL cluster falls out).
* **DCTR (row counter)** — live increment/load, VSCROL compares at the
  real cycles (Altirra: DLI compare uses the cycle-6 sample used at 7;
  row stop uses the cycle-109 sample used at 112/1; block-entry DCTR
  load from live VSCROL).  No separate latch plumbing: the samples are
  just what the machine reads when it reaches those cycles.
* **NMIST / NMI**: DLI decision at cycle 7 (rowCounter == rowStop with
  the DLI bit), VBI at line 248 cycle 7; NMIST set from the same slot;
  /NMI as the 2-cycle pulse gated by NMIEN — all same-domain with the
  CPU, so recognition timing is exact by construction.
* **WSYNC**: the latch + release on this machine's own cycle grid.
  /RDY is a same-domain signal to the fid core — the registered-set /
  q1-retime / CDC / sample-grid chain (and its +3 residual) is deleted,
  not recalibrated.
* the **bus schedule** (`cycle_type`: cpu / dl-fetch / pf-fetch /
  pm-fetch / refresh / halted-wsync) — replaces antic_dma_steal's
  modeled stealing.  Phase 1 schedules playfield/PM slots without using
  the data (the *pattern* is what dmapattern/virtdma/pfstart/pfstop
  test); the render side keeps its own fetch path until phase 4.

## Domain and grid

* **clk_sally**, gridded by the same synchronised phi2 tick the fid
  core already paces on.  CPU-relative exactness needs both parties on
  the same edges — it does not need clock-authority changes.  The
  clk_sys render raster is untouched in phases 1-3.
* **Register writes are snooped same-cycle** (the hwreg write path
  originates in clk_sally).  NMIEN/DMACTL/VSCROL/DLIST writes reach the
  machine with zero latency; the entire "write lands ~1-2 cycles later
  through the snoop CDC" bug class is structural history.
* **DL fetches use the stolen slot on the real sally_mem port**: when
  the machine steals a cycle the CPU is halted, the port is idle, and
  the machine drives it — like the chip.  No new BRAM ports.

## What it does NOT do

No pixels.  No line buffer contents (phase-1), no character ROM, no
colour.  The parse/walk/compositor pipeline keeps rendering the frame
exactly as today; in phase 4 it consumes this machine's per-line decode
(mode, LMS, DCTR span) instead of maintaining its own truth, and the
phantom list / carry flags / latch ticks / steal gating are deleted.

## Migration plan (each step board-sweepable, renderer untouched)

0. Design doc (this file) + module skeleton + directed tb.
1. Machine runs headless alongside the current model; tb_fid_raster
   instantiates both; a diff tracer compares VCOUNT / NMIST / NMI edge
   times / RDY edges cycle-by-cycle.  Acceptance: progs A, 1-6
   reproduce Avery's cycle numbers (the harness already encodes them).
2. Switch consumers one at a time, sweep after each:
   a. VCOUNT read  → antic_timing (anchor: antic_vcount)
   b. NMIST + NMI  → antic_timing (anchors: nmist, dlitiming legs,
      blockednmi — expected first flips)
   c. /RDY         → antic_timing (anchors: wsync bytes d0-d5, vcount)
   d. steal schedule → antic_timing (anchors: nmist chain cycles,
      dmapattern/virtdma expected to move or flip)
3. Delete wsync_gen/nmi_gen/antic_dma_steal + the calibration register
   bits they consumed.
4. Renderer fed from the machine's line decode; delete phantoms,
   carries, latch ticks; revisit vscroldli (needs the renderer's DLI
   source to be this machine — it already is by then) and the walker's
   24-row skew (render-only concern at that point).

## Reference sources

Altirra source (golden, licensed reading) for exact cycle numbers —
key anchors already verified this week: mX==6 latch sample used at 7,
row-advance at 112/1 with post-use re-latch, VCOUNT increment at 111,
NMI pending at mX==7, `mDLControl &= ~0x4f` JVB DLI preservation,
blocked-NMI consumption during BRK vector fetch.  MiSTer's antic.vhdl
is a structural reference ONLY (GPL — look, don't copy): one machine,
fetch destinations {instruction, list_low, list_high, line_buffer},
`next_cycle_type` bus ownership.  Our measured constants live in
docs/a800/HANDOFF.md §0e-0h and the tb_fid_raster progs.
