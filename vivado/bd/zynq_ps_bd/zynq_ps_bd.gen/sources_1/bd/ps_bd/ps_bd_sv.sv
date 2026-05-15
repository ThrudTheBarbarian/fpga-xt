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

`timescale 1ps / 1ps

`include "vivado_interfaces.svh"

module ps_bd_sv (
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp0" *)
  (* X_INTERFACE_MODE = "slave m_axi_hp0" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME m_axi_hp0, DATA_WIDTH 64, PROTOCOL AXI3, FREQ_HZ 150000000, ID_WIDTH 0, ADDR_WIDTH 32, AWUSER_WIDTH 0, ARUSER_WIDTH 0, WUSER_WIDTH 0, RUSER_WIDTH 0, BUSER_WIDTH 0, READ_WRITE_MODE READ_WRITE, HAS_BURST 1, HAS_LOCK 1, HAS_PROT 1, HAS_CACHE 1, HAS_QOS 1, HAS_REGION 1, HAS_WSTRB 1, HAS_BRESP 1, HAS_RRESP 1, SUPPORTS_NARROW_BURST 1, NUM_READ_OUTSTANDING 1, NUM_WRITE_OUTSTANDING 1, MAX_BURST_LENGTH 16, PHASE 0.0, NUM_READ_THREADS 1, NUM_WRITE_THREADS 1, RUSER_BITS_PER_BYTE 0, WUSER_BITS_PER_BYTE 0, INSERT_VIP 0" *)
  vivado_aximm_v1_0.slave m_axi_hp0,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp1" *)
  (* X_INTERFACE_MODE = "slave m_axi_hp1" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME m_axi_hp1, DATA_WIDTH 64, PROTOCOL AXI3, FREQ_HZ 150000000, ID_WIDTH 0, ADDR_WIDTH 32, AWUSER_WIDTH 0, ARUSER_WIDTH 0, WUSER_WIDTH 0, RUSER_WIDTH 0, BUSER_WIDTH 0, READ_WRITE_MODE READ_WRITE, HAS_BURST 1, HAS_LOCK 1, HAS_PROT 1, HAS_CACHE 1, HAS_QOS 1, HAS_REGION 1, HAS_WSTRB 1, HAS_BRESP 1, HAS_RRESP 1, SUPPORTS_NARROW_BURST 1, NUM_READ_OUTSTANDING 1, NUM_WRITE_OUTSTANDING 1, MAX_BURST_LENGTH 16, PHASE 0.0, NUM_READ_THREADS 1, NUM_WRITE_THREADS 1, RUSER_BITS_PER_BYTE 0, WUSER_BITS_PER_BYTE 0, INSERT_VIP 0" *)
  vivado_aximm_v1_0.slave m_axi_hp1,
  (* X_INTERFACE_IGNORE = "true" *)
  output wire FCLK_RESET0_N_0,
  (* X_INTERFACE_IGNORE = "true" *)
  inout wire DDR_cas_n,
  (* X_INTERFACE_IGNORE = "true" *)
  inout wire DDR_cke,
  (* X_INTERFACE_IGNORE = "true" *)
  inout wire DDR_ck_n,
  (* X_INTERFACE_IGNORE = "true" *)
  inout wire DDR_ck_p,
  (* X_INTERFACE_IGNORE = "true" *)
  inout wire DDR_cs_n,
  (* X_INTERFACE_IGNORE = "true" *)
  inout wire DDR_reset_n,
  (* X_INTERFACE_IGNORE = "true" *)
  inout wire DDR_odt,
  (* X_INTERFACE_IGNORE = "true" *)
  inout wire DDR_ras_n,
  (* X_INTERFACE_IGNORE = "true" *)
  inout wire DDR_we_n,
  (* X_INTERFACE_IGNORE = "true" *)
  inout wire [2:0] DDR_ba,
  (* X_INTERFACE_IGNORE = "true" *)
  inout wire [14:0] DDR_addr,
  (* X_INTERFACE_IGNORE = "true" *)
  inout wire [3:0] DDR_dm,
  (* X_INTERFACE_IGNORE = "true" *)
  inout wire [31:0] DDR_dq,
  (* X_INTERFACE_IGNORE = "true" *)
  inout wire [3:0] DDR_dqs_n,
  (* X_INTERFACE_IGNORE = "true" *)
  inout wire [3:0] DDR_dqs_p,
  (* X_INTERFACE_IGNORE = "true" *)
  inout wire [53:0] FIXED_IO_mio,
  (* X_INTERFACE_IGNORE = "true" *)
  inout wire FIXED_IO_ddr_vrn,
  (* X_INTERFACE_IGNORE = "true" *)
  inout wire FIXED_IO_ddr_vrp,
  (* X_INTERFACE_IGNORE = "true" *)
  inout wire FIXED_IO_ps_srstb,
  (* X_INTERFACE_IGNORE = "true" *)
  inout wire FIXED_IO_ps_clk,
  (* X_INTERFACE_IGNORE = "true" *)
  inout wire FIXED_IO_ps_porb
);

  // interface wire assignments
  assign m_axi_hp0.BUSER = 0;
  assign m_axi_hp0.RUSER = 0;
  assign m_axi_hp1.BUSER = 0;
  assign m_axi_hp1.RUSER = 0;

  ps_bd inst (
    .m_axi_hp0_arready(m_axi_hp0.ARREADY),
    .m_axi_hp0_awready(m_axi_hp0.AWREADY),
    .m_axi_hp0_bvalid(m_axi_hp0.BVALID),
    .m_axi_hp0_rlast(m_axi_hp0.RLAST),
    .m_axi_hp0_rvalid(m_axi_hp0.RVALID),
    .m_axi_hp0_wready(m_axi_hp0.WREADY),
    .m_axi_hp0_bresp(m_axi_hp0.BRESP),
    .m_axi_hp0_rresp(m_axi_hp0.RRESP),
    .m_axi_hp0_bid(m_axi_hp0.BID),
    .m_axi_hp0_rid(m_axi_hp0.RID),
    .m_axi_hp0_rdata(m_axi_hp0.RDATA),
    .m_axi_hp0_arvalid(m_axi_hp0.ARVALID),
    .m_axi_hp0_awvalid(m_axi_hp0.AWVALID),
    .m_axi_hp0_bready(m_axi_hp0.BREADY),
    .m_axi_hp0_rready(m_axi_hp0.RREADY),
    .m_axi_hp0_wlast(m_axi_hp0.WLAST),
    .m_axi_hp0_wvalid(m_axi_hp0.WVALID),
    .m_axi_hp0_arburst(m_axi_hp0.ARBURST),
    .m_axi_hp0_arlock(m_axi_hp0.ARLOCK),
    .m_axi_hp0_arsize(m_axi_hp0.ARSIZE),
    .m_axi_hp0_awburst(m_axi_hp0.AWBURST),
    .m_axi_hp0_awlock(m_axi_hp0.AWLOCK),
    .m_axi_hp0_awsize(m_axi_hp0.AWSIZE),
    .m_axi_hp0_arprot(m_axi_hp0.ARPROT),
    .m_axi_hp0_awprot(m_axi_hp0.AWPROT),
    .m_axi_hp0_araddr(m_axi_hp0.ARADDR),
    .m_axi_hp0_awaddr(m_axi_hp0.AWADDR),
    .m_axi_hp0_arcache(m_axi_hp0.ARCACHE),
    .m_axi_hp0_arlen(m_axi_hp0.ARLEN),
    .m_axi_hp0_arqos(m_axi_hp0.ARQOS),
    .m_axi_hp0_awcache(m_axi_hp0.AWCACHE),
    .m_axi_hp0_awlen(m_axi_hp0.AWLEN),
    .m_axi_hp0_awqos(m_axi_hp0.AWQOS),
    .m_axi_hp0_arid(m_axi_hp0.ARID),
    .m_axi_hp0_awid(m_axi_hp0.AWID),
    .m_axi_hp0_wid(m_axi_hp0.WID),
    .m_axi_hp0_wdata(m_axi_hp0.WDATA),
    .m_axi_hp0_wstrb(m_axi_hp0.WSTRB),
    .m_axi_hp1_arready(m_axi_hp1.ARREADY),
    .m_axi_hp1_awready(m_axi_hp1.AWREADY),
    .m_axi_hp1_bvalid(m_axi_hp1.BVALID),
    .m_axi_hp1_rlast(m_axi_hp1.RLAST),
    .m_axi_hp1_rvalid(m_axi_hp1.RVALID),
    .m_axi_hp1_wready(m_axi_hp1.WREADY),
    .m_axi_hp1_bresp(m_axi_hp1.BRESP),
    .m_axi_hp1_rresp(m_axi_hp1.RRESP),
    .m_axi_hp1_bid(m_axi_hp1.BID),
    .m_axi_hp1_rid(m_axi_hp1.RID),
    .m_axi_hp1_rdata(m_axi_hp1.RDATA),
    .m_axi_hp1_arvalid(m_axi_hp1.ARVALID),
    .m_axi_hp1_awvalid(m_axi_hp1.AWVALID),
    .m_axi_hp1_bready(m_axi_hp1.BREADY),
    .m_axi_hp1_rready(m_axi_hp1.RREADY),
    .m_axi_hp1_wlast(m_axi_hp1.WLAST),
    .m_axi_hp1_wvalid(m_axi_hp1.WVALID),
    .m_axi_hp1_arburst(m_axi_hp1.ARBURST),
    .m_axi_hp1_arlock(m_axi_hp1.ARLOCK),
    .m_axi_hp1_arsize(m_axi_hp1.ARSIZE),
    .m_axi_hp1_awburst(m_axi_hp1.AWBURST),
    .m_axi_hp1_awlock(m_axi_hp1.AWLOCK),
    .m_axi_hp1_awsize(m_axi_hp1.AWSIZE),
    .m_axi_hp1_arprot(m_axi_hp1.ARPROT),
    .m_axi_hp1_awprot(m_axi_hp1.AWPROT),
    .m_axi_hp1_araddr(m_axi_hp1.ARADDR),
    .m_axi_hp1_awaddr(m_axi_hp1.AWADDR),
    .m_axi_hp1_arcache(m_axi_hp1.ARCACHE),
    .m_axi_hp1_arlen(m_axi_hp1.ARLEN),
    .m_axi_hp1_arqos(m_axi_hp1.ARQOS),
    .m_axi_hp1_awcache(m_axi_hp1.AWCACHE),
    .m_axi_hp1_awlen(m_axi_hp1.AWLEN),
    .m_axi_hp1_awqos(m_axi_hp1.AWQOS),
    .m_axi_hp1_arid(m_axi_hp1.ARID),
    .m_axi_hp1_awid(m_axi_hp1.AWID),
    .m_axi_hp1_wid(m_axi_hp1.WID),
    .m_axi_hp1_wdata(m_axi_hp1.WDATA),
    .m_axi_hp1_wstrb(m_axi_hp1.WSTRB),
    .FCLK_RESET0_N_0(FCLK_RESET0_N_0),
    .DDR_cas_n(DDR_cas_n),
    .DDR_cke(DDR_cke),
    .DDR_ck_n(DDR_ck_n),
    .DDR_ck_p(DDR_ck_p),
    .DDR_cs_n(DDR_cs_n),
    .DDR_reset_n(DDR_reset_n),
    .DDR_odt(DDR_odt),
    .DDR_ras_n(DDR_ras_n),
    .DDR_we_n(DDR_we_n),
    .DDR_ba(DDR_ba),
    .DDR_addr(DDR_addr),
    .DDR_dm(DDR_dm),
    .DDR_dq(DDR_dq),
    .DDR_dqs_n(DDR_dqs_n),
    .DDR_dqs_p(DDR_dqs_p),
    .FIXED_IO_mio(FIXED_IO_mio),
    .FIXED_IO_ddr_vrn(FIXED_IO_ddr_vrn),
    .FIXED_IO_ddr_vrp(FIXED_IO_ddr_vrp),
    .FIXED_IO_ps_srstb(FIXED_IO_ps_srstb),
    .FIXED_IO_ps_clk(FIXED_IO_ps_clk),
    .FIXED_IO_ps_porb(FIXED_IO_ps_porb)
  );

endmodule
