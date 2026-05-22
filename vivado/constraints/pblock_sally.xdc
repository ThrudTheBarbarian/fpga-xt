# pblock_sally.xdc — anchor sally_mem + sally_core inside one clock region.
#
# Problem: Without a placement constraint, Vivado's placer scatters
# sally_mem's BRAM banks across multiple BRAM columns (post-impl shows the
# violating path running from RAMB36_X5Y4 → sally_core CARRY4 chain →
# RAMB36_X2Y16 — i.e. opposite sides of the die).  The path is the CPU's
# stack-pointer write-back: BRAM read DATA → ALU adders → BRAM write
# ADDR.  With ~4 ns of logic in the carry chains and ~5 ns of cross-die
# routing, post-route WNS lands at −0.12 ns on a path that pre-sprite was
# +0.106 ns.  The slack delta is dominated by placer variance: adding
# unrelated cells perturbs the placer's LOC choices for sally_mem's
# BRAMs without any real resource pressure (BRAM util ~52 %, slice
# util ~31 %).
#
# Fix: pin sally_mem + sally_core inside CLOCKREGION_X0Y0 alone (30 RAMB36
# for sally_mem's 17, 2500 SLICE for ~1.1 k cells).
#
# IMPORTANT — this MUST stay a single region.  A floorplan study (2026-05-22)
# found that letting sally span two regions (any pairing: {X0Y0,X1Y0},
# {X0Y0,X0Y1}, or overlapping xt_blitter) lifts clk_sally setup to
# +0.12..+0.16 ns BUT breaks clk_sys hold (-0.18..-0.20 ns on the
# rst_sys_pipe -> xt_blitter/hdmi CLR reset-deassertion paths) that even
# three phys_opt+route hold-recovery passes cannot fix; one overlapping
# variant crashed phys_opt outright.  Confining sally to X0Y0 keeps the
# reset distribution compact enough that clk_sys hold closes (+0.057 ns),
# at the cost of a tight-but-positive clk_sally setup (+0.005 ns).  The two
# goals are mutually exclusive without reworking the sys-reset pipeline.
#
# Note: this pblock is "soft" (no CONTAIN_ROUTING).  The placer must keep
# the listed cells inside the region; routing across the boundary is
# allowed but the placer will prefer short routes inside the region.

create_pblock pb_sally
add_cells_to_pblock [get_pblocks pb_sally] [get_cells u_sally_mem]
add_cells_to_pblock [get_pblocks pb_sally] [get_cells u_sally_core]
resize_pblock [get_pblocks pb_sally] -add {CLOCKREGION_X0Y0}
