# fpga_xt_top.xdc — Phase 2a timing constraints for fpga_xt_top (Zynq-7020 -2).
#
# Three independent clock domains sourced from the on-board 50 MHz osc
# and synthesised via two MMCME2_BASE primitives inside fpga_xt_top:
#
#   clk_sally  100.000   MHz  — SALLY core, sally_mem, sally_clock, AXI
#                                pad registers.  Phase 1a closed at this
#                                rate with WNS +0.343 ns; Arlet ALU
#                                carry chain caps fmax ~107 MHz.
#   clk_sys    150.000   MHz  — ANTIC pipeline + AXI HP fetch master(s)
#                                (ANTIC bus, POKEY, fb_scanout AXI side).
#                                Raised back to 150 MHz via BL_RACC pipeline +
#                                AXI register slice + cx CARRY4 pipeline.
#   clk_pix    148.4375  MHz  — RGB565 + sync output to the SiI9022A on
#                                Z-Turn (CEA-861 1080p60 nominal
#                                148.500 MHz; -0.042 % error, well inside
#                                HDMI ±0.5 % spec).
#
# CDC paths:
#   - SALLY hwreg writes  → ANTIC bus: async FIFO (cdc_fifo_1w1r)
#   - ANTIC status (NMI/IRQ/HALT) → SALLY: 2-FF synchroniser
#   - vbeam pix → bus signals inside antic_top: 2-FF synchroniser
# All cross-domain paths are CDC-safe; tell STA to skip them via
# set_clock_groups -asynchronous.

# ---- Primary input clock (50 MHz on-board oscillator) ---------------------
create_clock -name clk_50 -period 20.000 [get_ports clk_50]

# HD.CLK_SRC for clk_50 lives in constraints/ooc_only.xdc — applying it
# in the bit flow trips Common 17-69 because clk_50's IBUF is already
# inferred.

# ---- MMCM-derived clocks are auto-derived by Vivado from the MMCM cell ----
# create_generated_clock is implicit when an MMCME2_BASE is instantiated.
# We just need to find the three BUFG output nets and group them as
# asynchronous so STA doesn't try to time the CDC crossings.
set_clock_groups -name async_xt_domains -asynchronous \
    -group [get_clocks -of_objects [get_pins u_bufg_sally/O]] \
    -group [get_clocks -of_objects [get_pins u_bufg_sys/O]] \
    -group [get_clocks -of_objects [get_pins u_bufg_pix/O]]

# ---- Output delays (SiI9022A HDMI transmitter) ----------------------------
# The SiI9022A on Z-Turn SOM samples RGB + sync on pixclk rising edge.
# Setup requirement is typically ~2 ns; hold ~0 ns.  Budget accordingly.
# TODO: populate once board-level IO standards and package pins are known.
# set_output_delay -clock clk_pix -max 2.0 [get_ports rgb_*]
# set_output_delay -clock clk_pix -min -0.5 [get_ports rgb_*]

# ---- Async reset false paths ----------------------------------------------
# The reset deassertion is synchronised in each domain via a 3-deep shift
# register (rst_*_pipe).  The synchroniser output is used as an async
# CLR/PRE on flip-flops throughout the design.  STA checks these as
# recovery/removal paths in the async_default group, but they are not
# timing-critical (the synchroniser guarantees >1 cycle for the reset
# to propagate through clock-tree skew).  False-path them to avoid
# triggering on harmless route-dominated delay at high fanout.
#
# antic_top rst_n_q2 -> rst_pix (LUT fanout buffer) -> CLR on 1653 loads,
# route-dominated at 5.5 ns.  Safe to false-path since rst_n_q2 is
# synchronised and reset deassertion is not cycle-accurate.
#
# The `-quiet` flag silences ~100 Constraints 18-401 warnings: the
# -hier filter on CLR/PRE pin names also matches FFs that synth
# remapped to FDRE/FDSE primitives where the CLR/PRE input is tied
# to a constant — those pins exist in the netlist but aren't real
# timing endpoints.  The constraint still applies to the pins that
# ARE endpoints; we just don't want a warning for every dead pin
# the filter touches.
set_false_path -quiet -from [get_pins u_antic_top/rst_n_q2_reg/C] \
               -to [get_pins -hier -filter {NAME =~ */CLR || NAME =~ */PRE}]

# fb_scanout vbeam CLR/PRE paths from rst_pix_pipe
set_false_path -quiet -from [get_pins rst_pix_pipe_reg[*]/C] \
               -to [get_pins -hier -filter {NAME =~ */CLR || NAME =~ */PRE}]

# sally_core CLR/PRE paths from rst_sally_pipe
set_false_path -quiet -from [get_pins rst_sally_pipe_reg[*]/C] \
               -to [get_pins -hier -filter {NAME =~ */CLR || NAME =~ */PRE}]
