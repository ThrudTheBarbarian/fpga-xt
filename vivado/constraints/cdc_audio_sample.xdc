# cdc_audio_sample.xdc — POKEY's mixed sample crossing clk_sys -> clk_aud.
#
# The audio serialiser asks for a sample once per frame (a toggle through a
# 2-FF synchroniser) and clk_sys answers by latching the 24-bit pair into
# hold_l/hold_r.  The serialiser consumes that pair at the FOLLOWING frame
# start, ~20 us later, so the data has enormous settling time.
#
# But STA does not know that, and it must be told, because clk_sys and clk_aud
# are BOTH derived from fclk_50 — so the tool treats them as related, works out
# a common-edge requirement, and tries to close a 48-bit bus against it.  Left
# unconstrained that is a ~2.4 ns miss on a design whose real margin is 0.15 ns,
# and the timing gate refuses to write a bitstream.
#
# Bound the transfer rather than cutting it: the words must not skew across a
# whole clk_aud period, or a 24-bit sample could tear and put a full-scale click
# on the wire.  81 ns is one clk_aud period (12.28448 MHz) — still ~250x tighter
# than the 20 us the design actually allows, and trivially routable.
#
# Constrain the CLOCKS, not cell names.  A first attempt used
# `-from [get_cells -hier -filter {NAME =~ *hold_l_reg*}]`, which also matched
# combinational cells that carry the register's name (hold_r_reg[23]_i_2) and
# drew a pile of "not a valid startpoint" warnings — a constraint that looks
# applied, is not, and fails silently.  The clock-to-clock form cannot miss:
# the only paths between these two domains ARE this handover.
set_max_delay -datapath_only -from [get_clocks clk_sys_unbuf] -to [get_clocks clk_aud_unbuf] 81.000
set_max_delay -datapath_only -from [get_clocks clk_aud_unbuf] -to [get_clocks clk_sys_unbuf] 81.000
