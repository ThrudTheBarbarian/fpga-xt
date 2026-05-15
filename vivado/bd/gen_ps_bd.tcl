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

# ---- Configure PS ----------------------------------------------------------
set_property -dict [list \
    CONFIG.PCW_PACKAGE_NAME {clg400} \
    CONFIG.PCW_USE_S_AXI_HP0 {1} \
    CONFIG.PCW_USE_S_AXI_HP1 {1} \
    CONFIG.PCW_EN_CLK0_PORT {1} \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {150} \
    CONFIG.PCW_USE_FABRIC_INTERRUPT {1} \
    CONFIG.PCW_IRQ_F2P_MODE {DIRECT} \
    CONFIG.PCW_UIPARAM_DDR_PARTNO {MT41K256M16RE-125} \
    CONFIG.PCW_UIPARAM_DDR_BUS_WIDTH {32 Bit} \
    CONFIG.PCW_UIPARAM_DDR_DRAM_WIDTH {16 Bits} \
    CONFIG.PCW_UIPARAM_DDR_BANK_ADDR_COUNT {3} \
    CONFIG.PCW_UIPARAM_DDR_ROW_ADDR_COUNT {15} \
    CONFIG.PCW_UIPARAM_DDR_COL_ADDR_COUNT {10} \
    CONFIG.PCW_UIPARAM_DDR_TRAIN_WRITE_LEVEL {1} \
    CONFIG.PCW_UIPARAM_DDR_TRAIN_READ_GATE {1} \
    CONFIG.PCW_UIPARAM_DDR_TRAIN_DATA_EYE {1} \
    CONFIG.PCW_UIPARAM_DDR_USE_INTERNAL_VREF {1} \
    CONFIG.PCW_UIPARAM_DDR_SPEED_BIN {DDR3_1066F} \
    CONFIG.PCW_DDR_RAM_HIGHADDR {0x3FFFFFFF} \
    CONFIG.PCW_EN_CLK1_PORT {0} \
    CONFIG.PCW_EN_CLK2_PORT {0} \
    CONFIG.PCW_EN_CLK3_PORT {0} \
    CONFIG.PCW_EN_RST0_PORT {1} \
    CONFIG.PCW_EN_RST1_PORT {0} \
    CONFIG.PCW_EN_RST2_PORT {0} \
    CONFIG.PCW_EN_RST3_PORT {0} \
    CONFIG.PCW_USE_M_AXI_GP0 {1} \
    CONFIG.PCW_USE_S_AXI_GP0 {0} \
    CONFIG.PCW_USE_S_AXI_ACP {0} \
    CONFIG.PCW_USE_S_AXI_HP2 {0} \
    CONFIG.PCW_USE_S_AXI_HP3 {0} \
] $ps

# ---- Connect HP AXI clocks to FCLK_CLK0 ------------------------------------
for {set i 0} {$i <= 1} {incr i} {
    set aclk_pin [get_bd_pins -quiet /zynq_ps/S_AXI_HP${i}_ACLK]
    if {$aclk_pin ne ""} {
        connect_bd_net [get_bd_pins /zynq_ps/FCLK_CLK0] $aclk_pin
    }
}

# ---- Export HP ports as external AXI3 slave interfaces (64-bit, 150 MHz) ----
for {set i 0} {$i <= 1} {incr i} {
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

# GP0 clock — driven by clk_sys from the PL (not FCLK_CLK0, which stays
# internal for HP ports).  clk_sys and FCLK_CLK0 are both 150 MHz.
create_bd_port -dir I -type clk -freq_hz 150000000 s_axi_gp0_aclk
connect_bd_net [get_bd_ports s_axi_gp0_aclk] [get_bd_pins zynq_ps/M_AXI_GP0_ACLK]

# ---- Make FCLK reset external -----------------------------------------------
make_bd_pins_external [get_bd_pins zynq_ps/FCLK_RESET0_N]

# Associate AXI interfaces with their clocks
set fclk_port [get_bd_ports -quiet *FCLK_CLK0*]
if {$fclk_port ne ""} {
    set_property CONFIG.ASSOCIATED_BUSIF {m_axi_hp0 m_axi_hp1} $fclk_port
}
set gp0clk_port [get_bd_ports s_axi_gp0_aclk]
if {$gp0clk_port ne ""} {
    set_property CONFIG.ASSOCIATED_BUSIF {m_axi_gp0} $gp0clk_port
}

# ---- Assign HP address spaces to DDR ---------------------------------------
assign_bd_address [get_bd_addr_segs /zynq_ps/S_AXI_HP0/HP0_DDR_LOWOCM]
assign_bd_address [get_bd_addr_segs /zynq_ps/S_AXI_HP1/HP1_DDR_LOWOCM]

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
