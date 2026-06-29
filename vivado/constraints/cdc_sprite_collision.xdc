# cdc_sprite_collision.xdc — bound the sprite_engine collision snapshot
# clk_pix->clk_fetch crossing.
#
# sprite_engine accumulates the per-pixel opaque-sprite mask into coll_acc
# (clk_pix), snapshots it into coll_snap at frame_start, and the clk_fetch side
# loads coll_snap into the collision[] readback regs on the synchronised
# coll_tgl edge (coll_frame_pulse).  coll_snap is held stable for a whole frame
# (~16.7 ms) before that capture edge, so this is a valid stable-data +
# synced-flag transfer, NOT a free-running 2-FF bus sync (the multi-bit hazard
# that gave the row-128 "rainbow line" / cursor-blob flicker — see
# cdc_fetch_row.xdc / cdc_sprite_vcount.xdc).
#
# Genuinely false for STA: the transfer is qualified by the synced flag, not the
# clk_pix/clk_fetch relationship, and coll_snap settles a whole frame before the
# capture.  False from the SOURCE cells only (no -to), matching the sibling CDC
# XDCs.  The correctness is in the RTL; this is hygiene + future-proofing.
set_false_path \
    -from [get_cells -hier -filter {NAME =~ *coll_snap_reg[*]}]
