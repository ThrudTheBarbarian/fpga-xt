//Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
//Copyright 2022-2026 Advanced Micro Devices, Inc. All Rights Reserved.
//--------------------------------------------------------------------------------
//Tool Version: Vivado v.2025.2.1 (lin64) Build 6403652 Thu Mar 19 13:47:00 MDT 2026
//Date        : Thu May 14 20:06:09 2026
//Host        : ldaps.e-2-e.net running 64-bit Ubuntu 24.04.4 LTS
//Command     : generate_target ps_bd_wrapper.bd
//Design      : ps_bd_wrapper
//Purpose     : IP block netlist
//--------------------------------------------------------------------------------
`timescale 1 ps / 1 ps

module ps_bd_wrapper
   (DDR_addr,
    DDR_ba,
    DDR_cas_n,
    DDR_ck_n,
    DDR_ck_p,
    DDR_cke,
    DDR_cs_n,
    DDR_dm,
    DDR_dq,
    DDR_dqs_n,
    DDR_dqs_p,
    DDR_odt,
    DDR_ras_n,
    DDR_reset_n,
    DDR_we_n,
    FCLK_RESET0_N_0,
    FIXED_IO_ddr_vrn,
    FIXED_IO_ddr_vrp,
    FIXED_IO_mio,
    FIXED_IO_ps_clk,
    FIXED_IO_ps_porb,
    FIXED_IO_ps_srstb,
    m_axi_hp0_araddr,
    m_axi_hp0_arburst,
    m_axi_hp0_arcache,
    m_axi_hp0_arid,
    m_axi_hp0_arlen,
    m_axi_hp0_arlock,
    m_axi_hp0_arprot,
    m_axi_hp0_arqos,
    m_axi_hp0_arready,
    m_axi_hp0_arsize,
    m_axi_hp0_arvalid,
    m_axi_hp0_awaddr,
    m_axi_hp0_awburst,
    m_axi_hp0_awcache,
    m_axi_hp0_awid,
    m_axi_hp0_awlen,
    m_axi_hp0_awlock,
    m_axi_hp0_awprot,
    m_axi_hp0_awqos,
    m_axi_hp0_awready,
    m_axi_hp0_awsize,
    m_axi_hp0_awvalid,
    m_axi_hp0_bid,
    m_axi_hp0_bready,
    m_axi_hp0_bresp,
    m_axi_hp0_bvalid,
    m_axi_hp0_rdata,
    m_axi_hp0_rid,
    m_axi_hp0_rlast,
    m_axi_hp0_rready,
    m_axi_hp0_rresp,
    m_axi_hp0_rvalid,
    m_axi_hp0_wdata,
    m_axi_hp0_wid,
    m_axi_hp0_wlast,
    m_axi_hp0_wready,
    m_axi_hp0_wstrb,
    m_axi_hp0_wvalid,
    m_axi_hp1_araddr,
    m_axi_hp1_arburst,
    m_axi_hp1_arcache,
    m_axi_hp1_arid,
    m_axi_hp1_arlen,
    m_axi_hp1_arlock,
    m_axi_hp1_arprot,
    m_axi_hp1_arqos,
    m_axi_hp1_arready,
    m_axi_hp1_arsize,
    m_axi_hp1_arvalid,
    m_axi_hp1_awaddr,
    m_axi_hp1_awburst,
    m_axi_hp1_awcache,
    m_axi_hp1_awid,
    m_axi_hp1_awlen,
    m_axi_hp1_awlock,
    m_axi_hp1_awprot,
    m_axi_hp1_awqos,
    m_axi_hp1_awready,
    m_axi_hp1_awsize,
    m_axi_hp1_awvalid,
    m_axi_hp1_bid,
    m_axi_hp1_bready,
    m_axi_hp1_bresp,
    m_axi_hp1_bvalid,
    m_axi_hp1_rdata,
    m_axi_hp1_rid,
    m_axi_hp1_rlast,
    m_axi_hp1_rready,
    m_axi_hp1_rresp,
    m_axi_hp1_rvalid,
    m_axi_hp1_wdata,
    m_axi_hp1_wid,
    m_axi_hp1_wlast,
    m_axi_hp1_wready,
    m_axi_hp1_wstrb,
    m_axi_hp1_wvalid);
  inout [14:0]DDR_addr;
  inout [2:0]DDR_ba;
  inout DDR_cas_n;
  inout DDR_ck_n;
  inout DDR_ck_p;
  inout DDR_cke;
  inout DDR_cs_n;
  inout [3:0]DDR_dm;
  inout [31:0]DDR_dq;
  inout [3:0]DDR_dqs_n;
  inout [3:0]DDR_dqs_p;
  inout DDR_odt;
  inout DDR_ras_n;
  inout DDR_reset_n;
  inout DDR_we_n;
  output FCLK_RESET0_N_0;
  inout FIXED_IO_ddr_vrn;
  inout FIXED_IO_ddr_vrp;
  inout [53:0]FIXED_IO_mio;
  inout FIXED_IO_ps_clk;
  inout FIXED_IO_ps_porb;
  inout FIXED_IO_ps_srstb;
  input [31:0]m_axi_hp0_araddr;
  input [1:0]m_axi_hp0_arburst;
  input [3:0]m_axi_hp0_arcache;
  input [5:0]m_axi_hp0_arid;
  input [3:0]m_axi_hp0_arlen;
  input [1:0]m_axi_hp0_arlock;
  input [2:0]m_axi_hp0_arprot;
  input [3:0]m_axi_hp0_arqos;
  output m_axi_hp0_arready;
  input [2:0]m_axi_hp0_arsize;
  input m_axi_hp0_arvalid;
  input [31:0]m_axi_hp0_awaddr;
  input [1:0]m_axi_hp0_awburst;
  input [3:0]m_axi_hp0_awcache;
  input [5:0]m_axi_hp0_awid;
  input [3:0]m_axi_hp0_awlen;
  input [1:0]m_axi_hp0_awlock;
  input [2:0]m_axi_hp0_awprot;
  input [3:0]m_axi_hp0_awqos;
  output m_axi_hp0_awready;
  input [2:0]m_axi_hp0_awsize;
  input m_axi_hp0_awvalid;
  output [5:0]m_axi_hp0_bid;
  input m_axi_hp0_bready;
  output [1:0]m_axi_hp0_bresp;
  output m_axi_hp0_bvalid;
  output [63:0]m_axi_hp0_rdata;
  output [5:0]m_axi_hp0_rid;
  output m_axi_hp0_rlast;
  input m_axi_hp0_rready;
  output [1:0]m_axi_hp0_rresp;
  output m_axi_hp0_rvalid;
  input [63:0]m_axi_hp0_wdata;
  input [5:0]m_axi_hp0_wid;
  input m_axi_hp0_wlast;
  output m_axi_hp0_wready;
  input [7:0]m_axi_hp0_wstrb;
  input m_axi_hp0_wvalid;
  input [31:0]m_axi_hp1_araddr;
  input [1:0]m_axi_hp1_arburst;
  input [3:0]m_axi_hp1_arcache;
  input [5:0]m_axi_hp1_arid;
  input [3:0]m_axi_hp1_arlen;
  input [1:0]m_axi_hp1_arlock;
  input [2:0]m_axi_hp1_arprot;
  input [3:0]m_axi_hp1_arqos;
  output m_axi_hp1_arready;
  input [2:0]m_axi_hp1_arsize;
  input m_axi_hp1_arvalid;
  input [31:0]m_axi_hp1_awaddr;
  input [1:0]m_axi_hp1_awburst;
  input [3:0]m_axi_hp1_awcache;
  input [5:0]m_axi_hp1_awid;
  input [3:0]m_axi_hp1_awlen;
  input [1:0]m_axi_hp1_awlock;
  input [2:0]m_axi_hp1_awprot;
  input [3:0]m_axi_hp1_awqos;
  output m_axi_hp1_awready;
  input [2:0]m_axi_hp1_awsize;
  input m_axi_hp1_awvalid;
  output [5:0]m_axi_hp1_bid;
  input m_axi_hp1_bready;
  output [1:0]m_axi_hp1_bresp;
  output m_axi_hp1_bvalid;
  output [63:0]m_axi_hp1_rdata;
  output [5:0]m_axi_hp1_rid;
  output m_axi_hp1_rlast;
  input m_axi_hp1_rready;
  output [1:0]m_axi_hp1_rresp;
  output m_axi_hp1_rvalid;
  input [63:0]m_axi_hp1_wdata;
  input [5:0]m_axi_hp1_wid;
  input m_axi_hp1_wlast;
  output m_axi_hp1_wready;
  input [7:0]m_axi_hp1_wstrb;
  input m_axi_hp1_wvalid;

  wire [14:0]DDR_addr;
  wire [2:0]DDR_ba;
  wire DDR_cas_n;
  wire DDR_ck_n;
  wire DDR_ck_p;
  wire DDR_cke;
  wire DDR_cs_n;
  wire [3:0]DDR_dm;
  wire [31:0]DDR_dq;
  wire [3:0]DDR_dqs_n;
  wire [3:0]DDR_dqs_p;
  wire DDR_odt;
  wire DDR_ras_n;
  wire DDR_reset_n;
  wire DDR_we_n;
  wire FCLK_RESET0_N_0;
  wire FIXED_IO_ddr_vrn;
  wire FIXED_IO_ddr_vrp;
  wire [53:0]FIXED_IO_mio;
  wire FIXED_IO_ps_clk;
  wire FIXED_IO_ps_porb;
  wire FIXED_IO_ps_srstb;
  wire [31:0]m_axi_hp0_araddr;
  wire [1:0]m_axi_hp0_arburst;
  wire [3:0]m_axi_hp0_arcache;
  wire [5:0]m_axi_hp0_arid;
  wire [3:0]m_axi_hp0_arlen;
  wire [1:0]m_axi_hp0_arlock;
  wire [2:0]m_axi_hp0_arprot;
  wire [3:0]m_axi_hp0_arqos;
  wire m_axi_hp0_arready;
  wire [2:0]m_axi_hp0_arsize;
  wire m_axi_hp0_arvalid;
  wire [31:0]m_axi_hp0_awaddr;
  wire [1:0]m_axi_hp0_awburst;
  wire [3:0]m_axi_hp0_awcache;
  wire [5:0]m_axi_hp0_awid;
  wire [3:0]m_axi_hp0_awlen;
  wire [1:0]m_axi_hp0_awlock;
  wire [2:0]m_axi_hp0_awprot;
  wire [3:0]m_axi_hp0_awqos;
  wire m_axi_hp0_awready;
  wire [2:0]m_axi_hp0_awsize;
  wire m_axi_hp0_awvalid;
  wire [5:0]m_axi_hp0_bid;
  wire m_axi_hp0_bready;
  wire [1:0]m_axi_hp0_bresp;
  wire m_axi_hp0_bvalid;
  wire [63:0]m_axi_hp0_rdata;
  wire [5:0]m_axi_hp0_rid;
  wire m_axi_hp0_rlast;
  wire m_axi_hp0_rready;
  wire [1:0]m_axi_hp0_rresp;
  wire m_axi_hp0_rvalid;
  wire [63:0]m_axi_hp0_wdata;
  wire [5:0]m_axi_hp0_wid;
  wire m_axi_hp0_wlast;
  wire m_axi_hp0_wready;
  wire [7:0]m_axi_hp0_wstrb;
  wire m_axi_hp0_wvalid;
  wire [31:0]m_axi_hp1_araddr;
  wire [1:0]m_axi_hp1_arburst;
  wire [3:0]m_axi_hp1_arcache;
  wire [5:0]m_axi_hp1_arid;
  wire [3:0]m_axi_hp1_arlen;
  wire [1:0]m_axi_hp1_arlock;
  wire [2:0]m_axi_hp1_arprot;
  wire [3:0]m_axi_hp1_arqos;
  wire m_axi_hp1_arready;
  wire [2:0]m_axi_hp1_arsize;
  wire m_axi_hp1_arvalid;
  wire [31:0]m_axi_hp1_awaddr;
  wire [1:0]m_axi_hp1_awburst;
  wire [3:0]m_axi_hp1_awcache;
  wire [5:0]m_axi_hp1_awid;
  wire [3:0]m_axi_hp1_awlen;
  wire [1:0]m_axi_hp1_awlock;
  wire [2:0]m_axi_hp1_awprot;
  wire [3:0]m_axi_hp1_awqos;
  wire m_axi_hp1_awready;
  wire [2:0]m_axi_hp1_awsize;
  wire m_axi_hp1_awvalid;
  wire [5:0]m_axi_hp1_bid;
  wire m_axi_hp1_bready;
  wire [1:0]m_axi_hp1_bresp;
  wire m_axi_hp1_bvalid;
  wire [63:0]m_axi_hp1_rdata;
  wire [5:0]m_axi_hp1_rid;
  wire m_axi_hp1_rlast;
  wire m_axi_hp1_rready;
  wire [1:0]m_axi_hp1_rresp;
  wire m_axi_hp1_rvalid;
  wire [63:0]m_axi_hp1_wdata;
  wire [5:0]m_axi_hp1_wid;
  wire m_axi_hp1_wlast;
  wire m_axi_hp1_wready;
  wire [7:0]m_axi_hp1_wstrb;
  wire m_axi_hp1_wvalid;

  ps_bd ps_bd_i
       (.DDR_addr(DDR_addr),
        .DDR_ba(DDR_ba),
        .DDR_cas_n(DDR_cas_n),
        .DDR_ck_n(DDR_ck_n),
        .DDR_ck_p(DDR_ck_p),
        .DDR_cke(DDR_cke),
        .DDR_cs_n(DDR_cs_n),
        .DDR_dm(DDR_dm),
        .DDR_dq(DDR_dq),
        .DDR_dqs_n(DDR_dqs_n),
        .DDR_dqs_p(DDR_dqs_p),
        .DDR_odt(DDR_odt),
        .DDR_ras_n(DDR_ras_n),
        .DDR_reset_n(DDR_reset_n),
        .DDR_we_n(DDR_we_n),
        .FCLK_RESET0_N_0(FCLK_RESET0_N_0),
        .FIXED_IO_ddr_vrn(FIXED_IO_ddr_vrn),
        .FIXED_IO_ddr_vrp(FIXED_IO_ddr_vrp),
        .FIXED_IO_mio(FIXED_IO_mio),
        .FIXED_IO_ps_clk(FIXED_IO_ps_clk),
        .FIXED_IO_ps_porb(FIXED_IO_ps_porb),
        .FIXED_IO_ps_srstb(FIXED_IO_ps_srstb),
        .m_axi_hp0_araddr(m_axi_hp0_araddr),
        .m_axi_hp0_arburst(m_axi_hp0_arburst),
        .m_axi_hp0_arcache(m_axi_hp0_arcache),
        .m_axi_hp0_arid(m_axi_hp0_arid),
        .m_axi_hp0_arlen(m_axi_hp0_arlen),
        .m_axi_hp0_arlock(m_axi_hp0_arlock),
        .m_axi_hp0_arprot(m_axi_hp0_arprot),
        .m_axi_hp0_arqos(m_axi_hp0_arqos),
        .m_axi_hp0_arready(m_axi_hp0_arready),
        .m_axi_hp0_arsize(m_axi_hp0_arsize),
        .m_axi_hp0_arvalid(m_axi_hp0_arvalid),
        .m_axi_hp0_awaddr(m_axi_hp0_awaddr),
        .m_axi_hp0_awburst(m_axi_hp0_awburst),
        .m_axi_hp0_awcache(m_axi_hp0_awcache),
        .m_axi_hp0_awid(m_axi_hp0_awid),
        .m_axi_hp0_awlen(m_axi_hp0_awlen),
        .m_axi_hp0_awlock(m_axi_hp0_awlock),
        .m_axi_hp0_awprot(m_axi_hp0_awprot),
        .m_axi_hp0_awqos(m_axi_hp0_awqos),
        .m_axi_hp0_awready(m_axi_hp0_awready),
        .m_axi_hp0_awsize(m_axi_hp0_awsize),
        .m_axi_hp0_awvalid(m_axi_hp0_awvalid),
        .m_axi_hp0_bid(m_axi_hp0_bid),
        .m_axi_hp0_bready(m_axi_hp0_bready),
        .m_axi_hp0_bresp(m_axi_hp0_bresp),
        .m_axi_hp0_bvalid(m_axi_hp0_bvalid),
        .m_axi_hp0_rdata(m_axi_hp0_rdata),
        .m_axi_hp0_rid(m_axi_hp0_rid),
        .m_axi_hp0_rlast(m_axi_hp0_rlast),
        .m_axi_hp0_rready(m_axi_hp0_rready),
        .m_axi_hp0_rresp(m_axi_hp0_rresp),
        .m_axi_hp0_rvalid(m_axi_hp0_rvalid),
        .m_axi_hp0_wdata(m_axi_hp0_wdata),
        .m_axi_hp0_wid(m_axi_hp0_wid),
        .m_axi_hp0_wlast(m_axi_hp0_wlast),
        .m_axi_hp0_wready(m_axi_hp0_wready),
        .m_axi_hp0_wstrb(m_axi_hp0_wstrb),
        .m_axi_hp0_wvalid(m_axi_hp0_wvalid),
        .m_axi_hp1_araddr(m_axi_hp1_araddr),
        .m_axi_hp1_arburst(m_axi_hp1_arburst),
        .m_axi_hp1_arcache(m_axi_hp1_arcache),
        .m_axi_hp1_arid(m_axi_hp1_arid),
        .m_axi_hp1_arlen(m_axi_hp1_arlen),
        .m_axi_hp1_arlock(m_axi_hp1_arlock),
        .m_axi_hp1_arprot(m_axi_hp1_arprot),
        .m_axi_hp1_arqos(m_axi_hp1_arqos),
        .m_axi_hp1_arready(m_axi_hp1_arready),
        .m_axi_hp1_arsize(m_axi_hp1_arsize),
        .m_axi_hp1_arvalid(m_axi_hp1_arvalid),
        .m_axi_hp1_awaddr(m_axi_hp1_awaddr),
        .m_axi_hp1_awburst(m_axi_hp1_awburst),
        .m_axi_hp1_awcache(m_axi_hp1_awcache),
        .m_axi_hp1_awid(m_axi_hp1_awid),
        .m_axi_hp1_awlen(m_axi_hp1_awlen),
        .m_axi_hp1_awlock(m_axi_hp1_awlock),
        .m_axi_hp1_awprot(m_axi_hp1_awprot),
        .m_axi_hp1_awqos(m_axi_hp1_awqos),
        .m_axi_hp1_awready(m_axi_hp1_awready),
        .m_axi_hp1_awsize(m_axi_hp1_awsize),
        .m_axi_hp1_awvalid(m_axi_hp1_awvalid),
        .m_axi_hp1_bid(m_axi_hp1_bid),
        .m_axi_hp1_bready(m_axi_hp1_bready),
        .m_axi_hp1_bresp(m_axi_hp1_bresp),
        .m_axi_hp1_bvalid(m_axi_hp1_bvalid),
        .m_axi_hp1_rdata(m_axi_hp1_rdata),
        .m_axi_hp1_rid(m_axi_hp1_rid),
        .m_axi_hp1_rlast(m_axi_hp1_rlast),
        .m_axi_hp1_rready(m_axi_hp1_rready),
        .m_axi_hp1_rresp(m_axi_hp1_rresp),
        .m_axi_hp1_rvalid(m_axi_hp1_rvalid),
        .m_axi_hp1_wdata(m_axi_hp1_wdata),
        .m_axi_hp1_wid(m_axi_hp1_wid),
        .m_axi_hp1_wlast(m_axi_hp1_wlast),
        .m_axi_hp1_wready(m_axi_hp1_wready),
        .m_axi_hp1_wstrb(m_axi_hp1_wstrb),
        .m_axi_hp1_wvalid(m_axi_hp1_wvalid));
endmodule
