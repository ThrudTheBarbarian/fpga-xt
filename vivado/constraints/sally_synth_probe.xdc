# fpga_xt_top.xdc — Phase 1 timing constraints for fpga_xt_top (Zynq-7020 -2).
#
# Phase 1a: all domains share a single physical clock (clk_50).
# Constrain clk_50 at the SALLY target frequency (121 MHz / 8.22 ns)
# to verify the integrated design closes at that speed.
#
# Phase 1b: when a PLL generates separate clocks, each domain will
# get its own create_clock constraint with set_clock_groups for CDC.

# ---- Primary input clock (121 MHz target for Phase 1a) --------------------
create_clock -name clk_50 -period 8.22 [get_ports clk_50]

# ---- Output delays (SiI9022A HDMI transmitter) ----------------------------
# The SiI9022A on Z-Turn SOM samples RGB + sync on pixclk rising edge.
# Setup requirement is typically ~2 ns; hold ~0 ns.  Budget accordingly.
# TODO: populate once board-level IO standards and package pins are known.
# set_output_delay -clock clk_pix -max 2.0 [get_ports rgb_*]
# set_output_delay -clock clk_pix -min -0.5 [get_ports rgb_*]
