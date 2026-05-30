# gen_ps_bd.tcl — Generate a minimal Zynq-7020 PS block design for the Z-Turn SOM.
#
# Usage: vivado -mode batch -source gen_ps_bd.tcl
# After:  vivado bd/zynq_ps_bd/zynq_ps_bd.xpr &

set script_dir [file dirname [info script]]
set proj_dir   [file join $script_dir zynq_ps_bd]

file delete -force $proj_dir
puts ">> creating project at $proj_dir"
create_project zynq_ps_bd $proj_dir -part xc7z020clg400-2 -force

create_bd_design ps_bd

# ---- ZYNQ7 Processing System -----------------------------------------------
set ps [create_bd_cell -type ip -name zynq_ps \
    -vlnv xilinx.com:ip:processing_system7:5.5]

# ---- Configure PS: board-physical baseline (MyIR), then our PL-interface ----
# Step 1 — board-physical config lifted VERBATIM from the MyIR Z-Turn hdmi-1080p
# reference, whose BOOT.bin was confirmed to boot DDR + UART + HDMI on the real
# V2 board (2026-05-29).  This is the authoritative source for the MIO map
# (UART1 -> MIO 48/49), DDR (MT41J256M16 + board-delay/DQS trace matching),
# clock tree (33.333 MHz PS xtal -> PLLs), bank voltages (bank1 = 1.8 V), and
# the SOM peripheral pinmux (ENET0/USB0/SD0/QSPI).  Our earlier hand-rolled
# generic config left the UART off and the DDR board delays absent, which hung
# ps7_init before the FSBL banner -> silent serial + dark HDMI.
source [file join $script_dir zturn_ps_preset.tcl]

# Step 2 — OUR PL interface overrides, applied last (last write wins).  These
# own every PS<->PL port so the ps_bd port set keeps matching fpga_xt_top:
# HP0/1/3 + GP0 read/write masters on a single 150 MHz clk_sys net, FCLK0 = 150,
# and — critically — every EMIO the MyIR reference enabled (GPIO/I2C0/TTC0 +
# FCLK_CLK1) is forced OFF, since our top has no ports for them.  TTC0/I2C0
# (which MyIR routed via EMIO) are disabled outright; we don't use them.
set_property -dict [list \
    CONFIG.PCW_PACKAGE_NAME {clg400} \
    CONFIG.PCW_USE_S_AXI_HP0 {1} \
    CONFIG.PCW_USE_S_AXI_HP1 {1} \
    CONFIG.PCW_USE_S_AXI_HP2 {0} \
    CONFIG.PCW_USE_S_AXI_HP3 {1} \
    CONFIG.PCW_USE_M_AXI_GP0 {1} \
    CONFIG.PCW_USE_M_AXI_GP1 {0} \
    CONFIG.PCW_USE_S_AXI_GP0 {0} \
    CONFIG.PCW_USE_S_AXI_ACP {0} \
    CONFIG.PCW_EN_CLK0_PORT {1} \
    CONFIG.PCW_EN_CLK1_PORT {0} \
    CONFIG.PCW_EN_CLK2_PORT {0} \
    CONFIG.PCW_EN_CLK3_PORT {0} \
    CONFIG.PCW_FCLK_CLK1_BUF {FALSE} \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {150} \
    CONFIG.PCW_EN_RST0_PORT {1} \
    CONFIG.PCW_EN_RST1_PORT {0} \
    CONFIG.PCW_EN_RST2_PORT {0} \
    CONFIG.PCW_EN_RST3_PORT {0} \
    CONFIG.PCW_USE_FABRIC_INTERRUPT {1} \
    CONFIG.PCW_IRQ_F2P_MODE {DIRECT} \
    CONFIG.PCW_EN_EMIO_GPIO {0} \
    CONFIG.PCW_GPIO_EMIO_GPIO_ENABLE {0} \
    CONFIG.PCW_EN_EMIO_I2C0 {0} \
    CONFIG.PCW_I2C0_PERIPHERAL_ENABLE {0} \
    CONFIG.PCW_EN_EMIO_TTC0 {0} \
    CONFIG.PCW_TTC0_PERIPHERAL_ENABLE {0} \
] $ps

# ---- HP AXI clocks: driven by clk_sys, NOT FCLK_CLK0 -----------------------
# The fabric HP masters (antic_writeback, xt_blitter, plane_fetch) all run on
# clk_sys.  Clocking the PS HP slave ports from FCLK_CLK0 (a SEPARATE 150 MHz
# PS clock) put the whole HP datapath on a clk_sys<->clk_fpga_0 crossing —
# post-route that was the dominant clk_sys miss (-0.466 ns over 64 endpoints)
# and functionally fragile (same freq, different source).  S_AXI_HP*_ACLK is
# instead driven from the same external clk_sys net as GP0, so ALL PS<->PL AXI
# is one clock domain.  The connection is made after that port is created (the
# "GP0 / HP clock" block below).

# ---- Export HP ports as external AXI3 slave interfaces (64-bit, 150 MHz) ----
for {set i 0} {$i <= 3} {incr i} {
    set hp_name "S_AXI_HP${i}"
    set iface [get_bd_intf_pins -quiet zynq_ps/$hp_name]
    if {$iface ne ""} {
        set ext_name "m_axi_hp${i}"
        create_bd_intf_port -mode Slave \
            -vlnv xilinx.com:interface:aximm_rtl:1.0 $ext_name
        set_property -dict [list \
            CONFIG.PROTOCOL {AXI3} \
            CONFIG.DATA_WIDTH {64} \
            CONFIG.FREQ_HZ {150000000} \
        ] [get_bd_intf_ports $ext_name]
        connect_bd_intf_net [get_bd_intf_ports $ext_name] $iface
        puts ">> exported HP${i} as external interface '$ext_name' (AXI3, 64-bit)"
    }
}

# ---- Export GP0 as external AXI3 master interface (32-bit, 150 MHz) ---------
set gp0_iface [get_bd_intf_pins -quiet zynq_ps/M_AXI_GP0]
if {$gp0_iface ne ""} {
    set ext_name "m_axi_gp0"
    create_bd_intf_port -mode Master \
        -vlnv xilinx.com:interface:aximm_rtl:1.0 $ext_name
    set_property -dict [list \
        CONFIG.PROTOCOL {AXI3} \
        CONFIG.DATA_WIDTH {32} \
        CONFIG.FREQ_HZ {150000000} \
        CONFIG.ADDR_WIDTH {32} \
    ] [get_bd_intf_ports $ext_name]
    connect_bd_intf_net [get_bd_intf_ports $ext_name] $gp0_iface
    puts ">> exported GP0 as external interface '$ext_name' (AXI3, 32-bit)"
}

# GP0 + HP clock — one external clk_sys net (150 MHz) for ALL PS<->PL AXI.
# Named s_axi_gp0_aclk for back-compat (fpga_xt_top drives it with clk_sys);
# it now also clocks every enabled S_AXI_HP* port so the HP datapath stays in
# the clk_sys domain (no clk_sys<->FCLK crossing).
create_bd_port -dir I -type clk -freq_hz 150000000 s_axi_gp0_aclk
connect_bd_net [get_bd_ports s_axi_gp0_aclk] [get_bd_pins zynq_ps/M_AXI_GP0_ACLK]
foreach i {0 1 2 3} {
    set hp_aclk [get_bd_pins -quiet /zynq_ps/S_AXI_HP${i}_ACLK]
    if {$hp_aclk ne ""} {
        connect_bd_net [get_bd_ports s_axi_gp0_aclk] $hp_aclk
        puts ">> S_AXI_HP${i}_ACLK <- s_axi_gp0_aclk (clk_sys)"
    }
}

# ---- Make FCLK reset external -----------------------------------------------
make_bd_pins_external [get_bd_pins zynq_ps/FCLK_RESET0_N]

# Associate AXI interfaces with their clocks.  ALL of them (GP0 + HP) are now
# on the s_axi_gp0_aclk (clk_sys) net, so associate them there and clear the
# stale FCLK association (FCLK no longer clocks the HP datapath).
set fclk_port [get_bd_ports -quiet *FCLK_CLK0*]
if {$fclk_port ne ""} {
    set_property CONFIG.ASSOCIATED_BUSIF {} $fclk_port
}
set gp0clk_port [get_bd_ports s_axi_gp0_aclk]
if {$gp0clk_port ne ""} {
    set_property CONFIG.ASSOCIATED_BUSIF {m_axi_gp0 m_axi_hp0 m_axi_hp1 m_axi_hp3} $gp0clk_port
}

# ---- Assign HP address spaces to DDR ---------------------------------------
assign_bd_address [get_bd_addr_segs /zynq_ps/S_AXI_HP0/HP0_DDR_LOWOCM]
assign_bd_address [get_bd_addr_segs /zynq_ps/S_AXI_HP1/HP1_DDR_LOWOCM]
assign_bd_address [get_bd_addr_segs /zynq_ps/S_AXI_HP3/HP3_DDR_LOWOCM]

# ---- Assign GP0 address range for PL register access -----------------------
assign_bd_address [get_bd_addr_segs /m_axi_gp0/Reg]

# ---- DDR + MIO -------------------------------------------------------------
create_bd_intf_port -mode Master -vlnv xilinx.com:interface:ddrx_rtl:1.0 DDR
connect_bd_intf_net [get_bd_intf_pins zynq_ps/DDR] [get_bd_intf_ports DDR]

set fixio_vlnv [get_property VLNV [get_bd_intf_pins zynq_ps/FIXED_IO]]
create_bd_intf_port -mode Master -vlnv $fixio_vlnv FIXED_IO
connect_bd_intf_net [get_bd_intf_ports FIXED_IO] [get_bd_intf_pins zynq_ps/FIXED_IO]

# ---- Validate and generate wrapper -----------------------------------------
regenerate_bd_layout
save_bd_design
validate_bd_design

set wrapper_file [make_wrapper -files [get_files ps_bd.bd] -top]
add_files -norecurse $wrapper_file
generate_target all [get_files ps_bd.bd]

puts "========================================"
puts ">> Block design generated successfully"
puts ">> Project: $proj_dir/zynq_ps_bd.xpr"
puts ">> Wrapper: $wrapper_file"
puts ">> Open: vivado $proj_dir/zynq_ps_bd.xpr &"
puts "========================================"
close_project
exit
