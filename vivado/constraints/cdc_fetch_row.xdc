# cdc_fetch_row.xdc — bound the plane_fetch fetch_row clk_pix->clk_sys crossing.
#
# plane_fetch captures the 12-bit fetch_row (clk_pix) into row_to_fetch (clk_sys)
# directly on the synchronised line_start flag (line_start_sys), when fetch_row_pix
# is guaranteed stable (held since line_start_d1, ~2-3 clk_sys earlier).  This is a
# valid stable-data + synced-flag transfer, NOT a free-running 2-FF bus sync (that
# multi-bit hazard was the row-128 "rainbow line" — a 127->128 8-bit transition
# caught mid-flight gave a garbage row -> wrong DDR address -> garbage pixels).
#
# set_max_delay -datapath_only keeps the 12 data bits' routing skew well under one
# destination cycle so they all settle before the capture edge.  6.0 ns < both the
# 133 MHz (7.5 ns) and the production 150 MHz (6.67 ns) clk_sys period.  Covers both
# plane_fetch instances (desktop + XL).
set_max_delay -datapath_only \
    -from [get_cells -hier -filter {NAME =~ *plane_fetch*fetch_row_pix_reg[*]}] \
    -to   [get_cells -hier -filter {NAME =~ *plane_fetch*row_to_fetch_reg[*]}] \
    6.0
