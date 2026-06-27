# Architecture review — the "tock" (2026-06-27)

> Forward-looking review / proposal, not a current-behaviour spec (like NextSteps,
> it intentionally carries options and opinions). v1 grew organically — correctly,
> that's how it got to a working machine on real silicon. Now that a lot is in
> place, this is a deliberate pass with fresh eyes: **lower the cost of change, kill
> recurring bug classes, and lay foundations we already know we want** (notably the
> partial-reconfig CPU swap). Nothing here says "rewrite what works"; it says "stop
> paying the same taxes on every change."

---

## 0. The acute trigger: we nursemaid the bitstream

Every RTL change is a 30–40 min dice-roll. The GP0 re-partition (a change that did
**not** touch any binding path) still came back **clk_sys WNS −0.185, 13 failing
endpoints** — and the worst path was `u_antic_top/u_compositor/pair_idx → col_presH`
(**13 logic levels, 7.28 ns, 58% routing**), nothing to do with the edit. It only
closed (+0.019) after a `PLACE_DIRECTIVE=Explore` retry.

Diagnosis: the design is **one flat netlist placed fresh every build, with clk_sys
(133 MHz, the binding clock) closing at ~0 ns margin on paths scattered across the
die**. Placement noise (±0.1–0.2 ns) then flips those paths positive/negative at
random. The symptom is "the ANTIC compositor failed"; the disease is "no margin +
no placement stability." Three cures, in increasing effort:

1. **Floorplan (pblocks)** — localize placement so a change in one subsystem can't
   move another.
2. **Incremental implementation** — reuse P&R for untouched logic.
3. **Pipeline the 2–3 genuinely-binding paths** — buy real margin so variance stops
   mattering.

This is the headline theme, and it pays a dividend we want anyway (Section 1.4).

---

## 1. Theme — build determinism: floorplan + incremental + pipeline

### 1.1 Floorplan the stable subsystems into pblocks
Pin the big, stable blocks to regions:
- **CPU + `sally_mem`** (the `clk_sally` critical loop: xt6502 + registered MAR +
  read mux) — one pblock.
- **ANTIC / GTIA / POKEY** legacy chiplets — one pblock.
- **Video** (vbeam + plane_fetch ×N + plane_compositor + sprite_engine + writeback).
- **PS-interface band** (GP0 regs, HP-port AXI logic, CDC) near the PS hard block.

Payoff: editing the GP0 regs re-places only the PS band; the ANTIC compositor keeps
its placement and its timing. The design already uses pblocks tactically (the sally
pblock); this generalises that into a deliberate floorplan.

### 1.2 Incremental implementation
Turn on Vivado incremental P&R (reference the last good `.dcp`). With pblocks, an
edit to one module re-runs only that region → **~5-min, deterministic builds**
instead of 35-min dice-rolls. Biggest single quality-of-life win in the whole review.

### 1.3 Pipeline the binding paths (surgical)
Two paths actually set the clk_sys/clk_sally ceiling:
- **ANTIC compositor** `pair_idx → col_presH` (13 levels, route-dominated). Either
  add a pipeline stage (split the 13 levels) or — since it's 58% routing — let the
  floorplan localize it. Try floorplan first; pipeline if needed.
- **CPU ↔ `sally_mem` read mux** (the registered-MAR ceiling, [[xt6502_clean_sheet]]).
  Known territory; treat carefully (it gates turbo).

Margin is what makes placer variance a non-event. Even +0.3 ns turns "every build is
a gamble" into "every build closes."

### 1.4 The through-line: floorplan **is** the partial-reconfig substrate
The CPU+`sally_mem` pblock is exactly the **Reconfigurable Partition** the dual-CPU
swap needs. The fidelity-core analysis (NextSteps §6502) already found PR is only
fMax-neutral if the RP **contains the entire `clk_sally` critical loop** (CPU +
registered MAR + read mux) so the partition boundary carries only slow signals.
So when we floorplan that loop for build-determinism, we're drawing the RP fence.
**One investment → deterministic builds now + the turbo↔fidelity↔m68k cold-swap
(desktop/video staying live) later.** This is the strongest reason to do the
floorplan properly rather than as a one-off patch.

**Effort:** medium-high. **Payoff:** the highest in the review — it compounds on
every future change and unblocks a known long-term goal.

---

## 2. Theme — CDC discipline: stop the recurring bus-sync bug

We have hit the **identical** bug twice: a free-running multi-bit value 2-FF
*bus*-synced across clocks, latching a garbage intermediate on a multi-bit carry —
the row-128 "rainbow line" (`fetch_row`) and then the sprite-cursor flicker
(`fetch_next_vcount`). Each cost most of a session and a wrong-fix detour. That's a
pattern, not bad luck.

**Proposal:** a small, vetted CDC primitive library + a convention + a lint gate.
- Primitives: 1-bit 2-FF flag sync (`cdc_sync_bit`, have it); **multi-bit transfer =
  capture-on-synced-flag** (data held stable, flag synced — the fix both bugs needed)
  or gray-coded counter (`cdc_fifo` has it) or async FIFO. **Never** a free-running
  multi-bit 2-FF sync.
- Lint: run `report_cdc` in CI and fail on unsafe crossings; a naming convention
  (`*_cdc`, `*_sync`) so review can spot them.

**Effort:** low-medium (primitives largely exist; codify + lint). **Payoff:** kills a
whole class of the most expensive, hardest-to-see bugs we have.

---

## 3. Theme — memory & coherency

### 3.1 Coherent shared buffers (the ACP option)
Today every A9→PL surface needs a manual `Xil_DCacheFlushRange`; a forgotten flush is
a classic stale-pixel bug. Routing the **A9-shared, low-bandwidth** surfaces (sprite
arena, GEM assets, drag overlay, glyph atlases) through **S_AXI_ACP** makes them
cache-coherent — the flush dance disappears.
- Trade-off: ACP contends with the CPU and pollutes L2, so keep the **real-time
  video** (desktop/XL plane reads, writeback) on HP where it belongs; ACP only for
  the GEM/desktop control-rate surfaces. Measure L2 impact before committing.
- This is *an option*, not a foregone conclusion (per your framing) — but it directly
  retires a bug class, so it earns a real evaluation.

### 3.2 The SALLY memory hierarchy (bigger, optional)
The registered-MAR read path is the `clk_sally` ceiling; the page cache / banking /
screen RAM all interact. A fresh look could ask whether a different cache org relieves
the binding path (ties into 1.3). Higher effort/risk — flag, don't rush. Getting SALLY back up to 120MHz is highly desirable, however.

### 3.3 HP-port headroom (cheap to bank)
We use 4 HP; 2 S_AXI_GP + 1 ACP sit free. Worth documenting as the explicit budget so
future masters (SDMA for the DSP56001 note, etc.) have a home plan. See [[hp_port_map]].

Also worth documenting the direction (R/W) that we've currently used for each port since different directions can be used separately. Also worth mentioning the congestion-level and/or bandwidth use in each direction.

**Effort:** 3.1 medium (BD change + driver). **Payoff:** removes the flush-bug class.

---

## 4. Theme — single source of truth + CI

### 4.1 Generated register map
We just **hand-mirrored** `xt_gp0_regs.sv` ↔ `xt_gp0_map.h`. That drifts. A small
generator (one YAML/JSON spec → SV package + C header + a docs table) makes the map
authoritative and keeps RTL/SW/docs in lockstep — valuable now the map is stable and
about to grow (XL-control, compositor, window-manager blocks).

### 4.2 CI + a timing gate
There is no CI; every change is a manual sim + a build gamble, and regressions surface
on HW. (NextSteps already lists a "CI smoke step.") Propose:
- **Per-commit:** the iverilog sim suite (`make all`) — catches RTL regressions in
  minutes. The SRC_BLIT mismatch would have a standing red to fix, not a surprise.
- **Per-PR / nightly:** a build that **fails if clk_sys/clk_sally WNS < 0** — encodes
  the "don't flash a negative build" gate we apply by hand, and flags fragility early.
- The xt6502 co-sim oracle (`cosim_diff.py`) already exists; wire it in.

**Effort:** medium. **Payoff:** catches regressions and timing fragility *before* a
power-cycle, not after.

---

## 5. Theme — video/compositor pipeline (lower priority)

The video path (plane_fetch ×N + compositor + writeback + sprite + overlay) grew
organically and **works well on HW** (the display-artifact + cursor fixes landed). The
ANTIC compositor being the binding path is better addressed by **pipelining/floorplan
(Section 1)** than by a rearchitect. Recommendation: **do not rearchitect working
video**; only revisit if Section 1 can't tame its path. Listed for completeness.

---

## 6. Recommended sequence

Front-load the cheap enablers (they make the big work safer), then the structural cure,
then the quality-of-life track:

1. **CI + timing gate + the sim suite** (§4.2) — cheap, immediate, makes every later
   step safe to land. Fix the standing SRC_BLIT red while here.
2. **CDC library + lint** (§2) — cheap, retires the most expensive recurring bug.
3. **Floorplan + incremental implementation** (§1.1–1.2) — the headline determinism
   cure; deterministic ~5-min builds; lays the PR fence (§1.4).
4. **Pipeline the binding paths** (§1.3) only if floorplan alone doesn't give margin.
5. **Generated register map** (§4.1) — once the map next needs to grow.
6. **Selective ACP coherency** (§3.1) — evaluate on the GEM/desktop surfaces.
7. **(Deferred)** memory-hierarchy rethink (§3.2), video rearchitect (§5).

If only one thing gets done: **#3 (floorplan + incremental)** — it pays back on every
future change and is the dual-CPU-PR foundation.

## 7. Explicitly NOT now (scope discipline)

- Don't rewrite the working video pipeline (§5).
- Don't ACP the high-bandwidth video (keep it on HP).
- Don't let "tock" become "rewrite v1" — the goal is *cost-of-change*, not novelty.

---

## Through-lines (the reasons these compound)
- **Floorplan once → build-determinism now + PR CPU-swap substrate later** (§1.4).
- **CDC library → the row-128 / cursor-flicker bug class never returns** (§2).
- **CI timing-gate → the "−0.185 surprise" becomes a red check, not a flashed board** (§4.2).
- **Generated map + SSoT → no more hand-mirroring RTL↔C drift** (§4.1).
