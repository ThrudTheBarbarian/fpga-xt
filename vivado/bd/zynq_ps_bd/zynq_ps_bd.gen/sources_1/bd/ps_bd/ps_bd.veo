// Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
// Copyright 2022-2026 Advanced Micro Devices, Inc. All Rights Reserved.
// -------------------------------------------------------------------------------
// This file contains confidential and proprietary information
// of AMD and is protected under U.S. and international copyright
// and other intellectual property laws.
//
// DISCLAIMER
// This disclaimer is not a license and does not grant any
// rights to the materials distributed herewith. Except as
// otherwise provided in a valid license issued to you by
// AMD, and to the maximum extent permitted by applicable
// law: (1) THESE MATERIALS ARE MADE AVAILABLE "AS IS" AND
// WITH ALL FAULTS, AND AMD HEREBY DISCLAIMS ALL WARRANTIES
// AND CONDITIONS, EXPRESS, IMPLIED, OR STATUTORY, INCLUDING
// BUT NOT LIMITED TO WARRANTIES OF MERCHANTABILITY, NON-
// INFRINGEMENT, OR FITNESS FOR ANY PARTICULAR PURPOSE; and
// (2) AMD shall not be liable (whether in contract or tort,
// including negligence, or under any other theory of
// liability) for any loss or damage of any kind or nature
// related to, arising under or in connection with these
// materials, including for any direct, or any indirect,
// special, incidental, or consequential loss or damage
// (including loss of data, profits, goodwill, or any type of
// loss or damage suffered as a result of any action brought
// by a third party) even if such damage or loss was
// reasonably foreseeable or AMD had been advised of the
// possibility of the same.
//
// CRITICAL APPLICATIONS
// AMD products are not designed or intended to be fail-
// safe, or for use in any application requiring fail-safe
// performance, such as life-support or safety devices or
// systems, Class III medical devices, nuclear facilities,
// applications related to the deployment of airbags, or any
// other applications that could lead to death, personal
// injury, or severe property or environmental damage
// (individually and collectively, "Critical
// Applications"). Customer assumes the sole risk and
// liability of any use of AMD products in Critical
// Applications, subject only to applicable laws and
// regulations governing limitations on product liability.
//
// THIS COPYRIGHT NOTICE AND DISCLAIMER MUST BE RETAINED AS
// PART OF THIS FILE AT ALL TIMES.
//
// DO NOT MODIFY THIS FILE.

// MODULE VLNV: amd.com:blockdesign:ps_bd:1.0

// The following must be inserted into your Verilog file for this
// module to be instantiated. Change the instance name and port connections
// (in parentheses) to your own signal names.

// INST_TAG     ------ Begin cut for INSTANTIATION Template ------
ps_bd your_instance_name (
  .m_axi_hp0_arready(m_axi_hp0_arready), // output wire m_axi_hp0_arready
  .m_axi_hp0_awready(m_axi_hp0_awready), // output wire m_axi_hp0_awready
  .m_axi_hp0_bvalid(m_axi_hp0_bvalid), // output wire m_axi_hp0_bvalid
  .m_axi_hp0_rlast(m_axi_hp0_rlast), // output wire m_axi_hp0_rlast
  .m_axi_hp0_rvalid(m_axi_hp0_rvalid), // output wire m_axi_hp0_rvalid
  .m_axi_hp0_wready(m_axi_hp0_wready), // output wire m_axi_hp0_wready
  .m_axi_hp0_bresp(m_axi_hp0_bresp), // output wire [1:0] m_axi_hp0_bresp
  .m_axi_hp0_rresp(m_axi_hp0_rresp), // output wire [1:0] m_axi_hp0_rresp
  .m_axi_hp0_bid(m_axi_hp0_bid), // output wire [5:0] m_axi_hp0_bid
  .m_axi_hp0_rid(m_axi_hp0_rid), // output wire [5:0] m_axi_hp0_rid
  .m_axi_hp0_rdata(m_axi_hp0_rdata), // output wire [63:0] m_axi_hp0_rdata
  .m_axi_hp0_arvalid(m_axi_hp0_arvalid), // input wire m_axi_hp0_arvalid
  .m_axi_hp0_awvalid(m_axi_hp0_awvalid), // input wire m_axi_hp0_awvalid
  .m_axi_hp0_bready(m_axi_hp0_bready), // input wire m_axi_hp0_bready
  .m_axi_hp0_rready(m_axi_hp0_rready), // input wire m_axi_hp0_rready
  .m_axi_hp0_wlast(m_axi_hp0_wlast), // input wire m_axi_hp0_wlast
  .m_axi_hp0_wvalid(m_axi_hp0_wvalid), // input wire m_axi_hp0_wvalid
  .m_axi_hp0_arburst(m_axi_hp0_arburst), // input wire [1:0] m_axi_hp0_arburst
  .m_axi_hp0_arlock(m_axi_hp0_arlock), // input wire [1:0] m_axi_hp0_arlock
  .m_axi_hp0_arsize(m_axi_hp0_arsize), // input wire [2:0] m_axi_hp0_arsize
  .m_axi_hp0_awburst(m_axi_hp0_awburst), // input wire [1:0] m_axi_hp0_awburst
  .m_axi_hp0_awlock(m_axi_hp0_awlock), // input wire [1:0] m_axi_hp0_awlock
  .m_axi_hp0_awsize(m_axi_hp0_awsize), // input wire [2:0] m_axi_hp0_awsize
  .m_axi_hp0_arprot(m_axi_hp0_arprot), // input wire [2:0] m_axi_hp0_arprot
  .m_axi_hp0_awprot(m_axi_hp0_awprot), // input wire [2:0] m_axi_hp0_awprot
  .m_axi_hp0_araddr(m_axi_hp0_araddr), // input wire [31:0] m_axi_hp0_araddr
  .m_axi_hp0_awaddr(m_axi_hp0_awaddr), // input wire [31:0] m_axi_hp0_awaddr
  .m_axi_hp0_arcache(m_axi_hp0_arcache), // input wire [3:0] m_axi_hp0_arcache
  .m_axi_hp0_arlen(m_axi_hp0_arlen), // input wire [3:0] m_axi_hp0_arlen
  .m_axi_hp0_arqos(m_axi_hp0_arqos), // input wire [3:0] m_axi_hp0_arqos
  .m_axi_hp0_awcache(m_axi_hp0_awcache), // input wire [3:0] m_axi_hp0_awcache
  .m_axi_hp0_awlen(m_axi_hp0_awlen), // input wire [3:0] m_axi_hp0_awlen
  .m_axi_hp0_awqos(m_axi_hp0_awqos), // input wire [3:0] m_axi_hp0_awqos
  .m_axi_hp0_arid(m_axi_hp0_arid), // input wire [5:0] m_axi_hp0_arid
  .m_axi_hp0_awid(m_axi_hp0_awid), // input wire [5:0] m_axi_hp0_awid
  .m_axi_hp0_wid(m_axi_hp0_wid), // input wire [5:0] m_axi_hp0_wid
  .m_axi_hp0_wdata(m_axi_hp0_wdata), // input wire [63:0] m_axi_hp0_wdata
  .m_axi_hp0_wstrb(m_axi_hp0_wstrb), // input wire [7:0] m_axi_hp0_wstrb
  .m_axi_hp1_arready(m_axi_hp1_arready), // output wire m_axi_hp1_arready
  .m_axi_hp1_awready(m_axi_hp1_awready), // output wire m_axi_hp1_awready
  .m_axi_hp1_bvalid(m_axi_hp1_bvalid), // output wire m_axi_hp1_bvalid
  .m_axi_hp1_rlast(m_axi_hp1_rlast), // output wire m_axi_hp1_rlast
  .m_axi_hp1_rvalid(m_axi_hp1_rvalid), // output wire m_axi_hp1_rvalid
  .m_axi_hp1_wready(m_axi_hp1_wready), // output wire m_axi_hp1_wready
  .m_axi_hp1_bresp(m_axi_hp1_bresp), // output wire [1:0] m_axi_hp1_bresp
  .m_axi_hp1_rresp(m_axi_hp1_rresp), // output wire [1:0] m_axi_hp1_rresp
  .m_axi_hp1_bid(m_axi_hp1_bid), // output wire [5:0] m_axi_hp1_bid
  .m_axi_hp1_rid(m_axi_hp1_rid), // output wire [5:0] m_axi_hp1_rid
  .m_axi_hp1_rdata(m_axi_hp1_rdata), // output wire [63:0] m_axi_hp1_rdata
  .m_axi_hp1_arvalid(m_axi_hp1_arvalid), // input wire m_axi_hp1_arvalid
  .m_axi_hp1_awvalid(m_axi_hp1_awvalid), // input wire m_axi_hp1_awvalid
  .m_axi_hp1_bready(m_axi_hp1_bready), // input wire m_axi_hp1_bready
  .m_axi_hp1_rready(m_axi_hp1_rready), // input wire m_axi_hp1_rready
  .m_axi_hp1_wlast(m_axi_hp1_wlast), // input wire m_axi_hp1_wlast
  .m_axi_hp1_wvalid(m_axi_hp1_wvalid), // input wire m_axi_hp1_wvalid
  .m_axi_hp1_arburst(m_axi_hp1_arburst), // input wire [1:0] m_axi_hp1_arburst
  .m_axi_hp1_arlock(m_axi_hp1_arlock), // input wire [1:0] m_axi_hp1_arlock
  .m_axi_hp1_arsize(m_axi_hp1_arsize), // input wire [2:0] m_axi_hp1_arsize
  .m_axi_hp1_awburst(m_axi_hp1_awburst), // input wire [1:0] m_axi_hp1_awburst
  .m_axi_hp1_awlock(m_axi_hp1_awlock), // input wire [1:0] m_axi_hp1_awlock
  .m_axi_hp1_awsize(m_axi_hp1_awsize), // input wire [2:0] m_axi_hp1_awsize
  .m_axi_hp1_arprot(m_axi_hp1_arprot), // input wire [2:0] m_axi_hp1_arprot
  .m_axi_hp1_awprot(m_axi_hp1_awprot), // input wire [2:0] m_axi_hp1_awprot
  .m_axi_hp1_araddr(m_axi_hp1_araddr), // input wire [31:0] m_axi_hp1_araddr
  .m_axi_hp1_awaddr(m_axi_hp1_awaddr), // input wire [31:0] m_axi_hp1_awaddr
  .m_axi_hp1_arcache(m_axi_hp1_arcache), // input wire [3:0] m_axi_hp1_arcache
  .m_axi_hp1_arlen(m_axi_hp1_arlen), // input wire [3:0] m_axi_hp1_arlen
  .m_axi_hp1_arqos(m_axi_hp1_arqos), // input wire [3:0] m_axi_hp1_arqos
  .m_axi_hp1_awcache(m_axi_hp1_awcache), // input wire [3:0] m_axi_hp1_awcache
  .m_axi_hp1_awlen(m_axi_hp1_awlen), // input wire [3:0] m_axi_hp1_awlen
  .m_axi_hp1_awqos(m_axi_hp1_awqos), // input wire [3:0] m_axi_hp1_awqos
  .m_axi_hp1_arid(m_axi_hp1_arid), // input wire [5:0] m_axi_hp1_arid
  .m_axi_hp1_awid(m_axi_hp1_awid), // input wire [5:0] m_axi_hp1_awid
  .m_axi_hp1_wid(m_axi_hp1_wid), // input wire [5:0] m_axi_hp1_wid
  .m_axi_hp1_wdata(m_axi_hp1_wdata), // input wire [63:0] m_axi_hp1_wdata
  .m_axi_hp1_wstrb(m_axi_hp1_wstrb), // input wire [7:0] m_axi_hp1_wstrb
  .FCLK_RESET0_N_0(FCLK_RESET0_N_0), // output wire FCLK_RESET0_N_0
  .DDR_cas_n(DDR_cas_n), // inout wire DDR_cas_n
  .DDR_cke(DDR_cke), // inout wire DDR_cke
  .DDR_ck_n(DDR_ck_n), // inout wire DDR_ck_n
  .DDR_ck_p(DDR_ck_p), // inout wire DDR_ck_p
  .DDR_cs_n(DDR_cs_n), // inout wire DDR_cs_n
  .DDR_reset_n(DDR_reset_n), // inout wire DDR_reset_n
  .DDR_odt(DDR_odt), // inout wire DDR_odt
  .DDR_ras_n(DDR_ras_n), // inout wire DDR_ras_n
  .DDR_we_n(DDR_we_n), // inout wire DDR_we_n
  .DDR_ba(DDR_ba), // inout wire [2:0] DDR_ba
  .DDR_addr(DDR_addr), // inout wire [14:0] DDR_addr
  .DDR_dm(DDR_dm), // inout wire [3:0] DDR_dm
  .DDR_dq(DDR_dq), // inout wire [31:0] DDR_dq
  .DDR_dqs_n(DDR_dqs_n), // inout wire [3:0] DDR_dqs_n
  .DDR_dqs_p(DDR_dqs_p), // inout wire [3:0] DDR_dqs_p
  .FIXED_IO_mio(FIXED_IO_mio), // inout wire [53:0] FIXED_IO_mio
  .FIXED_IO_ddr_vrn(FIXED_IO_ddr_vrn), // inout wire FIXED_IO_ddr_vrn
  .FIXED_IO_ddr_vrp(FIXED_IO_ddr_vrp), // inout wire FIXED_IO_ddr_vrp
  .FIXED_IO_ps_srstb(FIXED_IO_ps_srstb), // inout wire FIXED_IO_ps_srstb
  .FIXED_IO_ps_clk(FIXED_IO_ps_clk), // inout wire FIXED_IO_ps_clk
  .FIXED_IO_ps_porb(FIXED_IO_ps_porb) // inout wire FIXED_IO_ps_porb
);
// INST_TAG_END ------  End cut for INSTANTIATION Template  ------

// You must compile the wrapper file ps_bd.v when simulating
// the module, ps_bd. When compiling the wrapper file, be sure to
// reference the Verilog simulation library.
