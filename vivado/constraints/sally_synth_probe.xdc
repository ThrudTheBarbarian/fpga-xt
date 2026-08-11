# fpga_xt_top.xdc — Phase 2a timing constraints for fpga_xt_top (Zynq-7020 -2).
#
# Three independent clock domains sourced from the on-board 50 MHz osc
# and synthesised via two MMCME2_BASE primitives inside fpga_xt_top:
#
#   clk_sally  120.000   MHz  — xt6502 core, sally_mem, sally_clock, AXI
#                                pad registers (MMCM1 CLKOUT0: VCO 1200 /10).
#                                The xt6502 operating target; the binding
#                                paths are the sally_mem BRAM->hwreg read mux
#                                and the core P/state regs (floorplan-sensitive,
#                                see pblock_sally.xdc).
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
#   - SALLY hwreg writes  → ANTIC bus: deterministic mesochronous toggle handoff
#     (2-FF toggle sync + held payload); covered by the async clock-group below
#   - ANTIC status (NMI/IRQ/HALT) → SALLY: 2-FF synchroniser
#   - vbeam pix → bus signals inside antic_top: 2-FF synchroniser
# All cross-domain paths are CDC-safe; tell STA to skip them via
# set_clock_groups -asynchronous.

# ---- clk_50 pin: actually a 12 MHz crystal (X2), heartbeat-LED only -------
# The Z-Turn's PL clock pin (U14) is a 12 MHz crystal, NOT 50 MHz — so it no
# longer feeds the MMCMs (they run off the PS FCLK_CLK1 = exact 50 MHz; see
# fpga_xt_top.sv).  clk_50 now drives only the free-running heartbeat counter,
# so its period is non-critical, but constrain it honestly at 12 MHz (83.333 ns).
create_clock -name clk_50 -period 83.333 [get_ports clk_50]

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

# ---- Fid-core phi2 CDC (single-phi2 pacing) -------------------------------
# ANTIC's phi2 (clk_sys) is the CPU timing master; the fid 6502 (clk_sally)
# paces its machine cycles off it via a 2-FF sync (phi2f_s0/s1/s2).  The
# async clock-group above already false-paths clk_sys -> clk_sally, so this
# bounds only the specific launch (phi2_cdc_src, a dedicated DONT_TOUCH
# replica in antic_top) -> capture (phi2f_s0) skew so the level lands cleanly.
set_max_delay -datapath_only 7.0 -quiet \
    -from [get_cells -quiet -hier -filter {NAME =~ *phi2_cdc_src_reg*}] \
    -to   [get_cells -quiet -hier -filter {NAME =~ *phi2f_s0_reg*}]

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

# ---- Phase-6 multicycle: the chipset stall cone (clk_sally) ---------------
# The routed worst path (WNS +0.001 on the ba04f4a6 build) was a 17-level
# cone: antic2 DMACTL -> dma_stop/beam geometry -> dma_steal -> fid_rdy ->
# hwreg_we -> register-file CEs.  Every producer on that cone changes only
# at the machine-cycle tick (slot 0 of ~56 clk_sally) or at the SUB_DATA
# write strobe (slot 49); the EARLIEST consumer samples at slot 2
# (fid_mem_step, sally_mem's read step).  The tightest genuine
# launch->capture window through the stall nets is therefore 2 clocks —
# a 2-cycle setup exception is conservative by construction, and hold
# moves back to the launch edge (-hold 1, the standard pairing).
# Scoped -through the KEEP-anchored nets so ONLY the stall cone relaxes:
# the fabric's clock-rate internals (mem_req/mem_valid handshake, strobe
# registration, last-bus latch) do not route through these nets.
# rw_nmi_n is deliberately excluded — the core edge-detects it every clk.
set_multicycle_path -setup 2 -through [get_nets rw_steal]
set_multicycle_path -hold  1 -through [get_nets rw_steal]
set_multicycle_path -setup 2 -through [get_nets rw_rdy_n]
set_multicycle_path -hold  1 -through [get_nets rw_rdy_n]

# Same stall-cone contract for the legacy timing machine's branch of the
# authority mux (iteration 2: with the rewrite cone relaxed, the next worst
# path was dl_ctl -> tm_cycle_type -> fid_rdy -> mbox WE — the identical
# class through the tm nets).
set_multicycle_path -setup 2 -through [get_nets {tm_cycle_type[*]}]
set_multicycle_path -hold  1 -through [get_nets {tm_cycle_type[*]}]
set_multicycle_path -setup 2 -through [get_nets tm_rdy_n]
set_multicycle_path -hold  1 -through [get_nets tm_rdy_n]
