No pblocks — deliberate, measured 2026-07-22.
=============================================

pblock_blitter.xdc (u_xt_blitter -> X1Y0/X1Y1) and pblock_sally.xdc
(u_sally_mem + u_sally_core -> X0Y0/X0Y1) were REMOVED. Read this before
re-adding a floorplan constraint.

Why they were wrong by 2026-07:

  * SIZED FOR A MODULE THAT NO LONGER EXISTS. pblock_blitter was written for
    "xt_blitter (~2.7 k cells, 6 RAMB36)". Measured on the routed design it is
    now leaves=20239 LUT=10299 FF=8318 BRAM=10 — 7.5x larger — still confined
    to the two clock regions chosen for the small version.

  * PINNED THE WRONG CPU. pb_sally pinned u_sally_core (the TURBO core) while
    u_fid_core — the power-on default that the ACID800 work runs on — was left
    unconstrained.

  * THEY CAUSED THE INSTABILITY THEY EXISTED TO PREVENT. Their stated purpose
    was reproducible placement across netlist churn. With them, clk_sys setup
    across consecutive builds ran -0.096, -0.069, -0.096, 0.000, +0.023 —
    coin-flipping on placer seed, repeatedly failing the timing gate.

Measured, same RTL, two placer directives (setup / hold, ns):

                          clk_sys        clk_sally      clk_pix
  pblocks,   Explore      +0.000/+0.027  +0.079/+0.032  +0.142/+0.105
  none,      Explore      +0.020/+0.067  +0.028/+0.116  +0.141/+0.067
  none,      ExtraTimingOpt +0.016/+0.036 +0.119/+0.073 +0.197/+0.066

Both unconstrained builds close setup AND hold on every clock. clk_sys hold —
the pblocks' whole justification — is BETTER without them (+0.067 / +0.036 vs
+0.027). The placer also co-locates u_fid_core, u_sally_core and u_sally_mem in
the same regions on its own, which is what pb_sally was hand-written to force.

Verified functionally on HW: boots, /bin/blittest byte-identical to baseline
(STRETCH bilinear corner=abcd0000 mid=abcd0009), ACID800 antic_vcount /
pokey_noise / cpu_timing / gtia_collision all pass.

If clk_sys goes negative again, prefer fixing the PATH over re-pinning cells —
the last real win was pipelining the blitter's bilinear tap operands (commit
3918b57: 19 logic levels -> 8). A pblock is a blunt instrument that goes stale
silently as the module it names grows.


Directive sweep, 2026-07-22 (no pblocks, blitter DO_REG enabled)
----------------------------------------------------------------
Removing the pblocks widened the solution space and raised the pass rate from
2-of-5 builds to 4-of-5 — but the design is NOT robust to arbitrary placement:

    directive               clk_sys setup/hold    gate
    Default                   -0.028 / +0.036     FAIL
    Explore                   +0.024 / +0.036     pass
    ExtraPostPlacementOpt     +0.016 / +0.036     pass
    ExtraNetDelay_high        +0.065 / +0.036     pass
    AltSpreadLogic_high       +0.121 / +0.009     pass
    ExtraTimingOpt            +0.123 / +0.009     pass  (HW-verified build)

Setup varies across a 0.15 ns spread; hold is stable at +0.036 EXCEPT for the
two directives that buy the best setup by spending hold down to +0.009. That is
a real setup/hold trade the placer makes, not noise.

Because Vivado's own Default lands negative, run-valhalla.sh now defaults
PLACE_DIRECTIVE to ExtraTimingOpt rather than leaving it empty. Every good build
before that point only happened because a directive was passed explicitly.
