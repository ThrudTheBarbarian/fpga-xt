//Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
//Copyright 2022-2026 Advanced Micro Devices, Inc. All Rights Reserved.
//--------------------------------------------------------------------------------
//Tool Version: Vivado v.2025.2.1 (lin64) Build 6403652 Thu Mar 19 13:47:00 MDT 2026
//Date        : Thu May 14 20:06:08 2026
//Host        : ldaps.e-2-e.net running 64-bit Ubuntu 24.04.4 LTS
//Command     : generate_target ps_bd.bd
//Design      : ps_bd
//Purpose     : IP block netlist
//--------------------------------------------------------------------------------
`timescale 1 ps / 1 ps

(* CORE_GENERATION_INFO = "ps_bd,IP_Integrator,{x_ipVendor=xilinx.com,x_ipLibrary=BlockDiagram,x_ipName=ps_bd,x_ipVersion=1.00.a,x_ipLanguage=VERILOG,numBlks=1,numReposBlks=1,numNonXlnxBlks=0,numHierBlks=0,maxHierDepth=0,numSysgenBlks=0,numHlsBlks=0,numHdlrefBlks=0,numPkgbdBlks=0,bdsource=USER,synth_mode=Hierarchical}" *) (* HW_HANDOFF = "ps_bd.hwdef" *) 
module ps_bd
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
  (* X_INTERFACE_INFO = "xilinx.com:interface:ddrx:1.0 DDR ADDR" *) (* X_INTERFACE_MODE = "Master" *) (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME DDR, AXI_ARBITRATION_SCHEME TDM, BURST_LENGTH 8, CAN_DEBUG false, CAS_LATENCY 11, CAS_WRITE_LATENCY 11, CS_ENABLED true, DATA_MASK_ENABLED true, DATA_WIDTH 8, MEMORY_TYPE COMPONENTS, MEM_ADDR_MAP ROW_COLUMN_BANK, SLOT Single, TIMEPERIOD_PS 1250" *) inout [14:0]DDR_addr;
  (* X_INTERFACE_INFO = "xilinx.com:interface:ddrx:1.0 DDR BA" *) inout [2:0]DDR_ba;
  (* X_INTERFACE_INFO = "xilinx.com:interface:ddrx:1.0 DDR CAS_N" *) inout DDR_cas_n;
  (* X_INTERFACE_INFO = "xilinx.com:interface:ddrx:1.0 DDR CK_N" *) inout DDR_ck_n;
  (* X_INTERFACE_INFO = "xilinx.com:interface:ddrx:1.0 DDR CK_P" *) inout DDR_ck_p;
  (* X_INTERFACE_INFO = "xilinx.com:interface:ddrx:1.0 DDR CKE" *) inout DDR_cke;
  (* X_INTERFACE_INFO = "xilinx.com:interface:ddrx:1.0 DDR CS_N" *) inout DDR_cs_n;
  (* X_INTERFACE_INFO = "xilinx.com:interface:ddrx:1.0 DDR DM" *) inout [3:0]DDR_dm;
  (* X_INTERFACE_INFO = "xilinx.com:interface:ddrx:1.0 DDR DQ" *) inout [31:0]DDR_dq;
  (* X_INTERFACE_INFO = "xilinx.com:interface:ddrx:1.0 DDR DQS_N" *) inout [3:0]DDR_dqs_n;
  (* X_INTERFACE_INFO = "xilinx.com:interface:ddrx:1.0 DDR DQS_P" *) inout [3:0]DDR_dqs_p;
  (* X_INTERFACE_INFO = "xilinx.com:interface:ddrx:1.0 DDR ODT" *) inout DDR_odt;
  (* X_INTERFACE_INFO = "xilinx.com:interface:ddrx:1.0 DDR RAS_N" *) inout DDR_ras_n;
  (* X_INTERFACE_INFO = "xilinx.com:interface:ddrx:1.0 DDR RESET_N" *) inout DDR_reset_n;
  (* X_INTERFACE_INFO = "xilinx.com:interface:ddrx:1.0 DDR WE_N" *) inout DDR_we_n;
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 RST.FCLK_RESET0_N_0 RST" *) (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME RST.FCLK_RESET0_N_0, INSERT_VIP 0, POLARITY ACTIVE_LOW" *) output FCLK_RESET0_N_0;
  (* X_INTERFACE_INFO = "xilinx.com:display_processing_system7:fixedio:1.0 FIXED_IO DDR_VRN" *) (* X_INTERFACE_MODE = "Master" *) (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME FIXED_IO, CAN_DEBUG false" *) inout FIXED_IO_ddr_vrn;
  (* X_INTERFACE_INFO = "xilinx.com:display_processing_system7:fixedio:1.0 FIXED_IO DDR_VRP" *) inout FIXED_IO_ddr_vrp;
  (* X_INTERFACE_INFO = "xilinx.com:display_processing_system7:fixedio:1.0 FIXED_IO MIO" *) inout [53:0]FIXED_IO_mio;
  (* X_INTERFACE_INFO = "xilinx.com:display_processing_system7:fixedio:1.0 FIXED_IO PS_CLK" *) inout FIXED_IO_ps_clk;
  (* X_INTERFACE_INFO = "xilinx.com:display_processing_system7:fixedio:1.0 FIXED_IO PS_PORB" *) inout FIXED_IO_ps_porb;
  (* X_INTERFACE_INFO = "xilinx.com:display_processing_system7:fixedio:1.0 FIXED_IO PS_SRSTB" *) inout FIXED_IO_ps_srstb;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp0 ARADDR" *) (* X_INTERFACE_MODE = "Slave" *) (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME m_axi_hp0, ADDR_WIDTH 32, ARUSER_WIDTH 0, AWUSER_WIDTH 0, BUSER_WIDTH 0, DATA_WIDTH 64, FREQ_HZ 150000000, HAS_BRESP 1, HAS_BURST 1, HAS_CACHE 1, HAS_LOCK 1, HAS_PROT 1, HAS_QOS 1, HAS_REGION 1, HAS_RRESP 1, HAS_WSTRB 1, ID_WIDTH 0, INSERT_VIP 0, MAX_BURST_LENGTH 16, NUM_READ_OUTSTANDING 1, NUM_READ_THREADS 1, NUM_WRITE_OUTSTANDING 1, NUM_WRITE_THREADS 1, PHASE 0.0, PROTOCOL AXI3, READ_WRITE_MODE READ_WRITE, RUSER_BITS_PER_BYTE 0, RUSER_WIDTH 0, SUPPORTS_NARROW_BURST 1, WUSER_BITS_PER_BYTE 0, WUSER_WIDTH 0" *) input [31:0]m_axi_hp0_araddr;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp0 ARBURST" *) input [1:0]m_axi_hp0_arburst;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp0 ARCACHE" *) input [3:0]m_axi_hp0_arcache;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp0 ARID" *) input [5:0]m_axi_hp0_arid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp0 ARLEN" *) input [3:0]m_axi_hp0_arlen;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp0 ARLOCK" *) input [1:0]m_axi_hp0_arlock;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp0 ARPROT" *) input [2:0]m_axi_hp0_arprot;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp0 ARQOS" *) input [3:0]m_axi_hp0_arqos;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp0 ARREADY" *) output m_axi_hp0_arready;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp0 ARSIZE" *) input [2:0]m_axi_hp0_arsize;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp0 ARVALID" *) input m_axi_hp0_arvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp0 AWADDR" *) input [31:0]m_axi_hp0_awaddr;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp0 AWBURST" *) input [1:0]m_axi_hp0_awburst;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp0 AWCACHE" *) input [3:0]m_axi_hp0_awcache;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp0 AWID" *) input [5:0]m_axi_hp0_awid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp0 AWLEN" *) input [3:0]m_axi_hp0_awlen;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp0 AWLOCK" *) input [1:0]m_axi_hp0_awlock;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp0 AWPROT" *) input [2:0]m_axi_hp0_awprot;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp0 AWQOS" *) input [3:0]m_axi_hp0_awqos;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp0 AWREADY" *) output m_axi_hp0_awready;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp0 AWSIZE" *) input [2:0]m_axi_hp0_awsize;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp0 AWVALID" *) input m_axi_hp0_awvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp0 BID" *) output [5:0]m_axi_hp0_bid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp0 BREADY" *) input m_axi_hp0_bready;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp0 BRESP" *) output [1:0]m_axi_hp0_bresp;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp0 BVALID" *) output m_axi_hp0_bvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp0 RDATA" *) output [63:0]m_axi_hp0_rdata;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp0 RID" *) output [5:0]m_axi_hp0_rid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp0 RLAST" *) output m_axi_hp0_rlast;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp0 RREADY" *) input m_axi_hp0_rready;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp0 RRESP" *) output [1:0]m_axi_hp0_rresp;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp0 RVALID" *) output m_axi_hp0_rvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp0 WDATA" *) input [63:0]m_axi_hp0_wdata;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp0 WID" *) input [5:0]m_axi_hp0_wid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp0 WLAST" *) input m_axi_hp0_wlast;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp0 WREADY" *) output m_axi_hp0_wready;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp0 WSTRB" *) input [7:0]m_axi_hp0_wstrb;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp0 WVALID" *) input m_axi_hp0_wvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp1 ARADDR" *) (* X_INTERFACE_MODE = "Slave" *) (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME m_axi_hp1, ADDR_WIDTH 32, ARUSER_WIDTH 0, AWUSER_WIDTH 0, BUSER_WIDTH 0, DATA_WIDTH 64, FREQ_HZ 150000000, HAS_BRESP 1, HAS_BURST 1, HAS_CACHE 1, HAS_LOCK 1, HAS_PROT 1, HAS_QOS 1, HAS_REGION 1, HAS_RRESP 1, HAS_WSTRB 1, ID_WIDTH 0, INSERT_VIP 0, MAX_BURST_LENGTH 16, NUM_READ_OUTSTANDING 1, NUM_READ_THREADS 1, NUM_WRITE_OUTSTANDING 1, NUM_WRITE_THREADS 1, PHASE 0.0, PROTOCOL AXI3, READ_WRITE_MODE READ_WRITE, RUSER_BITS_PER_BYTE 0, RUSER_WIDTH 0, SUPPORTS_NARROW_BURST 1, WUSER_BITS_PER_BYTE 0, WUSER_WIDTH 0" *) input [31:0]m_axi_hp1_araddr;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp1 ARBURST" *) input [1:0]m_axi_hp1_arburst;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp1 ARCACHE" *) input [3:0]m_axi_hp1_arcache;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp1 ARID" *) input [5:0]m_axi_hp1_arid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp1 ARLEN" *) input [3:0]m_axi_hp1_arlen;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp1 ARLOCK" *) input [1:0]m_axi_hp1_arlock;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp1 ARPROT" *) input [2:0]m_axi_hp1_arprot;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp1 ARQOS" *) input [3:0]m_axi_hp1_arqos;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp1 ARREADY" *) output m_axi_hp1_arready;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp1 ARSIZE" *) input [2:0]m_axi_hp1_arsize;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp1 ARVALID" *) input m_axi_hp1_arvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp1 AWADDR" *) input [31:0]m_axi_hp1_awaddr;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp1 AWBURST" *) input [1:0]m_axi_hp1_awburst;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp1 AWCACHE" *) input [3:0]m_axi_hp1_awcache;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp1 AWID" *) input [5:0]m_axi_hp1_awid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp1 AWLEN" *) input [3:0]m_axi_hp1_awlen;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp1 AWLOCK" *) input [1:0]m_axi_hp1_awlock;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp1 AWPROT" *) input [2:0]m_axi_hp1_awprot;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp1 AWQOS" *) input [3:0]m_axi_hp1_awqos;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp1 AWREADY" *) output m_axi_hp1_awready;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp1 AWSIZE" *) input [2:0]m_axi_hp1_awsize;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp1 AWVALID" *) input m_axi_hp1_awvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp1 BID" *) output [5:0]m_axi_hp1_bid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp1 BREADY" *) input m_axi_hp1_bready;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp1 BRESP" *) output [1:0]m_axi_hp1_bresp;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp1 BVALID" *) output m_axi_hp1_bvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp1 RDATA" *) output [63:0]m_axi_hp1_rdata;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp1 RID" *) output [5:0]m_axi_hp1_rid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp1 RLAST" *) output m_axi_hp1_rlast;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp1 RREADY" *) input m_axi_hp1_rready;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp1 RRESP" *) output [1:0]m_axi_hp1_rresp;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp1 RVALID" *) output m_axi_hp1_rvalid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp1 WDATA" *) input [63:0]m_axi_hp1_wdata;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp1 WID" *) input [5:0]m_axi_hp1_wid;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp1 WLAST" *) input m_axi_hp1_wlast;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp1 WREADY" *) output m_axi_hp1_wready;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp1 WSTRB" *) input [7:0]m_axi_hp1_wstrb;
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi_hp1 WVALID" *) input m_axi_hp1_wvalid;

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
  wire zynq_ps_FCLK_CLK0;

  ps_bd_zynq_ps_0 zynq_ps
       (.DDR_Addr(DDR_addr),
        .DDR_BankAddr(DDR_ba),
        .DDR_CAS_n(DDR_cas_n),
        .DDR_CKE(DDR_cke),
        .DDR_CS_n(DDR_cs_n),
        .DDR_Clk(DDR_ck_p),
        .DDR_Clk_n(DDR_ck_n),
        .DDR_DM(DDR_dm),
        .DDR_DQ(DDR_dq),
        .DDR_DQS(DDR_dqs_p),
        .DDR_DQS_n(DDR_dqs_n),
        .DDR_DRSTB(DDR_reset_n),
        .DDR_ODT(DDR_odt),
        .DDR_RAS_n(DDR_ras_n),
        .DDR_VRN(FIXED_IO_ddr_vrn),
        .DDR_VRP(FIXED_IO_ddr_vrp),
        .DDR_WEB(DDR_we_n),
        .FCLK_CLK0(zynq_ps_FCLK_CLK0),
        .FCLK_RESET0_N(FCLK_RESET0_N_0),
        .MIO(FIXED_IO_mio),
        .PS_CLK(FIXED_IO_ps_clk),
        .PS_PORB(FIXED_IO_ps_porb),
        .PS_SRSTB(FIXED_IO_ps_srstb),
        .S_AXI_HP0_ACLK(zynq_ps_FCLK_CLK0),
        .S_AXI_HP0_ARADDR(m_axi_hp0_araddr),
        .S_AXI_HP0_ARBURST(m_axi_hp0_arburst),
        .S_AXI_HP0_ARCACHE(m_axi_hp0_arcache),
        .S_AXI_HP0_ARID(m_axi_hp0_arid),
        .S_AXI_HP0_ARLEN(m_axi_hp0_arlen),
        .S_AXI_HP0_ARLOCK(m_axi_hp0_arlock),
        .S_AXI_HP0_ARPROT(m_axi_hp0_arprot),
        .S_AXI_HP0_ARQOS(m_axi_hp0_arqos),
        .S_AXI_HP0_ARREADY(m_axi_hp0_arready),
        .S_AXI_HP0_ARSIZE(m_axi_hp0_arsize),
        .S_AXI_HP0_ARVALID(m_axi_hp0_arvalid),
        .S_AXI_HP0_AWADDR(m_axi_hp0_awaddr),
        .S_AXI_HP0_AWBURST(m_axi_hp0_awburst),
        .S_AXI_HP0_AWCACHE(m_axi_hp0_awcache),
        .S_AXI_HP0_AWID(m_axi_hp0_awid),
        .S_AXI_HP0_AWLEN(m_axi_hp0_awlen),
        .S_AXI_HP0_AWLOCK(m_axi_hp0_awlock),
        .S_AXI_HP0_AWPROT(m_axi_hp0_awprot),
        .S_AXI_HP0_AWQOS(m_axi_hp0_awqos),
        .S_AXI_HP0_AWREADY(m_axi_hp0_awready),
        .S_AXI_HP0_AWSIZE(m_axi_hp0_awsize),
        .S_AXI_HP0_AWVALID(m_axi_hp0_awvalid),
        .S_AXI_HP0_BID(m_axi_hp0_bid),
        .S_AXI_HP0_BREADY(m_axi_hp0_bready),
        .S_AXI_HP0_BRESP(m_axi_hp0_bresp),
        .S_AXI_HP0_BVALID(m_axi_hp0_bvalid),
        .S_AXI_HP0_RDATA(m_axi_hp0_rdata),
        .S_AXI_HP0_RDISSUECAP1_EN(1'b0),
        .S_AXI_HP0_RID(m_axi_hp0_rid),
        .S_AXI_HP0_RLAST(m_axi_hp0_rlast),
        .S_AXI_HP0_RREADY(m_axi_hp0_rready),
        .S_AXI_HP0_RRESP(m_axi_hp0_rresp),
        .S_AXI_HP0_RVALID(m_axi_hp0_rvalid),
        .S_AXI_HP0_WDATA(m_axi_hp0_wdata),
        .S_AXI_HP0_WID(m_axi_hp0_wid),
        .S_AXI_HP0_WLAST(m_axi_hp0_wlast),
        .S_AXI_HP0_WREADY(m_axi_hp0_wready),
        .S_AXI_HP0_WRISSUECAP1_EN(1'b0),
        .S_AXI_HP0_WSTRB(m_axi_hp0_wstrb),
        .S_AXI_HP0_WVALID(m_axi_hp0_wvalid),
        .S_AXI_HP1_ACLK(zynq_ps_FCLK_CLK0),
        .S_AXI_HP1_ARADDR(m_axi_hp1_araddr),
        .S_AXI_HP1_ARBURST(m_axi_hp1_arburst),
        .S_AXI_HP1_ARCACHE(m_axi_hp1_arcache),
        .S_AXI_HP1_ARID(m_axi_hp1_arid),
        .S_AXI_HP1_ARLEN(m_axi_hp1_arlen),
        .S_AXI_HP1_ARLOCK(m_axi_hp1_arlock),
        .S_AXI_HP1_ARPROT(m_axi_hp1_arprot),
        .S_AXI_HP1_ARQOS(m_axi_hp1_arqos),
        .S_AXI_HP1_ARREADY(m_axi_hp1_arready),
        .S_AXI_HP1_ARSIZE(m_axi_hp1_arsize),
        .S_AXI_HP1_ARVALID(m_axi_hp1_arvalid),
        .S_AXI_HP1_AWADDR(m_axi_hp1_awaddr),
        .S_AXI_HP1_AWBURST(m_axi_hp1_awburst),
        .S_AXI_HP1_AWCACHE(m_axi_hp1_awcache),
        .S_AXI_HP1_AWID(m_axi_hp1_awid),
        .S_AXI_HP1_AWLEN(m_axi_hp1_awlen),
        .S_AXI_HP1_AWLOCK(m_axi_hp1_awlock),
        .S_AXI_HP1_AWPROT(m_axi_hp1_awprot),
        .S_AXI_HP1_AWQOS(m_axi_hp1_awqos),
        .S_AXI_HP1_AWREADY(m_axi_hp1_awready),
        .S_AXI_HP1_AWSIZE(m_axi_hp1_awsize),
        .S_AXI_HP1_AWVALID(m_axi_hp1_awvalid),
        .S_AXI_HP1_BID(m_axi_hp1_bid),
        .S_AXI_HP1_BREADY(m_axi_hp1_bready),
        .S_AXI_HP1_BRESP(m_axi_hp1_bresp),
        .S_AXI_HP1_BVALID(m_axi_hp1_bvalid),
        .S_AXI_HP1_RDATA(m_axi_hp1_rdata),
        .S_AXI_HP1_RDISSUECAP1_EN(1'b0),
        .S_AXI_HP1_RID(m_axi_hp1_rid),
        .S_AXI_HP1_RLAST(m_axi_hp1_rlast),
        .S_AXI_HP1_RREADY(m_axi_hp1_rready),
        .S_AXI_HP1_RRESP(m_axi_hp1_rresp),
        .S_AXI_HP1_RVALID(m_axi_hp1_rvalid),
        .S_AXI_HP1_WDATA(m_axi_hp1_wdata),
        .S_AXI_HP1_WID(m_axi_hp1_wid),
        .S_AXI_HP1_WLAST(m_axi_hp1_wlast),
        .S_AXI_HP1_WREADY(m_axi_hp1_wready),
        .S_AXI_HP1_WRISSUECAP1_EN(1'b0),
        .S_AXI_HP1_WSTRB(m_axi_hp1_wstrb),
        .S_AXI_HP1_WVALID(m_axi_hp1_wvalid));
endmodule
