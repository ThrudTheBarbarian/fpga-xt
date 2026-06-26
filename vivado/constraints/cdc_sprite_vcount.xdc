# cdc_sprite_vcount.xdc — bound the sprite_engine next_vcount clk_pix->clk_fetch crossing.
#
# sprite_engine captures the 12-bit pix_next_vcount (clk_pix) into next_vcount_q
# (clk_fetch) directly on the synchronised fetch_line_start flag, when
# pix_next_vcount is guaranteed stable (held since line_start, ~2-3 clk_fetch
# cycles earlier).  This is a valid stable-data + synced-flag transfer, NOT a
# free-running 2-FF bus sync.  That multi-bit hazard — a carry such as 127->128
# caught mid-flight, some flops old / some new — gave a garbage scanline number
# -> the fetcher read the WRONG arena row -> a stale/foreign row splattered into
# the line cache (the cursor "blob"/right-edge flicker).  Same failure/fix class
# as the row-128 "rainbow line" fetch_row CDC.
#
# Genuinely false for STA: the transfer is qualified by the synced flag, not by
# the clk_pix/clk_fetch relationship, and pix_next_vcount is stable for a whole
# line (~6.7 us) before the capture edge, so the bits always settle regardless of
# routing skew.  False from the SOURCE cells only (no -to), matching the
# cdc_fetch_row.xdc approach (the -to cell is absorbed downstream and the dest
# clock is not yet named when this XDC is read).  NOTE: the fix is in the RTL and
# closes timing without this constraint — this is hygiene + future-proofing.
set_false_path \
    -from [get_cells -hier -filter {NAME =~ *pix_next_vcount_reg[*]}]
