# cdc_fetch_row.xdc — bound the plane_fetch fetch_row clk_pix->clk_sys crossing.
#
# plane_fetch captures the 12-bit fetch_row (clk_pix) into row_to_fetch (clk_sys)
# directly on the synchronised line_start flag (line_start_sys), when fetch_row_pix
# is guaranteed stable (held since line_start_d1, ~2-3 clk_sys earlier).  This is a
# valid stable-data + synced-flag transfer, NOT a free-running 2-FF bus sync (that
# multi-bit hazard was the row-128 "rainbow line" — a 127->128 8-bit transition
# caught mid-flight gave a garbage row -> wrong DDR address -> garbage pixels).
#
# It is a genuinely false path for STA: the transfer is qualified by the synced
# line_start flag, not by the clk_pix/clk_sys relationship, and fetch_row_pix is
# stable for a whole line (~6.7 us) before the capture edge — so the bits always
# settle regardless of routing skew.  -to the clk_sys clock catches the real
# destination robustly (row_to_fetch is absorbed into the row*stride DSP input
# register, so a row_to_fetch_reg cell filter matches nothing).  Covers both
# plane_fetch instances (desktop + XL).
set_false_path \
    -from [get_cells -hier -filter {NAME =~ *plane_fetch*fetch_row_pix_reg[*]}] \
    -to   [get_clocks clk_sys_unbuf]
