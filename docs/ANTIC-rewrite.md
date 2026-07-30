# ANTIC rewrite — plan

Re-orienting the Atari port around **ANTIC as the bus master**, rather than
bolting ANTIC onto a fast CPU. Decided 2026-07-30.

## Why

The port was built CPU-first: a fast 6502, then ANTIC attached to service it.
That is backwards for this machine. ANTIC *is* the bus master — it gates the CPU
clock, steals cycles, and drives the whole 1.79 MHz cadence. The CPU is its
slave.

Two concrete consequences of having it backwards:

**Correctness.** Of 26 remaining ACID800 failures, ~14 are the same shape: a
register changed *partway along a scanline*. The current compositor decides an
entire row's pixels, P/M overlay and colour at one instant, so it cannot express
that at all. Every fix so far has been a per-register reconstruction of beam time
(`early`/`chg_x` for SIZEP, again for HPOSP, a separate collision engine, shift
registers inside it). The tell is that the compose instant had to be *tuned* —
cycle 110 landed after `gtia_pmretrigger`'s read, cycle 96 sits between its write
and its read. Choosing an instant that falls inside one test's window is a
coincidence, not a model.

**Area.** The 7020 is a hard stop — the project ships on it or not at all. The
design is currently **97.3% slice-occupied** (12,939 of 13,300) with 1,685
control sets, while LUTs are only 56% and registers 39%. A perfectly packed
design of this size needs ~7,500 slices, so ~73% is packing overhead. The burst
compositor is the largest block on the congested clock, and it is congestion —
not logic depth — that makes 4 of every 6 builds miss the timing gate on changes
unrelated to the failing path.

Both problems have the same root, and the same fix.

## The key lever: serial logic

At 1.79 MHz against a 100–133 MHz fabric there are **~56–74 fabric cycles per
machine cycle**. Anything ANTIC does can be spread across those cycles, because
effects only need to be correct at the 1.79 MHz boundary.

That means one shared comparator walked across objects and colour clocks, rather
than parallel logic replicated per pixel. It attacks correctness and area at the
same time — the opposite of the current design, which evaluates wide parallel
cones per pixel and is therefore both wrong about mid-line writes and large.

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

**Line buffer format: one byte per pixel, holding the RESOLVED Atari colour**
(hue:luma). Colour *must* be resolved in the line — if the buffer held indices
and the expander coloured them later, mid-line COLPF/COLBK writes would be lost,
which is the current bug moved downstream. The palette is quasi-static, so the
expander's LUT from colour byte → RGBA32 is safe to do late, and a byte per pixel
is a quarter of the buffer RGBA32 would need.

**Expander** converts the line to RGBA32 into DDR on a line cadence, then blits
a completed screen during VBLANK (or double-buffers) so a new frame appears
seamlessly. Everything downstream of the framebuffer is unchanged.

## What stays, what goes

| Block | Lines | Decision |
|---|---|---|
| `xt6502f` (fid, slow) | 839 | **KEEP** — passes Klaus and the illegal-opcode tests. Slaved to the new ANTIC. Rewrite only if `/HALT` as an input proves insufficient. |
| `xt6502` (turbo, fast) | 1,068 | **DROP** from the build. HDL retained for later. |
| `math_cop` | 535 | **DROP** — belongs to the fast CPU. |
| bank switching (`bank_xlat`, `banked_axi_reader`, `banked_page_cache`, `screen_bank`) | 1,379 | **DROP** — not needed for the slow CPU. |
| `compositor` (burst) | 1,678 | **REPLACE** — the whole point. |
| `xt_blitter` | 3,696 | **KEEP** — fundamental to XTOS. |
| `sprite_engine` + line cache | ~1,400 | **KEEP for now** — currently only the mouse pointer. |
| HDMI / `plane_compositor` / `plane_fetch` / `vbeam` | — | **KEEP** — essential, and generic (carries the GEM desktop). |

Rough removal: ~4,660 lines of RTL dropped outright, plus the burst compositor
replaced by something much smaller. That is the area headroom the 7020 needs.

## What already exists

This is assembly plus one real piece of work, not a rewrite from scratch. Built
and sim-verified over 2026-07-28/29:

| Module | Lines | Role in the new design |
|---|---|---|
| `antic_timing` | 706 | **The spine.** Beam-accurate DL fetch, DMA schedule, WSYNC/NMI/VCOUNT, memscan, CHBASE, playfield byte stream. |
| `gtia_pm_collide` | 301 | Per-object shift registers walked per colour clock; collisions fall out; per-colour-clock presence exposed. |
| `gtia_stream` | 104 | Per-colour-clock pixel resolution against live registers. |
| `antic_pf_serial` | 99 | Playfield byte stream → per-colour-clock nibble (bitmap modes). |
| `color_resolver` | 238 | Index + PRIOR + colour registers → Atari colour byte. |

Missing: char-mode decode migration, the line buffer itself, and the expander.

## Test strategy

**Static first.** Before any CPU is involved: preload memory with a known
display list and screen data for a single mode (MODE 2, MODE 0, MODE F…),
run ANTIC, capture the line buffer, and compare **pixel-perfect** against a
hand-computed expected image. This is the cheapest possible way to catch
mode-decode errors and it needs no 6502 at all.

**Then ACID, driven by the tests.** The ACID tests are 6502 programs — they
write registers mid-line and read results back — so they cannot run without a
CPU. The fid core stays in for exactly this reason.

**Test before code, per mode family.** For each mode family being migrated,
write the relevant ACID constraint as a directed testbench *first*, then make it
pass. That is the opposite of what has been happening: tests retrofitted to
existing code, which is why every fix was a bolt-on. Precedent that works:
`tb_pm_collide` mirrors `gtia_pmretrigger`'s exact geometry (p1 at HPOS 60, p2 at
100, p0 moving between them mid-line) and catches the real behaviour rather than
an approximation.

**The sim has to be genuinely good.** Sim-by-preference only pays off if it is
trustworthy; otherwise it stores up problems for hardware. Two lessons already
paid for:

* Count real assertions, never `grep -c "error|FAIL"` — an elaboration failure
  *lowers* that count and reads as progress ([[sim_pass_fail_counting]]).
* Drive stimulus on the **negedge**. Driving immediately after `@(posedge clk)`
  races the DUT's `always_ff` and shows up as everything lagging one step —
  hit twice, in `tb_gtia_stream` and `tb_pokey_serial`.

## Sequencing

1. **Line buffer + expander.** Small, and makes the pipeline observable end to
   end. Static test: known DL → known line buffer → known RGBA32.
2. **Static mode tests.** MODE 2 (char), MODE 0 (blank), MODE F (1bpp hires),
   MODE 8/E (bitmap). Pixel-perfect against hand-computed expectations.
3. **Migrate the mode decode** into the serial path, one family at a time, each
   preceded by its ACID constraint as a directed test.
4. **P/M and collisions** — fold in `gtia_pm_collide`, which already walks the
   beam.
5. **Bring the fid core back** and run the real ACID suite.
6. **Drop** turbo, math_cop and the banking blocks; re-measure slice occupancy.

## Open questions

* Does `/HALT` as an input really leave `xt6502f` unchanged? Believed yes; the
  cycle-exact DMA-steal model already exists ([[sally_halt_not_modeled]]).
* Where does the expander's line cadence sit relative to VBLANK for the screen
  blit — double-buffer, or blit-in-VBLANK?
* Does the sprite engine keep earning its ~1,400 lines once slice pressure is
  measured again?

## Success criteria

* Static mode tests pixel-perfect.
* The ~14 mid-line ACID render tests pass *structurally* — because state is
  sampled where the beam is, not because a compose instant was tuned.
* Slice occupancy back to a level where the timing gate is deterministic rather
  than a coin flip, on the 7020.
