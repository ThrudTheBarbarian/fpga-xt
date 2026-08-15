# cdc_audio_sample.xdc — POKEY's mixed sample crossing clk_sys -> clk_aud.
#
# The audio serialiser asks for a sample once per frame (a toggle through a
# 2-FF synchroniser) and clk_sys answers by latching the 24-bit pair into
# hold_l/hold_r.  The serialiser consumes that pair at the FOLLOWING frame
# start, ~20 us later, so the data has enormous settling time — but the path is
# still asynchronous and must not be timed as if it were not, or the tools will
# try (and fail) to close it against a same-cycle relationship that does not
# exist.
#
# Bound the transfer rather than cutting it: the words must not skew across a
# whole clk_aud period, or a 24-bit sample could tear and put a full-scale click
# on the wire.  81 ns is one clk_aud period (12.28448 MHz), which is ~500x
# tighter than the 20 us the design actually allows.
set_max_delay -datapath_only -from [get_cells -hier -filter {NAME =~ *hold_l_reg*}] 81.000
set_max_delay -datapath_only -from [get_cells -hier -filter {NAME =~ *hold_r_reg*}] 81.000

# The request toggle is a true one-bit CDC through ASYNC_REG flops; only the
# skew rule above matters for correctness, so let the toggle itself be relaxed.
set_max_delay -datapath_only -from [get_cells -hier -filter {NAME =~ *aud_req_reg*}] 81.000
