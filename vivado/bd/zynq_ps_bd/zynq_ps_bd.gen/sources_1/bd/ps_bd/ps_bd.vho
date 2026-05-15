-- Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
-- Copyright 2022-2026 Advanced Micro Devices, Inc. All Rights Reserved.
-- -------------------------------------------------------------------------------
-- This file contains confidential and proprietary information
-- of AMD and is protected under U.S. and international copyright
-- and other intellectual property laws.
--
-- DISCLAIMER
-- This disclaimer is not a license and does not grant any
-- rights to the materials distributed herewith. Except as
-- otherwise provided in a valid license issued to you by
-- AMD, and to the maximum extent permitted by applicable
-- law: (1) THESE MATERIALS ARE MADE AVAILABLE "AS IS" AND
-- WITH ALL FAULTS, AND AMD HEREBY DISCLAIMS ALL WARRANTIES
-- AND CONDITIONS, EXPRESS, IMPLIED, OR STATUTORY, INCLUDING
-- BUT NOT LIMITED TO WARRANTIES OF MERCHANTABILITY, NON-
-- INFRINGEMENT, OR FITNESS FOR ANY PARTICULAR PURPOSE; and
-- (2) AMD shall not be liable (whether in contract or tort,
-- including negligence, or under any other theory of
-- liability) for any loss or damage of any kind or nature
-- related to, arising under or in connection with these
-- materials, including for any direct, or any indirect,
-- special, incidental, or consequential loss or damage
-- (including loss of data, profits, goodwill, or any type of
-- loss or damage suffered as a result of any action brought
-- by a third party) even if such damage or loss was
-- reasonably foreseeable or AMD had been advised of the
-- possibility of the same.
--
-- CRITICAL APPLICATIONS
-- AMD products are not designed or intended to be fail-
-- safe, or for use in any application requiring fail-safe
-- performance, such as life-support or safety devices or
-- systems, Class III medical devices, nuclear facilities,
-- applications related to the deployment of airbags, or any
-- other applications that could lead to death, personal
-- injury, or severe property or environmental damage
-- (individually and collectively, "Critical
-- Applications"). Customer assumes the sole risk and
-- liability of any use of AMD products in Critical
-- Applications, subject only to applicable laws and
-- regulations governing limitations on product liability.
--
-- THIS COPYRIGHT NOTICE AND DISCLAIMER MUST BE RETAINED AS
-- PART OF THIS FILE AT ALL TIMES.
--
-- DO NOT MODIFY THIS FILE.

-- MODULE VLNV: amd.com:blockdesign:ps_bd:1.0

-- The following code must appear in the VHDL architecture header.

-- COMP_TAG     ------ Begin cut for COMPONENT Declaration ------
COMPONENT ps_bd
  PORT (
    m_axi_hp0_arready : OUT STD_LOGIC;
    m_axi_hp0_awready : OUT STD_LOGIC;
    m_axi_hp0_bvalid : OUT STD_LOGIC;
    m_axi_hp0_rlast : OUT STD_LOGIC;
    m_axi_hp0_rvalid : OUT STD_LOGIC;
    m_axi_hp0_wready : OUT STD_LOGIC;
    m_axi_hp0_bresp : OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
    m_axi_hp0_rresp : OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
    m_axi_hp0_bid : OUT STD_LOGIC_VECTOR(5 DOWNTO 0);
    m_axi_hp0_rid : OUT STD_LOGIC_VECTOR(5 DOWNTO 0);
    m_axi_hp0_rdata : OUT STD_LOGIC_VECTOR(63 DOWNTO 0);
    m_axi_hp0_arvalid : IN STD_LOGIC;
    m_axi_hp0_awvalid : IN STD_LOGIC;
    m_axi_hp0_bready : IN STD_LOGIC;
    m_axi_hp0_rready : IN STD_LOGIC;
    m_axi_hp0_wlast : IN STD_LOGIC;
    m_axi_hp0_wvalid : IN STD_LOGIC;
    m_axi_hp0_arburst : IN STD_LOGIC_VECTOR(1 DOWNTO 0);
    m_axi_hp0_arlock : IN STD_LOGIC_VECTOR(1 DOWNTO 0);
    m_axi_hp0_arsize : IN STD_LOGIC_VECTOR(2 DOWNTO 0);
    m_axi_hp0_awburst : IN STD_LOGIC_VECTOR(1 DOWNTO 0);
    m_axi_hp0_awlock : IN STD_LOGIC_VECTOR(1 DOWNTO 0);
    m_axi_hp0_awsize : IN STD_LOGIC_VECTOR(2 DOWNTO 0);
    m_axi_hp0_arprot : IN STD_LOGIC_VECTOR(2 DOWNTO 0);
    m_axi_hp0_awprot : IN STD_LOGIC_VECTOR(2 DOWNTO 0);
    m_axi_hp0_araddr : IN STD_LOGIC_VECTOR(31 DOWNTO 0);
    m_axi_hp0_awaddr : IN STD_LOGIC_VECTOR(31 DOWNTO 0);
    m_axi_hp0_arcache : IN STD_LOGIC_VECTOR(3 DOWNTO 0);
    m_axi_hp0_arlen : IN STD_LOGIC_VECTOR(3 DOWNTO 0);
    m_axi_hp0_arqos : IN STD_LOGIC_VECTOR(3 DOWNTO 0);
    m_axi_hp0_awcache : IN STD_LOGIC_VECTOR(3 DOWNTO 0);
    m_axi_hp0_awlen : IN STD_LOGIC_VECTOR(3 DOWNTO 0);
    m_axi_hp0_awqos : IN STD_LOGIC_VECTOR(3 DOWNTO 0);
    m_axi_hp0_arid : IN STD_LOGIC_VECTOR(5 DOWNTO 0);
    m_axi_hp0_awid : IN STD_LOGIC_VECTOR(5 DOWNTO 0);
    m_axi_hp0_wid : IN STD_LOGIC_VECTOR(5 DOWNTO 0);
    m_axi_hp0_wdata : IN STD_LOGIC_VECTOR(63 DOWNTO 0);
    m_axi_hp0_wstrb : IN STD_LOGIC_VECTOR(7 DOWNTO 0);
    m_axi_hp1_arready : OUT STD_LOGIC;
    m_axi_hp1_awready : OUT STD_LOGIC;
    m_axi_hp1_bvalid : OUT STD_LOGIC;
    m_axi_hp1_rlast : OUT STD_LOGIC;
    m_axi_hp1_rvalid : OUT STD_LOGIC;
    m_axi_hp1_wready : OUT STD_LOGIC;
    m_axi_hp1_bresp : OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
    m_axi_hp1_rresp : OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
    m_axi_hp1_bid : OUT STD_LOGIC_VECTOR(5 DOWNTO 0);
    m_axi_hp1_rid : OUT STD_LOGIC_VECTOR(5 DOWNTO 0);
    m_axi_hp1_rdata : OUT STD_LOGIC_VECTOR(63 DOWNTO 0);
    m_axi_hp1_arvalid : IN STD_LOGIC;
    m_axi_hp1_awvalid : IN STD_LOGIC;
    m_axi_hp1_bready : IN STD_LOGIC;
    m_axi_hp1_rready : IN STD_LOGIC;
    m_axi_hp1_wlast : IN STD_LOGIC;
    m_axi_hp1_wvalid : IN STD_LOGIC;
    m_axi_hp1_arburst : IN STD_LOGIC_VECTOR(1 DOWNTO 0);
    m_axi_hp1_arlock : IN STD_LOGIC_VECTOR(1 DOWNTO 0);
    m_axi_hp1_arsize : IN STD_LOGIC_VECTOR(2 DOWNTO 0);
    m_axi_hp1_awburst : IN STD_LOGIC_VECTOR(1 DOWNTO 0);
    m_axi_hp1_awlock : IN STD_LOGIC_VECTOR(1 DOWNTO 0);
    m_axi_hp1_awsize : IN STD_LOGIC_VECTOR(2 DOWNTO 0);
    m_axi_hp1_arprot : IN STD_LOGIC_VECTOR(2 DOWNTO 0);
    m_axi_hp1_awprot : IN STD_LOGIC_VECTOR(2 DOWNTO 0);
    m_axi_hp1_araddr : IN STD_LOGIC_VECTOR(31 DOWNTO 0);
    m_axi_hp1_awaddr : IN STD_LOGIC_VECTOR(31 DOWNTO 0);
    m_axi_hp1_arcache : IN STD_LOGIC_VECTOR(3 DOWNTO 0);
    m_axi_hp1_arlen : IN STD_LOGIC_VECTOR(3 DOWNTO 0);
    m_axi_hp1_arqos : IN STD_LOGIC_VECTOR(3 DOWNTO 0);
    m_axi_hp1_awcache : IN STD_LOGIC_VECTOR(3 DOWNTO 0);
    m_axi_hp1_awlen : IN STD_LOGIC_VECTOR(3 DOWNTO 0);
    m_axi_hp1_awqos : IN STD_LOGIC_VECTOR(3 DOWNTO 0);
    m_axi_hp1_arid : IN STD_LOGIC_VECTOR(5 DOWNTO 0);
    m_axi_hp1_awid : IN STD_LOGIC_VECTOR(5 DOWNTO 0);
    m_axi_hp1_wid : IN STD_LOGIC_VECTOR(5 DOWNTO 0);
    m_axi_hp1_wdata : IN STD_LOGIC_VECTOR(63 DOWNTO 0);
    m_axi_hp1_wstrb : IN STD_LOGIC_VECTOR(7 DOWNTO 0);
    FCLK_RESET0_N_0 : OUT STD_LOGIC;
    DDR_cas_n : INOUT STD_LOGIC;
    DDR_cke : INOUT STD_LOGIC;
    DDR_ck_n : INOUT STD_LOGIC;
    DDR_ck_p : INOUT STD_LOGIC;
    DDR_cs_n : INOUT STD_LOGIC;
    DDR_reset_n : INOUT STD_LOGIC;
    DDR_odt : INOUT STD_LOGIC;
    DDR_ras_n : INOUT STD_LOGIC;
    DDR_we_n : INOUT STD_LOGIC;
    DDR_ba : INOUT STD_LOGIC_VECTOR(2 DOWNTO 0);
    DDR_addr : INOUT STD_LOGIC_VECTOR(14 DOWNTO 0);
    DDR_dm : INOUT STD_LOGIC_VECTOR(3 DOWNTO 0);
    DDR_dq : INOUT STD_LOGIC_VECTOR(31 DOWNTO 0);
    DDR_dqs_n : INOUT STD_LOGIC_VECTOR(3 DOWNTO 0);
    DDR_dqs_p : INOUT STD_LOGIC_VECTOR(3 DOWNTO 0);
    FIXED_IO_mio : INOUT STD_LOGIC_VECTOR(53 DOWNTO 0);
    FIXED_IO_ddr_vrn : INOUT STD_LOGIC;
    FIXED_IO_ddr_vrp : INOUT STD_LOGIC;
    FIXED_IO_ps_srstb : INOUT STD_LOGIC;
    FIXED_IO_ps_clk : INOUT STD_LOGIC;
    FIXED_IO_ps_porb : INOUT STD_LOGIC
  );
END COMPONENT;
-- COMP_TAG_END ------  End cut for COMPONENT Declaration  ------

-- The following code must appear in the VHDL architecture
-- body. Substitute your own instance name and net names.

-- INST_TAG     ------ Begin cut for INSTANTIATION Template ------
your_instance_name : ps_bd
  PORT MAP (
    m_axi_hp0_arready => m_axi_hp0_arready,
    m_axi_hp0_awready => m_axi_hp0_awready,
    m_axi_hp0_bvalid => m_axi_hp0_bvalid,
    m_axi_hp0_rlast => m_axi_hp0_rlast,
    m_axi_hp0_rvalid => m_axi_hp0_rvalid,
    m_axi_hp0_wready => m_axi_hp0_wready,
    m_axi_hp0_bresp => m_axi_hp0_bresp,
    m_axi_hp0_rresp => m_axi_hp0_rresp,
    m_axi_hp0_bid => m_axi_hp0_bid,
    m_axi_hp0_rid => m_axi_hp0_rid,
    m_axi_hp0_rdata => m_axi_hp0_rdata,
    m_axi_hp0_arvalid => m_axi_hp0_arvalid,
    m_axi_hp0_awvalid => m_axi_hp0_awvalid,
    m_axi_hp0_bready => m_axi_hp0_bready,
    m_axi_hp0_rready => m_axi_hp0_rready,
    m_axi_hp0_wlast => m_axi_hp0_wlast,
    m_axi_hp0_wvalid => m_axi_hp0_wvalid,
    m_axi_hp0_arburst => m_axi_hp0_arburst,
    m_axi_hp0_arlock => m_axi_hp0_arlock,
    m_axi_hp0_arsize => m_axi_hp0_arsize,
    m_axi_hp0_awburst => m_axi_hp0_awburst,
    m_axi_hp0_awlock => m_axi_hp0_awlock,
    m_axi_hp0_awsize => m_axi_hp0_awsize,
    m_axi_hp0_arprot => m_axi_hp0_arprot,
    m_axi_hp0_awprot => m_axi_hp0_awprot,
    m_axi_hp0_araddr => m_axi_hp0_araddr,
    m_axi_hp0_awaddr => m_axi_hp0_awaddr,
    m_axi_hp0_arcache => m_axi_hp0_arcache,
    m_axi_hp0_arlen => m_axi_hp0_arlen,
    m_axi_hp0_arqos => m_axi_hp0_arqos,
    m_axi_hp0_awcache => m_axi_hp0_awcache,
    m_axi_hp0_awlen => m_axi_hp0_awlen,
    m_axi_hp0_awqos => m_axi_hp0_awqos,
    m_axi_hp0_arid => m_axi_hp0_arid,
    m_axi_hp0_awid => m_axi_hp0_awid,
    m_axi_hp0_wid => m_axi_hp0_wid,
    m_axi_hp0_wdata => m_axi_hp0_wdata,
    m_axi_hp0_wstrb => m_axi_hp0_wstrb,
    m_axi_hp1_arready => m_axi_hp1_arready,
    m_axi_hp1_awready => m_axi_hp1_awready,
    m_axi_hp1_bvalid => m_axi_hp1_bvalid,
    m_axi_hp1_rlast => m_axi_hp1_rlast,
    m_axi_hp1_rvalid => m_axi_hp1_rvalid,
    m_axi_hp1_wready => m_axi_hp1_wready,
    m_axi_hp1_bresp => m_axi_hp1_bresp,
    m_axi_hp1_rresp => m_axi_hp1_rresp,
    m_axi_hp1_bid => m_axi_hp1_bid,
    m_axi_hp1_rid => m_axi_hp1_rid,
    m_axi_hp1_rdata => m_axi_hp1_rdata,
    m_axi_hp1_arvalid => m_axi_hp1_arvalid,
    m_axi_hp1_awvalid => m_axi_hp1_awvalid,
    m_axi_hp1_bready => m_axi_hp1_bready,
    m_axi_hp1_rready => m_axi_hp1_rready,
    m_axi_hp1_wlast => m_axi_hp1_wlast,
    m_axi_hp1_wvalid => m_axi_hp1_wvalid,
    m_axi_hp1_arburst => m_axi_hp1_arburst,
    m_axi_hp1_arlock => m_axi_hp1_arlock,
    m_axi_hp1_arsize => m_axi_hp1_arsize,
    m_axi_hp1_awburst => m_axi_hp1_awburst,
    m_axi_hp1_awlock => m_axi_hp1_awlock,
    m_axi_hp1_awsize => m_axi_hp1_awsize,
    m_axi_hp1_arprot => m_axi_hp1_arprot,
    m_axi_hp1_awprot => m_axi_hp1_awprot,
    m_axi_hp1_araddr => m_axi_hp1_araddr,
    m_axi_hp1_awaddr => m_axi_hp1_awaddr,
    m_axi_hp1_arcache => m_axi_hp1_arcache,
    m_axi_hp1_arlen => m_axi_hp1_arlen,
    m_axi_hp1_arqos => m_axi_hp1_arqos,
    m_axi_hp1_awcache => m_axi_hp1_awcache,
    m_axi_hp1_awlen => m_axi_hp1_awlen,
    m_axi_hp1_awqos => m_axi_hp1_awqos,
    m_axi_hp1_arid => m_axi_hp1_arid,
    m_axi_hp1_awid => m_axi_hp1_awid,
    m_axi_hp1_wid => m_axi_hp1_wid,
    m_axi_hp1_wdata => m_axi_hp1_wdata,
    m_axi_hp1_wstrb => m_axi_hp1_wstrb,
    FCLK_RESET0_N_0 => FCLK_RESET0_N_0,
    DDR_cas_n => DDR_cas_n,
    DDR_cke => DDR_cke,
    DDR_ck_n => DDR_ck_n,
    DDR_ck_p => DDR_ck_p,
    DDR_cs_n => DDR_cs_n,
    DDR_reset_n => DDR_reset_n,
    DDR_odt => DDR_odt,
    DDR_ras_n => DDR_ras_n,
    DDR_we_n => DDR_we_n,
    DDR_ba => DDR_ba,
    DDR_addr => DDR_addr,
    DDR_dm => DDR_dm,
    DDR_dq => DDR_dq,
    DDR_dqs_n => DDR_dqs_n,
    DDR_dqs_p => DDR_dqs_p,
    FIXED_IO_mio => FIXED_IO_mio,
    FIXED_IO_ddr_vrn => FIXED_IO_ddr_vrn,
    FIXED_IO_ddr_vrp => FIXED_IO_ddr_vrp,
    FIXED_IO_ps_srstb => FIXED_IO_ps_srstb,
    FIXED_IO_ps_clk => FIXED_IO_ps_clk,
    FIXED_IO_ps_porb => FIXED_IO_ps_porb
  );
-- INST_TAG_END ------  End cut for INSTANTIATION Template  ------

-- You must compile the wrapper file ps_bd.vhd when simulating
-- the module, ps_bd. When compiling the wrapper file, be sure to
-- reference the VHDL simulation library.
