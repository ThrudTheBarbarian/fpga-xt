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
* **ANTIC DMA schedule: 50/50**, timing core, display-list execution and line
  buffer all in; **GTIA collisions** in.
* **The real ACID800 binaries run**: `make acid` → 11 pass / 38 fail / 9 jammed
  / 2 looping / 3 skipped, of 63. Not comparable to the fabric's 32/63 — that runs on hardware with a
  full POKEY and an OS ROM, whereas POKEY here is only the RANDOM LFSR, the five
  `mod_*` never halt, and OS-dependent tests hang because `_SKIP` needs the OS.
  Every `cpu_*` test that completes passes.

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

## Open: antic_dmapattern measures the DMA pattern LIVE

Now that POKEY starts out of poly init (the runner seeds it, since this test
never writes SKCTL), `antic_dmapattern` decodes its random pair and runs to a
real assertion instead of spinning. It reports **"Incorrect timing for mode 2-a"**
— read that off d1 = $02 and d2 = $61 = 'a'; the message string the runner prints
for this one is garbage, because the failure arrives through a path that has no
inline text.

The interesting part: `make dma` matches ACID's own DMA table 50/50, so the
tabulated pattern is right. This test measures the pattern **live**, by timing
RANDOM, so it is checking something the table cannot — when each cycle is
actually taken, not merely which ones. Mode 2 variant 'a' is where it first
disagrees.

The LFSR-decode technique applies directly here: the test reads RANDOM either
side of a DMA burst, so a wrong value converts to an exact cycle count.

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

## Open: a recurring ONE CYCLE early in the post-WSYNC instruction stream

Three tests now fail the same way, and it is not the release cycle:

* `antic_vcount` d2 — `sta wsync / bit $0100 / lda vcount`, annotated so the read
  lands on cycle 111. It lands on 110.
* `gtia_pmretrigger` #2 — its `sta hposp0` lands on CPU cycle 28 where the
  annotation says 29, so the player misses its trigger at $40.
* `antic_dlitiming`'s "Even count".

The release itself has been re-swept with everything else in place —
102/103/104/105 score 29/31/30/29 — so 103 stands, and `antic_wsync`,
`antic_nmist` and `antic_vscroldli` all pass at it. What is one cycle short is
the instruction stream AFTER the release, in cases whose first instruction is
short: `bit $0100` (4 cycles) and `sta abs` (4), where the tests that pass open
with `pha:pla` (7).

That asymmetry is the clue worth chasing — something about the first instruction
after the halt, rather than about when the halt ends. Note also that the suite's
own annotations disagree with each other here: `antic_nmist`'s seven-cycle
`pha:pla` spanning 104..109 puts its first cycle at 103, while `antic_vcount`'s
four-cycle `bit $0100` spanning 105..107 plus an unnumbered first puts it at 104.

## Open: pokey_sertiming's two blocks disagree about the SEROUT take

SEROR and SEROC are both LEVELS (see the commit), which reconciled
`pokey_serclock` with `pokey_sertiming`'s second block and is settled. What is
left is that sertiming's own two blocks want opposite things from the SAME
228-cycle clock:

* **Block A** (`.lst` lines 135-145): reset SKCTL, `sta serout`, delay **195
  cycles**, read IRQST, expect `$00` — SEROC still ASSERTED, i.e. the shift
  register has NOT taken the byte. Fails as "loaded too early".
* **Block B** (lines 151-167): two WSYNCs, **STIMER**, reset SKCTL,
  `sta serout`, read IRQST immediately, expect `$08` — SEROC DEASSERTED, i.e. it
  HAS taken it. Fails as "loaded too late".

Both follow the same `audctl $78 / audf 228-7` and neither reconfigures it.
Measured: an immediate take passes serclock and block B and fails block A; a
tick-driven take passes serclock and block A and fails block B. Both score 34.
The immediate take is what is currently in, because it is what reconciled the
serclock contradiction.

The difference between the blocks is that **B does STIMER and A does not**, and
A relies on the free-running divider still having more than 195 of its 228
cycles left. So the resolution is probably about what STIMER does to the serial
clock specifically — if STIMER makes the shift register sample immediately, or
starts the bit clock in a state that takes the byte at once, both blocks work
with a tick-driven take. That is the next thing to test, and it is checkable:
block A must see NO tick in 195 cycles while block B sees one straight away.

**Tried, and partially right.** Gating the immediate take on "a STIMER has
happened since the last take" keeps `serclock` passing and moves the failure to
block A's "loaded too early" — i.e. block B is satisfied — but block A still
takes immediately, because the flag survives from a STIMER earlier in the test
and nothing has consumed it in between. So the flag is too coarse: what matters
is presumably how far the serial divider is from its next tick at the moment
SEROUT is written, not merely whether a STIMER has ever occurred. Reverted; the
committed state is the plain immediate take at 34.
