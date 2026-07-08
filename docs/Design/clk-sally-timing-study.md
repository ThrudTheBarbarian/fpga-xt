# clk_sally timing study — the overlay-read regression and how to unwind it

*Thought-experiment / analysis doc (not canonical — see the site for truth).
Written 2026-07-08 during an HDMI-down window, after the TRNG+display-sleep
bitstream forced a fresh placement and exposed how little margin clk_sally has.*

## TL;DR

The 100 MHz `clk_sally` domain now closes at only **+0.023 ns** (and it took the
`ExtraTimingOpt` directive to get there; `Explore` missed at −0.347). The binding
path is **`u_screen_bank` BRAM → sally_mem read mux → 6502 P-flag register**,
10.066 ns, **53 % routing**. This is a *regression* from the fmax chase's
documented 8.36 ns worst path — and the ~1.7 ns delta is entirely the **overlay
read sources** (screen-bank page-flip + the math page) that were bolted onto the
CPU read path *after* that chase concluded. None of it is fundamental; three
independent, low-risk levers unwind it, all **zero cycle-cost**:

| # | Lever | Where | Kind | Attacks | Est. |
|---|-------|-------|------|---------|------|
| A | Floorplan the overlay BRAMs next to the CPU | XDC only | placement | the 53 % route | ~1.5–2.5 ns route |
| B | Give the overlay reads the shallow final-mux slot | `sally_mem.sv` | topology | deep-cascade depth | ~1–1.5 ns logic |
| C | Split adder-Z from non-adder-Z in the flag cone | `xt6502.sv` | topology | the P-flag tail | ~0.5–1 ns logic |

Do **A first** (cheapest, no RTL, deterministic — it removes the directive-luck
dependency). A alone likely restores the +1 ns-class margin the design had before
the overlays. B and C are the structural cleanups that make it durable and could
push toward reclaiming the 120 MHz operating point.

---

## Why this matters now

Two domains are on the knife's edge after the last build: `clk_sally` **+0.023**
and `clk_sys` **+0.004**. At that margin *every* change is a coin-flip — the TRNG
addition tipped `clk_sally` to −0.347 purely by perturbing placement. Reclaiming
real headroom on `clk_sally` (this study) turns the coin-flip back into a
comfortable build and is the prerequisite for ever raising the turbo ceiling
again. (`clk_sys`'s +0.004 is a *separate* ANTIC-compositor path — noted at the
end as follow-up, not addressed here.)

---

## Root cause — decomposed

The path is `screen_bank BRAM(cpu_bram) → sally_mem cpu_rdata mux → xt6502
ALU/flag cone → P_reg[1] (Z flag)`. Route report: logic 4.731 ns (47 %), route
5.335 ns (53 %), 14 levels (`CARRY4×2, LUT2, LUT5×2, LUT6×6, MUXF7×2, MUXF8`).
Two structural faults compound, plus a placement fault:

### Fault 1 — the overlays sit in the *deep* read mux, not the shallow slot

`sally_mem.sv` deliberately splits the CPU read mux (the prior "LEVER-2" work):

- a **shallow final 2:1** — `cpu_rdata = use_rare ? rare_dout : bram_dout_q`
  (`sally_mem.sv:813`) — so the late `bram_dout_q` (~2.1 ns BRAM clk-to-out) only
  ever crosses one mux;
- a **deep 8-level priority cascade** `rare_dout` (`:802-810`) for sources that
  are *early fabric flops*, ready well before the BRAM.

The invariant is *"everything in `rare_dout` is early."* The overlays broke it.
`scrn_cpu_rdata` (`:150`) and `math_cpu_rdata` (`:166`) are declared **"registered
read, aligned with `bram_dout_q`"** — they have the *same* ~2.1 ns BRAM
clk-to-out arrival as the hot path — yet they were inserted mid-cascade at
`:804-805`, so a screen-bank read = **latest arrival + deepest logic**. That is
the 10.066 ns path. (The final 2:1 for `bram_dout_q` was *not* re-deepened — the
overlays built themselves a second, worse path instead.)

### Fault 2 — the P-flag cone is a double-stacked wide mux

The Z/N next-value (`xt6502.sv`, flag writeback `:836-1021`) is selected twice:
`alu_z`/`alu_n` are *themselves* a `case(ir_op)` mux over zero-detects sitting
**downstream of the ALU CARRY4** (`:143-168`), and that already-muxed `alu_z` is
then fed into a **second, wider opcode-class mux** in `exec` (`:982-1019`). The
6×LUT6 tail is that stacking. Non-ALU flags (load/transfer/BIT/pull — just
`byte==0` and `bit7`, no CARRY4 needed) are forced through the same deep mux and
inherit depth they don't need. There is **no** register between the memory read
and this cone on main (the read-pipeline `mdr` experiment is reverted/absent) —
so it is one long combinational run from BRAM to `P_reg`.

### Fault 3 — the overlay BRAMs are free-floating (the 53 % route)

`u_screen_bank` and `u_math_cop` are **top-level siblings** (`fpga_xt_top.sv:1220,
1259`) in **no pblock, with no RLOC anywhere**. Their consumer — the `rare_dout`
mux and the CPU — is pinned to `CLOCKREGION_X0Y0/X0Y1` (`pblock_sally.xdc:41-43`,
a *soft* pblock, placement-only). So the placer drops the overlay BRAMs wherever
it likes and their read bytes route **across the die** into the sally region.
That is the 53 %. It's the same disease the design already cured for the far
`hwreg_dout` (a local re-timing flop `hwreg_dout_q`, `:687-702`) — just never
applied to the overlays. `ExtraTimingOpt` closing where `Explore` failed is the
tell: the placement *can* be pulled tight, we're just leaving it to directive luck.

> **Reconciling with the paused chase.** The fmax-chase memory concluded
> *"floorplan/RLOC is NOT the lever"* — but that was about the **distributed**
> 5-source read *net* (balloon-squeezing: RLOC one source, shove the rest out).
> Fault 3 is different: a **point-to-point** BRAM→mux net whose source is
> *entirely unconstrained*. Pinning a free-floating BRAM near its single consumer
> is genuine, non-balloon-squeezing placement. The overlays post-date that
> analysis, so this doesn't contradict it — it's new ground.

---

## The levers, in detail

### A. Floorplan the overlay BRAMs (do this first)

Add the screen-bank/math CPU-side read BRAMs to a pblock adjacent to (or inside
the free corner of) `CLOCKREGION_X0Y0`, so the `cpu_bram → rare_dout` route stops
crossing the die. XDC-only, no RTL, no cycle cost, and it makes the closure
**deterministic** instead of directive-dependent.

- **Risk:** congesting the already-full sally region if pinned *into* X0Y0/X0Y1.
  Mitigate by pinning *adjacent* (e.g. the BRAM columns of X1Y0) rather than on
  top of the CPU, and by constraining only the CPU-read BRAM, not the whole
  engine (the clk_sys engine side can stay put).
- **Payoff:** directly on the 53 % (5.335 ns). Even halving the overlay route is
  ~1.5–2.5 ns — on its own that lifts +0.023 to a comfortable ~+1.5 ns.
- **Verify:** re-run `bit`; compare the `clk_sally` WNS and the worst-path route %.

### B. Give the overlays the shallow final-mux slot

Restructure the `sally_mem` read mux so the **three late BRAM-class sources**
(`bram_dout_q`, `scrn_cpu_rdata`, `math_cpu_rdata`) resolve in **one balanced
final mux** (a 4:1 / 2-level tree) driven by their **already-cycle-early selects**
(`was_scrn_q`/`was_math_q`, latched `:749-750`), and leave only the genuinely-early
fabric-FF sources (selftest, ctlreg, hwreg, cart, mpd, bank, stack) in the
parallel `rare_dout` branch. All three late sources then see equal, minimal depth.

- **Equivalence:** logically identical (same priority — the overlays are mutually
  exclusive with each other and with `bram_dout_q`). Guard with
  `tb_sally_mem`/`tb_sally`/`tb_sally_math_overlay` + `make boot`.
- **Payoff:** removes the ~8-level cascade from the overlay path (~1–1.5 ns logic).
- **Risk:** low — it's the same common-case-fast pattern already proven for
  `bram_dout_q`; just widened to a 4:1.

### C. Split adder-Z from non-adder-Z in the flag cone

In `xt6502.sv`, compute in parallel with the adder:
`z_fast = mux(M==0, di==0, (A&M)==0, imp_val==0, …)` and `n_fast` (bit 7 of the
same operands); compute `z_alu`/`n_alu` from the CARRY4 result; then a **single
2:1** at the `P[Z]`/`P[N]` assignment: `Z.D = sel_alu ? z_alu : z_fast`. This
lifts the whole wide opcode-class select **off** the critical adder path (it runs
beside the CARRY4), leaving one mux downstream of the adder instead of the
stacked pair. `sel_alu` is a simple early opcode decode (only ADC/SBC/CMP are
adder-Z).

- **Payoff:** ~0.5–1 ns off the flag tail, and it helps **every** flag-setting op
  (both cores, ALU and load paths) — not just the overlay path.
- **Risk:** moderate — it's core ALU/flag logic; must pass **Klaus** ($3469) plus
  `sally_isa`/`sally`/micro, since Z/N correctness is exhaustively checked there.
  BCD is *not* on the Z/N cone (Z takes the binary sum), so decimal is untouched.

---

## Recommended sequence

1. **A (floorplan)** — one XDC, one build. Highest ROI, zero RTL risk, removes the
   directive-luck dependency. Measure; this alone may be enough to make the design
   comfortable again.
2. **B (read-mux)** — if we want the overlay depth gone for good (durable against
   the *next* overlay someone adds). Sim-guarded, then a build.
3. **C (flag cone)** — the broad win that helps clk_sally generally; do it when we
   actually want to push the ceiling back up (120 MHz), gated on Klaus.

Each is independently shippable and independently measurable. A+B together should
comfortably restore the pre-overlay 8.36 ns class (~+1.6 ns at 100 MHz); adding C
starts to reopen the road toward 120.

## Out of scope (follow-up)

- **`clk_sys` +0.004** — a different domain, the ANTIC compositor
  `cur_mode → col_presL` path (per the fmax memory). Not touched here; worth its
  own pass if we want both domains healthy before raising any clock.
- **The fundamental memory-topology wall** (~120–128 MHz) the chase documented
  (5-way distributed read net + decode FSM) is *real* but is **not** what's
  binding today — the overlay regression is. These levers recover the margin the
  overlays cost; they don't claim to break the documented wall.
