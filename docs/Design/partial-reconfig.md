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
- `pb_sally` already pins `{u_sally_core, u_sally_mem}` to `{X0Y0, X0Y1}` and is
  99.9% contained (2 of 2611 leaf cells stray). It is, in effect, the RP fence
  drawn already.

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

1. **Wrap the loop in one module** — DFX needs the RP to be a single hierarchical
   instance. Create `sally_subsystem` containing `xt6502` + `sally_mem` (+ the
   sally CDC syncs that belong to the loop), exposing exactly the slow boundary in
   §2. **Hierarchy-only refactor, no logic change** — verifiable with `make boot` /
   `make klaus` (bit-exact) before any DFX. This is the first concrete step.
2. **Pin the RP pblock** — keep `pb_sally`'s `{X0Y0, X0Y1}` as the RP region
   (`SNAPPING_MODE`, `RESET_AFTER_RECONFIG` per DFX rules); it already holds the
   loop. Disjoint from `pb_blitter` (no overlap — overlap once crashed phys_opt).
3. **DFX flow** — mark `sally_subsystem` as a `PARTITION_DEF` / Reconfigurable
   Partition; build the **static** design once, then each **Reconfigurable Module**
   (turbo xt6502 = RM0; fidelity core = RM1; m68k-JIT shim = RM2) as a partial
   bitstream against the locked static. Static keeps desktop/video/blitter/ANTIC.
4. **Swap at runtime** — A9 loads a partial bitstream over the ICAP/PCAP into the
   RP while the static (HDMI, compositor, ANTIC) stays live; assert
   `RESET_AFTER_RECONFIG` to the RP, reload CPU state.

## 4. Why now

The floorplan that makes builds deterministic and the RP fence are the **same**
investment (architecture-review §1.4). `pb_sally` + the slow boundary are already
in place; step 1 (the `sally_subsystem` wrapper) is the only RTL prerequisite and
is risk-free (hierarchy). DFX itself is a build-flow change, gated behind the
wrapper landing + a green `make boot`/`make klaus`.

## 5. Not blocking fMax

The RP does **not** raise clk_sally — the loop's depth is unchanged. Reaching
120 MHz is the separate logic-restructure task ([[xt6502_clean_sheet]]: read-
pipeline tried & reverted; residual levers are page_cache RLOC + LUTRAM ZP/stack
tiers). The RP just lets us *swap* cores at the achieved fMax without disturbing
the live static design.
