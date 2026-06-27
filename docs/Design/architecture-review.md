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
no placement stability."

**Measured 2026-06-27** (routed design; see §1 and docs/Design/floorplan.md): the
disease is confirmed — clk_sys binds at **+0.019 ns** on
`u_antic_top/u_compositor/unit_idx → cmd_data` (12 levels, 60% route; the original
`pair_idx → col_presH` culprit has drifted), with the blitter `m_axi_araddr` paths a
close second. Three candidate cures —

1. **Incremental implementation** — reuse P&R for untouched logic.
2. **Floorplan (pblocks)** — localize placement so one subsystem can't move another.
3. **Pipeline the 2–3 genuinely-binding paths** — buy real margin.

— but once the data was in, the *ordering* changed (§1): lead with incremental,
floorplan only the RP fence, and treat pipelining as a separate fmax task.

---

## 1. Theme — build determinism: incremental first, RP-fence floorplan, then pipeline

> **Revised 2026-06-27 from placement evidence.** This section originally led with a
> full subsystem floorplan. Probing the routed design (and a validated incremental
> build — data in docs/Design/floorplan.md) reordered it: the three cures address
> *different* problems, and the data says lead with incremental, floorplan only the
> RP fence, and treat fmax as a separate pipelining task.

### 1.1 Incremental implementation — the determinism cure (validated)
Vivado incremental P&R (reference the last routed `.dcp`) pins unchanged logic to a
known-good placement, so "an unrelated edit regressed a far path" cannot happen — and
the build is far faster. Measured: a one-module edit rebuilt in **~4.5 min vs ~25**
(100% cell / 99.95% net reuse) and the gate **reproduced** the reference timing
(clk_sys +0.000 vs +0.019 fresh) instead of rolling fresh dice. Plumbed and usable:
`INCR_REF_DCP=<routed.dcp> ./vivado/run-valhalla.sh bit`. **The single biggest
determinism + quality-of-life win, at near-zero risk.**

### 1.2 A full subsystem floorplan is NOT worth it here
The original plan (pin ANTIC / video / PS-band into their own pblocks) does not
survive the placement data:
- Everything is **deeply intermixed** — `u_antic_top`, `u_sprite_engine` and
  `u_antic_writeback` each span all four populated clock regions; un-mixing them is
  high churn against an already-working placement.
- It's **BRAM-bound** (54% of 140 RAMB36, unevenly distributed across regions), so
  the BRAM-heavy blocks can't be freely relocated.
- **Incremental overrides pblocks anyway** — the incremental run reported *"Pblock
  constraints were ignored for 101 of 14267 cells because the Pblock boundaries
  conflict with the reused placement"*. Reuse wins, so elaborate pblocks become
  partly fiction once incremental is on.

Keep the two tactical pblocks (`pb_sally`, `pb_blitter`); do **not** add
`pb_antic`/`pb_video`.

### 1.3 Floorplan only the sally loop — as the RP fence (§1.4)
The one durable reason to floorplan is the partial-reconfig fence, and that needs
only the `clk_sally` loop pinned. `pb_sally` already contains it (measured: 2 of 2611
leaf cells stray), so the fence is ~free to formalize.

### 1.4 The RP fence is the sally pblock (unchanged)
The CPU+`sally_mem` pblock is exactly the **Reconfigurable Partition** the dual-CPU
swap needs. PR is fMax-neutral only if the RP **contains the entire `clk_sally`
critical loop** (CPU + registered MAR + read mux) so the boundary carries only slow
signals (NextSteps §6502, [[xt6502_clean_sheet]]). `pb_sally` already does this — so
the floorplan investment worth making is exactly this one pblock, not a whole-design
partition.

### 1.5 The two long-poles (full-path review, 2026-06-27)
Both binding paths are ~60% route, so the lever differs by *whether the route is a
cross-region crossing (floorplan helps) or local congestion (logic restructure)*:

- **clk_sys — GTIA/compositor colour-priority cone** (worst, +0.001, 14 levels):
  `u_compositor/cur_mode → [compositor cmd_data logic] → u_gtia_regs cmd_data CARRY4
  → missile_covers → col_presH_q`. **Both `u_compositor` and `u_gtia_regs` span
  X0Y0 + X1Y0**. **Floorplan co-location TRIED (2026-06-27)** — pblock pinning
  `u_compositor`+`u_gtia_regs` to the free top row {X0Y2,X1Y2}: clk_sys **NEUTRAL**
  (+0.000 vs +0.001), clk_sally slightly worse (+0.245 vs +0.309) → reverted. So the
  path is **logic-depth-bound** (14 levels), not the column route. **Lever = a
  pipeline stage** in the col_presH cone — but it is the real-time pixel pipeline, so
  a stage shifts pixel timing and must be compensated through the compositor; deep,
  treat carefully (deferred).
- **clk_sally — CPU memory loop** (+0.166–0.309, 11 levels): `sally_mem BRAM → IR/adl
  /PC decode → page_cache tag-match (code_page_match) → state_q → data_flush_idx`.
  Endpoints **already co-located in X0Y0** → the 60% route is *local congestion*, not
  a crossing, so floorplan won't help. This is the registered-MAR/page-cache ceiling;
  read-pipeline was tried & reverted ([[xt6502_clean_sheet]]). Residual levers:
  page_cache RLOC + LUTRAM ZP/stack tiers — deep, treat carefully; gates 120 turbo.
- **blitter `m_axi_araddr`** — was a clk_sys long-pole (+0.015, 12 CARRY4); **FIXED**
  by the column-address accumulator (commit d8bc7a8): now +0.482.

The RP fence (§1.4) and the clk_sally loop are the same `pb_sally` region — see
docs/Design/partial-reconfig.md.

**Effort:** incremental = low (done). RP-fence formalize = low. Pipelining = the real
work, a dedicated fmax task. **Payoff:** determinism now (incremental), turbo later
(pipelining) — decoupled, which is the correction to the original §1.

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
ANTIC compositor being the binding path is better addressed by **pipelining its depth
(§1.5)** than by a rearchitect. Recommendation: **do not rearchitect working video**;
only revisit if §1.5 can't tame its path. Listed for completeness.

---

## 6. Recommended sequence

Front-load the cheap enablers (they make the big work safer), then the structural cure,
then the quality-of-life track:

1. **CI + timing gate + the sim suite** (§4.2) — ✓ landed (GH Actions + Vivado WNS gate).
2. **CDC library + lint** (§2) — ✓ landed.
3. **Generated register map** (§4.1) — ✓ landed (HW-validated).
4. **Incremental implementation** (§1.1) — ✓ plumbed + validated; the determinism cure
   (~4.5-min reuse builds, deterministic timing).
5. **Formalize `pb_sally` as the RP fence** (§1.3–1.4) — cheap; the *only* floorplan
   worth doing (a full subsystem floorplan was evaluated and rejected, §1.2).
6. **Pipeline the binding paths** (§1.5) — the real fmax/120 MHz task: clk_sally
   page-cache path + clk_sys ANTIC-compositor depth + blitter `m_axi_araddr` addr-gen.
7. **Selective ACP coherency** (§3.1) — evaluate on the GEM/desktop surfaces.
8. **(Deferred)** memory-hierarchy rethink (§3.2), video rearchitect (§5).

If only one thing gets done: **#4 (incremental implementation)** — the biggest
determinism + speed win at near-zero risk. (The original "do the big floorplan"
recommendation is **retired** — see §1.2.)

## 7. Explicitly NOT now (scope discipline)

- Don't rewrite the working video pipeline (§5).
- Don't add a full subsystem floorplan (`pb_antic`/`pb_video`) — evaluated and
  rejected (§1.2); incremental + the sally RP-fence is the play.
- Don't ACP the high-bandwidth video (keep it on HP).
- Don't let "tock" become "rewrite v1" — the goal is *cost-of-change*, not novelty.

---

## Through-lines (the reasons these compound)
- **Incremental P&R → build-determinism now; `pb_sally` → the PR CPU-swap substrate
  later** (§1.1, §1.4). fmax/120 is a separate pipelining task (§1.5).
- **CDC library → the row-128 / cursor-flicker bug class never returns** (§2).
- **CI timing-gate → the "−0.185 surprise" becomes a red check, not a flashed board** (§4.2).
- **Generated map + SSoT → no more hand-mirroring RTL↔C drift** (§4.1).
