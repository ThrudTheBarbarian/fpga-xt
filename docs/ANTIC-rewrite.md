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

## The complexity check: ANTIC was ~2000-3000 transistors

If emulating an ANTIC effect needs something complicated, we have missed the
mechanism and are doing it wrong. This is a falsifiable check, not a slogan.

Work the budget. ANTIC's architectural state is roughly:

| | bits | | bits |
|---|---|---|---|
| DLIST pointer | 16 | DMACTL | 6 |
| memory scan | 16 | CHACTL | 3 |
| data shift register | 16 | HSCROL | 4 |
| char name + glyph | 16 | VSCROL | 4 |
| vertical counter | 9 | PMBASE | 6 |
| horizontal counter | 8 | CHBASE | 6 |
| instruction register | 8 | NMIST | 3 |
| DCTR row counter | 4 | NMIEN | 2 |

**~127 bits.** As NMOS latches at 6-10 transistors per bit that is
**760-1,270 transistors of state alone**, leaving roughly **120-560 gates for
ALL the logic** at 4-6 transistors per gate.

That budget buys: a counter chain, a handful of comparators, a small PLA for
instruction decode, and a shift register with a variable shift rate. It does not
buy anything else. So whenever a design here needs more than that, the mechanism
has been missed.

**Worked example — the sixteen "modes" are not sixteen cases.** ANTIC cannot
afford sixteen decoders. The mode nibble indexes a handful of parameters:

* bits per pixel (1 or 2)
* colour clocks per pixel (1, 2 or 4)
* source: character (name fetch, then glyph lookup) or direct bitmap
* scanlines per row (1, 2, 3, 4, 8, 16)
* the mode-3 descender quirk

One small parameter table feeding **one** datapath. The current `pack_pair` is a
sixteen-arm case statement with per-mode windowing — that is the smell this check
exists to catch.

The same reasoning applies to GTIA (a separate chip, similarly small): four
player shift registers, four 2-bit missile registers, position comparators, a
priority encoder and collision latches. A wide combinational priority cone
resolving everything per pixel is not something that chip could contain.

**Rule of thumb:** if a module cannot be described as "a counter, a comparator, a
shifter and a small decoder", stop and find the mechanism.

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
