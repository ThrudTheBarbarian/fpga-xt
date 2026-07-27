# ACID800 conformance — session handoff

**Status: 30 / 57 passing** (board: build 46b/af09c8f, run `2026-07-26-4`.
Greens incl. `antic_nmist`, `antic_vscroll`, `antic_addresswrap`, `pia_irq`,
`pokey_irqtiming`, wsync/vcount/clisei anchors — all HELD across builds
44-46b. The overnight 07-25→26 ledger is §0h: four structural fixes landed
(VSCROL latches, VBLANK DLI carry, real SKSTAT/SKRES, NMOS blocked-NMI),
two failures moved to their next assert, and the three biggest remaining
blockers are each root-caused with committed sim instruments: the +3
WSYNC-resume residual (§0h), the walker 24-row raster skew (§0g), and the
dlitiming penultimate-poll rule (§0f).)

Branch: `fix-antic-nmi-pulse`. Board: `192.168.192.179` (a.k.a. `xtos.local`,
but mDNS is flaky — **use the IP**). Build host: `valhalla` over SSH.
**Board gotcha:** the board's network DIES after ~4-15 xexload sessions —
power-cycle + reload (`jtag-valhalla.sh reset && testbed`), don't debug mDNS.
**Build gotcha:** never JTAG-load while a valhalla build is in flight (the
build regenerates the ps7_init tree under the JTAG scripts).

---

## 0. 2026-07-25 sessions (newest)

### 0k. Night of 2026-07-26/27 — where things stand (READ THIS FIRST)
BOARD: build 66 (400d414) loaded, LEGACY default (sallyrst[2]=0) = 31/57.
Machine authority (sallyrst[2]=1) is ALSO 31/57, measured with a clean
chunked sweep (6 blocks, reboot between each) and ZERO errors — the
cascade that wrecked earlier authority sweeps is gone.

THE MIX DIFFERS, AND THE DIFFERENCE IS INSTRUCTIVE:
  authority GAINS antic_vscroldli — structurally impossible for the old
    parse/walk architecture (needs a CPU write at cycle 3 to interact
    with the row-end decision made on the SAME scanline).
  authority LOSES gtia_collision — and this is a CLASS, not a bug.
    Collisions are computed by the RENDERER, which still runs on the
    legacy raster, while under authority the CPU is paced by the timing
    machine.  Any test whose result depends on CPU-write timing
    RELATIVE TO RENDERED OUTPUT is therefore sensitive to the phase
    between the two domains.  That is exactly the step-4 gap in
    docs/Design/antic-timing-machine.md and it closes when the renderer
    is fed from the machine.  Expect more of this class until then.
    (Verified: collision PASSES under legacy on the same bitstream.)

DMA CLUSTER — SCHEDULE PROVEN, DELIVERY EXCLUDED, CAUSE STILL OPEN.
The schedule now matches Avery's own expected masks CYCLE-FOR-CYCLE for
narrow mode 2, both first row (mode2a: 25,26,28..91) and later rows
(mode2b: 25,29/30/31,33/34/35...61,63,65...).  Reproduce any time with
    make -C sim antic_timing && vvp -N build/tb_antic_timing.vvp \
        +pfdump=1 +pfrow=<0|1> +pfw=<1|2|3>
Both DELIVERY phases have been excluded experimentally on hardware:
combinational (builds 62, 66) and one-cycle-delayed (65b) — neither
moves any cluster test, and the delayed one costs gtia_collision, so
the combinational view is what is checked in.  antic_dmapattern still
reports "mode 02-a", which IS the narrow-first-row case that matches in
sim.  So the error is neither the schedule nor the delivery phase.
NEXT SUSPECTS (untested): whether POKEY RANDOM advances exactly once
per machine cycle (the test measures cycle positions by sampling it —
if RANDOM is off, every mode fails regardless of DMA), and whether the
test's per-sub-test DMACTL writes are seen by the machine at the right
cycle.  Check RANDOM first; it invalidates the whole measurement.

CORRECTION TO AN EARLIER NOTE: there is no missing "badline" fetch
mechanism.  That claim came from decoding a .lst line TRUNCATED at 150
columns; re-read untruncated, mode2a ends at cycle 91 exactly as we
produce.  Always `cut -c1-400` those table lines.

### 0j. DMA-pattern cluster — ground truth located (Sun night)
antic_dmapattern embeds its EXPECTED cycle-blocking bitmasks as a table
at $3800 in the test image (labels mode2a/2b/3a/3b/... in the .lst,
~line 2334), with a cycle-number header comment directly above:
    mode2a dta $08,%01000011,%00000000,%00000000,%01101111,%11111111...
FORMAT (confirmed): entries are 16 bytes each, contiguous from $3800 in
table order (mode2a $3800, mode2b $3810, mode3a $3820, ...).  Byte 0 is
a descriptor ~= mode*4 | variant; bytes 1..14 are a BIT-PER-CYCLE
blocked mask starting at cycle 0 (MSB first), byte 15 = $A5 terminator.
The mask is self-validating: mode2a's first blocked cycles decode to
{1, 6, 7}, which is exactly the DL instruction fetch at 1 plus the LMS
operand fetches at 6/7 that the machine already implements — so both
the format reading and our DL model are confirmed correct.
mode2a full decode: {1,6,7} u {25,26} u {28..99}.  NOTE this does NOT
match a plain names-every-2-from-{10,18,26} + data+3 model for any
width (that predicts a gap at cycle 90 for narrow, and different
extents), so the playfield START/EXTENT rules still need deriving from
these masks rather than from the prose.  THAT IS THE ORACLE: any
future DMA work should decode this table and diff it against
`make -C sim antic_timing` + `+pfdump=1`, which dumps the machine's own
schedule for a forced mode-2 line.  Do not hand-guess cycle offsets.

SOLVED FROM THE ORACLE (2026-07-27 early hours):
 * REFRESH SLIPS, AND LATE REFRESHES ARE DROPPED.  Altirra's
   ATAnticSetRefreshCycles is the spec and is now implemented verbatim:
       r = 24; for (x = 25; x < 61; x += 4) { if (r >= x) continue;
                r = x; while (r < 107) if (free(r)) {place(r); break;} r++; }
   Nine nominal slots every 4 from 25; a blocked refresh moves to the
   next free cycle; a refresh still seeking when the next nominal slot
   arrives is DROPPED (not queued — that was my first, wrong model).
   The arm must be COMBINATIONAL or every refresh lands one cycle late.
   RESULT: our narrow non-first-row schedule matches mode2b
   CYCLE-FOR-CYCLE across the whole line, including the point near 59
   where the refreshes are spent and the pattern relaxes to data-every-2.
 * BITMAP MODES START 2 CYCLES LATER than char modes: Altirra
   mPFDMAStart = (mode < 8) ? {26,18,10} : {28,20,12} for
   narrow/normal/wide.  Ours used the char start for every mode.
 * P/M DMA is display-region only (lines 8..247), and the PLAYER enable
   forces missile DMA (DMACTL & 0x0C).
 * cycle_type must stay COMBINATIONAL.  Registering it to match
   rdy_n_q's depth shifts the whole pattern +1 — the WSYNC register is
   already absorbed into RELEASE_CYCLE, so the paths must agree with
   the RASTER, not with each other (I made and then reverted this).

STILL OPEN — the first-row ("badline") extent: mode2a's mask runs solid
to cycle 99 where our narrow row-0 schedule stops at 91 (names 26..88
every 2, data 29..91 every 2, refresh at 25 and 90).  Eight cycles
unaccounted.  Altirra's own refresh comment notes "the latest a refresh
cycle will ever run is 106, which happens on a wide 40 char badline",
so first rows evidently fetch more than names+data as modelled.  The
next step is Altirra's rotating DMA-clock model (kClockPattern /
kModeToFetchRate, antic.cpp ~2830+) rather than the start+step
approximation used here.

Progress so far: the machine's mode-2 pattern is structurally correct
(names every 2 from the width start, char data +3 then every 2, 40+40
fetches at normal width, nothing >= 105).  Two DELIVERY bugs found and
fixed by comparing paths rather than guessing:
  * the CPU-facing steal gate was combinational while /RDY goes through
    one register (rdy_n_q) — every stolen cycle landed one machine
    cycle earlier than the calibrated WSYNC path (c17f56c);
  * P/M DMA ran on every scanline; Altirra gates it to lines 8..247, so
    the machine was stealing 5 cycles/line through the VBI, where the
    tests do their setup (dc3efe6).
antic_pfstarttiming MOVED in response (stride 20 -> 12), confirming the
cluster is sensitive to these.  Still red: dmapattern (mode 02-a),
virtdma, pfstart/pfstop, hscrolbug.

### 0i. ANTIC timing machine — authority calibration (Sun 07-26, LIVE)
The cycle-serial machine (docs/Design/antic-timing-machine.md,
hdl/antic_timing.sv) is ON THE BOARD behind sallyrst[2] (CTRL 0x31C
bit 2; xexload preserves it since fdf5991).  Legacy default = 31/57;
the board is LEFT ON LEGACY after every probe.  Migration status and
the phase plan live in the design doc — read that first.

**Iterate SINGLE-TEST, never by sweep.**  ~3 min/test: set the bit,
`xexload -h`, read Y, `acid-shots` for the assert text.  THREE probe
hygiene rules learned the hard way today:
 1. RETRY each load (3x) and report `loadfail` distinctly — a BOOT
    ERROR screen looks exactly like an assert failure in the Y register
    and cost an incorrect "regression" diagnosis.
 2. Run the test you care about FIRST: a failed test leaves the core in
    a state that boot-errors the NEXT load (antic_blockednmi showed
    BOOT ERROR for two builds purely as contamination).
 3. Build directives are DETERMINISTIC — re-spinning the same directive
    reproduces the WNS exactly (52 and 52c, both medium, both
    clk_sys -0.236).  Rotate: medium / high / Explore.

AUTHORITY SCOREBOARD (build 54b, 47405af — retried, so solid):
  PASS  antic_vcount (incl. the single-cycle rollover), antic_wsync
        (all six bytes), cpu_clisei
  FAIL  antic_nmist       -> the NMIEN sub-tests (see below)
  FAIL  antic_blockednmi  -> 'BRK handler should not have executed'
                            (test #3: an EARLY edge must still hijack;
                            passed at pulse 8-9 on build 51b, so the
                            pulse position and the NMIEN window are
                            coupled and must be solved together)
  FAIL  antic_vscroll     -> test #5 'expected 15, got 1' (the oversize
                            frame-spanning DL: the machine restarts at
                            line 8 unconditionally; real ANTIC keeps
                            fetching to the VBI)

**THE NMIEN WINDOW — SOLVED IN STRUCTURE, UNVERIFIED ON HW.**  Four
asserts measured from both directions bracket it:
  enable  on cycle 6 -> MUST activate    (gate at 7 failed this)
  enable  on cycle 7 -> must NOT activate(gate at 9 failed this)
  disable on cycle 5 -> MUST deactivate
  disable on cycle 6 -> must NOT deactivate (gate at 8 failed this)
No single sample point can satisfy those.  Altirra (antic.cpp ~594,
640-666) takes TWO samples and combines them asymmetrically:
    mX==7: early  = NMIEN
    mX==8: early2 = NMIEN
           cumulative     = pending & early           -> assert NOW
           cumulativeLate  = pending & early2 & ~early -> assert +1 cycle
An enable at the first sample fires promptly; an enable arriving
between the samples fires one cycle late; a disable after the first
sample CANNOT cancel.  Implemented in antic_timing (nmi_en_early /
nmi_en_late, samples entering 8 and 9, pulse at 9 or 10) — benches
green, NOT yet on hardware.  NEXT BUILD carries this.

CALIBRATED CONSTANTS (each from one named assert, HW-derived):
  RELEASE_CYCLE   = 104   (fid data-sample sits one window ahead of
                           commit; prog=7 replica reads 01/02/03)
  NMIST change    = entering 7, DLI compare on the cycle-6 VSCROL
                    sample (= Altirra mLatchedVScroll2 exactly)
  status set      = dominant over a same-cycle NMIRES (re-assert at 8)
  VCOUNT rollover = 131 for exactly one cycle at the end of line 261
  PF DMA windows  = Altirra UpdateDMAPattern (steps 2/4/8, starts
                    10/18/26, char data +3, bitmap +2, HSCROL widens
                    one step + delays HSCROL/2, >=105 virtual)
  DL capture      = AT the launch tick (dl_pc advances the same tick)

SIM INSTRUMENTS (committed, fast):
  make -C sim antic_timing        T1-T6 directed anchors
  tb_fid_raster +tmauth=1         machine drives /RDY,/NMI,VCOUNT,NMIST
                +tmskew=N         arbitrary HW raster phase (proven immune)
                +prog=7           antic_vcount d0/d1/d2 replica
                +prog=6           antic_blockednmi #1 replica
                +prog=4           antic_vscroldli bracket
LESSON: mixed authority is unsound — machine WSYNC/VCOUNT with
legacy-raster steals shifts every post-WSYNC stream by the arbitrary
phase offset.  Steal authority must move with the rest.

### 0h. Overnight 07-25→26 ledger (builds 44-46)
Score stayed 30/57 across the night but FOUR structural fixes landed,
two failure modes moved to their next assert, and three root causes are
now fully documented (0e/0f/0g + below).  Build history:
 * build 44 (39c634b, AltSpreadLogic_medium): Altirra VSCROL dual
   latches.  30/57 held, no regressions; vscroldli residual root-caused
   to the walker's 24-row raster skew + parse-time phantom rows (§0g).
   NOTE: a false alarm nearly rolled this build back — see
   [[ssh-stdin-script-broken]]: `ssh board sh -s < script` regressed to
   executing ONE line, masquerading as xexload/GP0 wedges; `strace` on
   the board proved the fabric fine.  Sweeps now cat-push the script.
 * build 45/45b: FAILED TIMING (clk_sally -0.190 / -0.311) — the
   VBLANK DLI-carry as a combinational (carry && dli_row==0) term in
   the dli_at cone.  Lesson: keep that cone free of comparators.
 * build 45c (9c36eaa, AltSpreadLogic_medium, +0.087/+0.010): DLI
   carry REGISTERED (carry_row0_q) + real POKEY SKSTAT layout/SKRES.
   30/57 held.  pokey_skstat MOVED: framing assert passes, now blocks
   on 'Timeout occurred while sending status command' = the M25
   serial-output engine (same wall as serclock/sertiming/serdirect/
   twotone — one serial engine unblocks five tests).  antic_dlistwrap
   test #2 needs the live-DMACTL stuck-control-byte model (DL DMA
   killed mid-frame -> the current DL control byte keeps firing its
   DLI every row-end forever, across the VBI) — live-DMACTL cluster,
   not the budget-stop carry (which is correct per Altirra restart).
 * build 46b (af09c8f, AltSpreadLogic_high; 46's AltSpreadLogic_medium
   spin missed on the KNOWN-thin sally_mem->axi_rdata_q and
   display_shadow->compositor paths — placer variance, not the change):
   NMOS blocked-NMI — genuine BRK's vector fetch consumes a late NMI
   edge (lost forever); early edge still hijacks; hijacked BRK drains
   the recognition pipeline (latent double-NMI fixed).  tb_xt6502f_irq
   T5/T6 prove all three mechanisms.  30/57 held; antic_blockednmi did
   NOT flip — tb_fid_raster +prog=6 (exact test-#1 replica, committed)
   reproduces the HW failure and pins the cause: the post-WSYNC resume
   runs +3 vs Avery (LDA# at 106-107 vs 103-104; BRK4 at cycle 10, VBI
   pend at 9 -> pend arrives BEFORE the decision = legit hijack).

THE +3 RESUME RESIDUAL — full accounting (now gates THREE tests:
blockednmi, nmist exactness, dlitiming's alignment):
  release pulse @104 (rel_adj-pinned by vcount)
    -> wsync_gen registered set/clear: latch high @105
    -> q1 history tap: @106
    -> phi2_fall mid-cycle retime + fid commit-slot sample: resume ~107.
Each stage is there for a HW-proven reason (registered set = the late-
INC straddle; q1 shape = the six antic_wsync bytes — tools/wsyncrtl.py).
rel_adj can't move (vcount pins the release RELATIVE to the raster).
The fix must shave the RISE path only: candidates = shape_sel 110
(latch|q1: rise immediate, fall 1 behind — runtime-sweepable, model it
in wsyncrtl.py first against all six wsync bytes), or moving the fid
rdy sample earlier in the subcycle window.  Sweep shape_sel on HW
(cfg knob, NO rebuild) with antic_wsync+vcount as anchors, then chase
the remaining ticks in the CDC/sample stage.  Instruments: prog=6
(blockednmi), prog A (nmist+vcount chains), scan-247 tracer window.
Cluster note (dawn analysis): antic_charcontrol verifies its rendering
via P/M COLLISIONS (players parked over the playfield, collision regs
read back) — its 'chactl=$00 expected $10 got $00' failure is the
per-colour-clock P/M evaluation cluster (with gtia_hiresbug/pmoverlap/
pmresize/vdelay), NOT a CHACTL register bug.  One P/M colour-clock
engine likely moves 5-6 tests.
Stale-tb discovery: tb_hscrol_e2e + tb_antic_display fail at HEAD —
pre-walker-rework benches (never step the walker); recorded in
NextSteps, excluded from the gate.

### 0g. antic_vscroldli ROOT CAUSE (overnight 07-25→26 — DEFINITIVE, fix deferred)
Instrument: `tb_fid_raster +prog=4` — full replica of Avery's two-probe
bracket (real DL: VS mode-8 block + 1-line VS-exit blank+DLI rows at
raster 40/57; STX VSCROL write at cycle ~3 must suppress that line's
DLI, write at ~4 must not; NMIST is the witness, NMIEN=0).

Layered findings:
1. The VSCROL latch semantics (commit 39c634b: cycle-6 DLI copy /
   cycle-109 stop copy = Altirra mLatchedVScroll2/mLatchedVScroll)
   are CORRECT and measured working: the cycle-6 latch captures a
   cycle-3/4 write and misses later ones, exactly as on real silicon.
   Altirra confirms the entry-DCTR load (mRowCounter = mVSCROL on
   block entry) uses the LIVE register — ours does too.  KEEP THIS.
2. But the probes still fail because the VS-exit BLANK row's DLI never
   fires at the right line: appended blank+DLI entries deliver their
   DLI via a PARSE-TIME phantom raster row (lead + scan_total + sc - 1)
   which assumes STATIC row heights.  Vertical scrolling shortens the
   VS-exit row dynamically (8 lines -> 1 with VSCROL=0), so the phantom
   fires at raster 47/71 instead of 40/57.
3. Walker delivery (drop the `cur_mode != 0` exclusion in dli_at, no
   phantom for appended blanks) was tried and REVERTED: the walker runs
   24 ROWS EARLY relative to true raster — the parser skips the
   standard blank lead (LEAD_OVERSCAN=24) and the walker serves entry 0
   at ar_atari_row 0 (raster 8, measured in-sim), with output framing
   hiding the uniform shift on HDMI.  Walker-timed blank DLIs therefore
   fire 24 lines early (regressed the nmist probe from $9F to $1F).
4. The test fundamentally requires RASTER-TIME COINCIDENCE: the CPU
   write at cycle 3/4 of raster line 40 must interact with the row-end
   decision made ON that raster line.  A walker skewed -24 rows decided
   that row 24 lines ago; a scheduled/dynamic phantom (walker row +
   lead) gets the LINE right but freezes the decision a frame-slice too
   early.  No small patch closes this.
THE FIX (daylight, architectural): run the walker lead-aligned (idle
through lead_skipped rows so walker row == true raster row) and move
the output-window base to compensate, OR drive DLI/NMI timing from a
raster-true row sequencer (antic_seq).  Either needs HW visual
verification of the XL plane calibration — not an unattended change.
All sims for the committed state re-verified green after the revert.

### 0f. dlitiming NMI-recognition matrix (overnight 07-25→26 — DEFINITIVE)
Measured with `tb_fid_raster +prog=N` (PC-recording NMI handler; the
pushed PCL is the verdict).  Real-NMOS expected values: delayed-odd
$32, delayed-even $32, plain-odd $2C.  Three recognition/pulse configs
measured end-to-end through the real ANTIC pulse + 2-FF CDC + fid
commit pipeline:

| config                              | plain | dly-even | dly-odd |
|-------------------------------------|-------|----------|---------|
| A: 2-stage rec, pulse @8 (build 42) | $2C ✓ | ✓ (HW)   | $31 −1  |
| B: 3-stage rec, pulse @8 (build 43) | $2D +1| $32 ✓    | $32 ✓   |
| C: 2-stage rec, MiSTer dual-tick    | $2C ✓ | $32 ✓    | $31 −1  |

Config C = cycle-7 pulse leg gated by one-tick-delayed NMIEN, plus a
cycle-8 leg gated by live NMIEN for the just-armed case (NMIEN write
completing at cycle 6 only reaches nmien_q ~cycle 7 via the snoop CDC,
so the c7 leg alone never fires for the delayed progs).  Reverted —
no better than A for the suite verdict (ACID asserts in order and
delayed-odd precedes delayed-even).

WHY NO UNIFORM PIPELINE CAN PASS ALL THREE: the real NMOS rule polls
interrupts at each instruction's PENULTIMATE cycle.  Whether the /NMI
edge lands on the final vs penultimate cycle of the instruction in
flight decides hijack-now vs one-more-instruction — that's exactly the
odd/even sled parity, and a fixed-depth pipeline (2- or 3-stage) sees
the same edge age in both cases.  THE REAL FIX (specified, not built):
in xt6502f, freeze the recognition capture during each instruction's
FINAL commit (the commit whose next state is ST_FETCH), so the value
consulted at the fetch reflects the penultimate-commit sample.  Needs
a clean "last commit" marker in the state machine (SYNC is the fetch
itself — one too late; derive will-enter-ST_FETCH or tag the ~40
`state <= ST_FETCH` sites).  IRQ side has the same structure
(pokey_inittiming odd-sled) — one mechanism fixes both, but IRQ
timing is calibrated against 2-stage, so rebalance STIMER lag in the
same pass.  Measured constants to reuse: /NMI pend rises at cycle 9
for a cycle-8 pulse start (1-cycle delivery latency); NMIEN snoop
write latency ≈1 cycle.

### 0e. WSYNC/NMIST calibration dossier (2026-07-25 evening — READ FIRST)
**INSTRUMENT LANDED (late evening):** `make -C sim fid_raster`
(tb_fid_raster.sv) — fid core + antic_top + sally_mem at real 3:4
pacing executing the exact nmist chain, per-commit (PC, IR, scanline,
cycle) trace.  FIRST RESULT: WSYNC write completes at 38/14; the core
resumes with PHA at CYCLE 107 (real ~103-104).  The +3 is in the
release-to-resume path (release tick @104 -> antic_rdy_n -> clk_sally
CDC -> q1 mid-retime -> fid commit-slot sampling).  Tune there with
seconds-long sim runs; add vcount/wsync chains to the same tb as
sim-side anchors BEFORE any rebuild.  (tb_boot runs the TURBO core —
no other sim exercises fid-vs-raster timing.)

Build 41c (3cfb686 + AltSpreadLogic_high) is on the board: steal-gate +
status-tick-6, ALL anchors green, dlitiming back to delayed-odd-only.
Probe data (DBG_TB mode 2, NMIST reads with raster positions):
 * build 38: the nmist cycle-critical read (Avery: scanline 39 data cycle
   5) measured at cycle 8; post-WSYNC-immediate reads (Avery ~108) exact.
 * build 41c (fill-steal gated): same read at cycle 7 (+2 residual).
Runtime release-offset matrix (cfg[23:20], NO rebuild needed):
 * adj 0 (release 104): vcount PASS (pins the release), nmist "too early"
 * adj -1/-2: vcount FAIL, nmist flips to "too LATE (>cycle 6)"
 * adj +1: vcount FAIL
So: release=104 is confirmed; the nmist chain (sta wsync -> pha:pla ->
lda abs -> nop -> lda nmist, crossing the line boundary) lands +2 late
while the vcount chain is exact — chain-dependent, not a global offset.
PHA/PLA state counts verified nominal (3/4 cycles).  wsync_gen already
models the one-cycle post-write delay slot (both edges, header essay).
REMAINING QUESTION: where the +2 accumulates in that specific chain —
candidates: stall-entry vs delay-slot interaction when the write lands
early in the line, the fid commit-slot sampling of the retimed /RDY
edges, or the status-bit visibility (ours registers at tick 6 -> visible
7; MiSTer sets combinationally from the cycle-6 slot — see the MiSTer
dossier below).  NEXT SESSION'S TOOL: a co-sim tb driving antic_top +
xt6502f executing Avery's exact chain, printing (instruction, raster
cycle) per cycle — the bookkeeping is beyond blind analysis.
MiSTer findings (behavioral reference, non-commercial licence — never
copy): NMIST DLI flag set from the hcount slot = latter half of cycle 6
(combinational into NMIST); /NMI = separate 2-cycle registered pulse
(cycles 7-8); WSYNC "write takes 1.5 cycles to assert rdy" (one cycle
runs post-write); release such that first executed cycle is 105; VCOUNT
increments at the cycle-111 boundary; CPU-enable one fast-clock late vs
ANTIC's; NMI recognized via a ~2-cycle pipeline with the
no-poll-on-branch-taken quirk modeled.


### 0-day. Display-shadow split (afternoon, commit 7850d08, HW-validated)
The compositor now reads a dedicated 64 KB display_shadow BRAM copy
(write-mirrored from sally_mem's SINGLE write site — cpu_w + rom_we;
the RAMB port clocks are the CDC).  dl_parser keeps sally_mem's dma
port; **bram_shim is out of the datapath** (mem_read_muxes in plain-BRAM
snoop mode, sh_ready=1).  Timing: compositor route pressure dropped
~2 ns, closure went 7 spins -> 1 spin, all 29 greens hold on HW.
BRAM: 106.5/140 tiles (76%).  The compositor's private port is the
groundwork for the live-DMACTL cluster (per-scanline DL fetch).

### 0a. pia_irq GREEN — full 6821 CA2/CB2 model (`hdl/pia_regs.sv`)
Pending-transition semantics derived from all 17 of the test's own vectors
(paper-verified, then `sim/tb_pia_irq.sv` replays them): a control write whose
implied line transition matches the edge select being written ARMS a pending
bit; a high->low fall KILLS it; input-mode entry CONVERTS it (or a matching
entry edge) into the visible flag; input->output entry clears the flag; data-
register read clears. PIA /IRQ (flag && CR[3], input mode) is wired into the
IRQ tree (`antic_top.sv` irq_n_combined). Commit `8cac0f0`.

### 0b. THE LIVE ROW WALKER — dl_parser rearchitecture (`hdl/dl_parser.sv`)
Parse-ahead row expansion is GONE. Now: parse (per VBI) appends one ENTRY per
DL line {mode, dli, vs, hs, lms, height} into a ping-pong BRAM; a WALKER flips
through entries in raster lockstep, comparing the 4-bit DCTR against the LIVE
VSCROL each scanline (E = last-of-block ? VSCROL : height-1, S latched at line
start = first-of-block ? VSCROL : 0). Mid-frame VSCROL writes move region
boundaries exactly like real ANTIC — antic_vscroll tests 1-4 (mid-frame DLI-
driven VSCROL rewrites incl. over-scroll) now pass on HW.
 * DLI semantics: mode lines fire LIVE on the flagged line's LAST scanline
   (real ANTIC; the old next-line-first-row convention is gone). Blank-line
   DLIs fire at TRUE PHYSICAL raster rows via a parse-computed phantom list
   (PH_N=24; skipped-lead blanks in S_SKIP, emitted blanks in S_APPEND).
 * Frame budget: the parse STOPS at 240 scanlines leaving the DL PC mid-list
   -> next frame continues (real vblank-halt semantics). The straddling
   line's VS bit carries over via act_carry_vs (parse-published).
 * antic_addresswrap flipped GREEN (1K DL-PC wrap + 4K LMS wrap per entry).
 * antic_pfstarttiming: DLIs now FIRE; it fails later at the mid-scanline
   DMACTL response ("stride=20") — the known deferred feature.
 * mem_req protocol trap (cost hours): the parser must pulse mem_req one
   cycle AFTER the FETCH state (settled address), or the read adapter
   latches the previous address and every DL byte decodes one behind.
 * Timing closure took 7 spins: entry list forced to BRAM (ram_style),
   phantom-CE moved off raw mem_rdata (S_SKIP state), and
   PLACE_DIRECTIVE=AltSpreadLogic_medium (ExtraTimingOpt is deterministic
   and kept reproducing -0.056 on the TURBO core's BRAM->P flags cone; that
   cone is the turbo core's PAUSED fmax work, not new logic).

### 0c. OPEN after the walker (next session's first targets)
 1. **antic_nmist — 2026-07-25 afternoon triage CONCLUSION**: after a full
    day of fetch-stream captures (DBG_TB mode 7 circular + freeze windows),
    the earlier "zero cycle-8 dli_at" and "zero-crawl" observations were
    POST-RESTORE red herrings: tests call _testRestore at the end, so any
    capture after ~1s shows the framework screen DL (and later a crawl
    through zeroed RAM once test text scribbles over the framework list —
    cosmetic).  The surviving coherent explanation for the failing assert:
    the probe DL IS live, phantoms {31,39} fire their status at scanline
    39 cycle 7, and the CPU's `lda nmist` — which Avery's cycle math puts
    at cycle 5 — actually lands at raster cycle ~7-8 on our machine: the
    CPU-execution-to-raster phase LAGS ~2 cycles.  The read catches the
    freshly-set bit -> "DLI bit set too early".  This is the SAME class as
    antic_dlitiming's delayed-odd ($0E vs $0F) and pokey_inittiming's odd
    sled ($1E): one CPU-vs-raster phase calibration, three tests.
    OPEN QUESTION: why build 34 (pre-walker) passed nmist — possibly a
    vacuous pass off the framework banner DLIs (every pre-"<cycle 6"
    assert can pass without the probe DL; verified by reading the test).
    NEXT: build a dedicated phase-calibration measurement (streaming
    trace of WSYNC-release -> hwreg-read arrival in raster cycle terms),
    and consult the MiSTer core (semantics only, GPL) for its
    WSYNC-release/NMIST-set alignment.  Do NOT chase dli_at placement —
    it is sim-proven and phantom rows are correct.
    PROBE TRAPS (hard-won): xexload must run FOREGROUND in board scripts
    (backgrounding kills the toysh session); `6502` control writes are
    fine; captures are only meaningful in the first ~1s or via the
    address-filtered modes; the incremental-flow bitstream (build 40)
    passed timing but broke `6502 break/go` — verify the debugger after
    any incremental deploy, and prefer full builds for deploys.
 2. **antic_vscroll GREEN** (build 37): act_carry_vs fixed the
    frame-straddle case — all 5 sub-tests pass on HW.
 2b. **antic_dlistwrap** is NOT a simple DLI-carry: test #2 kills DL DMA
    MID-FRAME (DMACTL=0 at scanline 14) and expects the LATCHED DL
    instruction (with its DLI bit) to persist and re-fire after the
    vblank once NMIEN comes on.  That's the live-DMACTL response family
    (ANTIC IR-latch semantics), same cluster as pfstart/pfstop's
    stride tests — the parser currently ignores DMACTL entirely.  Test
    #3 additionally checks NMIRES doesn't clear a pending DLI.
 3. **antic_dlitiming delayed-odd**: back at the known $0E != $0F. A 3-stage
    NMI poll was tried and REVERTED ($F5 = NMI far late; and the build-35
    "Even $09" that motivated it was actually the marginal phantom-CE
    timing path). The real fix is per-instruction poll granularity
    (penultimate-cycle rule) WITHOUT adding a uniform stage — needs the
    poll latch captured once per instruction, not per cycle.
    pokey_inittiming's odd-sled ($1E, unchanged by REL_SKEW 2->3) is the
    SAME granularity class on the IRQ side.
 4. **pokey_inittiming even sled FIXED** by phi2-paced init-release ref
    dividers + REL_SKEW=3 (`hdl/pokey_audio.sv`) — keep.

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
