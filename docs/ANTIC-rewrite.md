# ANTIC rewrite — plan

**This is a reset.** The Atari display path is being rebuilt from the constraint
set upward, with ANTIC as the bus master. No ANTIC/GTIA RTL carries over.
Decided 2026-07-30.

## Why the old way did not work

The port was built CPU-first: a fast 6502, then ANTIC attached to service it.
That is backwards for this machine. ANTIC *is* the bus master — it gates the CPU
clock, steals cycles, and drives the whole 1.79 MHz cadence.

Two symptoms, one root cause:

**Correctness.** ~14 of 26 remaining ACID800 failures are the same shape: a
register changed *partway along a scanline*. The compositor decides an entire
row's pixels, P/M overlay and colour at one instant, so it cannot express that at
all. Every fix became a per-register reconstruction of beam time — `early`/`chg_x`
for SIZEP, the same again for HPOSP, a separate collision engine, shift registers
inside that. Four mechanisms, each re-deriving what a beam-walking design gets
for free. The tell: the compose instant had to be **tuned** — cycle 110 landed
after `gtia_pmretrigger`'s read, cycle 96 sits between its write and its read.
Choosing an instant that happens to fall inside one test's window is a
coincidence, not a model.

**Area.** The 7020 is a hard stop. The design is **97.3% slice-occupied** (12,939
of 13,300) with 1,685 control sets, while LUTs sit at 56% and registers at 39%.
A perfectly packed design of this size needs ~7,500 slices — ~73% is packing
overhead. Congestion, not logic depth, is why 4 of every 6 builds miss the timing
gate on changes unrelated to the failing path.

Both come from the same mistake: **wide parallel logic evaluated per pixel.**

## The governing rule: serial, not parallel

At 1.79 MHz against a 100 MHz fabric there are **~56 fabric clocks per machine
cycle**, and **~28 per colour clock**. Every effect only has to be correct at the
1.79 MHz boundary, so anything ANTIC or GTIA does may be spread across those
clocks.

**Deep parallel logic is prohibited.** One shared datapath, walked, beats N
replicated evaluations — always. Per colour clock the budget looks like:

```
  1 clk    playfield source from the shifter
  8 clks   step each object's shift register in turn through ONE
           comparator, accumulating presence into a register
 ~8 clks   priority walk — visit objects in PRIOR order, first hit wins;
           collisions accumulate free, since each object is visited anyway
 ------
 ~17 of ~28 available
```

One object-evaluation datapath instead of eight. One priority comparator instead
of a resolution tree. Shift registers remain — they are *state*, which is cheap
and packs well — but the logic around them collapses by roughly 8×.

Every module in this rewrite states its per-colour-clock clock budget in its
header. A module that cannot say how many clocks it uses is not finished.

## The complexity smell test: ANTIC was ~2000-3000 transistors

**This is a diagnostic, not a budget.** We are not trying to fit in 3,000 gates —
an FPGA spends resources completely differently, and some things we need had no
1979 analogue at all. The message is narrower and more useful:

> If modelling an ANTIC or GTIA behaviour needs a big complicated structure, we
> have probably missed the mechanism.

Why that carries weight: ANTIC's architectural state alone is ~127 bits, which as
NMOS latches is most of the transistor budget. Whatever logic remained was on the
order of a few hundred gates — a counter chain, some comparators, a small decode
PLA, and a shift register with a variable rate. Every behaviour those chips
exhibit *emerges from that*, so a faithful model should be able to emerge from
something similarly small. When ours doesn't, that is information.

**Worked example — the sixteen "modes" are not sixteen cases.** ANTIC could not
afford sixteen decoders, so it doesn't have them. The mode nibble selects a few
parameters:

* bits per pixel (1 or 2)
* colour clocks per pixel (1, 2 or 4)
* source: character (name fetch, then glyph lookup) or direct bitmap
* scanlines per row (1, 2, 3, 4, 8, 16)
* the mode-3 descender quirk

One small parameter table feeding **one** datapath. Our `pack_pair` is a
sixteen-arm case statement with per-mode windowing — that is the smell.

Likewise GTIA: four player shift registers, four 2-bit missile registers,
position comparators, a priority encoder, collision latches. A wide combinational
cone resolving every object per pixel is not something that chip could contain,
which is independent confirmation — arrived at from silicon rather than from a
timing report — that `color_resolver` is the wrong shape.

**Where the analogy does NOT apply.** These are legitimate, not missed mechanisms:

* the **line buffer** — ANTIC had none, it fed GTIA in real time into a CRT; we
  target a framebuffer, so a buffer is a real structural difference
* the **expander**, DDR traffic, clock-domain crossings, HDMI — no 1979 analogue
* **pipelining for fmax** where ANTIC ran comfortably at 1.79 MHz

So: apply the smell test to the *behavioural* modelling of ANTIC and GTIA. Do not
apply it to the plumbing that gets pixels to a modern display.

**Rule of thumb:** if the ANTIC/GTIA behaviour in a module cannot be described as
"a counter, a comparator, a shifter and a small decoder", stop and look for the
mechanism before writing more.

## What carries over: knowledge, not code

**No ANTIC/GTIA RTL is reused.** `compositor`, `color_resolver`, `gtia_stream`,
`gtia_pm_collide`, `antic_pf_serial` and `antic_top` are all replaced.
`antic_timing` is a **reference for facts, not a foundation** — its behaviour was
verified at cost, but it too contains parallel constructs (`cycle_type_c` is a
priority mux; playfield start/span are parallel tables) and must be re-derived
under the serial rule rather than lifted.

What survives is the hard-won *facts about the Atari*, carried as documented
constraints and as testbenches — never as implementation:

| Fact | Where it came from |
|---|---|
| Visible window `X_LO = -28`, `X_HI = 346`, and ACID pins **both** halves of the HPOS `$21`/`$22` edge | `tb_pm_collide` T7/T8 |
| Player model: shift register loads on HPOS match, advances at the SIZE rate, **reloads on a second match** | `gtia_pmretrigger`, `gtia_pmresize` |
| Mid-draw SIZE changes the advance rate only — emitted pixels stand | `gtia_pmresize` (`4x-to-1x`, `$80` not `$E0`) |
| Hi-res quirk: lit pixel displays as COLPF1 luma over COLPF2 hue, but collides as **PF2** | `antic_hiresbug`, `antic_charcontrol` |
| Playfield start 26/18/10 (char) and 28/20/12 (bitmap); span 96/80/64 | `antic_pfstarttiming`/`pfstoptiming` |
| Memscan wraps within 4K; DL PC wraps within 1K; JVB parks while DLIs keep firing | `antic_addresswrap`, `antic_dlistwrap` |
| VCOUNT increments at cycle 111; /RDY releases at 104; writes are RDY-immune | `antic_vcount`, `antic_wsync` |
| GTIA does not compare during vertical blank | `gtia_collision` |
| PM5 routes missiles through COLPF3; players never collide with themselves | `gtia_pm_collide` T5 |
| Refresh: 9 slots every 4 from cycle 25, blocked refresh **slips**, one still seeking when the next slot arrives is **dropped** | `antic_dmapattern` |

The testbenches encoding these carry over. The RTL beneath them does not.

## Target architecture

```
        ┌──────────────┐
   ┌───▶│ 64KB Memory  │
   │    └──────────────┘
   │            │
   │            ▼
   │    ┌──────────────┐
   │ ┌──│    ANTIC     │        anticClk (fast) gates cpuClk on DMA steals
   │ │  └──────────────┘
   │ ▼          │
┌──────────┐    ▼
│   6502   │  ┌──────────────────────┐
└──────────┘  │ ANTIC BRAM line buf  │  1 byte/pixel: RESOLVED Atari colour
              └──────────────────────┘
                       │
                       ▼
              ┌──────────────┐  Ctrl   ┌──────────┐
              │ANTIC expander│────────▶│ Blitter  │
              └──────────────┘         └──────────┘
                       │ Data                │
                       ▼                     ▼
                 ┌──────────┐         ┌─────────────┐     ┌──────┐
                 │   DDR    │────────▶│ Framebuffer │────▶│ HDMI │
                 └──────────┘         └─────────────┘     └──────┘
```

**Line buffer: one byte per pixel, the RESOLVED Atari colour.** Colour must be
resolved *in the line* — if the buffer held indices and the expander coloured
them later, mid-line COLPF/COLBK writes would be lost, which is today's bug moved
downstream. The palette is quasi-static, so the expander's colour byte → RGBA32
LUT is safe to do late, and a byte per pixel is a quarter of what RGBA32 costs.

**Expander** converts a line to RGBA32 into DDR on a line cadence, then blits a
completed screen during VBLANK (or double-buffers) so a new frame appears
seamlessly. Everything downstream of the framebuffer is unchanged.

## System-level keep / drop

Unrelated to the ANTIC path, but the area budget depends on it:

| Block | Lines | Decision |
|---|---|---|
| `xt6502f` (fid, slow) | 839 | **KEEP** — passes Klaus and the illegal-opcode tests. Slaved to the new ANTIC via `/HALT`. Rewrite only if that proves insufficient. |
| `xt6502` (turbo, fast) | 1,068 | **DROP** from the build; HDL retained for later. |
| `math_cop` | 535 | **DROP** — belongs to the fast CPU. |
| banking (`bank_xlat`, `banked_axi_reader`, `banked_page_cache`, `screen_bank`) | 1,379 | **DROP** — not needed for the slow CPU. |
| `xt_blitter` | 3,696 | **KEEP** — fundamental to XTOS. |
| `sprite_engine` + line cache | ~1,400 | **KEEP for now** — currently only the mouse pointer; revisit once slice pressure is re-measured. |
| HDMI / `plane_compositor` / `plane_fetch` / `vbeam` | — | **KEEP** — generic, carries the GEM desktop. |
| ANTIC/GTIA path (`antic_top`, `compositor`, `color_resolver`, `gtia_*`, `antic_pf_serial`, `antic_timing`) | ~5,300 | **REPLACE** — this rewrite. |

~2,980 lines dropped outright, ~5,300 replaced by something that should be
markedly smaller under the serial rule.

## Which tests hit which module

**See `docs/ANTIC-rewrite-tests.md`** — all 31 ANTIC and GTIA tests mapped to the
module that must satisfy them, with what each pins and what is already known
about each failure. **Read the row for a module before writing that module.**

## Test strategy

**Static first, no CPU.** Preload memory with a known display list and screen
data for one mode, run ANTIC, capture the line buffer, compare **pixel-perfect**
against a hand-computed expectation. Cheapest possible way to catch mode-decode
errors.

**Then ACID.** The tests are 6502 programs that write registers mid-line and read
results back, so they need a CPU — which is why the fid core stays.

**Test before code, per mode family.** Write the relevant ACID constraint as a
directed testbench *first*, then make it pass. The opposite of what happened
before, where tests were retrofitted and every fix became a bolt-on.

**The sim must be trustworthy**, or this just defers problems to hardware. Three
lessons already paid for:

* Count real assertions — never `grep -c "error|FAIL"`. An elaboration failure
  *lowers* that count and reads as progress ([[sim_pass_fail_counting]]).
* Drive stimulus on the **negedge**. Driving right after `@(posedge clk)` races
  the DUT and shows up as everything lagging one step — hit twice.
* Assert the ANTIC **authority bit** per test. A tooling bug that silently
  dropped it made three tests look non-deterministic for a day (HANDOFF 1n).

## Sequencing

1. **Line buffer + expander** — small, makes the pipeline observable end to end.
2. **Static mode tests** — MODE 0/2/F/8/E, pixel-perfect.
3. **Mode decode**, serial, one family at a time, each preceded by its ACID test.
4. **Playfield start/stop/HSCROL** — one per-colour-clock mechanism, three tests.
5. **P/M DMA fetch** hoisted to line start — unblocks `antic_pmdma`,
   `gtia_phantomdma`, and DMA-fetched shapes for the object walk.
6. **P/M geometry and collisions** — the serial object walk.
7. **Special modes**, then **DLI emission**, then the **DMA schedule** last.
8. **Drop** turbo, `math_cop`, banking; re-measure slice occupancy.

## Build status

Steps 1-4 are built and green. Thirteen modules, each with its own testbench in
`sim/`; run any of them with `make -C sim <name>`.

| Module | Testbench | What it owns |
|---|---|---|
| `antic_line_buf` | 7 checks | ping-pong scanline, one resolved Atari colour per pixel |
| `antic_expander` | 5 | line buffer -> palette -> RGBA32 -> DDR |
| `antic_mode_tbl` | 7 | the shape of all 14 display modes |
| `antic_pixel_shift` | 7 | the one shifter every mode uses |
| `antic_pf_source` | - | pixel value -> playfield source |
| `antic_color_sel` | - | source -> colour byte, including the hi-res trick |
| `antic_char_ctl` | 6 | CHACTL blank / invert / reflect |
| `antic_pf_fetch` | 11 | ANTIC's internal 48-byte line buffer, the scan pointer |
| `antic_line_render` | 10 | buffer -> shifter -> colour, paced by the beam |
| `antic_beam` | 6 | the counter chain and the cycle-111 VCOUNT advance |
| `antic_dl` | 10 | display list: 1K wrap, LMS, JVB, DCTR, VSCROL |
| `antic_pf_geom` | 7 | playfield start / stop / width / HSCROL |
| `antic_scanline` | 7 | the sequencer: all of the above, end to end |
| `antic_pm_fetch` | 5 | player/missile DMA, hoisted to line start |
| `gtia_obj_walk` | 7 | the serial object walk: 8 objects, one datapath |
| `gtia_priority` | 10 | the priority walk, all four orderings |
| `gtia_collide` | 8 | the sixteen collision latches |
| `gtia_stage` | 8 | one colour clock of GTIA, schedule measured |
| `gtia_special` | 9 | GTIA modes 9/10/11 colour decode |
| `antic_nmi` | 9 | NMIEN, NMIST and the /NMI line |
| `antic_dma_sched` | 50 maps | which machine cycles ANTIC takes from the CPU |
| `antic_reg_file` | 8 | ANTIC's registers, $D400-$D40F, and WSYNC |
| `gtia_reg_file` | 7 | GTIA's registers, $D000-$D01F |
| `antic_gtia` | 8 | the pair as one addressable block, driven over the CPU bus |
| `a8_core` | 3 | the fid CPU joined to the display chips |

Two structural decisions were forced by evidence rather than chosen:

* **Fetch is split from emit.** Emission is paced by the beam and stops when the
  display window closes; fetching must always consume `bytes_per_line` bytes so
  the scan pointer lands correctly for the next scanline. A scrolled narrow line
  fetches 40 bytes and displays 32 — coupled, the pointer drifts 8 bytes per
  scanline. This is also what the hardware does: `antic_hscrolbug` dumps the
  internal buffer's contents, so it demonstrably exists.
* **The DMA window follows the FETCH width.** Read out of `antic_hscrolbug`'s own
  cycle map, which shows a scrolled *narrow* mode E fetching forty bytes at
  cycles 20, 22 ... 98 — the *normal* window. The same map pins the display list
  fetch at cycle 1 and nine refresh cycles at 25, 29 ... 57, both of which the
  DMA schedule step will need.

Two bugs were caught by the testbenches rather than by hardware:

* On a **blank-line instruction bits [6:4] are the line count**, so the standard
  `$70 $70 $70` display-list opener has bit 5 set. Reading it as the VSCROL bit
  made the block after it believe it was closing a scroll region and end after a
  single scanline.
* The renderer's **emit strobes must be combinational**. Registered, the shifter
  advanced a clock after `px_val` was sampled, so pixel 0 of every byte was
  written twice and the whole line shifted by one.

### The GTIA stage, and why it is a pipeline

Object presence changes once per **colour clock**, but the playfield source
changes once per **hi-res pixel** — mode F has one pixel per hi-res pixel — so
priority resolves twice per colour clock. The first attempt did not fit:

```
  28 fabric clocks per colour clock at 100 MHz
   9   object walk (once per colour clock)
  10   priority walk for hi-res pixel A
  10   priority walk for hi-res pixel B
  ---
  29   over budget
```

Two cuts fixed it, and both made the circuit *smaller*:

* **The background is not walked.** It is always present and always ranks last,
  so it wins exactly when nothing else was found — which the running minimum
  already says. That also removed the only place where "unset" and "found
  source 0" had to be told apart.
* **The playfield contributes at most two candidates, not four** — the one the
  beam is over, plus PF3 again under the fifth-player bit. Walking four when at
  most two can be present is what the smell test is for.

With the two handshakes made combinational as well, the measured worst case is
**26 of 28**. `tb_gtia_stage` T1 *counts* the clocks rather than asserting them
and fails above 28, because every other check could pass while the design
silently failed to fit in real time.

The stage is pipelined by **two colour clocks**, and the reason is structural
rather than a fudge: a colour clock's pair of playfield pixels is not complete
until its second hi-res pixel has been emitted, so the walk for colour clock N
cannot start until N+1 begins, and the answer arrives 26 clocks into N+1 — so the
pair is written during N+2. That is a uniform four-hi-res-pixel delay on
playfield, objects and border alike, and the line buffer's rewind is delayed by
the same four so each line still receives exactly its own 456 pixels.

`tb_antic_scanline` runs at the real 56-clocks-per-machine-cycle ratio for this
reason — a compressed ratio would not exercise the schedule at all — and checks
that a player at `HPOSP0 = 60` lands at buffer pixels 120..135, a position
derived from the geometry beforehand rather than read off the simulator.

### Where the GTIA-mode nibble comes from — and what pseudo mode E is

`gtia_special` decodes modes 9/10/11 and is done. The interesting part was
working out where its 4-bit input comes from, because the obvious framing —
"mode F data reinterpreted" — is too narrow and hides the mechanism.

ANTIC hands GTIA **two playfield bits per colour clock** whatever mode it is in,
and GTIA shifts two colour clocks' worth together into a nibble:

| ANTIC mode | per colour clock | |
|---|---|---|
| F | two hi-res pixels of one bit each | 2 bits |
| E | one 2-bit pixel spanning both | 2 bits |

So a GTIA mode laid over mode E assembles its nibbles out of *pairs of mode E
pixel values* — which is exactly the display `gtia_psuedomodee` probes. There is
no special case for it: the same two bits arrive either way. That is the
mechanism the smell test was asking for.

**What is deliberately not settled:** collisions under a GTIA mode.
`gtia_psuedomodee` asserts particular `P0PF` values across a mid-line PRIOR
change (`$04`, then `$0f`) and `gtia_collision2` depends on the same behaviour.
Feeding the playfield source through unchanged does not reproduce it, and
guessing would be the plausible-but-wrong modelling this rewrite exists to avoid.
The colour path is complete and tested on its own; the collision path is left
alone until those two can be measured.

The nibble assembly is now wired through: the renderer publishes the raw 2-bit
playfield value, `antic_scanline` forms the colour clock's two bits, and
`gtia_stage` shifts two colour clocks together. A GTIA mode therefore costs one
more *pair* of colour clocks than a normal one, and that is causal rather than a
choice — a GTIA pixel's nibble is not complete until both of its colour clocks
have delivered their bits, so it cannot go on display until the following aligned
pair. Real GR.9/10/11 displays sit shifted for the same reason.

Holding it there takes **two** registers, not one: the pair completes on an odd
colour clock but must be displayed across a whole aligned pair. With a single
register the second half of every GTIA pixel showed the *following* pixel.

`tb_antic_scanline` T11 runs a real mode F line of `$E4` under mode 9 and checks
the GTIA pixels land at pixels 84-87 (`$5E`) and 88-91 (`$54`), positions worked
out from the byte's bit layout beforehand.

### VDELAY is a write mask

`VDELAY` ($D01C) inhibits the P/M store on **even** scanlines. In two-line
resolution both scanlines of a pair fetch the same byte, so an object that only
stores on the odd one changes a scanline later — which is the object appearing a
scanline lower. One gate.

It has to be a per-bit **mask** rather than a store enable, because the single
missile byte carries four missiles with four independent delay bits and they
share one register: missile 0 can be delayed while missile 1 is not. So the
fetcher emits a mask alongside the data and the register file merges, which also
keeps GRAFM one register as the CPU sees it.

In one-line resolution consecutive scanlines fetch *different* bytes, so the same
gate drops half the updates instead of delaying by a line. That is not a special
case being tolerated — it is what the hardware does with the same circuit, and
why VDELAY is documented as a two-line-resolution feature.

### DLI emission: the status and the /NMI are on different cycles

This is what `antic_dlitiming` was really about. The notes recorded that the CPU
side had been closed out — recognition depth, both pulse positions, RDY gating
and penultimate-poll all moved the two delivery sleds *together*, so the split
was not in the CPU. It is here: the status bit is set one machine cycle **before**
/NMI is asserted, so a CPU read of NMIST landing between them already sees the
flag. Modelling them as a single event is what made the sleds move together.

The absolute placement (status 7, /NMI 8) is carried across from the old path,
where both were bisected against hardware — `antic_nmist` fails "set too late" at
8 and "set too early" at 6. They are parameters on `antic_nmi` and will need
re-bisecting once the CPU is attached; the *relationship* between them is the
structural fact.

Two other behaviours worth recording, both carried rather than invented:

* **The two flags are a latch, not two independent bits.** A DLI sets NMIST to
  `$80` and clears the VBI bit; a VBI sets `$40` and clears the DLI bit. A
  program that misses an interrupt therefore never sees both at once. A
  coincidence goes to the VBI.
* **NMIEN gates the interrupt, not the status**, so a polling program still sees
  the event with interrupts off — and a set beats a coincident NMIRES, otherwise
  an interrupt arriving during its own acknowledge would vanish.

`antic_beam` also gains a `vbi_line` output, and its display height default moves
from 192 to ANTIC's actual maximum of 240 — the height is the display list's
business, not the counter chain's. That puts the display at lines 8..247 and the
vertical blank interrupt on 248, where the hardware has it.

### The DMA maps, and the bug they found

`antic_dmapattern` carries its own expected DMA patterns as bit masks at `$3800`.
Decoding them out of the binary gives an exact, per-mode, per-width,
first-row/later-row cycle map for a whole scanline — recorded in
[antic-dma-maps.md](antic-dma-maps.md). They confirm the display list fetch at
cycle 1, LMS operands at 6 and 7, refresh as 9 slots every 4 from cycle 25, and
every playfield window `antic_pf_geom` already computes.

They also found a real bug in what was already built:

* **A character name is fetched once per mode line, not once per scanline.** A
  later scanline of a narrow mode 2 line has exactly 32 fetches for 32
  characters, and a normal one exactly 40 for 40 — one each, where the first
  scanline has two. The names sit in the internal buffer for the whole block and
  only the glyph is re-read, because only the glyph *row* changes. That is what
  the buffer is actually for.
* **A bitmap mode with several rows fetches nothing at all on its later
  scanlines** — `mode8b`, `mode9b`, `modeAb`, `modeBb` and `modeDb` are refresh
  and nothing else.
* And therefore **the scan pointer advances once per mode line, not per
  scanline**, which falls out rather than needing its own rule: a later row does
  not fetch names, and it is the name fetch that steps the pointer. The previous
  code advanced it every scanline, which would have run a mode 2 block through
  320 bytes instead of 40. No existing test caught it, because every display
  list in the testbenches used one-row modes.

`antic_dma_sched` reproduces **all 50 maps exactly** — fixed slots, playfield
stepping, and one refresh rule: nine requests every 4 cycles from 25, the
playfield has absolute priority, a blocked refresh slips to the next free cycle,
and one still seeking when the next request arrives is dropped. That accounts for
every refresh position in every map, including the extreme case where a narrow
character first row leaves exactly two refreshes alive — the one at 25 before the
playfield starts and one that finally lands at 91 after it ends.

This is the bus-master half of ANTIC and is not optional: `dma_steal` becomes
/HALT to the core, so without it the CPU runs unimpeded and every cycle-timing
test is wrong however correct the picture is. It is a separate module from the
fetchers on purpose — the fetchers decide *what* is read, this decides *which*
machine cycle the CPU loses, and `antic_dmapattern` tests the second without
caring about the first.

The character first-row phase, which looked like an unsettleable constant, turned
out to be `step/2 + 1` — modes 2/3/4/5 and modes 6/7 are exactly the character
modes with step 2 and step 4, and those are the only two steps a character mode
can have.

### The register files

Both chips' registers now exist as their own modules. Three things in them are
worth stating because they are not what a register file usually does:

* **Almost nothing reads back what was written.** GTIA's `$D000-$D00F` write the
  object positions and sizes but read the collision latches, and `$D015-$D01E`
  are write-only — returning `$0F`, not open bus and not zero, because the chip
  leaves D4-D7 low and drives D0-D3 high. ANTIC is starker still: only VCOUNT and
  NMIST read anything at all, everything else is `$FF`. Those values are what
  `antic_default` and `gtia_default` measure.
* **The display list pointer is not held in the register file.** DLISTL/DLISTH
  are `antic_dl`'s live counter, so the file forwards the writes rather than
  keeping a copy.
* **WSYNC is a latch with a one-machine-cycle delay slot.** ANTIC holds a
  latch, not a countdown, and **/RDY is a registered output of it, one machine
  cycle behind in *both* directions**. Avery Lee, from a logic-analyser capture
  of a real XE: *"there is a one-cycle delay before RDY is pulled. That delay is
  on ANTIC's side, so it is one cycle regardless of whether the next cycle is a
  DMA or CPU cycle."* A combinational /RDY has no delay slot and parks the CPU
  a position early; delaying only the assert breaks the case where an RMW's two
  writes straddle the release. A read-modify-write writes `$D40A` twice, and
  because the latch is level state the second write changes nothing — the extra
  machine cycle the RMW spends is exactly the one the delay slot allows, which
  is the whole difference between `STA WSYNC` and `INC WSYNC` in `antic_wsync`.
  And **clear beats set**: a write landing on the release must not start a fresh
  line-long stall. All four are pinned by `tb_antic_reg_file` T5-T8.

  **The DMA steal has no such delay.** `dma_steal` says "this machine cycle is
  ANTIC's" and applies in that cycle — the asymmetry is real and makes sense: a
  stolen cycle is ANTIC taking the bus now, whereas WSYNC is a request
  propagating through ANTIC's latch. Neither is instruction-granular; both are
  cycle-granular, and the read/write gating (a CPU write cannot be stalled,
  because the CPU is driving the bus) belongs to whoever drives the core's
  `rdy` — the `xt6502f` port comment says as much.

`gtia_reg_file` also carries the two-key gate `gtia_phantomdma` tests on: DMACTL
makes ANTIC *fetch* a shape and GRACTL makes GTIA *latch* it, and both are
needed. Turning off either leaves the last shape standing.

### The pair is now addressable

`antic_gtia` wires beam, registers and raster path together behind a CPU bus, and
`tb_antic_gtia` drives it the way a 6502 does — nothing but writes to `$D4xx` and
`$D0xx` and reads on the same bus. It brings a display up from nothing (display
list pointer, colours, DMACTL), moves a player, reads collisions back and clears
them with HITCLR, takes a WSYNC stall, and catches a DLI as an NMI with the
status readable at `$D40F`.

That matters more than another unit test: a register wired to the wrong place is
precisely the mistake that survives module-level testing and then costs a day on
hardware. It runs at the real 56 clocks per machine cycle for the same reason —
the GTIA stage needs 26 of the 28 in a colour clock, so a compressed ratio would
not exercise the schedule at all.

`dma_steal` and `rdy_n` come out separately and are deliberately not the same
signal: a stolen cycle is ANTIC using the bus for its own fetch, WSYNC is the CPU
asking to be parked until the end of the line. A core needs both, for different
reasons, and `antic_dmapattern` and `antic_wsync` test them apart.

### The CPU is attached

`a8_core` joins `xt6502f` to `antic_gtia`, and `tb_a8_core` runs a hand-assembled
6502 program: the core fetches it through the reset vector and the display comes
up because the CPU executed stores to `$D4xx` and `$D0xx`. Nothing is poked from
outside.

The cycle stealing measures **52 machine cycles held per scanline with a normal
mode E playfield, and 12 without** — which is 40 playfield fetches + 9 refresh +
1 display list + 2 LMS operands, and 12 when only the last three remain. Those
fall straight out of the DMA maps.

Three things had to be right for that, and two of them were wrong first:

* **`rdy` is a LEVEL for the fid core, not a pulse.** The turbo core takes `rdy`
  as its clock enable and needs a pulse; the fid core paces itself from
  `phi2_tick` and samples `rdy` at a commit slot inside the machine cycle. ANDing
  `phi2_tick` into it means the core never reaches a commit with `rdy` high — it
  sat on the reset vector for ever.
* **`dma_steal` had to become a level too**, for the same reason: a tick-aligned
  pulse is invisible at the commit slot, so the CPU lost nothing at all.
* **HALT and RDY are composed differently**, which is the whole reason SALLY
  exists rather than a stock 6502. WSYNC's RDY *cannot stall a write* — the CPU
  is driving the bus and cannot let go. ANTIC's HALT is *unconditional*, because
  a stock 6502's RDY could never guarantee ANTIC the cycle it needs. Getting
  those the same way round is a silent-corruption bug: a write-immune HALT makes
  ANTIC miss fetches only when the CPU happens to be storing, which is
  data-dependent and would look like random display glitches.

Next: run ACID against this, which is now possible for the first time, then the
drop of turbo / `math_cop` / banking and a re-measure of slice occupancy.

## Open questions

* Does `/HALT` as an input really leave `xt6502f` unchanged?
* Expander cadence: double-buffer, or blit-in-VBLANK?
* Does `sprite_engine` keep earning ~1,400 lines once slices are re-measured?

## Success criteria

* Static mode tests pixel-perfect.
* The mid-line render tests pass **structurally** — state sampled where the beam
  is, not a compose instant tuned to a test's read window.
* Every module states its per-colour-clock clock budget.
* Slice occupancy low enough that the timing gate is deterministic on the 7020.
