# Streaming GTIA — design note

Holistic review of the Atari video path, why the current shape keeps costing
us ACID800 tests, and what each stage should be worth.

## The pipeline as built

| stage | lines | what it does | time base |
|---|---|---|---|
| `antic_timing` | ~420 | DL fetch, DMA schedule, WSYNC/NMI/VCOUNT | **beam** (phi2, cycle-serial) |
| `compositor` | 1680 | ANTIC mode decode **+** P/M overlay, one row per `start_compose` | **burst** — one instant per row |
| `color_resolver` ×2 | 238 | index pair → Atari hue:luma | inside the burst |
| `plane_fetch` | 329 | AXI read of a DDR row into a line buffer | scan-out |
| `plane_compositor` | 312 | N depth-ordered planes, scale, clip | scan-out |
| → SiI9022 | | HDMI | scan-out |

The CPU-visible half is beam-accurate. The picture-producing half is not: one
burst per row decides the whole line's playfield pixels, P/M overlay **and**
colour.

## Why that is the blocker

Of 26 ACID800 failures, ~14 are render/GTIA tests, and every one of them is
"a register changed partway along a line": `pfstarttiming`, `pfstoptiming`,
`hscrolbug`, `charcontrol`, `linebuffering`, `hiresbug`, and the whole GTIA
group. A burst cannot express that — the line has exactly one value for
everything.

Each fix so far has been a bolt-on reconstruction of beam time for one
register: `early`/`chg_x` for SIZEP, the same again for HPOSP, a separate
beam-time engine for collisions, shift registers inside that engine. They work
individually and interact badly. The clearest symptom is that the compose
instant had to be *tuned* — cycle 110 landed after `gtia_pmretrigger`'s read,
cycle 96 lands between its write and its read. Guessing an instant that
happens to sit inside a test's window is not a model. In a streaming design
the question never arises.

`color_resolver`'s header says it is "meant to be instantiated at scan-out
time, not in the compositor". It is in fact instantiated in `antic_top` on the
`cmd_data` pair, i.e. inside the burst, so the DDR surface holds resolved
colour and mid-line COLPF/COLBK changes are lost the same way.

## The timing argument (this makes it CHEAPER, not riskier)

A colour clock is 3.579545 MHz against `clk_sys` at 133.3 MHz — **37 clk_sys
cycles per colour clock**. Streaming GTIA is nowhere near a hot path.

The burst is the opposite: it runs a 25-state FSM flat out at `clk_sys`, and
its emit path is the measured `clk_sys` limiter —
`display_shadow` BRAM → `pack_pair` → overlay → `cmd_data`, 8 logic levels,
8.354 ns against a 7.5 ns budget (HANDOFF 1i). Builds have been coin-flipping
on it for a week.

So moving the pixel path to beam time removes the critical path rather than
adding one.

## Target shape

```
antic_timing  (beam)  DL fetch, DMA, playfield BYTE stream   -- extend
    |
gtia_stream   (beam)  per colour clock: playfield bits + live P/M + PRIOR
    |                 -> presence -> priority -> hue:luma  -> line buffer
    |                 collisions fall out here for free
line buffer
    |
plane_fetch / plane_compositor / HDMI                        -- UNCHANGED
```

`gtia_pm_collide` is already the first slice of `gtia_stream`: a streaming
GTIA stage that happens to emit only collisions.

## What each stage is then worth

* **`antic_timing`** — earns its place, already beam-accurate. Extend it to
  emit the playfield byte stream (it already schedules the fetches).
* **`compositor`** — *dissolves*. Today its 1680 lines do two chips' jobs at
  the wrong time base: ANTIC mode decode and GTIA overlay. Mode decode belongs
  in the ANTIC stage, overlay in the GTIA stage. This is a net simplification,
  not new code on top.
* **`color_resolver`** — keep the function, move the sampling. It is correct
  logic fed at the wrong instant; in `gtia_stream` it is fed per colour clock
  from live registers, which is what its own header always intended.
* **`plane_fetch` / `plane_compositor`** — keep unchanged. These are generic
  multi-plane scaling/clipping used by the GEM desktop too, not Atari-specific,
  and they consume rows either way. They earn their place independently of any
  of this.
* **`sprite_engine`** — orthogonal (hardware cursor / GEM), untouched.

## Sequencing

1. **Measurement first.** At least three tests are non-deterministic and the
   dashboard records single samples as verdicts (HANDOFF 1m). The cold-boot
   state leak in `antic_timing` is one proven cause and is fixed; re-measure
   flake rates before trusting any before/after comparison of a change this
   size.
2. Extend `antic_timing` to emit the playfield byte stream.
3. `gtia_stream`: playfield + P/M + PRIOR → hue:luma per colour clock, with
   `gtia_pm_collide` folded in.
4. Retire the compositor's overlay/colour role; keep a thin row writer.
5. Re-measure the render cluster.
