# ACID800 conformance — session handoff

Goal: get the fidelity (fid) 6502 core to pass **all** of Avery Lee's ACID800
conformance suite (63 `.xex` tests in `rsrc/acid800/Acid800/standalone/`).
Altirra passes the suite, so it is the golden reference; whatever it does is
correct behaviour.

**Status: 25 / 57 passing** (2026-07-23: `antic_wsync` flipped to PASS —
see §1a; the run record is `docs/a800/runs/2026-07-23-1.json`).
Earlier status at handoff: ~22–24 / 57.
The session's headline result is a *structural* fix (a suite-wide deadlock) and
a full diagnostic toolchain — **not** a net increase in the pass count. The main
target this session (the DLI cluster) is **unsolved** and hit a wall that needs
a different debugging modality (ILA/ChipScope). Read the DLI section before
touching it.

Branch: `fix-antic-nmi-pulse`. Board: `192.168.192.179` (a.k.a. `xtos.local`,
but mDNS is flaky — **use the IP**). Build host: `valhalla` over SSH.

---

## 1. What actually got fixed (real, keep these)

### 1a. The INC-WSYNC-in-`_testEnd` deadlock — the important one
The ACID800 framework's `_testEnd` ($1D93) runs `INC WSYNC` at **$1DB8**. `INC`
is read-modify-write → it writes `$D40A` twice. On the fid core a WSYNC write
could *stall* the core mid-write while holding the bus; the held write re-armed
WSYNC and the machine **deadlocked**. Because `_testEnd` runs after every test,
this hung most of the suite (sweep scored ~25/63 as `na`).

Fix: on the NMOS 6502 `/RDY` only halts **read** cycles — writes always
complete. `hdl/fpga_xt_top.sv`: `fid_wsync_rdy = wsync_rdy_n | (~fid_rw & immune)`.
Board now boots clean and every test reaches a verdict. Commits `3084216`,
`04b2629`, `bb57d54`, `f4c698d`, `494300b`, `682854d`, `a62b6e0`.

Also in there: WSYNC is modelled as a **latch** (any $D40A write sets it,
line_start clears it, /RDY is a registered output; clear beats a same-cycle set)
— derived by cycle-modelling `antic_wsync` offline and **validated against
Altirra** (it reproduced all six `d0..d5` bytes exactly, including the two the
test never asserts). See memory `[[wsync_rmw_rearm]]`,
`[[acid800_wsync_deadlock_fixed]]`, `[[altirra_golden_reference]]`.

RESOLVED (2026-07-23): **`antic_wsync` PASSES on HW** (25/57), with
`antic_vcount` kept. Three stacked fixes (commits `dc1c388`, `e7f8d80`,
`2f81408`): the WSYNC latch SET is registered to the machine-cycle boundary
(clear-beats-set truly arbitrates, so the late-INC straddle no longer re-arms);
/RDY is the q1 tap retimed on the phi2 FALLING edge (tick-launched edges are
invisible to the fid core's SUB_COMMIT sample — measured, not theorised); the
release moved to cycle 104 (anchored by antic_vcount, since antic_wsync's poly
clock resyncs to the release and is offset-invariant). Shape and release stay
runtime-sweepable: DBG_TB `cfg[28:26]` shape mask, `cfg[23:20]` release offset,
`cfg[14]` comb fallback. `tools/wsyncrtl.py` is the validated cycle model
(byte-exact against a 28-config on-board sweep). See memory
`[[acid800_wsync_timing_solved]]`.

### 1b. Edge-detect the `we`-derived strobes
`antic_regs` derived `wsync_pending`/`nmires_strobe`/`pal_write_strobe`/
`os_rom_we` from the *level* `we` (held for the whole bus phase, which stretches
while the CPU is stalled) → a stalled write re-fired them every clock. Fixed
with edge detection (`canon_we_edge`/`chip_we_edge`). Commit `bb57d54`. Memory
`[[antic_strobe_level_deadlock]]`.

### 1c. `pal_sense`/`$D014` = NTSC `$0F`
Was `$02` (neither NTSC nor PAL). This is what made `antic_vcount` pass. A real
fidelity bug affecting anything checking video standard.

---

## 2. Tooling built this session (reuse it)

- **Altirra golden reference.** `~/src/AltirraSDL` (Avery Lee's own emulator,
  passes the suite). Run headless: `SDL_VIDEO_DRIVER=dummy AltirraSDL --headless
  --bridge` (bare `--headless` FAILS on macOS — the offscreen driver has no GL;
  token lands in `$TMPDIR`, not `/tmp`). Drive it with the stdlib Python SDK at
  `src/AltirraSDL/AltirraBridge/sdk/python`: `a.boot(xex); a.frame(300);
  a.peek16(0x58)` (SAVMSC → decode screen); `a.peek(0xC8,6)` (d0..d5);
  `a.history(32)` (per-instruction WITH cycle counts); watchpoints on $D40A/
  $D20A. Scripts: `scratchpad/acid_sweep_altirra.py`, `acid_ref.py`. Memory
  `[[altirra_golden_reference]]`.
- **`tools/bmp2text.py`** — decode a `graboverlay` BMP of the XL plane into the
  on-screen assertion text (exact OS-ROM glyph lookup, not OCR). Turns "FAIL"
  into e.g. `INC WSYNC failed: $1B != $0D`.
- **`tools/acid-sweep.sh`** — on-board full sweep (ONE ssh; Dropbear rate-limits
  loops). Copy it to `/media/6502/` and run `sh /media/6502/acid-sweep.sh`
  (piping the script over `ssh sh -s` stops working after a while). Writes
  `/tmp/acid-sweep.tsv`. **The sweep UNDERCOUNTS** — breakpoint races make
  passing tests score `na`/`fail`; trust an individual `xexload --hold` + screen
  grab for any single test's true verdict.
- **`tools/acid-shots.sh`** — grab result screens for named tests (kept separate
  from the sweep: toysh mis-parses quote/`$` in comments and nested `if` in
  `elif`). Shots go on the SD card (`/media/6502/acid-shots/`) — **`/tmp` is a
  tiny ramfs** that 184 KB BMPs overflow.
- **9-bit POKEY-poly cycle decoder** (`scratchpad/pokey-random-decode.py`,
  `wsyncmodel.py`): a wrong RANDOM byte decodes to an exact machine-cycle delta,
  because the suite reads `$D20A` RANDOM as a cycle-exact clock (AUDCTL=$80 →
  9-bit poly, 511-entry table).

### On-board debug primitives
- `/System/bin/6502 core fid|turbo`, `reset`, `status`, `break $A`, `watch $A
  [r|w|rw]`, `trace <secs>`, `diag`. NB: `6502 status`, `dmesg`, and
  `graboverlay` output is **lost to a plain board-side file redirect** — pipe it
  (`... | cat > file`).
- `/System/bin/xexload [--turbo] [--hold] <file.xex>` — `--hold` breakpoints at
  `_testEnd` $1D93 so the result survives (Y=$00 pass / Y=$80 fail).
- `mem <hexaddr> [hexval]` — read/write PL registers (hex only).
- **OVL peek**: `mem 43C00204 8000<addr16>` then read `mem 43C00418` (low byte =
  6502 RAM byte at addr, ANTIC-side read). **Always `mem 43C00204 0` after** —
  it hijacks the XL plane. Memory `[[ovl_peek_hijacks_display]]`.
- **DBG_TB probe** (@ `0x43C00878` cfg / `0x87C` stat / `0x880` cap): a 16-entry
  ring + trigger. **read_idx is cfg BITS [19:16]** → correct ring read is
  `mem CFG ${i}00E1` (5 hex digits). `${i}0000E1` (7 digits) puts i at [27:24]
  → **always reads slot 0** (this bug wasted hours). Modes: 1=write@match,
  2=read@match, 3=DLI@cyc8, 5=WSYNC, 6=any $D4xx write, 7=every line_start.

---

## 3. The DLI cluster — the wall (READ THIS before trying)

Tests: `antic_nmist`, `antic_pfstarttiming`, `antic_pfstoptiming`,
`antic_dlitiming`, `antic_vscroldli` (5). All fail "DLIs did not fire" /
"DLI1 handler was not called".

**Proven correct in sim.** `sim/tb_dli_e2e.sv` wires antic_raster + dl_parser +
nmi_gen exactly as `antic_top` and loads the pfstart DL — /NMI asserts at
scanline 31/49, `nmist=$9F`, with nmien=$80 held. `sim/tb_dli_map.sv` shows
dl_parser records the DLI at physical rows 23/41. **Sim always passes.**

**On hardware** (measured over ~20 diagnostic builds — see the `diag:` commits,
each repurposes diag8=`0x43C0041C` / diag9=`0x43C00420`; read with `mem`, always
before/after DELTAS since counters free-run):

1. DL loads correctly — OVL peek shows flat `mem[$2C00]=$70,$70,$F0` (the test DL).
2. dl_parser uses the right DL address ($2C00) and **populates the DLI state**
   correctly during vblank: line_dli_p bit 23 set at scanline **248**; the list
   version has row 23, `dli_cnt=8`.
3. But at scanline **31** (raster row 23 — where the DLI must fire) the DLI state
   reads **0** (both the constant-index `line_dli_p[23]` and the list `dli_cnt`).
   It is **cleared between the parse and the raster reaching the DLI row**.
4. The only clear path is `start_parse` (= `dl_start_pulse`), which `antic_seq`
   fires **only at vbi_start (scanline 248)**. Yet the falling edge is at
   scanline ~17, and **one build measured `dl_start` firing at scanline 4**
   (spurious) — while the *next* build measured zero. **Non-deterministic across
   builds.** `vbi_start` count during nmien[7] also read 0 in one build despite
   nmien being held many frames.
5. fid side: nmien[7] is HELD $80 through the whole dli1 phase (`clr_pc` =
   `_testEnd` $1DBE); the CPU's NMIST reads never return bit7=1.

**Conclusion: a genuine timing/metastability fault.** Every build passes setup
timing (WNS>0), sim never reproduces it, and functional `mem`-probe diagnostics
give inconsistent answers build-to-build. This is why I stopped — more 40-minute
functional-probe builds are not productive.

**Fixes attempted, all sim-clean, none worked on hardware** (all committed):
force `line_dli_p` to registers (`ram_style`); replace the 240-entry
`line_dli_p[dli_row]` array with `dli_list[0:23]` + parallel comparator;
double-buffer the list into a stable `active` snapshot swapped only at
parse_done; guard the swap against empty (dli_cnt=0) parses. The list +
double-buffer are retained (cleaner than the array, harmless).

Memory `[[acid800_dli_cluster]]` has the full chain.

---

## 4. What to do next (ideas, roughly ranked)

### A. DLI cluster → **ILA/ChipScope** (the right tool for the wall)
Add an ILA core to `fpga_xt_top` capturing, in clk_bus, at least:
`u_antic_top.dl_start_pulse`, `vbi_start_pulse_bus`, `ar_scanline`,
`ar_phi2_in_line`, `u_dl_parser.dli_cnt` (or `line_dli_p` for a few rows),
`nmi_cur_row_dli`, `nmien_q`, and `u_dl_parser.state`. Trigger on
`dl_start_pulse && ar_scanline != 248`, or on `dli_cnt` going non-zero→zero.
This directly shows the spurious clear/trigger that the functional probes
couldn't pin. Vivado hw_manager over the existing JTAG (`valhalla`,
`vivado/jtag-valhalla.sh` is the load path; the ILA needs the `.ltx` + an open
hw_server). Hypotheses to confirm/kill with the waveform:
  - `dl_start`/`vbi_start` genuinely glitches mid-frame (raster counter compare
    `scanline==248` metastable, or a fanout/timing issue on the pulse).
  - the parse for the LONG pfstart DL crosses >1 frame and the FSM re-enters
    S_IDLE + a start_parse at a bad time (check `u_dl_parser.state` vs scanline).
  - the DLI-state flops share a mis-synthesised reset that pulses mid-frame.
If it IS a spurious `dl_start`, the clean fix is to gate `start_parse` in
dl_parser to only accept it during the true vblank window (e.g. require
`scanline >= 200`), and/or register/retime the pulse.

### B. `antic_wsync` INC −1 — DONE (2026-07-23, see section 1a)
Registered-set latch + q1 mid-retimed /RDY + release 104. The useful reusable
trick from the fix: read a test's `d0..d5` result bytes from zero page
$C8-$CD over the OVL peek while halted at `_testEnd` — no screen decode
needed, and a shape×offset sweep of ~30 configs runs in under 10 minutes.

Side observation from that session's verification (unresolved, low priority):
`cpu_65c816.xex` now fails `xexload -h` persistently (`xexload: failed`,
rc=1, 20+ attempts across reboots) while other XEXes load first try —
differential-checked against `antic_wsync.xex` on the same board state. It
loaded on 2026-07-22 (sweep scored it `na` = loaded, never halted). Doesn't
affect the 25/57 count (out-of-scope test, recorded `na` either way), but if
xexload flakiness gets attention, start here: it may be a marginal handshake
race the 1-cycle WSYNC resume shift exposed, or XEX-content-specific.

### C. P/M cluster (`gtia_pmoverlap`, `gtia_pmresize`, `gtia_vdelay`,
`gtia_phantomdma`, `antic_pmdma`) — 5 tests, "Got 00"
These are NOT one bug anymore (the old GRAFP-dangling root cause is already
fixed — that's why `gtia_collision` passes). Each is a distinct P/M sub-feature
(overlap priority, SIZEP resize, VDELAY, phantom DMA, P/M DMA fetch). Decode each
assertion (`bmp2text`) and pick them off individually.

### D. Scattered singles — decode assertions and rank by cheapness
Full failure triage was captured (`bmp2text` of each result screen). Notable:
`antic_vscroll` "expected 12, got 14" (clean off-by-2, likely a small VSCROL
region-size fix), `antic_addresswrap`/`antic_dlistwrap` "did not wrap" (DL
address wrapping), `cpu_bugs` "BRK handler should not have executed" (a CPU test
— usually cleaner to fix than ANTIC timing). `antic_blockednmi` — **Altirra
itself fails it**, so it's out of scope (ceiling is 54, not 63: also skipped are
`cpu_65c816`, `pokey_serdirect`, `pokey_skstat` which need a real D1: disk).

---

## 4b. Overnight session 2026-07-23/24 — state so far

Confirmed flips tonight (Y-verdict, hardware): **pokey_irqtiming** (the
NMOS 2-cycle /IRQ setup rule in xt6502f, commit 69bf61e).  antic_nmist's
former double-DLI2 failure was root-caused (stale/junk DLI snapshot made
immortal by the empty-parse guard — see memory acid800_dli_staleness_fix)
and fixed (60f0050), plus: live DL program counter with 1K/4K wraps
(a04517d), deferred mid-parse DLIST writes (4317501), parse kick moved to
scanline 260 (872923b), CHACTL bit map + reflect (8af815f), POKEY STIMER
4-cycle lag (69bf61e).

**RESOLVED (build 14 era)**: the "wedge" was two things.  (1) SALLYRST now
aborts an in-flight parse — display always recovers on cold boot.  (2) The
persistent free-running DL PC accumulated garbage rows (probe-measured: DLI
events at rows 12/15/28/37 during plain resume_test phases, and row 177
during boot) — the live/pended DLISTL/H write-through could not keep it
honest.  Replaced with DIRTY-TRACKED reload: any DLIST write since the last
parse start makes the next parse reload from the registers; untouched
registers free-run (the antic_dlistwrap continue semantics).  Mid-parse
writes can no longer teleport a parse.

antic_nmist now progresses PAST the whole DLI-handler phase (d0/d1 pass) and
fails at resume_test's first NMIST-status assert ("DLI bit was not set in
NMIST with DLIs disabled", read at a fixed scanline ~41) — which the garbage
rows explain: with wrong rows the scanline-39 DLI event lands elsewhere.
Re-test after the dirty-reload build.

**OLD NOTE — the parser wedge**: after running an acid DLI test the
ANTIC display goes blank and stays blank across 6502 cold boots (PL
reload required).  BASIC and non-DLI tests render fine.  The wedged
parse also explains the DLI cluster still failing on builds 11-13 (rows
never load).  sim/tb_wedge.sv (real antic_top + the tests' DMACTL/DL-swap
sequence) does NOT reproduce — HW-timing shaped.  Build 14 adds: SALLYRST
aborts an in-flight parse (cold boot always recovers), and diag8
(0x43C0041C) = {[31:28] parser state, [27:26] emit phase, [25:24] 0,
[23:16] parse_count, [15:8] dlstart_bad, [7:0] ungated DLI count} — read
it around a wedge (script /media/6502/b14wedge.sh).

Also known: screen grabs while the core is HELD at a breakpoint read
all-zero on builds 10+ (running-core grabs are fine) — diagnostic-path
anomaly, unexplained, low priority.

### Next POKEY target, designed but not landed: pokey_inittiming
The 64k/15k reference dividers free-run in clk_bus and ignore SKCTL init —
real POKEY holds them preset in init and releases at exact phases:
**next 64 kHz tick = release + 22 cycles, next 15 kHz tick = release + 81**
(Altirra pokey.cpp SKCTL init-release block, with the LFSR explanation).
Design: make both dividers phi2-paced down-counters (period 28/114), held at
preset (22-1 / 81-1) while `skctl[1:0]==0`.  Audio rates are unchanged
(28 phi2 = 15.68 us = the current clk-based 64 kHz).  A first attempt was
reverted: tb_pokey's toggle-count expectations are calibrated to the old
clk-based cadence and its phase D0 (init RANDOM=$FF) assumes SKCTL is never
released — the tb needs recalibrating alongside (and check how tb_pokey
routes phi2_tick into pokey.sv; toggles came out ~100x low, suggesting the
tb's phi2 wiring differs from the fpga_xt_top one).  pokey_timertiming's
next step: DBG_TB mode-2 capture of IRQST reads with STOP-ON-FULL armed
AFTER xexload returns (circular gets flooded by post-fail polling).

## 4c. DLI-cluster endgame (2026-07-24 afternoon) — where each test stands

**antic_nmist: GREEN** (run 2026-07-24-2).  The full chain, each rung
hardware-verified: bram_shim per-port result registers (the cross-client
data leak — also explains the old gtia_collision/parse-kick-260 conflict:
one bug, both directions), parse kick at 260 (arm-timing frame miss),
NMIST status latch at cycle 7 (bisected 8→6→7; Altirra mX==7), NMIRES
tick-aligned with set-beats-clear + within-the-set-cycle discard, NMIEN
gate = armed-at-status-tick OR live-at-pulse.

**antic_dlitiming: 3 of 4 sub-cases pass.**  The interrupt-recognition
model that got there (xt6502f): d1 samples pend/level at EVERY commit
slot of the free-running sub counter (wall cycles, RDY or not); the POLL
latch samples d1 only at RDY-true commit slots; recognition reads the
poll latch at the fetch boundary.  Running: polled(B)=pend(B-2) = the
2-cycle NMOS setup rule (also what flipped pokey_irqtiming).  Stalled:
the decision freezes, so a mid-stall edge is taken one instruction after
resume.  REMAINING: 'Delayed odd count \$0E != \$0F' — the odd-alignment
delayed case is recognised one instruction early; a half-cycle poll-
granularity delta (the real poll point is phi2 of the penultimate cycle,
once per instruction — ours is per-cycle).  Next idea: latch the poll
ONCE per instruction at its penultimate commit slot instead of every
slot.  5 builds spent; park unless fresh.

**antic_vscroldli**: 'VSCROL took effect too late' — the DOCUMENTED
parse-ahead limit (dl_parser header): mid-frame VSCROL rewrites need
live per-raster-line region sizing in the compositor DCTR.  Same family
as antic_vscroll's off-by-2.  Feature work.

**antic_pfstarttiming / pfstoptiming**: 'Character mode DMACTL early
test failed: stride=20/22' — mid-scanline DMACTL writes must change
playfield DMA start/stop within the line.  Feature work (live DMACTL in
the fetch/steal path).

Regression state: 27/57 held across the whole interrupt rework (run
2026-07-24-3, full sweep on build 30).

## 5. Housekeeping the fresh session should do first

- **Revert the temporary diagnostics** for a clean bitstream. The `diag:` commits
  (`2da5d51`..`8bf2af3` interleaved) repurpose diag8/diag9 and add capture logic
  in `antic_top`/`fpga_xt_top`/`dl_parser`; they're read-only (don't corrupt the
  datapath) but should come out. Keep: all `wsync:` commits, `antic:` strobe
  fix, `tools:`, and the `dl_parser:` list+double-buffer (`9c8ca1f`, `3797980`,
  `feaa721`) — cleaner than the array. Watch: `e724687`'s message says "fixes the
  DLI cluster" — it does NOT; that title is wrong (the ram_style attempt failed).
- **Workflow**: edit on Mac, build on `valhalla` via `./vivado/run-valhalla.sh
  bit` (background it; ~30–40 min, watch `write_bitstream completed` +
  `TIMING GATE: PASS`). Load with `./vivado/jtag-valhalla.sh reset &&
  ./vivado/jtag-valhalla.sh load` (from **repo root**; reset = power-cycle
  equivalent; a plain `load` over a live image can wedge the board). After a
  load, wait for the board with an `until ssh ... cat /proc/uptime` loop.
  **Always checkpoint background jobs** (verify output is flowing) — an overnight
  chained job silently stalled at a load step this session and lost hours.
- **Sim**: `cd sim && make dl_parse` / `make boot` / `make wsync`, plus the new
  `tb_dli_e2e` / `tb_dli_map` (build them by hand — see their headers). `make all`
  runs the suite (70 pass; `tb_antic_modes` fails 23 pre-existing/unrelated).
- The SD image already has the tools (`/System/bin/{6502,xexload,graboverlay}`)
  and the tests (`/media/6502/acid/*.xex`). If you rebuild userland,
  `make -C loader sdpush` then **cold-load** (reset && load) — sdpush without a
  reboot doesn't take.

## 6. Key memory files (auto-loaded, but read these explicitly)
`[[acid800_wsync_deadlock_fixed]]`, `[[acid800_dli_cluster]]`,
`[[altirra_golden_reference]]`, `[[antic_strobe_level_deadlock]]`,
`[[wsync_rmw_rearm]]`, `[[acid800_failure_taxonomy]]`, `[[acid800_test_suite]]`,
`[[fid_first_class_core]]`, `[[jtag_cwd_and_verify_reboot]]`,
`[[feedback_jtag_empty_chain_not_cable]]`.
