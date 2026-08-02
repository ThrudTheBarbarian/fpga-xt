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
* **Interrupt timing: passes**, from ACID800 `cpu_clisei`'s three scenarios, NMI
  edge/one-shot, and the **NMI/BRK hijack boundary** swept cycle by cycle.
  Harte ties the interrupt lines inactive, so this is ground it cannot cover.
* **POKEY RANDOM LFSR: passes.** Not a sound model — the ANTIC timing tests use
  `RANDOM` as a one-cycle-resolution clock, so this is their prerequisite.
* **ANTIC DMA schedule: 50/50** against the table ACID800's `antic_dmapattern`
  carries as data — every mode 2–15 at narrow and normal width, on a row's first
  scanline and its later ones. Note what that table does NOT cover: it has no
  WIDE rows at all, so wide geometry is pinned solely by `antic_virtdma`.
* Timing core, display-list execution and the line buffer are in; **GTIA
  collisions** in.
* **The real ACID800 binaries run**: `make acid` → **48 pass** / 6 fail / 3
  jammed / 2 looping / 4 skipped, of 63, against **32** for the fabric at
  `sallyrst $06`. Recorded on the conformance dashboard beside the fabric sweeps
  — `python3 docs/a800/from-emu.py --note "..."`. **Every `cpu_*` test passes.**
  Five of the non-passing are `mod_*` modules that print "Press a key..." and
  spin: their assertion is a pair of human eyes and they can never go green
  headlessly. They are left COUNTED rather than reclassified, because excluding
  them would move the score without anything working.
* **Cost: `make bench` → 808 frames/s, 13.5x realtime, 41 ns per machine
  cycle**, on a deliberately expensive workload (mode 2 with playfield DMA, P/M
  DMA and four missiles). Projected onto one A9 at the measured 6–7.5x
  host:A9 ratio that is 108–135 fps, or 1.8–2.2x realtime — it fits. The A9
  figure is a projection, not a run there, and excludes POKEY audio rendering
  and video scan-out.

* **It cross-compiles for the A9.** The Makefile carried "the same sources are
  meant to cross-compile for the A9 later, so nothing here may depend on the
  host being 64-bit or little-endian" for a long time without anyone testing it.
  `make arm` is now that test and runs as part of `make test`: the eight core
  files build for a Cortex-A9 under `-Wconversion -Werror`, warning-free, in
  43.5 KB of ARM text. Two real warnings had to be fixed to get there — four
  flag clears where `~FLAG` promoted to `int`, and an `(uint8_t)~irqst == 0`
  that is correct but reads as a bug and warns on gcc.

## How to read this file

It is a **notebook in chronological order**, not a specification. Sections are
appended as work happens, so a later section may supersede an earlier one, and
the headings carry the verdict:

* **SOLVED / CLOSED / Resolved** — established, with the test that establishes it.
* **Open / PARKED** — still unknown; PARKED means the cheap avenues are
  exhausted and what has been ruled out is written down.
* **SUPERSEDED** — kept because the reasoning or the disproof is still worth
  reading, but a later section has the current answer.
* **Disproved** — a hypothesis that was tested and failed. These are as valuable
  as the confirmed ones: most of them look right, and several cost an iteration
  each to kill.

The rules distilled from all of it live in the loop prompt rather than here;
what this file holds is the evidence.

### CLOSED: antic_wsync's absolute cycle alignment

`d0..d5` reads `95 D1 D1 D0 E2 34` against the wanted `95 4B 0D 44 E2 34` — d0,
d4 and d5 correct. The remaining three are all WSYNC-duration measurements and
share one cause: **our instruction stream sits about three scanline cycles ahead
of where the test's annotations put it.** The bus trace shows `sta wsync`
writing `$D40A` on scanline cycle 113, while the source annotates that store as
occupying `113, 0, 1, 2` — i.e. the write belongs on cycle 2 of the next line.
`tools/pokey-random-decode.py` puts d1 eleven machine cycles early.

Ruled out by measurement, so do not re-test these: the POKEY tick ordering
around the CPU access (a uniform phase shift cannot change an elapsed count);
the WSYNC *release* cycle (104 vs 105 — byte-identical output either way); and
the LFSR model, which reproduces all four of its hardware-pinned constants.

The live question is what sets the stream's ABSOLUTE alignment to the scanline
— which cycle of a multi-cycle instruction the emulator attributes a device
access to, and where the CPU resumes after a halt. Harte pins the bus *trace*
(the order of accesses) but not their placement against an external clock, so
this is genuinely outside what the strongest existing gate can catch.

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

## Disproved: "DMA must not stall write cycles"

SALLY ignores /HALT on write cycles — that is real, documented, and the reason a
read-modify-write's three write cycles survive DMA. It is tempting as an
explanation for the remaining derails, because **every one of them lands in the
stack page or zero page** ($01F6, $01F8, $00E1, $0014), which is exactly what
corrupted pushes look like.

It is not the cause. Making `bus_wr` advance ANTIC exactly one cycle instead of
looping until ANTIC yields:

* left every jam in place — `cpu_illtiming` still died at the same address, with
  its cycle count moving only 38231 -> 38229;
* **broke `cpu_timing`**, which is the suite's direct authority on CPU cycle
  timing under DMA.

So the current model (a halted CPU is simply a callback that takes longer, on
reads and writes alike) is the one `cpu_timing` agrees with. Do not re-try this
without first explaining how `cpu_timing` can still pass.

The stack-page derails therefore remain unexplained and are still worth chasing —
just not from this direction.

## SUPERSEDED — the next structural gap: nothing renders pixels

`gtia.c` is complete enough to be unit-gated — collisions come off the emitted
pixel stream one colour clock at a time, and `gtia_clock(g, hpos, pf,
hires_lit)` is the entry point. **But `system.c` never calls it.** GTIA is wired
for register reads and writes only, so in a full-system run no object is ever
shifted out and no collision can ever register.

That single gap is what several failures actually reduce to:

* `antic_pmdma` verifies player DMA by reading `P0PF` — a *collision* register.
  The P/M DMA that feeds it now works, and the test still reads `$00`, because
  nothing collides.
* `antic_virtdma`, `antic_linebuffering` and `antic_charcontrol` all read back
  what was displayed rather than what was fetched.
* The whole of the GTIA object-rendering work (VDELAY's two-line extent, mode 10
  shifted one colour clock, player/player overlap colour) is unobservable from
  the suite until the stream exists.

Closing it needs one thing ANTIC does not yet have: a **pixel decode**.
`line_start` fetches playfield bytes into `linebuf`, but nothing turns those
bytes into a playfield colour class per colour clock. That means, per mode:
the character-set fetch through `CHBASE` for the character modes, the
bit-unpacking for the bitmap modes, and placement against the playfield window
(narrow/normal/wide) and `HSCROL`. `antic_dma.c` already derives that window —
`pf_nominal(w, hscrol)` — so the geometry is settled; it is the decode itself
that is missing.

Suggested order: playfield decode for the bitmap modes first (no CHBASE
dependency), wire `gtia_clock` into the scanline loop, confirm a collision
registers at all, then add the character modes.

## Resolved: re-anchoring, and VSCROL as a row-counter compare

The tension recorded below turned out to be two separate corrections, both of
which the code was missing, and `antic_vscroldli` was **passing by accident**
before either of them.

**The display list is only FETCHED from scanline 8 onward.** A row already in
progress still runs, which is what carries a list past the bottom of the frame,
but a list waiting for its next instruction waits for the top of the display.
Proof that this is right rather than merely convenient: `antic_vscroldli`'s own
display list is annotated with the scanline each instruction should land on
(`8, 16, 24, 32, 40`), and only the gated version produces those. Ungated, the
list started at scanline **253** and every row was eight lines early — the test
passed anyway, on a misaligned display.

**VSCROL is a row-counter trick, not a height adjustment.** Entering a scrolled
region the counter STARTS at VSCROL, so the first row is short by that much;
leaving one, the next row starts at 0 and ends when the counter reaches VSCROL,
compared LIVE every scanline. The blank-line instruction takes part — the `$f0`
after the scrolled mode 8 row is what `antic_vscroldli` actually measures. The
comparison is sampled once, at cycle 4, and the DLI's own row-end test reads
that same sample rather than re-reading at NMIST time on cycle 6.

Together these cost `antic_vscroldli` and gain `antic_dlistwrap` outright —
including its second test, the "DLI carried over around VBLANK" case that had no
explanation at all before. `antic_linebuffering` advances from its baseline to
its second scenario.

`antic_vscroldli` now fails for a reason worth naming: its two probes are one
cycle apart and both are anchored to a `sta wsync` release, so it is blocked by
the same absolute-alignment question as `antic_nmist` — moving the VSCROL sample
one cycle satisfies whichever probe the other then breaks. It belongs with the
PARKED group until that is settled.

## Original note: re-anchoring the display list to scanline 8

`antic_linebuffering` fails its very first readout, and the cause is not the
pixel decode — the geometry is provably right. Its `framedata` byte 5 is `$E4`,
i.e. the 2-bit pairs `11,10,01,00`, and it lands exactly on the four missiles at
`$44..$47`, which is what the test wants to read back as PF2, PF1, PF0,
background.

The problem is WHICH display-list instruction is running there. The test does
`_screenOff` (DMACTL = 0), then `_waitVBL`, then writes DLISTL/H and DMACTL.
**`_waitVBL` returns at scanline 248**, so the list resumes fetching right there
instead of at the top of the next display, and every row lands eight scanlines
early — scanline 32 shows a blank-line instruction instead of the mode E row.

The obvious fix is to fetch instructions only inside the display region. It
works: the baseline readout passes and the test moves on to its second scenario
(`aliased mode 8`). **But it costs `antic_vscroldli`** — net 16 against 17 — and
the reason is not yet understood, because that test's list ends in a JVB, parks,
and is released at scanline 8 anyway, so the bottom cutoff should never come
into play for it.

Tried and measured:

| gate on the instruction fetch | score | linebuffering baseline |
|---|---|---|
| none (current) | 17 | fails, reads `04 04 04 04` |
| `scanline < 8` only | 17 | fails, reads `00 00 00 00` |
| `scanline < 8 \|\| scanline >= 248` | 16 | **passes**, fails at scenario 2 |

So the rule is nearly right and something about the bottom edge is wrong. Worth
resolving from `antic_vscroldli`'s side first — find out why a list that parks on
a JVB cares about the cutoff at all — rather than by tuning the window.

## SUPERSEDED — gtia_pmresize, and a third WSYNC-anchored test

`gtia_pmresize` sets player 0 at HPOS `$48` with GRAFP0 = `$aa`, narrows SIZEP0
mid-object, and reads back which of eight probes — players at `$61..$63`,
missiles at `$64..$67` — the object reached. At 4x an eight-bit player spans
exactly `$48..$67`, so the probes sit at the far end and report where the resize
truncated it.

The first case expects `$80`: **only** the probe at `$61` is hit. That is the
sharp constraint — a 4x bit covers four colour clocks, so any 4x bit reaching
`$61` would also cover `$62` and `$63` and light three probes. One probe alone
means the object is emitting at 1x granularity by the time it gets there, i.e.
it is still running at `$61`. This model ends it around `$5f` and reports `$00`.

Tried and rejected: making the phase counter two bits with an EQUALITY compare,
so that narrowing the width while the counter has already passed the new target
makes it miss and wrap — the same shape as the ANTIC row-counter fix, and the
obvious candidate for the "lockup" the test names in its `1xalt` case. It
changes nothing here (still `$00`) and is not kept, since there is no evidence
for it either way.

Worth noting before spending more on it: `runtest` opens with `inc wsync` and
every cycle annotation in it flows from that release, so this is a **third**
test anchored to the parked absolute-alignment question, alongside `antic_wsync`,
`antic_nmist` and `antic_vscroldli`. The discrepancy here is larger than one
cycle, so alignment is probably not the whole story — but it should be settled
before the divider is tuned to fit.

## SUPERSEDED — Blocked on an OS ROM: antic_virtdma

`antic_virtdma` displays a mode 7 screen and reads back where the playfield
reaches by colliding four missiles parked at the right border (`$da`..`$dd`).
It cannot register anything here, and the reason is environmental rather than a
modelling error:

* its `framebuf` is 48 bytes of `$00` and is never written, so every character
  cell holds character 0;
* it never sets `CHBASE`. On a booted machine the OS leaves it pointing at the
  ROM character set; under the bare-XEX runner it is `$00`, so the "glyphs" are
  read out of zero page and every one of them is blank.

With no lit playfield pixel anywhere on the line, no missile can collide, so all
four patterns read `$00` — which is why pattern #1 (expected `$00`) "passes" and
#2 (expected `$05`) does not. Confirmed by tracing the glyph fetch: `chbase $00`,
`name $00`, `glyph $00` on every scanline of the row.

Filling `$f800` with `$ff` changes nothing, because CHBASE is not `$f8` — the
`mva #$f8 chbase` in the library sits in a path this test never calls.

So this one needs either an OS ROM image or a runner that initialises CHBASE the
way a booted OS would. It is not a defect in the ANTIC model, and it should not
be counted against the pixel decode. Note the same trap applies to any other
character-mode test that does not set CHBASE itself — `antic_charcontrol` passes
precisely because it supplies its own character set at `$2c00`.

## SUPERSEDED — the WSYNC release is cycle 103 (it is 104)

This was claimed twice in this file before it was right — first that the release
was "two cycles late", then that 105 was correct. The sequence is worth keeping,
because the first two readings were UNMEASURABLE for a reason rather than merely
mistaken.

**The instrument lied once.** The probe printed `an.cycle` after `antic_tick`
had already incremented it, so a write reported on 109 actually committed on 108.

**The model was missing memory refresh.** Refresh takes nine cycles of every
scanline whatever DMACTL says — even with the screen off, where no other DMA
does. Building the schedule only along the playfield path let the CPU run nine
cycles a line too fast whenever DMA was off. That is exactly the gap
`gtia_pmretrigger`'s fourth case showed: it calls `_screenOff`, then `delay82`,
and its `sta hposp0` landed on cycle 81 against an annotated 90. `delay82` really
is 82 CPU cycles; the missing nine were refresh. Fixing it also made
`cpu_illtiming` pass outright — a test that runs each illegal opcode 210 times
specifically *with* DMA and refresh present, and one of the four real jams.

**Only then could the release be measured.** Before the refresh fix, moving the
release broke `gtia_pmretrigger`'s second case, which made 105 look right. With
refresh present, sweeping 103/104/105 scores 24/23/23, and 103 is what two tests
annotate directly: `antic_nmist`'s seven-cycle `pha:pla` spanning 104..109 puts
its unnumbered first cycle at 103, and `antic_vscroldli` — parked until now —
passes only at that value.

`gtia_pmretrigger`'s own `sta hitclr` annotation reads as 104, but it is one slot
short for a four-cycle STA, so it is the odd one out rather than the arbiter.

Still open on this axis: `antic_wsync` itself, `antic_nmist` ("VBI bit was reset
too early"), `gtia_pmretrigger` #2 and `gtia_pmresize`.

## CLOSED: the WSYNC axis, and what actually finished it

All three tests parked on this question now pass — `antic_vscroldli`,
`antic_nmist` and `antic_wsync` itself. Four separate things were missing, and
no sweep of the release cycle alone could ever have found them:

1. **Memory refresh** takes nine cycles of every scanline whatever DMACTL says.
   Without it the CPU ran nine cycles a line too fast with the screen off, which
   is what made the release look unmeasurable — moving it broke other cases.
2. **The release is cycle 103**, the first cycle the CPU gets back.
3. **/RDY does not stop write cycles.** WSYNC pulls /RDY; ANTIC's /HALT for DMA
   is a different signal and does stop them. Modelling both the same way made an
   `INC WSYNC` re-arm on its second write — that write landed after the release,
   found the halt clear, and cost a whole extra scanline. This is NOT the
   disproved "DMA must not stall writes" change, which broke `cpu_timing` and is
   still wrong.
4. **A WSYNC write arriving while the halt is already armed delays the release
   by one cycle** rather than re-arming. That is exactly the difference between
   the suite's own annotations: after `sta wsync` the next instruction starts at
   104, after `inc wsync` it starts at 105.

The technique that made the last two findable: `antic_wsync` reads POKEY's
RANDOM at 113, 227 and 342 cycles after the SKCTL release, so **a wrong value
names the exact cycle error**. Decoding the LFSR backwards turned "d2 is wrong"
into "d2 is 455, i.e. one scanline late" and then "d2 is 341, i.e. one cycle
early". Two hypotheses, two measurements, no sweeping.

Also settled alongside: a NMIRES landing in the same cycle as a status set loses
to it, while a NMIEN write in that same cycle wins.

## CLOSED: antic_dmapattern measures the DMA pattern LIVE

`make dma` matches ACID's own DMA table 50/50, so the tabulated pattern was
never in doubt. This test measures the pattern **live**, by reading RANDOM
either side of a DMA burst, so it checks something the table cannot: when each
cycle is actually taken, not merely which ones. It reported **"Incorrect timing
for mode 2-a"** — read off d1 = $02 and d2 = $61 = 'a', since the message string
the runner prints for this one is garbage (the failure arrives through a path
with no inline text).

It fell out with the WSYNC release, and needed no DMA change at all: the burst
was in the right place, the CPU reading it was one cycle early. See "CLOSED: the
recurring ONE CYCLE early".

## SUPERSEDED — POKEY divider phase: the free-running tap is the wrong SHAPE

`pokey_inittiming` sets AUDF1 = 0 and measures how long after the SKCTL write
that leaves init the first timer-1 interrupt arrives. Its own comments give the
answer twice:

* 15 kHz clock — **86 to 87 machine cycles**, accepted as $1f or $20;
* 64 kHz clock — **83 to 84**, accepted as $1e.

**Three cycles apart, from clocks whose periods differ by 86.** So the delay is
not a period. It is however far a FREE-RUNNING divider happened to be from its
next tick, which the test makes reproducible by syncing with two WSYNCs first.

That much is now modelled: STIMER reloads the four channel counters but does not
touch the base divider, which is a tap off the machine-cycle count. The
`ptimer` gate measures the INTERVAL between consecutive interrupts rather than
the delay to the first, because for a free-running divider only the spacing is a
property of the configuration.

**But a single phase constant cannot make the test pass.** Sweeping
`POKEY_BASE_PHASE` across the whole 0..112 range fails at every value, and the
reported count does not even vary monotonically with it (38 -> 33, 40 -> 45,
42 -> 44, 44 -> 30). So the remaining error is structural, not a calibration:
something about how the two base clocks relate, or about IRQ latency, is wrong.
Do not tune the constant — it has been swept exhaustively and no value works.

Worth trying next: the 64 kHz and 15 kHz clocks are probably not independent
divisions of the master clock but taps off ONE chain, in which case their phases
are locked to each other in a way two separate moduli cannot express. The three
cycle difference between the two measured delays is the thing to reproduce.

`pokey_irqtiming` ("Incorrect IRQEN delay count") is likely the same question
from the interrupt-latency side, and `pokey_timertiming` may be too.

## CLOSED: the recurring ONE CYCLE early — the release is 104, not 103

Three tests failed the same way:

* `antic_vcount` d2 — `sta wsync / bit $0100 / lda vcount`, annotated so the read
  lands on cycle 111. It landed on 110.
* `gtia_pmretrigger` #2 — its `sta hposp0` landed on CPU cycle 28 where the
  annotation says 29, so the player missed its trigger at $40.
* `antic_dlitiming`'s "Even count".

It was the release after all — but no sweep could show that, because a bare
sweep scores the whole suite while every other landmark stays pinned at values
that were themselves calibrated against 103. Moving the release alone breaks
`antic_nmist` and `antic_vscroldli`, which is what a sweep sees; moving the
landmarks WITH it does not.

`antic_vcount` settles it alone, from an inequality on both sides. Its four
part-1 measurements differ only in how many cycles they burn after the WSYNC,
and `lda abs` reads on its fourth cycle:

| vars | preamble | the read lands on |
|---|---|---|
| `d0`, `d1` | `bit $00` (3 cycles) | WSYNC + 6 |
| `d2`, `d3` | `bit $0100` (4 cycles) | WSYNC + 7 |

`d0`/`d1` must see the OLD VCOUNT and `d2`/`d3` the NEW one, so
`WSYNC+6 < 111 <= WSYNC+7`. That admits exactly one value: **the release is
104**. At 103 the second pair reads at 110 and sees the old value — the "one
cycle early".

Everything else here was calibrated by reading it THROUGH the CPU, so all of it
moves with the release:

* `ANTIC_CYC_NMIST` 6 -> **7** (and NMIRES 7 -> 8) — `antic_nmist` fails with
  *"DLI bit set too early"* at 6 once the CPU is a cycle later, and passes at 7.
* `ANTIC_CYC_ROWEND` 4 -> **5** — `antic_vscroldli` fails with *"VSCROL took
  effect too late"* at 4, passes at 5.
* `ANTIC_CYC_VCOUNT` stays **111**: it is what the inequality above solves for,
  not something read through the CPU.

That retune took `antic_vcount` part 1, `antic_dmapattern`, `antic_nmist` and
`antic_vscroldli` together, 37 -> 38.

`antic_vcount` part 2 — "the nasty one, single cycle rollover" — then needed one
more thing, and the name is meant literally. Its two rollover probes sit on the
**same scanline** and differ only in the read cycle: 111 must read 131, and 112
must read **0**. So the 9-bit counter is not cleared by the line wrap at all; a
comparator clears it ONE CYCLE after the advance, and VCOUNT reads its maximum
for exactly one cycle per frame. 38 -> 39.

The suite's own inline annotations are NOT a usable cross-check and cost real
time here: `antic_nmist`'s seven-cycle `pha:pla` spanning `*, 104..109` reads as
a release at 103, while `antic_vcount`'s four-cycle `bit $0100` spanning
`*, 105, 106, 107` reads as 104. They cannot both be right. Trust the
assertions, not the comments.

Independent corroboration: the FABRIC path converged on the same two numbers
from its own hardware runs — see `vivado/archive/known-good-2f81408-wsync104.bit`
and `build52d-tm-rollover-nmist7.bit`.

## Resolved: pokey_sertiming, and how the divider phase was actually measured

`pokey_sertiming` passes. The chain of mistakes is worth keeping, because each
correction came from measuring rather than reasoning:

1. I recorded twice that its two blocks differ structurally — one delaying 195
   cycles, the other "no delay" — and hypothesised STIMER. Wrong: block B has
   `_DELAY_CYCLES_X 196`. **Re-read the delay macros.** It is an ordinary
   one-cycle boundary.
2. That reframed it as "the serial take happens 196 cycles after the SEROUT
   write", so I looked for a divider phase giving 196. Also wrong, and the
   reason is the interesting part: **195 CPU cycles is not 195 machine cycles.**
   Instrumented directly, the delay spans **217** machine cycles once memory
   refresh is counted, and 196 spans 218.
3. So the divider needs **218** left at the SEROUT write, not 196. Three
   candidate behaviours were measured:

   | SKCTL release behaviour | cnt0 at the write | result |
   |---|---|---|
   | reload to a full period | 224 | no tick in either block |
   | reload to period - 28 | 196 | tick in both blocks |
   | **free-running, no reload** | **218** | **217 no tick, 218 tick** |

   The chain free-runs through the release, and the take is tick-driven.

The lesson that generalises: when a test's delay is quoted in CPU cycles, convert
it by measuring, not by counting instructions — DMA and refresh make the two
differ by roughly 11% here, which is far more than the one-cycle boundary being
probed.

The 28-cycle offset that looked so promising — it is exactly one 64 kHz tick, and
`pokey_inittiming` shows the same gap — was a red herring for THIS test. It may
still be right for `pokey_inittiming`, which remains open.


## SUPERSEDED — pokey_inittiming: the 64 kHz tap LEADS the 15 kHz one by two

The two base clocks are now ONE chain: a tick for period P happens when
`chain % P == 0`, and the SKCTL release restarts the chain at 28. Both of the
test's expectations follow from that single constant —

* 64 kHz: `28 % 28 == 0`, so the next tick is a full 28 away. The test's own
  arithmetic agrees: *"84 - 28*2 = 28"* with `AUDF1 = 2`, i.e. the THIRD tick,
  84 cycles after the write.
* 15 kHz: `28 % 114 == 28`, so the next tick is `114 - 28 = 86` away, which is
  what the same test wants there.

Two independent expectations from one number, which is why this replaced the
earlier `base_period - 28` clamp even though the score did not move.

What remains is **two machine cycles** on the 64 kHz case: it reports `$1f`
where `$1e` is wanted, one NOP late. The 15 kHz case accepts `$1f` or `$20` and
passes, so the residual is only visible on the tighter assertion.

The test says where to look: *"We set the timer to run two extra cycles to clear
memory refresh, so this is actually 26-27 cycles."* So its 83-84 figure is
constructed to straddle refresh, and the two cycles are probably about WHICH
cycles refresh takes relative to the release rather than about the divider at
all. Note the same test's odd-offset variant accepts `$1d-$1e`, i.e. a
two-cycle spread, so the even case is the sharper of the pair.

## SUPERSEDED — the POKEY serial cluster needs an INPUT path

Output is largely done — `pokey_serclock`, `pokey_sertiming` and `pokey_seroc`
pass. What is left in this cluster mostly needs the RECEIVE side, which is not
modelled at all:

* `pokey_asyncrecv` — asynchronous receive mode (SKCTL bit 4) now correctly
  HOLDS timer 4, since POKEY is waiting for a start bit, and the test advances
  past that. Its next assertion checks that timers 3+4 are RESET when the start
  bit arrives, and expects the interrupt about twelve scanlines after STIMER, so
  it needs a start bit to arrive at all.
* `pokey_serdirect` and `pokey_skstat` turned out to need neither — both open by
  asking **D1: for a disk status** through the OS vector `DSKINV` ($e453) and
  SKIP themselves if it fails. With no OS ROM that call landed in unloaded RAM
  and the CPU BRK-walked the address space. The runner now answers "no device"
  at DSKINV/CIOV/SIOV, and both take the skip path they were written to take.
* `pokey_twotone` is DONE — two-tone holds timer 2 while the output line is a
  mark, which satisfied both its phases at once.

`pokey_inittiming`'s 64 kHz case remains two cycles out and is unrelated to the
input path.


## VERIFIED: the five mod_* are not standalone tests

The docs called these "non-terminating demo modules" — unverified, and wrong in
detail. Traced with `ACID_TRAPOUT`:

`mod_options` derails after **21 instructions**. Its RUN vector is `$3800`,
whose first instruction is `jsr showMenu`, which calls the library's `_imprint`
— and `_imprint` ends at `jmp (_vputchar)`, a vector the library declares as
`dta a(0)`. Nothing has initialised it, so the jump goes to `$0000` and the CPU
BRK-walks from there.

The routine that WOULD initialise it is in the same module at `$3987`: it opens
`E:` through CIOV and only then copies `ICPTL` into `_vputchar`. Nothing calls
it before `main` prints. So these files cannot run on their own on real hardware
either — they are **modules loaded by the Acid800 menu program**, which opens E:
and sets the vector before handing over, exactly as the library's
`_loadSeg`/`_runSeg` pair implies.

Seeding `ICPTL` in the runner (done — it points at a discard stub, since the
library reads that vector as address-1 and increments it) does not help on its
own, because the module never reaches the code that reads it.

They are therefore not conformance tests, and their JAM status is not a defect
in this emulator. Reporting them as skips would mean special-casing five
filenames in the runner, which is worse than leaving the count honest with the
reason recorded here.

## CLOSED: the NMI/BRK hijack boundary, and where the vector is committed

`antic_blockednmi` failed with *"VBI handler should not have executed."* It
asserts by control flow rather than by value — four handlers, three of which
call `_FAIL` if they are ever entered — so which handler runs **is** the answer.

Both halves arm a VBI and then place a `BRK` across the request, one cycle
apart:

```
half 1:  brk    ;3, 4, 5, 6, 7, 8, 9    -> must reach `irq`  ($FFFE)
half 2:  brk    ;4, 5, 6, 7, 8, 9, 10   -> must reach `nmi2` ($FFFA)
```

The request itself lands at scanline cycle **6** — `ANTIC_CYC_NMIST`, already
pinned by `antic_nmist`. A new `ACID_PCWATCH=<hex>` probe prints the scanline
and cycle at which a given PC is fetched, and confirmed our instruction stream
sits exactly where the test's own annotations say: `lda $0100` at 109, the two
`nop`s at 113 and 1, the `brk` at 3. So the request lands on **BRK cycle 4** in
half 1 and **BRK cycle 3** in half 2, and those must give opposite outcomes.

That places the commit point precisely:

> The vector is committed at the end of the sequence's **third** cycle, right
> after the PCH push. An NMI latched up to and including that cycle diverts the
> vector to `$FFFA`; one latched after it does not.

The second half of the rule is the part that is easy to miss. A late NMI is not
merely *deferred* — half 1 would still fail, because the `irq` handler does not
clear `NMIEN` until several instructions in, so a deferred NMI would be taken at
the very next instruction boundary and run the forbidden handler. It has to be
**swallowed**: the edge detector stays held reset for the rest of the sequence,
so `nmi_pend` is cleared unconditionally when the sequence ends. The poll must be
cleared with it, or `poll_prev` — sampled during the vector fetch, when the flag
was still set — hands the dead NMI straight back.

Previously `interrupt()` chose the vector *after* the status push, i.e. after
cycle 5, and never swallowed anything: every NMI hijacked. That passed half 2
and `cpu_bugs` and failed half 1. Moving the commit two cycles earlier and adding
the swallow passes all three.

`test/irq.c` now sweeps `k = 1..7`, raising `/NMI` from the bus callback during
the k'th cycle of a `BRK` — the only hook that runs once per machine cycle, so
it is the only way to place the edge inside an instruction. It checks both the
vector taken and, for the late cases, that the NMI does not come back on the
following step.


## CLOSED: /NMI follows the status bit by a cycle, and a late NMIEN costs two

`antic_dlitiming` is the sharpest instrument in the suite for this: its DLI
handler reads its own return address off the stack, so `d0` is *where the DLI
interrupted*, and the test converts that to an instruction offset from a labelled
origin. Five phasings of the instruction stream in part 1, two NMIEN-toggle cases
in part 2, one WSYNC case in part 3.

Three of the five phasings are insensitive to a one-cycle shift in the request;
the other two are not, and both said it was arriving early — `d1` got `$09` for
`$0a`, `d3` got `$0c` for `$0e`. **The status bit and the interrupt line are one
cycle apart**: NMIST lands at `ANTIC_CYC_NMIST` (7, which `antic_nmist` pins by
reading the register) and `/NMI` at `ANTIC_CYC_NMI` (8).

That is a RELATIVE constraint against the BRK hijack, so `antic_blockednmi` and
`cpu_bugs` move with it: the vector is committed after the **PCL** push, the
sequence's fourth cycle. Both still pass.

Part 2 then needed one more thing. Both its cases disable NMIEN across the DLI
point and re-enable it at scanline cycle 7 — the same cycle the status sets — and
both must deliver at the same instruction. They only do if the **write** path
takes two cycles where the status path takes one. So `/NMI` is now a countdown
rather than a fixed cycle: the status set arms it at 1, a same-cycle NMIEN write
arms it at 2, and the pulse is one cycle wide either way.

Ruled out on the way: dropping the WSYNC re-arm delay so `inc wsync` releases at
104 the way `antic_dlitiming`'s annotations say it does. That breaks `antic_wsync`
and `antic_dmapattern`, which pin the re-arm directly. The suite's annotations
disagree with each other about `inc wsync` exactly as they do about the release.

39 -> 40, and `antic_dlitiming` passes whole, part 3 included.


## CLOSED: pokey_asyncrecv wanted a RESET, not an input path

Worth recording because the obvious reading of the name was wrong: this test
never feeds POKEY a serial byte. It is entirely about what SKCTL bit 4 does to
the **timers**, and needs no SERIN, no SKSTAT input bits and no SKRES.

Its first three sub-tests only need the mode to silence timer 4, which
suppressing the underflow already did. The fourth is the real one: with 3+4
linked at 456 cycles it turns the mode on **mid-count**, off two lines later, and
then requires the next interrupt a full period after the mode ended — checking
both that it did not fire early (`skiptest_fail3`) and that it did fire by the
end (`skiptest_fail4`).

So async receive holds timers 3 **and** 4 in **reset**, not merely stopped:
POKEY is waiting for a start bit and the bit-time divider has to begin its count
from that edge. Suppressing the underflow instead leaves the counter sitting past
zero, so it fires on the very first tick after release — which is exactly the
sub-case 3 failure. 40 -> 41.


## SUPERSEDED — pokey_inittiming's two 15 kHz measurements disagree

`pokey_inittiming`'s 64 kHz cycle counts now pass. Its own arithmetic is what
gives the answer: it states 86-87 machine cycles to the first **15 kHz** tick
after the SKCTL release and, for the 64 kHz case, "84 - 28*2 = 28" with the
note that the two extra timer periods exist only "to clear memory refresh", so
the first **64 kHz** tick is at 26-27.

No single phase on one shared chain produces both — a residue that puts 15 kHz
at 86 puts 64 kHz at 28, and a residue that puts 64 kHz at 26 puts 15 kHz at 84.
So the two taps have different phases out of the release, and the 64 kHz one
**leads by two machine cycles** (`BASE_64K_LEAD`). Only a test that anchors both
to the same event can see it, which is why nothing before this measured it.

What remains open is a **one sled step (two machine cycle)** tension inside the
15 kHz side, between the test's two different measurement paths:

* the `result1`/`result2` counts go through the real IRQ sequence — `cli`, a NOP
  sled, and a handler that reads its own return address — and pass at
  `BASE_15K_LEAD` 0 or 1;
* the IRQST sub-tests poll `$D20E` directly with no interrupt at all, and need
  2 or more.

Swept 0..6: 0 and 1 fail "15KHz IRQ fired too late", 2 fails the odd count, 3+
fail the even count.

**Tried: sampling IRQST at the END of its cycle** instead of the start (`RANDOM`
must be read as of the start — `antic_wsync`'s LFSR decode pins that — but IRQST
need not follow it). It works, in the narrow sense: with `BASE_15K_LEAD = 1` and
a late IRQST sample, **the whole of `pokey_inittiming` passes**, all four groups.

It is not a win, though, because it costs `pokey_sertiming`, and the two cancel
exactly. `pokey_sertiming` is a one-cycle boundary read through the SAME
register — its 195-cycle delay must NOT see the SEROUT take and its 196-cycle
delay must — so moving the IRQST sample moves that boundary too. Net 41 either
way, and a two-parameter fit (lead AND sample phase) against one test while
breaking another is not evidence.

What this does establish: `pokey_inittiming` IS satisfiable, and the disagreement
is a single cycle in when a POKEY register read is observed relative to the
divider. The next thing to test is whether `ser_take`'s tick should move with it,
which would let both tests hold at once — but only if that has its own
justification rather than being fitted to restore the score.


## CLOSED (the DMACTL half): the window commits its start early and closes at its last grid point

All EIGHT DMACTL assertions across `antic_pfstarttiming` and `antic_pfstoptiming`
pass — character and bitmap, early and late, both polarities — from one rule.
**Check the polarity first**: `pfstarttiming` loads `A = $21` (narrow) and
`X = $22`, so it runs the row NORMAL and narrows it; `pfstoptiming` loads
`A = $22` and `X = $21` and runs it NARROW, widening. I built a whole model on
having that backwards.

| test | polarity | early | late |
|---|---|---|---|
| `antic_pfstarttiming` | normal, narrowed | 16 | 18 |
| `antic_pfstoptiming` | narrow, widened | 18 | 16 |

A mid-line DMACTL or HSCROL write finds the window in one of three states:

| write lands | what happens |
|---|---|
| before `nom - 3` | the whole window moves; the row is the new width outright |
| `nom - 3` … `nom + span - grid` | the START is committed but the STOP is still being compared — the row runs on its OLD grid to the NEW window's last fetch cycle, and its byte count belongs to NEITHER width |
| after `nom + span - grid` | the window has closed; a widening cannot restart it |

Three things had to be right together:

* **the commit point is `nom - 3` for every mode**, not the class-specific start.
  A bitmap row begins at `nom - 1` and still ignores a write landing at `nom - 3`.
* **the close is the window's LAST GRID POINT**, `nom + span - grid` — not the
  last actual fetch, and not the window edge. `pfstoptiming` widens *after* the
  last narrow fetch has already happened and still expects the stream to extend,
  so it is the comparator that is open rather than the fetcher that is running;
  four cycles later still, it expects nothing.
* **the pinned stream is bounded by a CYCLE, never a byte count.** The count
  belongs to a width the row is no longer using.

The rule was predicted from the raw fetch-cycle lists before being wired in, and
both predictions came out exactly:

```
mode $A pinned normal, bounded by narrow's last:  20 24 ... 88   = 18
mode 6  pinned narrow, bounded by normal's last:  26 31 ... 94   = 18
```

`antic_dma_line_map_at()` takes the pinned window position; `rebuild_line()`
decides which of the three states applies.

### The HSCROL half: a scrolled row fetches one width step MORE

`antic_pfstarttiming`'s first HSCROL assertion now passes too. The rule is that a
horizontally scrolled row **fetches at the next width up** — narrow reads a
normal row's worth, normal reads a wide one's — because the window has to have
something to show once it shifts. **The window POSITION comes from the next
width up as well** (corrected — see below); a scrolled narrow row simply *is* a
normal row for DMA purposes.

Measured rather than assumed: sweeping an "extra bytes" parameter 0..4 against
that assertion moved its answer 12, 13, 14, 15, **16** one for one, and 16 is the
wanted value. Four extra on a narrow mode 6 row is 16 -> 20, exactly normal's
count, which is what makes it a width step rather than a magic constant.

That paragraph used to end with a caveat: the extra was keyed on `hscrol != 0`
rather than the row's scroll bit, and "no test in the suite distinguishes them
yet". **Both halves of that were wrong**, and `antic_hscrolbug`'s own comment
says so — see the next section. It is a good example of a caveat that was
recorded honestly and then never re-tested: it sat here for a dozen iterations
while four tuning levers were swept above it.

### CORRECTED: position too, and keyed on the scroll BIT

`antic_hscrolbug` prints its own DMA map (lines 98-102 of the source) for a
**narrow, scrolled mode E row at HSCROL = 0**:

```
.D..................F.F.FRF.FRF.FRF.  ->  fetches at 20,22 ... 98   (40 bytes)
```

Forty bytes from cycle 20. Narrow's own window is 32 bytes from cycle 28; a
NORMAL window at HSCROL 0 is 40 bytes from cycle 20. The map is normal's,
exactly — so the step up moves the POSITION as well as the count, and it happens
at HSCROL = 0, which only the scroll bit can express. We were emitting 32 bytes
at 28...90 against hardware's 40 at 20...98.

Fixed by carrying the scroll bit through in the mode byte (`mode | 0x10`) so
`build()` can see it, and stepping the effective width once. Two consequences
worth noting:

* a WIDE scrolled row has no next width to step up to, and `antic_virtdma` still
  wants the extra bytes — so wide keeps the old count bump on its own window.
  Dropping it cost a test, which is how the case was found;
* `make dma`'s "HSCROL = 8 shifts by 4 cycles" check was comparing an UNSCROLLED
  HSCROL-0 row against a SCROLLED HSCROL-8 one, so it folded a whole width step
  into the answer. Rule (bb) again: the gate encoded a derivation. Both rows now
  set the scroll bit.

The suite score is unchanged at 48 — this is a correctness fix under the tests
that already passed, and the prerequisite for the run-on below.

### The unstopped playfield: what antic_hscrolbug actually measures

This test sat in the "exhausted, four levers disproved" pile for six iterations
because only its FAILURE STRING had ever been read. Its source says outright
what it does:

> temporarily glitch HSCROL to move the PF stop cycle, which causes ANTIC to
> **fail to stop the playfield counter**. This causes it to continue fetching
> through horizontal blank.

No constant can produce that. A stream bounded by a byte count always
terminates. The whole thing needed a different SHAPE, and six pieces of one:

**1. The stop is a comparator, and it is missable.** ANTIC's playfield
sequencer runs on its own fetch clock — every `stride` machine cycles — and
compares the horizontal counter against the window's stop on ITS OWN ticks, not
on every cycle. A stop of the wrong PARITY is never looked at. `build()` breaks
on `c == stop` and returns the stop it used.

**2. The numbers fall out with no tuning.** Narrow scrolled mode E at HSCROL 0:
start 20, forty bytes at stride 2, stop = 20 + 80 = **100** — even, sampled,
last fetch 98. Glitch HSCROL to 2 and the window moves one cycle left: start 19,
stop **99** — ODD, and an even grid never sees it. Restore HSCROL to 0 and the
stop is back at 100 with the counter already past it. Neither is matched, so the
row runs to the end of the line.

**3. The stream carries across the scanline boundary.** `pf_carry` holds the
cycle on the next line at which a still-running stream takes its next fetch;
`line_start` consumes it, and a line that fetches nothing drops it.

**4. Fetches past `PF_HBLANK_FIRST` (106) still FETCH but do not STEAL the
cycle** — the `#` versus `F` distinction in the test's own map.

**5. A rebuild must not RE-PHASE a running stream.** ANTIC's fetch clock
free-runs; a register write moves the COMPARATOR, not the phase. This one was
worth a whole iteration: the test's FIRST write already produced the published
map (47 fetches, last at 112, carry 0) and its SECOND — restoring HSCROL —
re-derived the grid from the new nominal, flipped its parity, ended at 113 and
carried into cycle 1 instead of 0. `rebuild_line` now hands the running phase
back in as `carry_in`.

**6. The display skips the bytes fetched before the window opened.** The line
buffer has a WRITE pointer that advances per FETCH and a READ pointer that
advances per DISPLAYED byte. A run-on line starts with its write pointer ahead,
so display index 18 must read the byte written by fetch 28. `lb_origin` counts
them and every display read goes through `lb()`. THIS is what "shifted left by
17 bytes" means — the bytes go into the buffer, the window shows the ones after
them.

Result: the fetch schedule matches the test's published map character for
character (scanline 32 at 20,22...112 = 47 fetches; scanline 33 at 0,2...98 =
50), and its FIRST assertion cluster passes: `d0..d3 = 01 00 04 04`, the `$04`
being the `$ff` byte reaching hpos `$78-$7b` as PF2.

Two register-semantics bugs fell out of the same test:

* **playfield DMA is gated by DMACTL's WIDTH bits, not bit 5**, which is the
  DISPLAY LIST DMA enable. Clearing bit 5 stops new INSTRUCTIONS being fetched;
  the playfield goes on being fetched at the programmed width;
* `line_start` returned as soon as a row ended with DL DMA off, and that return
  skipped the playfield build below it. **UNPROVEN** — kept on the argument, not
  on evidence, behind `DL_REUSE_KEEPS_PF`. Note a reused row does not currently
  get `row_first` set, and a bitmap mode's `stride_rest` is 0, so a reused
  bitmap row would fetch nothing anyway; the row bookkeeping has to be got right
  before that flag means much.

### RETRACTED: ACID_PCWATCH is NOT broken — the binary was missing

An earlier revision of this file claimed `ACID_PCWATCH` reported zero hits for
addresses the test provably executes, and concluded the tool was broken. **That
was wrong.** `build/acid` had been deleted by an `rm -f build/acid` during a
CFLAGS sweep and never rebuilt — `make test` builds the gate binaries, not that
one — so every invocation was the shell failing to find the executable, with the
error filtered out by the greps around it.

Rebuilt, it works: one hit each for `$2000`, `$210b` and `$2140`.

The lesson is the one this file already states, turned on itself: a tool that
reports "nothing happened" must be checked against a case known to produce
output BEFORE the conclusion is drawn — and "did the thing even run?" comes
before "is the thing broken?". Two consecutive iterations were spent on a
phantom. Worse, the false claim was committed here, where the next iteration
would have believed it.

### pfstarttiming: ONE collision in the whole run, and it is the mode 10 row

`ACID_COLPROBE=1` over the entire run prints exactly one line:

```
COLLIDE sl  34 cc $82 mode 10 ppf 1000 ppl 00 vbl 0
```

That single collision — P0 against PF0 — IS the early case's wanted bits 4, and
it identifies the measured row: the **`$0a` (mode 10) row**, not the `$66` mode 6
row. An earlier note here saying the test measures the `$66` row at scanlines 33
and 51 had the display-list mapping wrong; the `$66` rows are the LMS/VSCROL
setup and the mode 10 rows after them are what the players sit over.

So the failure is sharp: the mode 10 row at scanline 34 collides correctly, and
**the equivalent row after the second DLI produces no collision at all** — which
is why the late case reads bits 0 where it wants 6.

SUSPECT TOOL, not yet proven either way: `ACID_PFPROBE` prints nothing even for
scanline 34, where COLPROBE proves there is both a lit player and a playfield
class at that very colour clock. Its condition is `lit || pf >= 0` inside the
same per-clock loop that COLPROBE sits in, so it should fire. Do NOT repeat the
last mistake and declare it broken — the binary existed this time, but the "did
it run / is it wired up" check has not been done properly. Use COLPROBE for this
work; it is verified.

### PARKED: antic_hscrolbug's test #2

Its second case reads ALL ZEROS where it wants `d0..d3 = 02 00 04 04`. The
blocker is identified: **scanline 38's instruction is `$41` (JVB)**, so there is
no playfield row at all. The test turns DL DMA off mid-line 37 "so that the `$5e`
byte is reused" but restores `DMACTL = $21` before line 37 ends, and we then
fetch the next instruction at line 38 cycle 1. The open question is WHEN ANTIC
latches the decision to fetch a new display-list instruction and which DMACTL
sample it uses.

**DISPROVED, and this is why it is parked.** The obvious mechanism is that ANTIC
samples the decision late in the PREVIOUS line, catching `DMACTL = $01` before
the restore lands. Implemented as a latch and swept across cycles 100-113: the
result is FLAT — every cycle gives the same all-zero collisions. By rule (v),
when no setting of a parameter separates the cases the error is upstream, so the
latch was reverted rather than left in as a half-model. Note also that
`ANTIC_CYC_ROWEND` is cycle **5**, an early-line sample, not a late one; it is
not the latch this would need.

Whatever reuses the `$5e` is not a question of WHEN DMACTL is sampled. Test #1
passes and the whole run-on mechanism above is verified against the published
DMA map, so the remaining gap is specific to this second case. Four iterations
went in; the next thing worth more is the P/M pair.

DISPROVED along the way, so nobody re-runs them: the cycle-0 `rebuild_line` call
is NOT destroying the carried map. It runs BEFORE `line_start`, carries the
previous line's state, and wipes a map that has already been displayed. It
reports zero fetches only because a bitmap mode's `stride_rest` is 0 and
`row_first` is already cleared. That diagnosis was published here in error for
one iteration, on a probe that had not printed enough columns to say which
line's state it was showing.

### CORRECTED: "stride" is a COLLISION BITFIELD, not a byte count

This notebook, and every iteration that swept a fetch-side constant at these two
tests, was working from the failure STRING — "stride=%d" — instead of the
arithmetic behind it. The arithmetic is:

```
lda p0pf / asl / asl / ora p1pf / add #12   ; pfstarttiming, wants 18
lda p0pf / asl / asl / ora p1pf / add #14   ; pfstoptiming,  wants 18
```

So the reported number is `(p0pf << 2) | p1pf` plus a LITERAL OFFSET, and the
two offsets DIFFER. The shared "18" is a coincidence of those constants, not a
shared quantity, and nothing here is a byte count at all:

| test | offset | wanted bits | ours | meaning |
|---|---|---|---|---|
| `pfstarttiming` late | +12 | 6 | **0** | P0 must hit PF0 and P1 must hit PF1; NEITHER collides for us |
| `pfstoptiming` early | +14 | 4 | **2** | P0 must hit PF0 and P1 must hit nothing; we have it exactly backwards |

The setup, read rather than inferred: `hposp0 = $80`, `hposp1 = $84`, both
`grafp = $f0` and `sizep = 0`, so each player is FOUR colour clocks wide and the
two sit adjacent — `$80-$83` and `$84-$87` — in the MIDDLE of the playfield, not
at its edges. They sample two neighbouring character cells, and what the test
asks is which characters have reached that fixed screen position after a
mid-line DMACTL write.

So the "stride" label is fair in spirit — it is about how far the fetch stream
got — but the reported VALUE is a collision bitfield plus a literal, and the two
tests' literals differ. An intermediate reading recorded here for one iteration,
that the players sit at the window's left and right EDGES and the quantity is
`antic_pf_at`'s `start`/`span`, was an INFERENCE and is wrong; the positions are
mid-playfield.

What survives: the earlier framing ("both want 18, a hybrid byte count, both
SHORT so the mechanism ADDS") is wrong in every part — they do not want the same
thing, 18 is not a count, and one of them is not short but INVERTED (we light P1
where hardware lights P0).

### The trio MOVED: pfstarttiming and pfstoptiming now fail elsewhere

Worth re-reading a failure before trusting any summary of it. Both tests used to
fail on their HSCROL assertions — the "one byte per one cycle of write delay"
boundary tabulated below. The run-on rework carried them PAST those, and they
now fail on their **character-mode DMACTL** assertions instead:

| test | assertion | want | got |
|---|---|---|---|
| `pfstarttiming` | DMACTL early | 16 | 16 ✓ |
| `pfstarttiming` | DMACTL **late** | 18 | 12 |
| `pfstoptiming` | DMACTL **early** | 18 | 16 |
| `pfstoptiming` | DMACTL late | 16 | — |

Both now want **18**, the hybrid count belonging to neither width, and both are
SHORT — so the missing mechanism ADDS.

`PF_PIN_COMPARATOR` brackets the answer from opposite sides, which is the
interesting part:

| | pfstarttiming late | pfstoptiming early |
|---|---|---|
| comparator ON (1) | 12 | 16 |
| comparator OFF (0) | 15 | 20 |
| wanted | 18 | 18 |

With it off the STOP test overshoots (20) while the START test still undershoots
(15). No single setting satisfies both — rule (q), two tests forcing
incompatible values out of one constant means the shape is wrong.

DISPROVED: an additive adjustment on the pinned stream's stop. Swept 0..8 on
BOTH the shared bound and the character-mode branch's own separate `pstop`
(which is a distinct expression — adjusting only the shared one does nothing at
all for these two tests, and that flat curve was nearly mistaken for a result).
The response saturates: `pfstarttiming` moves 12 -> 13 and stops, `pfstoptiming`
never moves. So the count is bounded upstream of the stop, in the pair branch's
own byte budget, and the knob was reverted.

### Still open: the last HSCROL cycle, and antic_hscrolbug

What remains is a **one byte per one cycle of write delay** boundary, and both
tests show it from opposite sides:

| test | write cycle | want | got |
|---|---|---|---|
| `pfstarttiming` HSCROL early | 16 | 16 | 16 ✓ |
| `pfstarttiming` HSCROL late | 17 | 17 | 16 |
| `pfstoptiming` HSCROL early | 95 | 21 | 19 |
| `pfstoptiming` HSCROL late | 96 | 20 | — |

One cycle later gives exactly one more byte in `pfstarttiming` and one FEWER in
`pfstoptiming`. On a 4-cycle pair grid a single cycle should not change the count
at all, so near the boundary the stream must be resolvable at 1-cycle
granularity — each pair is two ADJACENT cycles, and a write landing between the
two halves plausibly drops one of them.

**Swept and ruled out: the commit lead.** `PF_COMMIT_LEAD` over 0..6 leaves both
HSCROL answers unmoved, and only 3 lets either test reach its HSCROL section at
all (0-2 and 4+ break a DMACTL assertion instead). So the lever is not where the
start commits.

Measured on the way, from `ACID_GLYPHPROBE=9`: `pfstoptiming`'s scrolled row is
fetching **19** where 21 is wanted, at cycles `26 31 35 ... 94 98`. Note it
begins the line UNSCROLLED — HSCROL is 0 at `line_start` and only written to 8
mid-line — so the "scrolled rows fetch a width step more" rule does not apply
when the schedule is first built, and the row's count depends entirely on what
the rebuild does. 21 is one MORE than a fully scrolled narrow row's 20, which no
combination of the current start/stop rules produces.

`antic_hscrolbug` ("Unstopped PF DMA test failed") has started producing data
rather than nothing — `d1..d3` are now `01 01 01` where they were `00 00 00`. It
glitches HSCROL so the stop is MISSED entirely and fetching runs on into
horizontal blank.

### Tried and REVERTED: pinning the start, and the prefetch as a non-name

Both were implemented in full and both traded passes away, so they are back out.
What they established is worth more than the attempt:

**The two tests have OPPOSITE polarity, which is easy to miss.**
`antic_pfstarttiming` loads `A = $21` (narrow) and `X = $22` (normal), so it runs
the row NORMAL and NARROWS it mid-line. `antic_pfstoptiming` loads `A = $22` and
`X = $21` — it runs the row NARROW and WIDENS it. Their assertions read
accordingly:

| test | polarity | early | late |
|---|---|---|---|
| `antic_pfstarttiming` | normal, narrowed | 16 | 18 |
| `antic_pfstoptiming` | narrow, widened | 18 | **16** |

**`pfstoptiming`'s late case wanting 16 — pure narrow — is the strongest single
fact here.** A widening that arrives after the stream has already stopped cannot
restart it. So the STOP commits too; it is not simply "compared live for ever".
Any rebuild that re-adds fetch slots past the old stop gets this wrong, which is
exactly what the reverted attempt did (it read 18).

**The prefetch IS name 0**, on the 4-cycle pair grid as well as the dense one.
Treating it as a non-name — which makes the pure-width counts come out the same,
so it looks free — breaks `antic_charcontrol` immediately, at row 0 of the first
character row.

**With the start pinned to the old window and the stop taken live, the pair grid
comes out ONE byte over** (19 where 18 is wanted). The bitmap case of the same
test lands exactly: mode $A pinned at the normal start, stopping at narrow's stop
cycle, gives 20,24,...,88 = 18 slots. So the geometry is right for bitmap and one
short of right for the character pair grid, and that single byte is the thing to
find. Do the BITMAP assertions first next time — same rule, far simpler stream.

`antic_hscrolbug` ("Unstopped PF DMA test failed") is the same mechanism from a
third side: it glitches HSCROL so the stop is MISSED entirely and fetching runs
on into horizontal blank, which only a cycle comparison can express.


## SUPERSEDED — gtia_pmresize reads ZERO player-to-player collisions

`gtia_pmresize` fails on its very first case — `d0..d7 = 70 00 80 E0 48 F0 00 00`,
so index 0, expected `$80`, got `$00`.

Its method is worth knowing because three GTIA tests share it: player 0 carries
`GRAFP0 = $AA` and is resized MID-LINE, while players 1-3 (`GRAFP = $80`, at
HPOS `$61/$62/$63`) and the four missiles (`GRAFM = $AA`, at `$64`-`$67`) sit
still as a **ruler**. The seven `P1PL`/`P2PL`/`P3PL`/`M0PL`..`M3PL` reads are
rotated into one byte, so the answer is literally a picture of how wide player 0
was at each position.

Zero means player 0 overlapped none of them. Both halves of the machinery it
needs are already present and are NOT the gap:

* player-to-player and missile-to-player collisions are implemented —
  `gtia.c` sets `ppl[]` and `mpl[]`, and `P1PL`/`M0PL` read back correctly;
* `SIZEP` is implemented with a per-object width divider that deliberately does
  NOT reset its phase, which is the behaviour `pmresize`'s own "alt" cases exist
  to check.

**The diagnosis was exact about the mechanism and wrong about the test.** The
render order WAS the missing piece — a cycle the CPU gets is now rendered after
its bus access, so a GTIA write lands before the two colour clocks that cycle
emits — but the test that turns on it is `gtia_pmretrigger`, not this one.
`pmresize` is unmoved. Keeping the reasoning below because it is still the right
frame for the remaining failure; only the conclusion about which test benefits
was wrong.

**Everything on this path is verified working, and it is one colour clock too
wide at the end.** Correcting an earlier misreading first: `d3` is the GOT
value and `d2` the WANTED one, so this is `$E0` against `$80`, not `$00` against
`$80`. `$E0` means player 0 collided with players 1, 2 AND 3; `$80` means it
should have hit only player 1.

Everything up to that point works, and `ACID_COLPROBE=1` now shows it end to end:

```
COLLIDE sl 17 cc $61 ... ppl 21
COLLIDE sl 17 cc $62 ... ppl 61
COLLIDE sl 17 cc $63 ... ppl e1
PLREAD $D00D sl 18 cyc  9 -> $01      <- P1PL, read back correctly
PLREAD $D00E sl 18 cyc 20 -> $01
PLREAD $D00F sl 18 cyc 33 -> $01
PLREAD $D008 sl 18 cyc 48 -> $00      <- M0PL..M3PL, correctly clear
```

The player is drawn, the collisions register, and the registers read back. The
row is one colour clock too WIDE at the end.

`GRAFP0 = $AA` at 4x from `$48` puts its last lit bit (bit 1) across
`$60`-`$63`, which is machine cycles 45 and 46. The test resizes to 1x with
`sty sizep0` annotated `42, 43, 44*, 45, 46++`, so the write lands on cycle
**46** — and cycle 46 is where colour clocks `$62` and `$63` are emitted. We
render a cycle's two colour clocks BEFORE servicing the CPU's access for it, so
those two clocks are still drawn at 4x and collide; hardware evidently applies
the write first, leaving them dark.

That ordering change was made and kept — a CPU cycle's colour clocks are now
rendered after its bus access — but `gtia_pmretrigger` is what cashed it and
`pmresize` did not move.

### Two eliminations on the remaining colour clock

`ACID_PFPROBE` shows player 0's lit clocks on the measured line, and the last lit
bit is plainly still four wide where it should end at `$61`:

```
$48 $49 $4A $4B   $50 $51 $52 $53   $58 $59 $5A $5B   $60 $61 $62 $63
```

The whole line runs one cycle late against its annotations: the resizing
`sty sizep0` starts on scanline cycle **43** where the listing says **42**, and
every instruction after the `inc wsync` measures one later than annotated. That
is the WSYNC RMW re-arm doing its job — `inc wsync` writes `$D40A` twice, so the
release is 105 rather than 104.

**Tried: a back-to-back RMW second write costing nothing.** If the two writes
land on consecutive cycles, do not charge the extra. 42 -> **39**. The re-arm
delay is real even for the RMW's own second write, which is the case it exists
for — so the release genuinely is 105 here and the annotation genuinely
disagrees.

**Tried: `REFRESH_FIRST` 24 instead of 25.** This test's annotations mark steals
at 24, 28, 32, 36, 40, 44 — a refresh phase one earlier than ours, which would
put the `sty`'s write on cycle 46 rather than 47 even with the release at 105.
42 -> **41**, and `pmresize` is unmoved at `$E0` regardless.

So the remaining colour clock is NOT simply where the write lands, and both
obvious cycle-level levers are out. `REFRESH_FIRST` is left overridable for
future sweeps. What has not been checked is what a mid-BIT size change does to
the width divider: `size_scale` is read live, so shrinking mid-bit ends that bit
early, and the test's "alt" cases exist precisely because the phase is NOT reset.
Whether the CURRENT bit should finish at its old width is the open question.


## CLOSED: STIMER makes the first period of a fast unlinked timer longer

`pokey_timertiming` hands the answer over in its own comment table, which is
reading rule (c) paying off again:

```
; A/B values are cycles after STIMER write before/after bit 0 is
; cleared for timer 1.
;           IRQST1      IRQST2
; AUDF1=0    7c/ 8c     11c/12c
; AUDF1=16  23c/24c     43c/44c
```

Read the deltas rather than the absolutes. Between the two AUDF values the first
interrupt moves by 16 and the second by 32, so the PERIOD is `AUDF + 4` — which
the divider already had. What it did not have is that the FIRST period after a
STIMER write is **four cycles longer**: 7-8 rather than 4 for `AUDF1 = 0`, with
every period after it back to 4.

Swept 0..8: 4 is the only value satisfying both the "too early" and "too late"
bounds. The extra applies to **fast, unlinked** channels only — applying it to
the base-clocked ones breaks the `ptimer` gate's 15 kHz tick outright, and
applying it to a linked pair leaves `pokey_timertiming`'s own 16-bit case firing
late.

Worth flagging a tension with the fabric, which reached the opposite conclusion —
see the commit *"pokey: extended first timer period applies to LINKED mode only"*
in the `docs/a800` history. Both cannot be right about the same silicon. The
software side is what the ACID assertions bound here, but this is a good candidate
for re-checking on hardware.

### Next: a linked pair is TWO counters, not one

`pokey_timertiming` now clears its whole 8-bit group and fails on **"1.79MHz
16-bit lo timer triggered too late"**. Sweeping the fast linked period constant
`LINK_FAST` over 4..9 moves the answer **not at all**, which rules it out — and
points straight at the reason.

The test checks the two halves of a linked pair SEPARATELY, and its own boundaries
give the structure away:

| case | AUDCTL | mask | boundary |
|---|---|---|---|
| 8-bit, `AUDF1 = 16` | `$40` | `#$01` | 19 / 20 |
| 16-bit **lo**, `AUDF16 = 16` | `$50` | `#$01` | 19 / 20 |
| 16-bit **hi**, `AUDF16 = 16` | `$50` | `#$02` | 22 / 23 |

The low half's interrupt fires at **exactly the same time linked as unlinked**,
and the high half's fires three cycles later. The 16-bit-hi case is the clincher:
it masks `#$02` and requires bit 1 still set at 22 while bit 0 has already
cleared, so **both interrupts exist independently while linked**.

Our model treats a linked pair as ONE divider of `AUDF16 + 7` whose event belongs
to the high channel, so `POKEY_IRQ_TIMER1` never fires at all when linked — which
is why no period constant can help. The fix is structural: the low counter
underflows and reloads on its own period, raising its own interrupt, and the high
counter decrements on each of those underflows.

It was built behind `LINK_TWO_COUNTERS` and is now **on by default**.

With the flag on, nothing regresses — `pokey_serclock`, `pokey_twotone`,
`pokey_timerirq`, `pokey_timergranularity` and `pokey_sertiming` all still pass,
the score stays 42 — and `pokey_timertiming` advances two assertion groups, from
"16-bit lo too late (loop #1)" to "16-bit lo too **early** (loop #2)". So the low
half's own interrupt is real and loop #1's boundary is now met.

### The gate that vetoed it, and why it was WITHDRAWN

The first attempt was held back by a gate asserting that the low half must
interrupt **before** the high, which reads straight off the test's 19/20 against
22/23. Under our counts the low is `AUDF1 + 4 + 4 = 24` and the pair
`AUDF16 + 7 = 23`, so the high fires first and the gate failed.

Three sweeps then established that the gate, not the model, was wrong:

* `LINK_EXTRA` (a STIMER extra for the PAIR) 0..4 — only **0** works.
  Anything else breaks `pokey_sertiming`, which clocks a fast linked pair.
* `LO_EXTRA` (the extra for the linked LOW half) 0..4 — only **4** works.
  Anything less puts `pokey_timertiming`'s 16-bit lo back to failing loop #1.
* those two are forced independently, and together they give exactly the 24
  against 23 the gate objects to.

So the configuration the ACID assertions demand is the one the gate calls
backwards. The inference was the weak link: 19/20 and 22/23 are measured through
**different instruction paths with different masks**, and the raw firing order
does not follow from comparing them. The assertions are the authority (reading
rules (d) and (e)); the gate over-claimed and is not re-added. What IS gated is
the part that is certain — both halves interrupt at all.

Also tried and reverted: having the PAIR's reload restart its low half, the
intuitive reading of a 16-bit borrow chain. It puts loop #1 back to failing, so
the low half keeps its own phase.

### The low half's first period is UNLINKED, the rest are LINKED

Loop #2 measures the low half's SECOND period, and sweeping its reload settles it
without any theory:

| reload | result |
|---|---|
| `AUDF1 + 4` (the unlinked period) | too early |
| 16..18 | too early |
| **19** | **passes, and moves on to the 16-bit HI group** |
| 20..22 | too late |
| 255 / 256 (a `$FF` borrow chain) | far too late |

With `AUDF1 = 16` the unique answer is a reload of 23, and 23 is `AUDF1 + 7` —
`LINK_FAST` exactly. So the low half's **first** period after STIMER is the
unlinked one (`AUDF1 + 4`, plus `LO_EXTRA`) and every period after it is the
**linked** one. Notably it is NOT a plain 16-bit low byte: a true `$FF` reload
fires far too late.

`pokey_timertiming` now clears its whole 16-bit LO group and fails on **"16-bit
hi too early (loop #1)"**.

### Open: the pair's own period cannot be a separate constant

The high half now fires too early, and the obvious fix — give the PAIR the same
STIMER extra the low half gets — is forced BOTH ways by two different tests:

| `LINK_EXTRA` | `pokey_timertiming` | `pokey_sertiming` |
|---|---|---|
| 0 | 16-bit hi too early | **passes** |
| 1..3 | 16-bit hi too early | fails |
| **4** | reaches a much later section ("8-bit timer fired too late after 23c change") | fails |

That is not a constant to be fitted. The first guess — that the extra applies
only when the high byte is zero, so the pair completes on the low half's first
borrow — was **tested and is wrong**, because both tests have `AUDF2 = 0`:

| | `pokey_timertiming` | `pokey_sertiming` |
|---|---|---|
| AUDCTL | `$50` (1+2 linked, fast) | `$78` (both pairs linked, both fast) |
| AUDF1 / AUDF2 | 16 / **0** | 221 / **0** |
| serial clock | not used | SKCTL `$63` -> **timer 2**, i.e. the same pair event |

Gating the extra on `AUDF2 == 0` sends `pokey_timertiming` a long way forward —
past every 16-bit group to its "8-bit timer fired too late after 23c change"
section — and breaks `pokey_sertiming`, because both land in the same branch.

So the two tests really are in the same timer configuration and still want
different timing. What differs is WHAT THEY MEASURE: `timertiming` watches
`TIMER2`'s **interrupt**, `sertiming` watches the **serial shift** (SEROR/SEROC).
Our model drives both from the one pair underflow. The evidence says those are
two edges, and only the interrupt carries the STIMER extra.

### CLOSED: the pair's interrupt edge LAGS its serial-clock edge, by four, always

Splitting them does it. The serial tick happens on the pair's underflow as
before; the interrupt is raised `PAIR_IRQ_LAG` ticks later. Swept 0..6:

| lag | `pokey_timertiming` | `pokey_sertiming` |
|---|---|---|
| 0..3 | 16-bit hi too early | passes |
| **4** | **clears every 16-bit group**, on to the "23c change" section | passes |
| 5..6 | 16-bit hi too late | passes |

`pokey_sertiming` passing at **every** value is the independent confirmation:
the serial clock genuinely does not see this lag, which is why one pair event
could never satisfy both tests.

The lag applies to EVERY pair underflow, not just the first after STIMER — tried
both, and only "every" gets past loop #2. So it is a property of the pair's
interrupt path, not another STIMER first-period effect, and `LINK_EXTRA` is gone.

`pokey_timertiming` now clears its 8-bit group, both 16-bit groups and all four
loop bounds, and fails much later on the AUDF-rewrite section.

### Open: AUDF is captured BEFORE the underflow, and one tick is too coarse

The test states the boundary in its own comments — a `sty audf1` at **+22c** past
STIMER is "written in time to affect second period" and one at **+23c** is
"written too late". Our `reload()` reads `audf[]` live at the underflow, so both
land, and the +23c case fires late.

Two shapes tried, both reverted:

* **Freeze the value while the counter is near zero** (`audf_sh` updated only
  while `cnt > LEAD`). At `LEAD = 1` this passes both 8-bit change assertions and
  advances to the 16-bit lo one — but over the full suite it scores **38**,
  breaking `pokey_asyncrecv`, `pokey_serclock`, `pokey_timerirq` and
  `pokey_twotone`. The trap is worth remembering: a channel with `AUDF = 0` has a
  period of ONE, so its counter is never far from zero, the shadow sticks at
  whatever it was initialised with, and the timer runs on a stale value for ever.
* **Delay it by a whole tick** (shadow copied at end of tick, reload uses the
  previous cycle's value). No sticking, but it overshoots — 41, and
  `pokey_timertiming` then fails the **+22c** case instead of the +23c one.

### CLOSED: AUDF is captured TWO cycles before the underflow

Measuring first settled it in one pass. `ACID_PCWATCH` on the STIMER store and
on both `sty audf1` sites:

```
sta stimer   line 25 cycle 59  -> 4-cycle STA, no refresh past 57, writes on 62
sty audf1    line 25 cycle 82  -> writes on 85   (the "+23c" case)
sty audf1    line 19 cycle 81  -> writes on 84   (the "+22c" case)
```

`AUDF1 = 16` gives a first period of `16 + 4 + 4` = 24, so the first underflow is
at `62 + 24` = **86**. The write that must LAND is at 84, two cycles before it;
the one that must MISS is at 85, one cycle before. So the counter captures AUDF
**two cycles ahead of its underflow**.

Expressed as a **delay line** (`AUDF_PIPE = 2`), never a freeze. Swept with the
full suite each time: 1 still fails the +23c case, 2 passes both 8-bit change
assertions at 42, 3 overshoots and fails +22c.

Two initialisation points are needed, and the `ptimer` gate found both: STIMER
primes the line because it is an explicit "load now", and so does an AUDF write
that arrives while the counter is further than the pipe from its underflow —
without them the first period after a fresh write uses whatever the line held.

### The period is decided near its END, not fixed at its start

Routing the low half's reload through the delay line changed **nothing**, and
measuring said why. For the 16-bit block (`AUDCTL $50`, `AUDF1 = 13`):

```
sta stimer   line 31 cycle 59  -> writes on 62
sty audf1    line 31 cycle 81  -> writes on 84   ("+22c")
```

The low half's first period is `13 + 4 + 4` = 21, so its first underflow is at
`62 + 21` = **83** — one cycle BEFORE the write. The write can only affect the
SECOND period, which ends around 103, and its capture point is 101. Our
down-counter reloaded at 83 using the value from 81, so it captured two cycles
before the underflow that was *finishing* rather than the one about to *start*.

Counting **up** and comparing the elapsed count against a live (delayed) AUDF
every tick fixes it: the period is decided near its end. `LO_UPCOUNT` is on by
default, 42 with all ten gates green, and `pokey_timertiming`'s "+22c" 16-bit
case now passes.

It fails on the companion **"+23c"** case instead, and measuring that one says
something awkward about the low half's FIRST period rather than about capture.

Both 16-bit blocks are identical — `AUDCTL $50`, `AUDF1 = $0d` = 13 — and differ
only in the write:

```
+22c block   sta stimer -> 62      sty audf1 -> 84    must LAND
+23c block   sta stimer -> 62      sty audf1 -> 85    must MISS
```

Under our model the low half's first period is `13 + 4 + 4` = 21, so its first
underflow is at **83** and its second at **103** with a capture at 101. Both
writes are after 83 and both are long before 101, so nothing in the current model
distinguishes them — and no capture rule can, because the boundary sits at 84/85
while our candidate points are 81, 83 and 101.

The 84/85 boundary is exactly `underflow - 2` / `underflow - 1` for an underflow
at **86**, so 24 looked like the answer. It is not, and the sweeps say why.

**The linked low half's first period is forced to two different values.**

| first period | `16-bit lo loop #1` (`AUDF1 = 16`) | the change block (`AUDF1 = 13`) |
|---|---|---|
| `AUDF1 + 8` — 24 and 21 | passes | +22c passes, +23c fails |
| constant 22 or 23 | fails, too early | — |
| **constant 24** | passes | **+22c fails, too late** |
| constant 25+ | fails, too late | — |

Loop #1 wants 24 and gets it either way, because its `AUDF1` is 16. The change
block wants 21 from the `+22c` assertion and 24 from the boundary arithmetic.
Tried with both counter shapes — up-count and down-count — and neither
combination satisfies both. The `Y` written by the change blocks is `$0f` = 15
against `AUDF1 = 13`, so landing LENGTHENS the period by two, which is consistent
either way and does not break the tie.

By rule (q) that is a shape problem, not a constant: something about the linked
low half's first period differs between the two blocks beyond `AUDF1`, and
nothing measured so far distinguishes them. Left at the known-good configuration
— `LO_UPCOUNT` with the AUDF-dependent first period, where `+22c` passes and
`+23c` fails.

This test has now given up five rules (the STIMER first period, both halves
interrupting, the interrupt/serial edge split, the AUDF capture delay, and the
end-decided period). The remaining assertion pair is deep in diminishing returns;
better value elsewhere.


## SOLVED: gtia_phantomdma latches the BUS, and the CPU is on it

Never examined before, and the name is exact. The test sets `DMACTL = $21` —
narrow playfield, display-list DMA on, and **P/M DMA off** — while `GRACTL = $02`
tells GTIA to latch player graphics anyway. With no P/M fetch happening, the
latch captures whatever ANTIC last drove onto the bus: display-list and playfield
bytes. That is the "phantom" data.

Our `pm_latch()` only ran when `an.pm_fetched` was set, so the objects kept the
`$FF` the test wrote directly and `d0` read back `$FF`.

A first cut — track the last byte ANTIC fetched and latch it into every object at
line start when GRACTL enables the latch and no P/M fetch happened — moves `d0`
from `$FF` to **`$88`**, which is a `framebuf` byte. So the phantom path is real
and now captures bus data. It is still wrong, and the wanted value says why:
`$AD` = `1010 1101` is a COLLISION pattern built from `p0pf` and the low bit of
each of `m0pl`..`m3pl`, and four objects cannot produce four different bits from
one shared byte.

So each player and missile latches on **its own slot**, capturing whatever ANTIC
drove at that particular cycle — four consecutive fetches, four different bytes.

The per-slot version is now implemented behind `PHANTOM_PM`, with `PM_SLOT_P` /
`PM_SLOT_M` for the slot cycles (our `pm_dma()` does all four fetches at
`line_start`, so the schedule has no P/M slot positions to reuse — they have to
be chosen and pinned). Sweeping `PM_SLOT_P` moves the answer, which confirms the
machinery works:

| `PM_SLOT_P` | `d0` |
|---|---|
| 0 | `$88` |
| 2, 4, 6, 8 | `$0F` |

Wanted is `$AD`. Still off, and decoding what `$AD` actually demands shows why it
is a three-way constraint rather than one byte:

* `d0 = (p0pf << 4) | m0pl.0 | m1pl.0 | m2pl.0 | m3pl.0`, so the low nibble
  `1101` says missiles 0, 1 and 3 hit player 0 and missile 2 MISSES. The missiles
  sit at HPOS `$89/$8b/$8d/$8f` and player 0 at `$81` with `SIZEP0 = 1` (2x, so
  two colour clocks per bit), which puts them on player-0 bits 3, 2, 1 and 0. So
  the phantom byte's low nibble must be `1101` — and none of the obvious bus
  bytes (`$70`, `$4F`, `$12`, `$24`, `$0F`, `$88`, `$76`, `$54`) ends in `$D`.
* `p0pf = $A` means player 0 overlaps PF1 AND PF3. **`PRIOR = $81` puts GTIA in
  mode 10**, so the playfield nibbles pick PF0-PF3 by bit 2 — and the `$88` body
  of `framebuf` has bit 2 CLEAR (not playfield at all), while its `$76,$54` tail
  gives exactly PF3, PF2, PF1, PF0. So the collision comes from the last two
  bytes of the buffer, not its body.

Which is what settled it, because the answer to "which bus byte can end in `$D`"
turned out to be **none of ANTIC's**. A bus trace of the measured scanline
(`ACID_BUSTRACE=<scanline>`, printing every access with its cycle and its
driver) says so directly:

```
  BUS sl  33 cyc   0 ANTIC $2406 -> $0F
  BUS sl  33 cyc   0 CPU-R $2098 -> $00
  BUS sl  33 cyc   2 CPU-R $0000 -> $00
  BUS sl  33 cyc   3 CPU-R $2099 -> $AD      <-- the only low nibble $D on the line
  BUS sl  33 cyc   4 CPU-R $209A -> $00
  BUS sl  33 cyc   5 CPU-R $209B -> $01
  BUS sl  33 cyc   8 CPU-R $0100 -> $00
  BUS sl  33 cyc  28 ANTIC $2432 -> $88      <-- ... and everything ANTIC fetches
```

`$AD` is the OPCODE of the test's own `lda $0100`. The test positions that
instruction — `inc wsync`, `sta hitclr`, two `nop`s, `lda $00` — so that its
opcode fetch lands on the player-0 slot, and asserts the opcode byte comes back
out of GRAFP0. So:

**The phantom latch samples the DATA BUS, not ANTIC.** On a cycle DMACTL has not
given to ANTIC, the CPU is the one driving, and GTIA latches the CPU's byte.

Two consequences for where the code goes. The source is a `last_bus` updated by
**every** access — `antic_fetch`, `bus_rd` and `bus_wr` alike — not the old
`last_fetch`. And the latch has to run **after** the cycle's access, so it could
not stay in `pm_latch()`: on a cycle the CPU gets, `sys_cycle()` has returned
long before the read happens. It is now its own `phantom_latch()`, called from
the ANTIC path after `antic_tick()` and from `cpu_cycle_done()` for the CPU's
own cycle.

`PM_SLOT_P = 3`, measured. That single value satisfies **both** of the
constraints above at once, which is the cross-check that this is a model and not
a fit: `$AD` in GRAFP0 lights player-0 bits 3, 2 and 0 (missiles 0, 1 and 3 hit,
missile 2 misses, low nibble `$D`), and the *same* lit bits put player 0 over
`framebuf`'s `$76,$54` at colour clocks `$81,$82` and `$85,$86` — PF3 and PF1,
`p0pf = $A` — via the mode-10 one-colour-clock playfield shift that was already
in `antic_pf_nibble()`. Nothing was tuned to make the second half come out.

Two things had to be got right beyond the slot:

* **Gate it on DMACTL, not on "ANTIC fetched nothing this cycle".** The first
  version tested `!an.pm_fetched`, and since `pm_dma()` does its fetches at
  `line_start` that flag is long since consumed by the time the slot cycles come
  round — so the phantom clobbered a perfectly good latch and cost
  `antic_pmdma`, `antic_charcontrol` and `gtia_vdelay`. One test up, three down:
  the full suite caught it, a single-test sweep would not have.
* **Player DMA drags missile DMA with it**, so the missile gate tests both
  DMACTL bits, as `pm_dma()` itself does.

The MISSILE phantom is written down but left OFF (`PHANTOM_PM_M`): no test in
the suite pins its slot, because `gtia_phantomdma` leaves `GRACTL` bit 0 clear
and writes GRAFM directly. The mechanism is certain, that one constant is not.

Gated in `test/sys.c` — a new `make sys`, the first host gate that links the
whole machine rather than one chip. The rules that live in `system.c` (who
drives the bus on a cycle, when a latch samples it, render-after-access) had no
gate at all before this, and they are exactly the kind a later refactor reverts
without anything noticing.

## SOLVED: pokey_noise's hot stop — entering init lags one cycle too

The release from SKCTL init was already modelled as taking effect one cycle late
(`release_cycle`): the write lands during a machine cycle whose advance still
belongs to the pre-release state. The way back IN is the same, and
`pokey_noise`'s "hot stop" measures it.

That section frees the counters, runs them one scanline, drops back into init
and reads RANDOM four cycles later:

```
    lda #3 / sta skctl      ;free
    sta wsync               ;one scanline
    lda #0 / sta skctl      ;back into init -- the "hot" stop
    lda random
```

Init does not snap the register to `$FF`; it keeps shifting and feeds ONES in.
So the byte read is a free-run value with its top bits already filled, and **the
number of leading ones counts how many of those four cycles were init cycles**.
That makes the assertion readable directly rather than by search:

| | leading ones | underlying free-run value |
|---|---|---|
| hardware `$E9` = `1110 1001` | 3 | `$4x` |
| ours `$F9` = `1111 1001` | 4 | `$9x` |

Four init cycles against three, and the remainder one free-run step further on —
the same total number of shifts with one moved from one side of the boundary to
the other. So the counters take one more real step after the write that enters
init. `STOP_LAG`, symmetric with `release_cycle`, and the 17-bit half of the
same test (`$F0`) falls out with it — a second constraint the one cycle had to
satisfy and was not tuned against.

The `pokey` gate had to be corrected rather than merely extended: its "init +1"
expectation was `$CA`, a one already at the top, which was my DERIVATION of what
entering init does and not a measurement of it. It now checks `$4A` — the
ordinary next step of the sequence — then the fill beginning one cycle later.
Assertions are the authority; a gate that encodes an inference is only as good
as the inference.

## SOLVED: IRQST and the /IRQ line are one cycle apart

`pokey_inittiming` measures the SAME underflow twice, and that is the whole
trick of the test. Its first half runs a NOP sled and records the return address
the IRQ handler pushed — which times when the CPU **acknowledged** the
interrupt. Its second half brackets the event between two `lda irqst` reads one
machine cycle apart — which times when the **flag became readable**:

```
    sty skctl / stx irqen   ;release, then enable
    jsr delay36 / jsr delay24 / nop / nop / nop
    lda irqst : and #1 : _ASSERTA $01   ;must NOT be pending  (release+82)
        ...same sequence with one more cycle of padding...
    lda irqst : and #1 : _ASSERTA $00   ;must     be pending  (release+83)
```

Two reads, one cycle apart, opposite polarity: the edge is pinned to a single
machine cycle. Sweeping the 15 kHz tap phase against BOTH halves gives

| `BASE_15K_LEAD` | result |
|---|---|
| 0, 1 | "15KHz IRQ fired too late" — the bracket |
| 2 | "Incorrect 15KHz cycle count (odd)" — the sled |
| 3, 4 | "Incorrect 15KHz cycle count (even)" — the sled |

which is rule (q) in its purest form: no value of one constant satisfies both,
so the shape is wrong. The sled wants the underflow two cycles LATER than the
bracket does, and the two observations differ in exactly one respect — one
watches the status bit, the other watches the interrupt line. **They are not the
same instant.** IRQST is set at the underflow; the line to the CPU follows
`IRQ_LINE_LAG` cycles behind.

One cycle of line lag is what fits, together with a tap lead of two — and the
second number is the corroboration rather than a second free parameter, because
the 64 kHz tap already led by two and the 15 kHz one led by ZERO. That split
existed only to absorb this error. With the lag modelled, **both taps lead by
the same two** and `BASE_64K_LEAD`/`BASE_15K_LEAD` collapse into a single
`BASE_LEAD` — the model got smaller, not larger.

`pokey_irqtiming` passed at the same time, unprompted.

Gated in `test/ptimer.c` on the SEPARATION rather than on either number alone:
there must be at least one cycle in which the flag reads pending and the CPU has
not been asked yet.

Two probes earned their keep and are worth keeping in mind:

* `ACID_IRQPROBE=1` prints every IRQST transition with its scanline cycle and
  machine cycle. Instruction granularity cannot answer "which cycle did it fire
  on", and that is the only question these tests ask.
* `ACID_PCWATCH` shows the ANTIC state at the INSTRUCTION BOUNDARY, which is
  before a pending WSYNC halt has been serviced. It reported the release write
  at line 20 cycle 110 when `ACID_COLPROBE` showed it actually landing at line
  21 cycle 108 — a whole scanline out. Rule (k) again: for anything downstream
  of a WSYNC, watch the WRITE, not the PC.

## SOLVED: pseudo mode E — GTIA latches hi-res once per line

`gtia_psuedomodee`'s two cases are the same code twice, and the ONLY difference
is one cycle:

```
    sta grafp0      ;7, 8, 9, 10        sta grafp0,y   ;7, 8, 9, 10, 11
    sty prior       ;11, 12, 13, (14)   sty prior      ;12, 13, 14, (15)
```

`sta grafp0,y` is a cycle longer than `sta grafp0` — indexed stores always take
their dummy read — so the write that leaves GTIA mode 10 lands on cycle 14 in
one case and cycle 15 in the other. Cycle 14 wants `$04`; cycle 15 wants `$0F`.

Everything else is identical, and in particular the player is at HPOS `$80`,
quad width, so it sits over colour clocks `$80..$9F` — a hundred colour clocks
after either write. The mode change cannot be affecting the display where the
collision happens. It has to be changing STATE that lasts the rest of the line.

What state? Read `$0F` (rule y). The playfield is `$E4` everywhere, and the
window is normal width, so each byte covers four colour clocks. `$E4` is
`11 10 01 00`. Four playfield classes out of four colour clocks of one repeated
byte means the two-bit pairs ARE the class index — and not mode E's mapping,
where `00` is background and the answer would be `$07`. A direct index, `00` ->
PF0. That is what the test is named for: it looks like mode E and its colours
are not mode E's.

The hi-res decode cannot produce it however it is phased — it reduces each pair
to "lit or not" and reports PF2, which is the `$04` the other case wants. So:

**GTIA decides ONCE PER SCANLINE whether mode F is hi-res.** A GTIA mode still
selected at that instant disables hi-res for the whole line; leave the GTIA mode
afterwards and the playfield keeps arriving with hi-res off, which is the
pair-as-index decode.

The latch cycle is **15**, and the two cases bracket it from both sides:

| `GTIA_MODE_LATCH` | result |
|---|---|
| 11, 12, 13, 14 | "Cycle 14 test failed" — that case goes pseudo too |
| **15** | **PASS** |
| 16 | "Cycle 15 test failed" — that case does not go pseudo at all |

Exactly one value separates them, which is what a well-built pair of cases is
for. A live `PRIOR` read cannot express any of this: both writes are long past
before the playfield window opens, so without the latch the two cases are
identical by construction — which is exactly what we saw, `$04` twice.

Gated in `test/antic.c` on the part that is ANTIC's: the same line buffer read
two ways, `antic_pf_at` giving PF2 alone and `antic_pf_pair` giving all four.
Which decode is in force is `system.c`'s latch.

## OPEN: `inc wsync`'s release cycle is forced to two different values

`gtia_pmresize` is blocked on ONE machine cycle, and it is not a GTIA cycle.

Its `runtest` is annotated end to end, and measuring ours against it (`ACID_PCWATCH`
on each instruction) shows a uniform offset that appears at the very first step
and never grows:

| instruction | annotated | ours |
|---|---|---|
| `stx hposp0` | 108 | 109 |
| `sta sizep0` | 112 | 113 |
| `lda #$aa`   | 2   | 3   |
| `lda $0100`  | 8   | 9   |
| `sty sizep0` | 42  | 43  |

Every gap between them matches exactly, DMA steals included — so the whole error
is at the resume from the leading `inc wsync`. We release an RMW's WSYNC at 105;
this test's arithmetic wants 104. That one cycle is two colour clocks, which is
exactly how far the player's resize lands late: the test resizes 4x -> 1x under a
player at HPOS `$48` and probes colour clocks `$61`..`$67`, wanting `$80` (only
the `$61` probe hit) and getting `$E0` (`$61`, `$62` and `$63`).

Removing the extra confirms the diagnosis and cannot be kept:

```
WSYNC_RMW_EXTRA=0:  the ENTIRE 4x-to-1x block passes (all 256 iterations)
                    and the failure moves on to 4x-to-2x
                    ...and antic_wsync, antic_dlitiming, antic_dmapattern,
                       gtia_phantomdma and gtia_psuedomodee all break.
                    47 -> 42.
```

Five tests force 105 and one forces 104, from one constant. By rule (q) that
means the SHAPE is wrong, not the value: "the second write of an RMW pushes the
release out by one" is the wrong generalisation of whatever the hardware does.

Logging every WSYNC write with its scanline cycle (`ACID_COLPROBE` now prints
them) gives four cases, and exactly one structural difference between them:

| test | RMW write pair | wants |
|---|---|---|
| `antic_wsync` | 1, 2 | extra |
| `pokey_noise` | 11, 12 and 113, 0 | extra |
| `antic_dlitiming` | 5, 6 / 96, 97 / 109, 110 | extra |
| `gtia_pmresize` | 32, **34** | NO extra |

Every case that wants the extra has its two writes on ADJACENT cycles; the one
that does not has a memory refresh at cycle 33 sitting between them. That looked
decisive, and it is wrong — **DISPROVED**. With the extra applied only to
adjacent pairs the suite stays at 47 and `gtia_pmresize` still fails, just one
iteration later: index 0 now passes and index 1 does not. Its loop runs 256
times and the pair's alignment drifts, so adjacency buys the iterations where a
refresh happens to fall between the writes and nothing else. On hardware all 256
behave the same, so DMA alignment cannot be the discriminator.

(That first attempt also failed for a second, separate reason worth remembering:
the pair can STRADDLE A LINE BOUNDARY — `pokey_noise` writes at 113 and 0 — so
"adjacent" cannot be tested on scanline cycles. `antic.ticks`, a free-running
machine-cycle count, was added for it and is worth keeping.)

Two shapes down. What is still true is that ONE machine cycle at this boundary
is all that stands between `gtia_pmresize` and its first 256 assertions, and
that the five tests wanting the extra measure it directly — `antic_wsync` reads
RANDOM after each and the LFSR decoder puts its INC read exactly 115 cycles
after its STA read, one scanline plus one. So both sides are real measurements
and the reconciliation is still missing.

Kept at 1, which is the known-good 47.

## The four `mod_*` JAMs are not hardware tests

Never diagnosed before, and worth writing down so nobody spends a day on them.

`ACID_TRAPOUT=1` puts `mod_options` at `$0000` after twenty-one instructions,
with the last few in `_print`/`_imprint` ending at `jmp (_vputchar)`. That vector
is filled in by the OS when `_testInit` opens IOCB0 — the exact call we stub to
RTS, having no OS ROM. So it stays zero and the first line of output sends the
CPU to address zero.

Stubbing `_vputchar` to an RTS is the same accommodation as the `_testInit`
stub, for the same reason, and is now done: printing becomes a no-op and the
module runs on. `mod_options` goes from JAM to LOOP.

LOOP, not PASS, and the other three still derail — because of what they then do:

```
_waitKeyPrompt:
    jsr _imprint / dta c"Press a key...",0
    lda #0 / sta ch
    lda:req ch                  ;spin until a HUMAN presses a key
```

These four are the suite's INTERACTIVE modules: they draw a pattern, print
"Press a key...", and wait for someone to look at the screen and decide. Their
assertion is a pair of human eyes. There is nothing here for a headless run to
measure, and simulating a keypress would produce a "pass" that means precisely
nothing.

**They are deliberately NOT reclassified as `na`.** The dashboard excludes `na`
from its pass/total, so marking them would take the score from 47/59 to 47/55
without a single new thing working — a bookkeeping change that reads exactly
like progress. They stay counted, and this section says why they can never go
green.

The `_vputchar` stub is kept anyway: it is correct independently of these four,
because any test that prints before it fails would otherwise derail to `$0000`
rather than reaching `_testFailed`.

## The HSCROL trio: the rate is the clue, not the constant

`antic_pfstarttiming` runs the SAME experiment twice — once moving DMACTL and
once moving HSCROL — with the write one cycle later in the "late" case each
time. Comparing the two pairs as DELTAS (rule c) is what the test is for:

| written mid-line | early (write at 13-16) | late (write at 14-17) | delta |
|---|---|---|---|
| DMACTL | 16 | 18 | **2** |
| HSCROL | 16 | 17 | **1** |

Both pairs are the same probe — `(p0pf << 2) | p1pf` plus a per-block constant
(rule j: `+12` for DMACTL, `+10` for HSCROL) — so the unit is the same in both
rows. One machine cycle of extra delay moves the DMACTL edge by TWO units and
the HSCROL edge by ONE.

The probe says what a unit IS. Player 0 sits at HPOS `$80` and player 1 at
`$84`, both `SIZEP = 0` with `GRAFP = $F0`, so each is four lit colour clocks
and together they tile colour clocks 128..135 — an eight-clock ruler laid across
the playfield's left edge, read at COLOUR-CLOCK resolution. So a unit is one
colour clock, and the DMACTL row's "2" is simply a machine cycle being two of
them. The HSCROL row's "1" is a HALF machine cycle, which is HSCROL's own
granularity: it counts in colour clocks, and the window start is
`nominal - hscrol/2` machine cycles.

Two units per machine cycle is the natural rate: a machine cycle is two colour
clocks. **HSCROL moves at half that** — which is the same half-cycle-per-clock
relation `make dma` already reports for the window derivation, showing up again
in the mid-line write path.

We get the DMACTL row right and the HSCROL row flat: 16 and 16. The reason is
visible in `rebuild_line`. Both writes go through it identically, and the
decision is

```c
int old_start = old_nom - PF_COMMIT_LEAD;      /* narrow: 26 - 3 = 23 */
int pin = (from >= old_start) ? old_nom : -1;
```

The HSCROL writes land at cycles 16 and 17, so `from` is 17 and 18 — BOTH below
23, both giving `pin = -1`, both rebuilding the whole line from the new HSCROL.
Identical by construction, which is exactly the symptom. The DMACTL pair works
because those writes straddle a boundary this rule does happen to place
correctly.

So the missing piece is not another value for `PF_COMMIT_LEAD` — that is
already disproved as the lever, and a binary commit/don't-commit test cannot
produce a ONE-unit shift anyway.

### Two attempts, both parked ON, both landing nowhere

**A rate-based clamp** (`HSCROL_CLAMP`, `HSCROL_REACH`). If a write one cycle
later yields one unit less scroll, the obvious rule is that the beam takes the
scroll away a unit at a time: `hscrol_eff = min(written, REACH - cycle)`, with
`REACH = 25` giving 8 for the early write and 7 for the late one. It does
exactly that — the probe confirms `hscrol_line` coming out 8 and 7 — and the
measured stride does not move.

Sweeping `REACH` says why, and it is rule (v): **no value of HSCROL can produce
the wanted 17.**

| effective HSCROL (late case) | stride |
|---|---|
| 0, 1 | 12 |
| 4, 5, 6, 7, 8 | 16 |

Our stride quantises in steps of FOUR where the test resolves single units, so
the resolution is missing upstream of the value, not in the value.

**Colour-clock display resolution** (`HSCROL_CC_DISPLAY`). Part of that
upstream: `antic_pf_nominal` folds HSCROL in as `hscrol >> 1`, which is right
for the FETCH GRID — half a machine cycle per unit, as `make dma` reports — and
throws the odd colour clock away for the DISPLAY, where a unit is a whole
colour clock. Odd HSCROL values are therefore indistinguishable from the even
one below them. Computing the display start as
`2*(nominal_at_0 + LEAD) - hscrol` fixes that, looks right on its own terms,
and changes no test.

Both are left in behind flags, both OFF (rule o), because neither is confirmed
by an assertion.

### And the display is not the lever either

`HSCROL_CC_DISPLAY` does exactly what it claims. Tabulating `antic_pf_at`'s
class across the probe's colour clocks in mode 6 narrow, one row per HSCROL:

```
              cc120 .............. cc140
OFF  hscrol 5  1...1...1...1...1...1
     hscrol 6  ..1...1...1...1...1..
     hscrol 7  ..1...1...1...1...1..     <- 6 and 7 identical
     hscrol 8  1...1...1...1...1...1     <- 8 back to 5's phase

ON   hscrol 5  ...1...1...1...1...1.
     hscrol 6  ..1...1...1...1...1..
     hscrol 7  .1...1...1...1...1...
     hscrol 8  1...1...1...1...1...1     <- every unit its own clock
```

Off, odd HSCROL values are invisible; on, each unit moves the pattern exactly
one colour clock. The resolution really was missing and really is restored.

It changes no assertion. All four combinations of the two flags leave
`antic_pfstarttiming`'s late case at 16, and re-running the reachability sweep
with the resolution ON gives stride 16 for effective HSCROL 1, 3, 5 AND 7 — the
value is now MORE uniform, not less.

So, decisively (rule v, third time): **the wanted 17 is unreachable through the
HSCROL value and unreachable through the display start.** Neither is the lever.

That points at the FETCH, and the test's own word for what it measures says so —
"stride", which is exact (rule f), not a display edge but how far the row's scan
address advanced. What must differ by one between the early and late cases is
the NUMBER OF BYTES the row fetches, which is `rebuild_line`'s map and byte
count, not `antic_pf_at`'s window. `antic_pfstoptiming` is consistent with that
reading: its HSCROL cases want 21 and 20, the opposite polarity to
`antic_pfstarttiming`'s 16 and 17 (rule i), which is what a fetch COUNT does
when a window is widened from one side rather than the other.

### ...and the fetch count is not the lever either. PARKED.

Tabulated with a scratch harness against `antic_dma_line_map` before building
anything (rule v), writing HSCROL `$08` at each cycle of the row's first line:

```
  write at  -1 (none)  -> fetches 16
  write at  10 .. 22   -> fetches 20
  write at  23, 24     -> fetches 19
```

Cycles 16 and 17 sit in the middle of a flat run. The count DOES change, but at
23, and the change is not the commit pin: giving HSCROL its own commit lead
(`HSCROL_COMMIT_LEAD`, so its boundary can sit between 16 and 17 independently
of DMACTL's) moves nothing at all — the boundary stays at 23 for every lead.
What actually changes the count there is simply how many of the new window's
fetch slots are still in the future, which moves in WHOLE SLOTS, four cycles
apart in mode 6 narrow. It can never separate two adjacent cycles.

So four levers are now disproved by direct measurement:

| lever | why it cannot work |
|---|---|
| `PF_COMMIT_LEAD` / any binary commit test | a binary test cannot yield a ONE-unit shift (rule ii) |
| the effective HSCROL value | 17 unreachable for any value, with or without the display fix |
| the display start | all four flag combinations leave the late case at 16 |
| the fetch count | flat across cycles 10..22; changes only in whole slots |

**Parked.** Three tests share the idea and it is worth real money, but four
measured dead ends say the missing mechanism is not any quantity currently in
the model — it is something that distinguishes two ADJACENT machine cycles in a
row that is already running, and nothing we compute has that resolution. The
next person should start by asking what in ANTIC could possibly be sampled at
colour-clock rather than machine-cycle granularity during a scrolled row,
because that is the only kind of thing left that could tell 16 from 17.

`HSCROL_COMMIT_LEAD` is left in place (defaulting to `PF_COMMIT_LEAD`, so no
behaviour change) because it costs one `#define` and makes the next attempt at
the split cheaper than re-deriving it.

`antic_pfstoptiming` fails on its own HSCROL early case (19 where 16 is wanted)
and `antic_hscrolbug` on "Unstopped PF DMA", so all three are almost certainly
one idea.

## antic_virtdma: a playfield slot that latches the CPU's bus byte

Never examined before, and it decodes in one step. Four consecutive scanlines
each end with a `lda abs` from a different address, and nothing else about them
differs:

| scanline | instruction | wanted pattern |
|---|---|---|
| 33 | `lda $0100` | `$00` |
| 34 | `lda $5000` | `$05` |
| 35 | `lda $c000` | `$0c` |
| 36 | `lda $f000` | `$0f` |

The wanted value is the HIGH NIBBLE OF THE ADDRESS. `lda abs` is `AD lo hi`, so
its third cycle fetches the operand's high byte — `$01`, `$50`, `$c0`, `$f0` —
and the test's own cycle map marks that cycle "(sampled by playfield DMA)". The
patterns are read back through four missiles parked along the right border at
`$da`..`$dd`, one colour clock each, so the nibble is read out of the playfield
by collision.

So: **one playfield DMA slot per line is VIRTUAL.** ANTIC accounts for the slot
and clocks its line buffer, but does not drive the bus, so what lands in the
buffer is whatever the CPU's own access put there. Its map comment marks that
slot `V` where the real fetches are `C` and refresh is `R`.

That is the same rule as `gtia_phantomdma`'s — a latch taking the DATA BUS
rather than a fetch — and half of it is already written down here: killing
playfield DMA mid-line does not stall the line buffer, "ANTIC keeps clocking it
and latches whatever is on the bus", which `antic_linebuffering` deliberately
does not check ("from the bus, but we don't test that yet"). `antic_virtdma` is
the test that does check it.

We produce `$00` for all four patterns, which is why pattern #1 passes and #2
fails immediately: the buffer holds memory content, never the bus byte.

### Its comment is also the only map we have for WIDE playfield

The test documents the DMA pattern it expects, and decoding that comment gives
fetches at cycles 14, 18 ... 102, refreshes at 25, 29 ... 57, and one `V` at
**106**. Ours, tabulated for the same geometry (mode 7, wide, HSCROL 2,
scrolled):

```
  test  ...C...C...C..RC..RC..  ...  ...C...V.......   23 fetches + 1 virtual
  ours  .R....RR.C..RC..RC..RC  ...  ..RC..R.........  24 fetches at 9,13..101
```

Two differences, and the first one matters beyond this test: **`ANTIC_WIDE` is
not covered by any validated table.** `antic_dmapattern`'s testdata — the source
of `acid_dmatable.h` and of `make dma`'s 50/50 — contains only `narrow` and
`normal` rows. The wide window's phase has never been checked against anything,
and `antic_virtdma`'s comment is the one independent measurement of it.

Against that measurement our wide fetches sit one cycle early: dropping our
prefetch at 9, ours run 13, 17 ... 101 where the test has 14, 18 ... 102.
`PF_WIDE_ADJ` exists to shift them and with it at 1 the last real fetch lands on
102, exactly as the test has it.

It is NOT sufficient on its own and is left at 0. Shifting the phase also moves
the fetches through the refresh region, and there ours come out at 27, 31, 35
where the test has 26, 30, 34 — so our refresh-versus-fetch arbitration for wide
differs as well, and one constant will not fix both.

The second difference is the point of the test: the test's 24th slot, at 106, is
the VIRTUAL one, and we do not schedule it at all. That slot is the "scrolled
row fetches one width step more" extra — and the test's execution trace shows
the CPU keeping cycles 104, 105 AND 106, so **the virtual slot does not steal a
cycle**. It only clocks the line buffer, which latches the bus.

### PF_WIDE_ADJ = 5 aligns fifteen of the twenty-four slots

Sweeping the phase against the test's map, `PF_WIDE_ADJ = 5` gives

```
  test   14 18 22 | 26 30 34 38 42 46 50 54 58 | 62 66 ... 102 | V 106
  ours   14 18 22 | 27 31 35 39 43 47 51 55 59 | 62 66 ... 102 |   106
```

The first three and the last twelve match EXACTLY, including a slot at 106 where
the test puts its virtual one. Only the nine inside the refresh region differ,
each by one: ours are displaced because our glyph fetch sits one cycle before
the name and collides with refresh, where the test's name fetches stay uniform.
(The test's map marks one slot per character and does not show glyph fetches at
all, so it cannot arbitrate that directly — but a displaced name fetch would
have shown up in it, and does not.)

`PF_WIDE_ADJ = 5` is SUITE-NEUTRAL: with it the score stays 47 and the only line
that changes anywhere is `antic_virtdma`'s own cycle count. That is exactly what
"wide is unvalidated" predicts, and it means the constant is safe — but safe is
not proven, so it stays at 0.

### The virtual slot and the bus latch are built, and do not move it

Behind `VIRT_DMA`: the line's last playfield slot is un-blocked (so it does not
steal the cycle, matching the test's trace of the CPU keeping 104, 105 AND 106)
and the line buffer takes `antic.bus_byte`, which `system.c` now keeps fresh
alongside `last_bus`. The byte goes into the GLYPH rather than the name, because
the missiles sit over four PIXELS of that character and in mode 7 a pixel is one
colour clock — four bits of the glyph byte, the top four, which is the high
nibble the test asserts.

All of it still reports `$00`, and the reachability check that should have come
first was skipped. Run properly, it inverts the assumption behind the phase
work:

| `PF_WIDE_ADJ` | display start | character index at cc `$da` |
|---|---|---|
| 0 (default) | 30 | **23** — the virtual slot, but its LAST four pixels |
| 1 | 32 | 23 |
| **2** | **34** | **23, and `$da` is its FIRST pixel** |
| 3 | 36 | 22 |
| 5 (the DMA-map fit) | 40 | 22 — off the virtual character entirely |

Character 23 is the last of the twenty-four, so it IS the virtual slot, and the
test reads the HIGH nibble — the character's first four pixels. Only
`PF_WIDE_ADJ = 2` puts `$da`..`$dd` there. **The value the DMA map argued for, 5,
moves the probe off the virtual character altogether.**

So the fetch schedule and the display window do not want the same phase, which
is a real finding in itself and says the two are related by something other than
`PF_DISPLAY_LEAD`.

### Why the latch almost never fires

With `PF_WIDE_ADJ = 2` and `VIRT_DMA = 1` it still reports `$00`, and a probe on
the latch itself (`ACID_GLYPHPROBE=7`) says why in one line:

```
  VIRT sl  32 cyc 103 idx 23 <- $00
```

ONE latch in the entire run, on scanline 32 — the mode 7 row's FIRST line. The
test measures scanlines 33 to 37. Our line map carries name fetches only on a
row's first line (ACID800's own DMA table has the same split, its `a` rows
against its `b` rows), so `pf_at` is empty on every later line and `virt_cyc`
comes out -1.

### SOLVED

Three things, each one measured before it was built.

**The virtual slot on a row's LATER lines.** Tabulating the map for
`first_line = 0` shows zero name fetches and glyph slots at 12, 16 ... 104.
Refresh is long finished by then, so the last blocked cycle of such a line IS
the last glyph slot, and that is the virtual one. The test's display list is
`$57` — a sixteen-line mode 7 row — and it reads scanlines 33..37, all later
lines, which is why the first-line path never fired for it.

**`PF_WIDE_ADJ = 2`, and it is the LATER-line map that fits.** With it, those
glyph slots land at 14, 18 ... 106 — exactly the map in the test's own comment,
virtual slot at 106 included. The earlier fit of 5 was against the FIRST-line
map, the wrong variant, and 5 moves the probe off character 23 altogether. Two
independent measurements now agree on 2: this one, and the display alignment
that puts colour clock `$da` on character 23's first pixel.

**The latch must run AFTER its own cycle's access.** At tick time the CPU has
not made its access yet, so the bus still holds the PREVIOUS cycle's byte — we
latched `$00` where the trace plainly showed `$50` arriving one cycle later:

```
  BUS sl  34 cyc 104 CPU-R $2082 -> $AD
  BUS sl  34 cyc 105 CPU-R $2083 -> $00
  BUS sl  34 cyc 106 CPU-R $2084 -> $50      <- and the slot is cycle 106
```

So `antic_virt_latch()` is called from the bus path, not from `antic_tick()`.
That is the same rule the phantom P/M latch needed, and it was already written
down here — worth reaching for sooner next time.

**WIDE only.** Un-blocking the last playfield cycle on every line costs
`antic_dmapattern` and `antic_linebuffering`, whose narrow and normal geometries
the DMA table says ARE blocked there. One test up, two down until the gate went
in — rule (gg) again.

The `dma` gate had to be CORRECTED, not obeyed. It asserted a width step of 8 in
both directions, but only narrow->normal is in ACID800's table; normal->wide was
a derivation by symmetry, and it is **6**.

47 -> 48 of 63, and the only line that changes anywhere in the suite is
`antic_virtdma` itself.

## gtia_pmoverlap is not a colour test at all

It has been carried as "needs a colour/priority model that does not exist" for a
long time. Reading it, that is simply wrong — and the label alone was enough to
keep it untouched.

Its structure: twelve passes, each setting a different `SIZEP0` and a different
missile start position, with `GRAFP0 = $81` — bits 7 and 0, the player's two
EDGE pixels — and four missiles at consecutive positions. For each pass it
sweeps the player's HPOS from `$64` to `$7f`, and at each position assembles
`m0pl`..`m3pl` into an index, looks that up in a shift table and compares.

So it measures, for every width and every position, exactly which missile the
resized player's edge bits land on. That is not colour or priority; it is the
same question `gtia_pmresize` asks, asked over a wider grid — the SIZEP
divider's exact bit positions. The two almost certainly share a root cause, and
`gtia_pmresize`'s own blocker is the WSYNC question below.

Ours fails at pass 3, `Y = $65`, wanting `$70` and getting `$00` — no missile
collisions registered at all where hardware sees a pattern.

### What its expected curve says: the player is RELOCATED, not restarted

Pass 3 is `SIZEP0 = $03` (quad) with the missile block at `$78`..`$7b`, and its
table (`wide_data_4`, indexed by `Y eor $60`) gives, for the even-`scanpos`
half:

| `Y` | expected index | missiles hit | lit clocks implied |
|---|---|---|---|
| `$64` | 0 | none | — |
| `$65` | 7 | m1, m2, m3 | `$79`, `$7a`, `$7b` |
| `$66` | 3 | m2, m3 | `$7a`, `$7b` |
| `$67` | 1 | m3 | `$7b` |

The missiles only see `$78`..`$7b`, so what this actually shows is a lit region
whose LEFT EDGE is `Y + $14` and which continues to the right. Twenty colour
clocks is five bits of a quad player, so the lit thing is the player's bit
INDEX 5 counted from `Y`... except `GRAFP0 = $81` has only bits 7 and 0 set,
which are indices 0 and 7. Index 5 is clear and cannot be lit.

It resolves if the mid-line `sty hposp0` does NOT restart the player. Suppose
the shift register keeps its bit counter and the new HPOS only says where the
REMAINING bits are drawn. Then the lit bit 0 — index 7 — lands at `Y + 4*(7-j)`
where `j` is the bit index reached when the write landed, and the observed
`Y + 20` gives `j = 2`.

**And it does not survive the full table either — DISPROVED.** It is worth
being exact about which part is evidence and which is inference. `Y = $64` with `j = 2` puts
the lit bit at `$78`..`$7b` — all four missiles — index `$F`. The table says 0.
So a uniform "relocate keeping the bit index" cannot be the whole rule either:
something makes `$64` behave like no relocation at all while `$65` onwards
relocate. The three rows `$65`, `$66`, `$67` are consistent with each other and
with `j = 2`; the `$64` row is the one that says the mechanism has a THRESHOLD
in it, most likely the beam position at which the write lands relative to the
new HPOS.

**So a mid-line HPOS write RELOCATES a player that is already drawing, rather
than retriggering it from bit 0.** Our `obj_step` does the opposite: any match
against the live HPOS sets `bit = 0`. Tabulated on `gtia.c` alone, ours puts the
quad player at `$65`..`$68` and `$81`..`$84`, which misses the missile block
entirely — exactly the `$00` observed.

This is not a contradiction of `gtia_pmretrigger`, which passes today: a match
may well still start an object that has NOT yet begun this line. The two rules
differ only for an object caught MID-DRAW, which is what `gtia_pmoverlap` sweeps
and `gtia_pmretrigger` does not. Implementing it needs that distinction kept, and
`gtia_pmresize` is the same family — a mid-draw SIZEP change, where the question
is again whether the object restarts or carries on.

## WSYNC RMW: two more mechanisms ruled out

**Write timing cannot explain it.** In `antic_wsync` both sequences put their
LAST write on the same cycle: `sta wsync` writes at cycle 2, and `inc wsync`
writes at 1 AND 2. Same last write, same halt point, and yet the following
instruction resumes one cycle later after the INC. So no rule of the form "the
halt begins when the write lands" can produce the difference, which is why
`wsync_extra` — "the CPU is charged for the cycle it took while halted" —
remains the simplest expression of the measurement even though it is not a
mechanism.

**`gtia_pmresize` is not compensating for a GTIA phase error.** Sweeping
`GTIA_CC_ORIGIN` 4..8 with the correct WSYNC model leaves its 4x-to-1x block
failing at every value (rule v). Whatever `WSYNC_RMW_EXTRA=0` is buying that
test, it is not a colour-clock offset.

## The RMW's read of WSYNC: disproved, and what it turned up

`inc wsync` is read, write-old, write-new, and both tests that disagree about
the release use it — so the READ's timing is the one thing that differs between
them (cycle 0 for `antic_wsync`, ~31 for `gtia_pmresize`). `WSYNC_READ_ARMS`
tests whether the read arms the halt in its own right.

It does not. Turning it on breaks `antic_wsync` — but on an assertion that had
never come up before, "Late INC WSYNC", and that one is worth having:

```
206A 2C 00 01  bit $0100   ;95-98
206D EE 0A D4  inc wsync   ;99-104     <- read at 102, writes at 103 and 104
```

Its `inc wsync` STRADDLES the release point: the first write lands at 103 and
the second AT 104. So `antic_wsync` pins three INC cases, not one — writes at
1/2, and writes at 103/104 — and our model satisfies both today. Any replacement
has to as well, which kills most of the simple reformulations.

### Which reopens whether the WSYNC conflict is real at all

Collecting every INC in the suite:

| test | write pair | wants |
|---|---|---|
| `antic_wsync` early | 1, 2 | extra |
| `antic_wsync` late | 103, 104 | extra |
| `pokey_noise` | 11, 12 and 113, 0 | extra |
| `antic_dlitiming` | 5, 6 / 96, 97 / 109, 110 | extra |
| `gtia_pmresize` | 32, 34 | **no extra** |

One outlier out of five, and it is the test whose OTHER problem we now
understand: `gtia_pmresize` changes SIZEP mid-line, which is exactly the
mid-draw object question `gtia_pmoverlap` has just shown we get wrong. If our
objects restart where hardware relocates, its geometry is wrong independently of
WSYNC — and shifting the whole line by one machine cycle moves the player two
colour clocks, which could easily line one block up by accident and then fail
the next. That is precisely what `WSYNC_RMW_EXTRA=0` does: the 4x-to-1x block
passes and the failure moves to 4x-to-2x.

So the working hypothesis is now that there is NO WSYNC conflict — that
`wsync_extra` is right, and `gtia_pmresize` was never evidence against it. The
way to settle that is to fix the mid-draw object first and re-test, not to keep
looking for a discriminator between five tests and one.

## The mid-draw object: measured, modelled, and disproved on the full table

The mid-line `sty hposp0` lands at ANTIC cycle 48 — colour clock `$66` — with
`HPOSP0 = $60` written back at cc `$14` each line (`ACID_COLPROBE`). That turns
the pass-3 rows into arithmetic rather than a fit, and a clean mechanism drops
out of it:

**An HPOS write repositions the player but never RELOADS its graphics shift
register.** GRAFP0 is a shift register, not an indexed array: bits already
clocked out are gone. Restarting at `Y` therefore emits whatever is left, so the
lit bit 0 appears five bits along — `Y + 20` for a quad player — which is
exactly the left edge the table shows, with no need for a bit index that GRAFP0
does not have set.

With the write taken as live at cc `$65` rather than `$66`, all four of pass 3's
first rows come out right: 0, 7, 3, 1.

**And that is as far as it goes.** Checked against every cell of the test — 12
passes x 2 missile positions x 28 player positions = 672 — it matches 330. The
four-row agreement was coincidence. Failures are spread across every pass, from
4/28 to 28/28, so this is not an edge case needing a tweak; the shape is wrong.

Rule (tt) is what saved this one: the same reading was written up two commits
ago as fitting "every row" on the strength of four, and this time it was scored
before any code was written.

`tools/pmoverlap-check.py` now scores an arbitrary model against all 672 cells
in about a second, with the geometry documented at the top. It carries a
leaderboard rather than one model, so the next attempt starts from evidence:

```
  noreload  322/672      repositions, never reloads the shift register
  restart   624/672      retrigger from bit 0 — WHAT gtia.c DOES TODAY
  union     634/672      a match ADDS an emission, leaving running ones alone
```

### Our current model is nearly right, and misses in four places

`restart` is what `gtia.c` implements, and it is not a poor model — 624 of 672.
The 48 misses are not spread: they sit in exactly four (pass, scanpos) cells,
`p3/$78` (15), `p3/$7c` (21), `p7/$6c` (9) and `p10/$64` (3).

`p10` is the one that explains itself. It wants 9 where we give 8: the missile at
`$67` should be hit and is not. In normal size the player at `$60` puts its lit
bit 7 exactly at `$67`, and the new emission at `$64` puts its lit bit 0 at
`$64`. Hardware registers BOTH. A single-emission model cannot — retriggering at
`$64` cancels the run that would have lit `$67`.

So a match does not cancel the emission in progress; it starts another one
alongside. That is the well-known Atari artefact of a player appearing twice
when it is moved mid-line, and scoring it gives **634/672** — ten better than the
current model, and the reason to prefer it is the mechanism rather than the ten.

Still not 672. And the 38 that remain are not spread: they sit entirely in
passes 3 and 7.

### The second effect: the write RE-ALIGNS the running emission's divider

Pass 3's wanted values cycle `7, 3, 1, 0` as Y advances — period FOUR, the quad
width. A period in Y means a bit BOUNDARY moving with Y, so the running
emission's divider boundaries shift to line up with the newly written position
while its bit counter keeps counting. Worked through by hand for pass 3, every
row falls out; scored, it takes that pass from 33 misses to 3 and the whole test
to **660/672**.

```
  noreload       322/672
  restart        624/672     what gtia.c does today
  union          634/672     a match ADDS an emission
  union_realign  660/672     ...and the write realigns the running one
```

The two effects are independent, which is the good kind of evidence: `union`
alone gains 10 and fixes `p10`'s two-emissions cell, `realign` alone is what
pass 3's period-4 repeat demands, and together they gain 36.

**Not implemented — 660 is not 672, and the test needs every cell.** Putting it
in `gtia.c` would gain no ACID800 pass while risking the P/M tests that do pass.

The residual 12 has a shape worth recording: pass 3 `sp $78` at Y `$7d`..`$7f`
(we light where hardware does not) and pass 7 `sp $6c` at odd Y (we light one
clock too many). Both are us lighting MORE than hardware, so the missing piece
SUPPRESSES rather than adds — an emission being cut short or refused, not
another one starting.

One process note: the first version of the realign scored 615 and looked
disproved. The bug was in the simulation, not the model — running emissions were
not advanced on the clock where a new one started. A model that contradicts a
hand derivation is worth re-reading the simulator for before it is discarded.

### PARKED at 660/672 — what the source says, and what is disproved

Read gtia_pmoverlap's SOURCE (which had never been read; only the scorer had
been run). Player 0 sits at `$60` with `GRAFP0 = $81` — bits 7 and 0 lit — and
`SIZEP0` from a 12-entry pass table; mid-scanline `sty hposp0` rewrites HPOSP0
to Y (`$64..$7f`); four missiles parked at sp..sp+3 read back `m0pl..m3pl`,
packed `lda m0pl / asl / ora m1pl / asl / ora m2pl / asl / ora m3pl` so bit 3 is
the missile at sp. 12 passes x 28 Y x 2 phases = the 672 cells. It skips its
first four lines deliberately, "to avoid tripping on a one-cycle delta in HPOSPx
deadline on different machines".

The residual is 12 cells, and the SAME 12 for every model that reaches 660.
DECODED from the packed patterns rather than described — which mattered, because
the earlier note in the tool said "one clock too many" and that was the wrong
sign:

* pass 7 (SIZEP 1, width 2) at sp `$6c`, odd Y: wants 3 = lit at `$6e,$6f`, we
  give 6 = lit at `$6d,$6e` — a boundary ONE COLOUR CLOCK EARLY;
* pass 3 (SIZEP 3, width 4) at sp `$78`, Y `$7d..$7f`: wants nothing lit there,
  we light a tail.

In BOTH, hardware's lit pixel is exactly where the UNREALIGNED old emission's
k=7 falls (`$6e,$6f` at width 2, `$7c-$7f` at width 4) — so hardware is not
re-phasing the old run in these cells. But plain `union`, with no realign at
all, scores only 634, so the realign is standing in for something real
elsewhere. Only 2 of 12 passes fail, each at only ONE of its two missile phases,
and no SIZEP-0 pass fails: a width>1 effect tied to where the boundary lands.

DISPROVED, with scores, so none of these is retried:

| model | cells | what it says |
|---|---|---|
| `noreload` | 322 | never reloads the shift register |
| `shared_divider` | 476 | one free-running divider per player, bit counter reloads |
| `realign_stopatwrite` | 580 | old run ends at the HPOS write |
| `realign_off_±1/±2` | 606/616 | a global off-by-one in the realign amount |
| `realign_killold` | 612 | old run ends when the new one triggers |
| `restart` | 624 | what gtia.c does today |
| `union` | 634 | both runs, no realign |
| `union_realign` | **660** | best known |

Two of those are worth keeping in mind. `realign_killold` and
`realign_stopatwrite` are both clearly WORSE than union, so **the old emission
genuinely survives the re-trigger** — "one shift register per player" is the
wrong picture. And the offset sweep is symmetric (616, 606, [660], 606, 616), so
by rule (v) the alignment is right at 0 and the error is upstream of it.

Three iterations went in without beating 660. Parked in favour of
`pokey_timertiming`, whose source has never been read — and reading a test's
source has now twice produced more than any sweep did.

Searched the suppressing family the residual pointed at — a cap on how many
emissions can be live (1, 2, 3, unlimited), killing the running one when a new
one starts, and applying the realign to all / newest / oldest — across write
instants `$63`..`$65`. Twenty-four combinations, and **every one of the top
scorers is 660**. The plateau is flat: none of those levers touches the last 12
cells at all.

That is rule (v) at model level. The last 12 are not a parameter of this family,
so the next attempt needs a different kind of mechanism, and there is no cheap
way to guess which. Two mechanisms are established and written down, the scorer
makes any future candidate a one-second test, and the residual's shape (we light
MORE than hardware, in exactly two pass/scanpos combinations) is recorded.

Worth being plain about the economics: `gtia_pmoverlap` needs all 672 cells, so
660 is worth exactly zero ACID800 passes. Several iterations have gone into it
and the last one bought nothing. The remaining open work — this, the HSCROL trio,
`pokey_timertiming` — is all in the same condition: understood in outline,
resistant in detail, and expensive per unit of score.