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

## Migration plan — status as of 2026-07-26 evening

Legend: **[done]** landed + committed · **[part]** partially landed ·
**[todo]** not started.  "Sweepable" = the runtime A/B bit (sallyrst[2])
means every step can be measured against legacy on the same bitstream.

**0. Skeleton + directed bench — [done]**
`hdl/antic_timing.sv` (~420 lines) + `sim/tb_antic_timing.sv` (T1-T6,
`make -C sim antic_timing`).  Anchors: VCOUNT advance at 111, WSYNC
delay slot + release, VBI NMIST + /NMI pulse, DL-driven DLIs + JVB
park, the vscroldli write-timing bracket, VCOUNT single-cycle rollover.

**1. Headless co-sim + diff — [done]**
`tb_fid_raster` instantiates the machine alongside the legacy model
with a real `display_shadow` on its fetch port (the production path —
the earlier hierarchical shortcut hid a capture-timing bug).
`+tmskew=N` reproduces the arbitrary hardware phase offset between the
machine and the render raster; under full authority the offset is
provably invisible.  Replicas of Avery's chains: `+prog=7` (vcount
d0/d1/d2), `+prog=6` (blockednmi #1), `+prog=4` (vscroldli bracket).

**2. Consumer switch — [done], but as ONE step, not four**
Wired in `fpga_xt_top` behind `sallyrst[2]` (CTRL 0x31C bit 2, power-on
0 = legacy, gated to the fid core; the turbo core never sees it).
  a. VCOUNT read     — local same-cycle mux at the fid data-in [done]
  b. NMIST + /NMI    — muxed at the fid glue                   [done]
  c. /RDY            — muxed at the fid glue                   [done]
  d. steal schedule  — full Altirra playfield DMA windows      [done]
**Lesson that cost a build cycle:** these can NOT be switched
independently.  Mixed authority (machine WSYNC/VCOUNT + legacy-raster
steals) shifts every post-WSYNC instruction stream by the arbitrary
phase offset between the two rasters — measured as `antic_vcount`
"#1 wrong: $02 != $01" on build 47b.  Steal authority must move with
the rest, which is why 2d was pulled forward.

Hardware state after step 2 (build 51b, single-test probes under
authority): `antic_blockednmi`, `antic_wsync` (all six bytes),
`cpu_clisei` **pass**; `antic_vcount` and `antic_nmist` each advanced
to a later assert and are fixed in 77ae654 (build 52x pending).
This step buys PARITY with legacy, not new greens — see step 4.

**3. Delete the legacy timing path — [todo]**
Remove `wsync_gen`, `nmi_gen`, `antic_dma_steal`, and the calibration
register bits they consumed (shape masks, `rel_adj`, comb fallback,
write-immunity toggle).  Gated on step 2 holding every anchor on
hardware, and on a decision to make authority the default.

**4. Renderer fed from the machine — [todo] — THIS IS WHERE THE REDS ARE**
Steps 0-2 only make the CPU's VIEW of ANTIC exact.  The renderer still
maintains its own truth (parse-per-frame + row walker), so the tests
that need render-time and CPU-time to agree are still red.  This step
feeds the parse/walk pipeline from the machine's per-line decode and
deletes the compensation layers: phantom DLI rows, `act_carry_vs` /
`act_carry_dli` / `carry_row0_q`, the VSCROL latch ticks, and
`meta_dl_active` steal gating.
Expected to unblock, in rough order of confidence:
  * `antic_vscroldli`  — needs the renderer's DLI source to be the
    machine (whose bracket already passes in the bench)
  * `antic_dlistwrap`  — test #2 needs the live-DMACTL stuck-control-
    byte behaviour, which the machine already implements
  * `antic_dmapattern`, `antic_virtdma` — need the machine's DMA
    schedule to be the one the renderer actually fetches on
  * `antic_pfstarttiming`, `antic_pfstoptiming`, `antic_hscrolbug`,
    `antic_linebuffering` — mid-scanline DMACTL/HSCROL effects
Also resolves the walker's 24-row raster skew (a render-only concern
once timing is elsewhere).

**Not on this plan at all** (the majority of the remaining reds): the
POKEY serial engine (serclock/serdirect/sertiming/twotone/skstat), the
POKEY timer/IRQ pair, and the GTIA per-colour-clock P/M engine
(hiresbug/pmoverlap/pmresize/pmretrigger/vdelay/collision2/psuedomodee/
charcontrol/phantomdma).  Sixteen of the twenty-six failures are in
those two clusters and no amount of ANTIC work touches them.

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
