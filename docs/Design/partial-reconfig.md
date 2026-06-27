# Partial-reconfiguration foundation — the CPU Reconfigurable Partition

Foundation for the dual-CPU cold-swap (turbo xt6502 ↔ fidelity core ↔ JIT-m68k
host) with the desktop/video staying live (architecture-review §1.4,
[[xtos-vision]], [[m68k_core_mmu_requirements]]). This doc records what the
Reconfigurable Partition (RP) is, why it is fMax-neutral, and the steps to stand
up the Vivado DFX flow. Build-host work; staged.

## 1. The RP is the clk_sally loop = `{xt6502 + sally_mem}`

PR is only fMax-neutral if the RP **contains the entire `clk_sally` critical
loop**, so the partition boundary carries only slow signals (no single-clk-sally
path crosses it). Measured on the routed design (2026-06-27):

- The clk_sally **binding path** is fully internal: `sally_mem` BRAM →
  `IR`/`adl`/`PC` decode → `page_cache` tag-match (`code_page_match`) → `state_q`
  → `data_flush_idx` — all in `u_sally_mem` (incl. `g_page_cache`) and
  `u_sally_core`, placed in **X0Y0** (page_cache + binding cells) / X0Y0–X0Y1
  (sally_mem). So the registered-MAR read loop never leaves the partition.
- `pb_sally` pins `{u_sally_core, u_sally_mem}` to `{X0Y0, X0Y1}` and is 99.9%
  contained — BUT it is a **soft** placement hint, **not** an RP. Today X0Y0/X0Y1
  are also full of *static* ANTIC/compositor logic interleaved with sally. That is
  the opposite of what DFX needs (see §2a).

## 2a. The RP region must be EXCLUSIVE — the hard part

> **FEASIBILITY: GO (proven 2026-06-27).** Two `EXCLUDE_PLACEMENT` experiments (an
> exclusive-RP proxy without the full DFX flow):
> - **RP = {X0Y0,X0Y1} → FAIL at placement.** Those regions hold immovable hard
>   blocks — `mmcm1` (X0Y0), the BUFGs, and the PS7 interface — which can't be
>   evicted (`ERROR Place 30-1131: insufficient capacity to place PS7`). The PS/AXI
>   corner where sally naturally sits cannot be an RP.
> - **RP = {X1Y2} (the only hard-block-free region) → PASS.** Sally placed
>   exclusively there, all static evicted into the other regions, design **routed
>   and closed**: clk_sally **+0.055**, clk_sys +0.007, clk_pix +0.225 (vs the
>   shared-placement baseline +0.309 / +0.001 / +0.128). The ~0.25 ns clk_sally hit
>   is the price of the RP being far from the PS/AXI, but it stays ≥0 at 100 MHz —
>   confirming the §2 slow-boundary thesis (the RP *can* live away from the PS).
>
> Conclusion: **DFX of the CPU is viable on the 7020 with the RP in X1Y2.** Hard
> blocks (`mmcm1`=X0Y0, `mmcm2`=X1Y0, PS7=left edge, BUFGs=centre) rule out the
> bottom row; X1Y2 is the home. Cost: ~0.25 ns clk_sally (acceptable at 100; would
> bite a future 120 push). The experiment is reverted on main (it costs margin for
> no benefit until DFX is actually wired).

A partial bitstream rewrites every CLB/BRAM/DSP frame in the RP region, so **no
static logic may live there**. Marking the cell `HD.RECONFIGURABLE` makes Vivado
reserve the RP pblock for the RM and evict static automatically — but the static
must then **fit in the fabric *minus* the RP region**. Consequences on this 7020:

- **The RP must contain `sally_mem`** (the registered-MAR + page-cache loop), not
  just `sally_core` — otherwise the fast loop crosses the partition pins and §1's
  fMax-neutrality is lost. So the RP region needs **~22 BRAM of its own**,
  exclusively, plus room for the largest RM's logic.
- **Size for the largest RM**: turbo `xt6502` vs the cycle-exact fidelity 6502
  core. (The m68k host is on the spare A9 via JIT — NOT a fabric RM
  [[m68k_core_mmu_requirements]] — so it does not size the RP.)
- **GO/NO-GO feasibility (must verify FIRST):** can the static design
  (ANTIC/GTIA/video/blitter/sprite/PS) fit in the fabric minus a ~22-BRAM RP
  region?

  **Budget (RAMB36 per region, measured): X0Y0 30 · X0Y1 10 · X0Y2 10 · X1Y0 30 ·
  X1Y1 30 · X1Y2 30 = 140.** Naive candidate {X0Y0} was disproven (hard blocks,
  §2a); the working RP is **{X1Y2}** (30 BRAM, 2600 SLICE, hard-block-free):
  - RP needs: sally_core (1321 cells, 0 BRAM) + sally_mem (1294 cells, **22 BRAM**)
    ≈ 2615 cells / ~1.9k LUT / 22 BRAM → fits X1Y2 (22 ≤ 30 BRAM). One whole clock
    region, frame-aligned. ✓ (proven: placed + closed.)
  - Static gets the other five regions: **110 BRAM** and ~10.2k SLICE; it needs
    ~**52 BRAM** + ~16k LUT → fits. ✓ (proven: evicted + routed.)

  Confirmed by the §2a experiments. If the largest RM (fidelity core) outgrows one
  region, widen to {X1Y1,X1Y2} (60 BRAM) — but X1Y1 is `pb_blitter` today, so the
  blitter would need to move. [[cheap_7020_second_target]] is the same LUT/BRAM so
  it's no escape;
  only a larger Zynq would be. **This check gates everything below.**

## 2. The boundary (future partition pins) is all slow

`xt6502`'s external interface is the classic 6502 bus, stable-per-emulated-cycle:

```
clk_sally, rst_sally,
addr[15:0], data_in[7:0], data_out[7:0], rw, rdy,   // bus to sally_mem (INTERNAL to RP)
irq_n, nmi_n,                                        // ANTIC via CDC (slow)
stack_op, s_high[3:0]                                // hidden-stack hints
```

`addr/data/rw/rdy` close the loop with `sally_mem` and must be **inside** the RP.
The RP's *external* boundary is therefore `sally_mem`'s connections to the rest of
the system:

- **AXI-HP master → DDR** (banked reader / page-cache refill) — registered AXI
  handshake; far from single-cycle critical.
- **hwreg / `$D4xx` bus** (GTIA/POKEY/PIA/ANTIC register access) — per-access, slow.
- **ANTIC DMA-steal / `rdy` / `halt`** — CDC'd, level signals.
- **irq_n / nmi_n** — CDC'd from ANTIC.
- **clk_sally / rst_sally**.

None is a clk_sally single-cycle critical net ⇒ the partition pins are slow ⇒
**PR is fMax-neutral**, the precondition from architecture-review §1.4.

## 3. Foundation steps (in order)

0. **GO/NO-GO — DONE, PASSED (§2a).** EXCLUDE_PLACEMENT experiments proved an
   exclusive RP at **{X1Y2}** places, evicts all static into the rest, routes, and
   closes (clk_sally +0.055). Region settled. (Bottom-row/X0Y0 RP impossible — hard
   blocks.)
1. **Wrap the loop in one module** — DFX needs the RP to be a single hierarchical
   instance. Create `sally_subsystem` containing `xt6502` + `sally_mem` (+ the
   sally CDC syncs that belong to the loop), exposing exactly the slow boundary in
   §2. **Hierarchy-only refactor, no logic change** — verifiable with `make boot` /
   `make klaus` (bit-exact) before any DFX.
2. **Make the RP region EXCLUSIVE** — give `sally_subsystem` a pblock sized for the
   largest RM + its ~22 BRAM, with `SNAPPING_MODE=ON`, `RESET_AFTER_RECONFIG=TRUE`,
   frame-aligned (whole clock regions). This REPLACES the soft `pb_sally`: static is
   evicted from the region, not merely discouraged. Disjoint from `pb_blitter`.
3. **DFX flow** — mark `sally_subsystem` `HD.RECONFIGURABLE`; build the **static**
   design once, then each **Reconfigurable Module** (turbo xt6502 = RM0; fidelity
   core = RM1) as a partial bitstream against the locked static. Static keeps
   desktop/video/blitter/ANTIC live.
4. **Swap at runtime** — A9 loads a partial bitstream over PCAP into the RP while
   the static (HDMI, compositor, ANTIC) stays live; assert `RESET_AFTER_RECONFIG`
   to the RP, reload CPU state.

## 4. Status / why it's not just "draw a fence"

The two *easy* preconditions are met: the clk_sally loop is identified and the RP
boundary is provably slow (§1–2), and the `sally_subsystem` wrapper (step 1) is a
risk-free hierarchy refactor. **But the gate is step 0** — DFX needs the RP region
*exclusive*, so the static design must fit in the fabric minus a ~22-BRAM reserved
region. The soft `pb_sally` does NOT establish that (static coexists in X0Y0/X0Y1
today). On a BRAM-54% 7020 this is genuinely uncertain and must be proven by a
placement experiment before the wrapper or DFX flow is worth building. If it
doesn't fit, DFX is a bigger-part feature, not a 7020 one.

## 5. Not blocking fMax

The RP does **not** raise clk_sally — the loop's depth is unchanged. Reaching
120 MHz is the separate logic-restructure task ([[xt6502_clean_sheet]]: read-
pipeline tried & reverted; residual levers are page_cache RLOC + LUTRAM ZP/stack
tiers). The RP just lets us *swap* cores at the achieved fMax without disturbing
the live static design.
