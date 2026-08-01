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
  scanline and its later ones.
* **ANTIC DMA schedule: 50/50**, timing core, display-list execution and line
  buffer all in; **GTIA collisions** in.
* **The real ACID800 binaries run**: `make acid` → 42 pass / 12 fail / 4 jammed
  / 1 looping / 4 skipped, of 63. Recorded on the conformance dashboard beside
  the fabric sweeps — `python3 docs/a800/from-emu.py --note "..."`. Not directly comparable to the fabric's 33/63:
  that runs on hardware with a full POKEY and an OS ROM, whereas POKEY here is
  the RANDOM LFSR, the timers and the serial OUTPUT path only, and the five
  `mod_*` are menu-loaded modules that cannot run standalone at all. **Every
  `cpu_*` test passes.**

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

## The next structural gap: nothing renders pixels

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

## Open: gtia_pmresize, and a third WSYNC-anchored test

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

## Blocked on an OS ROM: antic_virtdma

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

## Resolved: the WSYNC release is cycle 103, and refresh is why it was unmeasurable

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

## Open: POKEY divider phase — the free-running tap is the wrong SHAPE

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


## PARTLY CLOSED: pokey_inittiming — the 64 kHz tap LEADS the 15 kHz one by two

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

## Open: the POKEY serial cluster needs an INPUT path

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


## Open: pokey_inittiming's two 15 kHz measurements disagree by one sled step

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
something to show once it shifts. The window POSITION still comes from the row's
own width, less HSCROL/2.

Measured rather than assumed: sweeping an "extra bytes" parameter 0..4 against
that assertion moved its answer 12, 13, 14, 15, **16** one for one, and 16 is the
wanted value. Four extra on a narrow mode 6 row is 16 -> 20, exactly normal's
count, which is what makes it a width step rather than a magic constant.

Caveat worth knowing: the extra is currently keyed on `hscrol != 0`, because
`antic_dma_line()` is handed the VALUE and not the row's scroll bit. Real ANTIC
widens whenever the bit is set, HSCROL = 0 included. No test in the suite
distinguishes them yet.

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


## Open: gtia_pmresize reads ZERO player-to-player collisions

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

`pokey_timertiming` now clears its whole 8-bit group and fails further in, on
**"1.79MHz 16-bit lo timer triggered too late"** — the linked pair fires late,
which was invisible until the 8-bit case passed. Our fast linked period is
`AUDF16 + 7`; that constant is the next thing to bound.
