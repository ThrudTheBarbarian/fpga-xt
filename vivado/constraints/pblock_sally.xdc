# pblock_sally.xdc — anchor sally_mem + sally_core in the LEFT clock-region
# column so its placement is reproducible across unrelated netlist churn.
#
# Problem: Without a placement constraint, Vivado's placer scatters
# sally_mem's BRAM banks across multiple BRAM columns (post-impl shows the
# violating path running from RAMB36_X5Y4 → sally_core CARRY4 chain →
# RAMB36_X2Y16 — i.e. opposite sides of the die).  The critical paths are the
# CPU's single-cycle BRAM→ALU loops: a 64 KB read (a 2-deep RAMB36 cascade,
# ~3.7 ns) feeds the 12-bit hidden-stack SP arithmetic + cpu_addr/hwreg mux.
# With ~4.8 ns of logic plus cross-region routing this is the design's tightest
# clk_sally path; keeping the cells together is what makes it close.
#
# History / sizing (read before re-tightening):
#   * 2026-05-22 (pre-sprite netlist): confining to CLOCKREGION_X0Y0 alone
#     gave clk_sally setup +0.005 ns and was REQUIRED to close clk_sys hold
#     (the rst_sys_pipe → xt_blitter/hdmi reset-deassertion paths went
#     -0.18..-0.20 when sally spanned two regions).  X0Y0-only was right then.
#   * 2026-05-25: that trade-off flipped.  task-0013 deleted the 800×600 hdmi
#     display chain (removing most of those reset-deassertion hold paths), the
#     ANTIC compositor grew (collision pipeline etc.), and X0Y0-alone became
#     OVERCROWDED — clk_sally setup fell to -0.348 ns (sally_mem BRAM→hwreg
#     path, 54 % routing, cells spread X14..29/Y16..25) while clk_sys hold sat
#     at a comfortable +0.058 ns.  The single region no longer fits sally.
#
# Fix (2026-05-25): give sally the left column's lower TWO regions
# {X0Y0, X0Y1} so the placer can keep the BRAM→ALU loop compact without
# cross-column routes.  Stays DISJOINT from xt_blitter ({X1Y0,X1Y1}, right
# column — pblock_blitter.xdc) so neither perturbs the other's placement and
# phys_opt's hold-fix stays stable (an overlapping floorplan once crashed
# phys_opt with EXCEPTION_ACCESS_VIOLATION — do NOT overlap).
#
# WATCH clk_sys hold on re-synth: the 2026-05-22 note found two-region sally
# could pull the reset-deassertion paths negative.  With the hdmi chain gone
# and the build's phys_opt+route hold-recovery loop it is expected to close,
# but verify WHS stays positive; if not, the documented real fix is pipelining
# the rst_sys distribution rather than re-confining sally.
#
# Soft pblock (no CONTAIN_ROUTING): placement-only; routing may cross out.

create_pblock pb_sally
add_cells_to_pblock [get_pblocks pb_sally] [get_cells u_sally_mem]
add_cells_to_pblock [get_pblocks pb_sally] [get_cells u_sally_core]
resize_pblock [get_pblocks pb_sally] -add {CLOCKREGION_X0Y0 CLOCKREGION_X0Y1}
