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
# Fix: pin sally_mem + sally_core inside CLOCKREGION_X0Y0 (lower-left
# quadrant).  That region has a full BRAM column (≥ 25 RAMB36 sites,
# we use 16) plus ~2 kLUT of slices — more than sally_mem + sally_core
# need.  Forcing co-location eliminates the cross-die routing and makes
# the path's slack reproducible across builds.
#
# Note: this pblock is "soft" (no CONTAIN_ROUTING).  The placer must keep
# the listed cells inside the region; routing across the boundary is
# allowed but the placer will prefer short routes inside the region.

create_pblock pb_sally
add_cells_to_pblock [get_pblocks pb_sally] [get_cells u_sally_mem]
add_cells_to_pblock [get_pblocks pb_sally] [get_cells u_sally_core]
resize_pblock [get_pblocks pb_sally] -add {CLOCKREGION_X0Y0 CLOCKREGION_X1Y0}
