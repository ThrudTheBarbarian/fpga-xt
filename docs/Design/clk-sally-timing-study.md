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

## Build result — Lever A tested, and what it revealed (2026-07-08)

A coarse clock-region pblock pinning the overlays to `CLOCKREGION_X0Y2` (the only
region adjacent to sally that doesn't *overlap* `pb_sally`) **regressed** clk_sally
from +0.023 to **−0.583 ns**. The lesson is the useful part: **`ExtraTimingOpt`
already floorplans the overlays near-optimally** — that is precisely why it closes
at +0.023 where `Explore` misses at −0.347. The "free-floating BRAM hauls across
the die" failure is an *`Explore`* artifact; `ExtraTimingOpt`'s timing-driven
placement pulls the BRAM near the mux on its own. Forcing X0Y2 dragged it *farther*
than the directive's own choice.

So **Lever A is effectively subsumed by the build's default directive**
(`ExtraTimingOpt`, already the `build.tcl` default): the placement half of the
problem is handled without an explicit pblock, and a disjoint pblock can't beat it
(X0Y2 is too far; X0Y1 — right next to the mux — is inside `pb_sally`, so a
separate pblock there would overlap and risk the phys_opt crash). **Recommendation
change: don't chase an explicit overlay floorplan.** Keep `ExtraTimingOpt` and put
the effort into the *logic-depth* levers below, which the directive **cannot**
touch (placement can't shorten a 14-level combinational path). The path is 47 %
logic (4.731 ns) — that is the addressable-by-restructuring headroom.

## Build result — Lever B tested (2026-07-08)

Lever B landed and is equivalence-clean (tb_sally_math_overlay / sally / sally_isa
/ boot all pass). It did exactly what it was designed to: the worst clk_sally path
went **14 → 10 logic levels, logic 4.731 → 3.635 ns** (−1.1 ns) and the path length
10.066 → 9.258 ns. **But the slack barely moved: +0.023 → +0.025 ns**, because the
binding path is now **61 % route** (5.623 ns) — it flipped to
`u_math_cop/page_bram → u_sally_mem/…/WEA`, i.e. the **free-floating overlay BRAM
hauling across the die**. Logic reduction cannot move a route-bound path.

**Empirical conclusion: clk_sally is routing-dominated, exactly as the fmax memory
predicted.** The remaining lever is genuinely the *route* — get the overlay BRAMs
physically next to `sally_mem` — NOT more logic (so Lever C, also logic-only, would
likewise not move a route-bound path; keep it as a tidy-up, not a margin play). The
coarse-pblock attempt (X0Y2) failed because it's too far; the route only shortens
if the overlay BRAM lands *in/adjacent to* the sally region — which is the same
static-memory-block floorplan the **PR effort** requires anyway (CPU in a top-right
reconfigurable partition, memory static beside it). So the right home for the
aggressive floorplan is the PR design, done deliberately, not incremental pblock
pokes now.

**Net:** Lever B is banked as a durable *structural* win (shallower read path,
PR-friendlier, robust to the next overlay someone bolts on) even though it didn't
buy margin on this routing-bound build. Real clk_sally margin waits on the
memory-block floorplan (PR work).

## Build result — co-location sweep, and the real binding domain (2026-07-08)

Pushed the co-location properly (folded into pblock_sally.xdc — a separate augment
file failed: the constraint glob is unsorted, so it ran before pb_sally existed).
Expanded pb_sally to `{X0Y0,X0Y1,X0Y2}` with both overlay engines as members, and
swept two route-focused directives in parallel on valhalla:

| domain | Lever B (no co-loc) | co-loc ExtraTimingOpt | co-loc ExtraNetDelay_high |
|--------|--------------------:|---------------------:|--------------------------:|
| clk_sally | +0.025 | **+0.077** | −0.230 (fail) |
| clk_sys   | **+0.003** | +0.000 | +0.010 |
| clk_pix   | +0.206 | +0.309 | +0.066 |
| **min (governs the build)** | **+0.003** | +0.000 | fail |

The co-location DID shorten the clk_sally route (5.623 → 4.867 ns, slack +0.025 →
+0.077) — but expanding into X0Y2 **robbed clk_sys** (the ANTIC compositor lives
there): +0.003 → +0.000.  The governing *minimum* margin went from +0.003 to
+0.000 — a net loss.  Balloon-squeezing on a near-full 7020, exactly as the fmax
memory warned: the overlay route is genuinely shortenable, but the SPACE it claims
isn't free.  **Reverted.**

**The real finding: clk_sally was never the binding domain — clk_sys is.** With the
right directive (ExtraTimingOpt) clk_sally sits at +0.025..+0.077; the design's
governing margin is **clk_sys +0.003** (the ANTIC-compositor `cur_mode → col_presL`
path, out of scope of this sally study).  clk_sally only *fails* under the wrong
directive (Explore −0.347) — which is what the TRNG change first exposed.  So:
- **Lever B is the keeper** — it made clk_sally structurally shallower (durable,
  PR-friendly) without touching clk_sys; it's banked.
- **Incremental floorplan is a dead end here** — zero-sum on a full die.  The route
  belongs to the PR whole-die refloor (deliberate, not a squeeze).
- **If more OVERALL margin is wanted, the target is clk_sys** (a different domain /
  a separate study), not clk_sally.

## Recommended sequence (revised twice)

**A: done-by-directive** (ExtraTimingOpt) for the monolithic build; becomes a
*deliberate static-memory floorplan* under PR. **B: done** — structural, banked.
**C: deprioritised** — logic-only, won't move a route-bound path; do it only as
cleanup or once the route is fixed and logic re-binds.


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
