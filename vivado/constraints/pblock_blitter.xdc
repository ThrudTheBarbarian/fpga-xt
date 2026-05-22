# pblock_blitter.xdc — anchor xt_blitter in the right-hand clock-region
# column so its placement is reproducible across unrelated netlist churn.
#
# Problem: xt_blitter (~2.7 k cells, 6 RAMB36 + 1 RAMB18) has no placement
# constraint, so the placer scatters it wherever the global optimiser
# prefers — by default on top of sally in X0Y0/X1Y0.  Because it shares
# regions with sally, an unrelated change on the SALLY side (e.g. a CPU
# fix that adds a few cells) shifts the placer's choices for xt_blitter
# and tips its already-marginal clk_sys hold negative (observed:
# WHS=-0.18 ns, 381 endpoints, after a sally/cpu.v change with no logical
# connection to xt_blitter).  The build's route-time hold fix then has to
# rescue a placement that moved for no good reason.
#
# Fix: pin xt_blitter into {X1Y0, X1Y1} — the right column's lower two
# regions (60 RAMB36, 5800 SLICE; xt_blitter fills ~47 % of the slices and
# 10 % of the BRAM).  X1Y0 sits next to the PS / AXI-HP ports at the die
# edge: xt_blitter is an AXI master (DDR source/dest fetch), and keeping it
# on the bottom row is REQUIRED for clk_sys hold to close — a trial that
# moved it to the upper regions {X1Y1,X1Y2} left clk_sys hold at -0.197 ns
# that even three phys_opt+route recovery passes could not fix.
#
# sally is confined to X0Y0 alone (pblock_sally.xdc; required for clk_sys
# hold to close); xt_blitter takes {X1Y0,X1Y1}.  The two are DISJOINT (no
# shared region) so neither perturbs the other's placement and phys_opt's
# hold-fix stays stable (an earlier overlapping floorplan crashed it with an
# EXCEPTION_ACCESS_VIOLATION).  sprite_engine, fb_scanout, and PS/HDMI glue
# stay unconstrained in the remaining fabric (X0Y1/X0Y2/X1Y2 + unused parts).
#
# Soft pblock (no CONTAIN_ROUTING): placement-only, routing may cross out.

create_pblock pb_blitter
add_cells_to_pblock [get_pblocks pb_blitter] [get_cells u_xt_blitter]
resize_pblock [get_pblocks pb_blitter] -add {CLOCKREGION_X1Y0 CLOCKREGION_X1Y1}
