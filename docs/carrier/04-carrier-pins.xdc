# ============================================================================
# fpga-xt carrier pin constraints  --  DRAFT (do not build as-is)
#
# Net names + IOSTANDARD/slew/drive are complete; every PACKAGE_PIN is the
# token __TBD__ and MUST be replaced with the real Zynq ball before use.
#   - ball numbers: Z-Turn schematic sheet 3 (Bank 35 / Bank 13 IO_Bxx_LP/LN
#     -> XC7Z020 ball), cross-referenced to the CN1/CN2 pin via sheet 15.
#   - proposed net -> IO_B35/IO_B13 grouping: docs/carrier/03-schematic-sheets.md, Sheet 2.
# Whole carrier is one 3.3 V domain -> LVCMOS33 throughout (TMDS_33 for any
# differential expansion pairs, added when that pinout is finalized).
# When filled, merge into vivado/constraints/ alongside zturn_board.xdc.
#
# Top-level ports assumed (to be exposed by fpga_xt_top when the carrier path
# is wired out of antic_top): bus_data[7:0] is bidirectional (IOBUF, OE =
# bus_data_oe). The internal RTL names are kept where they already exist.
# ============================================================================

# ---- Cart/PBI shared bus : Bank 35 -> CB3T16210 A side ----------------------

# Address A0..A15 (outputs)
set_property -dict {PACKAGE_PIN __TBD__ IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8} [get_ports {bus_addr_o[0]}]
set_property -dict {PACKAGE_PIN __TBD__ IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8} [get_ports {bus_addr_o[1]}]
set_property -dict {PACKAGE_PIN __TBD__ IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8} [get_ports {bus_addr_o[2]}]
set_property -dict {PACKAGE_PIN __TBD__ IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8} [get_ports {bus_addr_o[3]}]
set_property -dict {PACKAGE_PIN __TBD__ IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8} [get_ports {bus_addr_o[4]}]
set_property -dict {PACKAGE_PIN __TBD__ IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8} [get_ports {bus_addr_o[5]}]
set_property -dict {PACKAGE_PIN __TBD__ IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8} [get_ports {bus_addr_o[6]}]
set_property -dict {PACKAGE_PIN __TBD__ IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8} [get_ports {bus_addr_o[7]}]
set_property -dict {PACKAGE_PIN __TBD__ IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8} [get_ports {bus_addr_o[8]}]
set_property -dict {PACKAGE_PIN __TBD__ IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8} [get_ports {bus_addr_o[9]}]
set_property -dict {PACKAGE_PIN __TBD__ IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8} [get_ports {bus_addr_o[10]}]
set_property -dict {PACKAGE_PIN __TBD__ IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8} [get_ports {bus_addr_o[11]}]
set_property -dict {PACKAGE_PIN __TBD__ IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8} [get_ports {bus_addr_o[12]}]
set_property -dict {PACKAGE_PIN __TBD__ IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8} [get_ports {bus_addr_o[13]}]
set_property -dict {PACKAGE_PIN __TBD__ IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8} [get_ports {bus_addr_o[14]}]
set_property -dict {PACKAGE_PIN __TBD__ IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8} [get_ports {bus_addr_o[15]}]

# Data D0..D7 (bidirectional - IOBUF, OE = bus_data_oe)
set_property -dict {PACKAGE_PIN __TBD__ IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8} [get_ports {bus_data[0]}]
set_property -dict {PACKAGE_PIN __TBD__ IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8} [get_ports {bus_data[1]}]
set_property -dict {PACKAGE_PIN __TBD__ IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8} [get_ports {bus_data[2]}]
set_property -dict {PACKAGE_PIN __TBD__ IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8} [get_ports {bus_data[3]}]
set_property -dict {PACKAGE_PIN __TBD__ IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8} [get_ports {bus_data[4]}]
set_property -dict {PACKAGE_PIN __TBD__ IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8} [get_ports {bus_data[5]}]
set_property -dict {PACKAGE_PIN __TBD__ IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8} [get_ports {bus_data[6]}]
set_property -dict {PACKAGE_PIN __TBD__ IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8} [get_ports {bus_data[7]}]

# Clock + control (outputs)
set_property -dict {PACKAGE_PIN __TBD__ IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8} [get_ports phi2_o]
set_property -dict {PACKAGE_PIN __TBD__ IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8} [get_ports bus_rw_o]
set_property -dict {PACKAGE_PIN __TBD__ IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8} [get_ports bus_s4_n_o]
set_property -dict {PACKAGE_PIN __TBD__ IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8} [get_ports bus_s5_n_o]
set_property -dict {PACKAGE_PIN __TBD__ IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8} [get_ports bus_cctl_n_o]
set_property -dict {PACKAGE_PIN __TBD__ IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8} [get_ports bus_d1xx_n_o]
set_property -dict {PACKAGE_PIN __TBD__ IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8} [get_ports bus_extenb_n_o]

# Control inputs (5 V devices drive these; CB3T clamps to 3.3 V). PULLUP for idle.
set_property -dict {PACKAGE_PIN __TBD__ IOSTANDARD LVCMOS33 PULLTYPE PULLUP} [get_ports bus_rd4_in]
set_property -dict {PACKAGE_PIN __TBD__ IOSTANDARD LVCMOS33 PULLTYPE PULLUP} [get_ports bus_rd5_in]
set_property -dict {PACKAGE_PIN __TBD__ IOSTANDARD LVCMOS33 PULLTYPE PULLUP} [get_ports bus_mpd_n_in]
set_property -dict {PACKAGE_PIN __TBD__ IOSTANDARD LVCMOS33 PULLTYPE PULLUP} [get_ports bus_extirq_n_in]

# CB3T16210 bank output-enables (outputs, tie active/low in normal use)
set_property -dict {PACKAGE_PIN __TBD__ IOSTANDARD LVCMOS33} [get_ports {bus_cb3t_oe_n[0]}]
set_property -dict {PACKAGE_PIN __TBD__ IOSTANDARD LVCMOS33} [get_ports {bus_cb3t_oe_n[1]}]
set_property -dict {PACKAGE_PIN __TBD__ IOSTANDARD LVCMOS33} [get_ports {bus_cb3t_oe_n[2]}]
set_property -dict {PACKAGE_PIN __TBD__ IOSTANDARD LVCMOS33} [get_ports {bus_cb3t_oe_n[3]}]

# NOT YET IN RTL - add top-level signals before constraining:
#   PBI /RST (pin34, out)  : from system reset
#   PBI /REF (pin40, out)  : DRAM refresh - not generated (DDR on SoM); tie inactive or stub
#   PBI /RDY (pin36, in)   : CPU wait - currently unused; PULLUP if exposed
# set_property -dict {PACKAGE_PIN __TBD__ IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8} [get_ports bus_rst_n_o]
# set_property -dict {PACKAGE_PIN __TBD__ IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8} [get_ports bus_ref_n_o]
# set_property -dict {PACKAGE_PIN __TBD__ IOSTANDARD LVCMOS33 PULLTYPE PULLUP}   [get_ports bus_rdy_n_in]

# ---- RP2354B peri SPI link : Bank 13 ---------------------------------------
# (FPGA = SPI master, peri_bridge.sv). CS optional - tie if using 3-wire.
set_property -dict {PACKAGE_PIN __TBD__ IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8} [get_ports peri_spi_sck]
set_property -dict {PACKAGE_PIN __TBD__ IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8} [get_ports peri_spi_mosi]
set_property -dict {PACKAGE_PIN __TBD__ IOSTANDARD LVCMOS33}                    [get_ports peri_spi_miso]
set_property -dict {PACKAGE_PIN __TBD__ IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8} [get_ports peri_spi_cs_n]
set_property -dict {PACKAGE_PIN __TBD__ IOSTANDARD LVCMOS33 PULLTYPE PULLUP}    [get_ports peri_spi_irq_n]

# ---- PCM1808 audio-in I2S : Bank 34 audio group ----------------------------
# SCKI is FPGA-generated (MMCM); BCK = SCKI/4, LRCK = SCKI/256.
set_property -dict {PACKAGE_PIN __TBD__ IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8} [get_ports pcm_scki]
set_property -dict {PACKAGE_PIN __TBD__ IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8} [get_ports pcm_bck]
set_property -dict {PACKAGE_PIN __TBD__ IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8} [get_ports pcm_lrck]
set_property -dict {PACKAGE_PIN __TBD__ IOSTANDARD LVCMOS33}                    [get_ports pcm_dout]

# ---- Expansion (Bank 35, ~39 pins, 3x 12-pin headers) ----------------------
# Add when the 3x12 pinout is finalized. Single-ended -> LVCMOS33; any
# differential pair -> IOSTANDARD TMDS_33 on the _p/_n, length-matched.
# set_property -dict {PACKAGE_PIN __TBD__ IOSTANDARD LVCMOS33} [get_ports {exp[0]}]
# ...

# ---- φ2 timing (bus is ~1.79 MHz; gentle) ----------------------------------
# create_clock or set_output_delay on phi2_o / bus signals once integrated.
