# Floorplan + incremental build — the build-determinism procedure

Implements architecture-review §1. Goal: stop every RTL change being a 30–40 min
full-die placement dice-roll, and draw the partition fence the dual-CPU
partial-reconfig swap will reuse (§1.4).

This is a **build-host procedure** (Vivado on valhalla), not a one-shot constraint
edit: pblock clock-region ranges must be chosen by inspecting a *placed* design
and iterating — picking the wrong region costs timing that recovery passes can't
claw back (see the history notes in `pblock_sally.xdc` / `pblock_blitter.xdc`).
Do not guess ranges; derive them as below and gate every build on the WNS check.

## Device canvas (xc7z020)

2 columns × 3 rows of clock regions:

```
  X0Y2   X1Y2      <- top    (currently unconstrained: ANTIC/video/PS glue)
  X0Y1   X1Y1
  X0Y0   X1Y0      <- bottom (next to PS / AXI-HP hard block at the die edge)
```

Already pinned (soft pblocks, placement-only, kept DISJOINT so neither perturbs
the other — overlap once crashed phys_opt):

| Pblock | Cells | Regions |
|--------|-------|---------|
| `pb_sally`   | `u_sally_mem`, `u_sally_core` | `X0Y0 X0Y1` |
| `pb_blitter` | `u_xt_blitter`               | `X1Y0 X1Y1` |

Free for new pblocks: the top row `X0Y2 X1Y2`, plus slack in the lower regions.

## Target assignment (review §1.1)

1. **`pb_sally` = the clk_sally critical loop = the RP fence.** It already holds
   `u_sally_mem` + `u_sally_core`. Confirm the *entire* registered-MAR read path
   (xt6502 core + MAR + `sally_mem` read mux) is inside it — that is the
   precondition for the partial-reconfig CPU swap to stay fMax-neutral (§1.4,
   [[xt6502_clean_sheet]]): the partition boundary must carry only slow signals.
   When the dual-CPU swap lands, this pblock becomes the `PARTITION_DEF` /
   Reconfigurable Partition; floorplanning it now is the same investment.
2. **`pb_antic`** — `u_antic_top` (ANTIC/GTIA/POKEY legacy chiplets, incl. the
   `pair_idx → col_presH` compositor path that is the clk_sys binding path).
3. **`pb_video`** — vbeam + plane_fetch ×N + plane_compositor + sprite_engine +
   writeback.
4. **PS-interface band** — `xt_gp0_regs`, HP-port AXI logic, CDC — near the PS
   hard block (bottom edge). May stay soft/unconstrained if it places stably.

On a part this small, 2–4 of these must share the top row + lower-region slack;
expect to iterate. Editing one subsystem then only re-places its pblock — the
ANTIC compositor keeps its placement and its timing across an unrelated edit.

## Procedure: derive ranges from a placed run (don't guess)

1. Build once, fully, and open the routed checkpoint:
   `open_checkpoint build/post_route.dcp`
2. For a candidate module, see where the placer actually put it and how spread it
   is:
   `highlight_objects -color red [get_cells -hier -filter {NAME =~ *u_antic_top*}]`
   then read the clock regions it spans in the device view / `report_utilization
   -pblocks`.
3. Create the pblock over the *smallest* set of whole clock regions that holds the
   cell count with headroom (BRAM/DSP/SLICE), keeping it **disjoint** from
   `pb_sally`/`pb_blitter`:
   ```tcl
   create_pblock pb_antic
   add_cells_to_pblock [get_pblocks pb_antic] [get_cells u_antic_top]
   resize_pblock [get_pblocks pb_antic] -add {CLOCKREGION_X0Y2 CLOCKREGION_X1Y2}
   ```
   Soft (no `CONTAIN_ROUTING`) — placement-only, routing may cross out, matching
   the existing two.
4. Save as `vivado/constraints/pblock_<name>.xdc` (auto-globbed by `build.tcl`)
   with a header documenting the measured cell count, the regions, and the WNS
   before/after — exactly as `pblock_sally.xdc` does.
5. Re-build and check the timing gate. Keep the pblock only if WNS does not
   regress; otherwise try a different region set. Record what you tried.

## Incremental implementation (review §1.2)

Plumbed into `build.tcl` (opt-in, default off): after `opt_design`, if
`INCR_REF_DCP` points at a routed `.dcp`, it is read as the incremental
reference so only changed logic re-places/re-routes.

```sh
# first build: full, produces build/post_route.dcp (the reference)
./vivado/run-valhalla.sh bit
# subsequent builds after a localized edit: reuse it
INCR_REF_DCP=build/post_route.dcp ./vivado/run-valhalla.sh bit
```

Incremental pays off most once the floorplan localizes change: an edit confined to
one pblock reuses P&R for everything else → deterministic ~minutes builds.

## Verify gate (always)

Every impl/bit build runs `fpgaxt_timing_gate` (`vivado/scripts/timing_gate.tcl`):
it prints worst setup slack per clock and **aborts before `write_bitstream` on
negative WNS**. Override only to knowingly flash a marginal build:
`TIMING_GATE_ALLOW_NEG=1`. Safe operating point: clk_sally 100 / clk_sys 133.3 /
clk_pix 148.4 ([[clk_operating_point]]).

## If the floorplan can't tame a path (review §1.3)

Two paths set the ceiling: the ANTIC compositor `pair_idx → col_presH` (13 levels,
58% routing — try floorplan first, pipeline-split if needed) and the CPU↔sally_mem
read mux (the registered-MAR ceiling — treat carefully, it gates turbo). Pipeline
only what floorplan alone can't buy margin on.
