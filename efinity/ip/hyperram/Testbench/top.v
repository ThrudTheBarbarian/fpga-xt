////////////////////////////////////////////////////////////////////////////////////
//                                                                                //
// Copyright (C) 2013-2021 Efinix Inc. All rights reserved.                       //
//                                                                                //
// Description:                                                                   //
// Example top file for Hyper RAM controller                                      //
//                                                                                //
// Language:  Verilog 2001                                                        //
//                                                                                //
// ------------------------------------------------------------------------------ //
// REVISION:                                                                      //
//  $Snapshot: $                                                                  //
//  $Id:$                                                                         //
//                                                                                //
////////////////////////////////////////////////////////////////////////////////////
`define EFX_IPM
//`define SIM
`timescale 1ns / 1ps
module top # (
`ifdef SIM
`ifndef EFX_IPM
    parameter                   AXI_DBW = 128,
    parameter                   AXI_SBW = AXI_DBW/8,
`endif
`endif
    parameter                   AWR_LEN = 63,
    parameter                   TOP_DBW = 16
)(
`ifndef SIM
// =============== User JTAG for Debug Feature  ============
    input  wire                 jtag_inst1_DRCK,
    input  wire                 jtag_inst1_RESET,
    input  wire                 jtag_inst1_TMS,
    input  wire                 jtag_inst1_RUNTEST,
    input  wire                 jtag_inst1_SEL,
    input  wire                 jtag_inst1_SHIFT,
    input  wire                 jtag_inst1_TDI,
    input  wire                 jtag_inst1_CAPTURE,
    input  wire                 jtag_inst1_TCK,
    input  wire                 jtag_inst1_UPDATE,
    output wire                 jtag_inst1_TDO,
`endif
    input  wire                 intosc_clkout,
    output wire                 intosc_en,
// =============== Global Reset ============================
    input  wire                 io_asyncReset,
// =============== PLL Phase Settings ======================
    input  wire                 clk,
    input  wire                 hbramClk,
    input  wire                 hbramClk_cal,
    input  wire                 hbramClk_cal_2,//new
    input  wire                 hbramClk_pll_locked,
    output wire                 hbramClk_pll_rstn,
    output wire                 sysClk_pll_rstn,
// =============== PLL Phase Settings ======================
    output wire [2:0]           hbc_cal_SHIFT,
    output wire [4:0]           hbc_cal_SHIFT_SEL,
    output wire                 hbc_cal_SHIFT_ENA,
    output wire [2:0]           hbc_cal_SHIFT_HI,//new
    output wire [4:0]           hbc_cal_SHIFT_SEL_HI,//new
    output wire [2:0]           hbc_cal_SHIFT_LO,//new
    output wire [4:0]           hbc_cal_SHIFT_SEL_LO,//new
// =============== HBRAM Related Signals ===================
    output wire                 hbc_rst_n,
    output wire                 hbc_cs_n,
    output wire                 hbc_ck_p_HI,
    output wire                 hbc_ck_p_LO,
    output wire                 hbc_ck_n_HI,
    output wire                 hbc_ck_n_LO,
    output wire [TOP_DBW/8-1:0] hbc_rwds_OUT_HI,
    output wire [TOP_DBW/8-1:0] hbc_rwds_OUT_LO,
    input  wire [TOP_DBW/8-1:0] hbc_rwds_IN_HI,
    input  wire [TOP_DBW/8-1:0] hbc_rwds_IN_LO,
    input  wire [TOP_DBW-1:0]   hbc_dq_IN_LO,
    input  wire [TOP_DBW-1:0]   hbc_dq_IN_HI,
    output wire [TOP_DBW/8-1:0] hbc_rwds_OE,
    output wire [TOP_DBW-1:0]   hbc_dq_OUT_HI,
    output wire [TOP_DBW-1:0]   hbc_dq_OUT_LO,
    output wire [TOP_DBW-1:0]   hbc_dq_OE,
// ============== HBRAM_2 Related Signals ==================
    output wire                 hbc_rst_n_2,
    output wire                 hbc_cs_n_2,
    output wire                 hbc_ck_p_HI_2,
    output wire                 hbc_ck_p_LO_2,
    output wire                 hbc_ck_n_HI_2,
    output wire                 hbc_ck_n_LO_2,
    output wire [TOP_DBW/8-1:0] hbc_rwds_OUT_HI_2,
    output wire [TOP_DBW/8-1:0] hbc_rwds_OUT_LO_2,
    input  wire [TOP_DBW/8-1:0] hbc_rwds_IN_HI_2,
    input  wire [TOP_DBW/8-1:0] hbc_rwds_IN_LO_2,
    input  wire [TOP_DBW-1:0]   hbc_dq_IN_LO_2,
    input  wire [TOP_DBW-1:0]   hbc_dq_IN_HI_2,
    output wire [TOP_DBW/8-1:0] hbc_rwds_OE_2,
    output wire [TOP_DBW-1:0]   hbc_dq_OUT_HI_2,
    output wire [TOP_DBW-1:0]   hbc_dq_OUT_LO_2,
    output wire [TOP_DBW-1:0]   hbc_dq_OE_2,
// =============== ED Status Signal ========================
    output wire                 one_round,
    output wire                 test_good,
    output wire                 test_fail,
    output wire                 hbc_cal_pass,
    output wire					hbc_cal_done
);

`include "hyperram_define.svh"

(* async_reg = "true" *) reg [1:0] start;

localparam RAM_DBW_NATIVE = (DUAL_RAM==1)? 2: 1;
wire               reset;
wire               memoryFail;
wire               io_arw_valid;
wire               io_arw_ready;
wire [31:0]        io_arw_payload_addr;
wire [7:0]         io_arw_payload_id;
wire [7:0]         io_arw_payload_len;
wire [2:0]         io_arw_payload_size;
wire [1:0]         io_arw_payload_burst;
wire [1:0]         io_arw_payload_lock;
wire               io_arw_payload_write;
wire [7:0]         io_w_payload_id;
wire               io_w_valid;
wire               io_w_ready;
wire [AXI_DBW-1:0] io_w_payload_data;
wire [AXI_SBW-1:0] io_w_payload_strb;
wire               io_w_payload_last;
wire               io_b_valid;
wire               io_b_ready;
wire [7:0]         io_b_payload_id;
wire               io_r_valid;
wire               io_r_ready;
wire [AXI_DBW-1:0] io_r_payload_data;
wire [7:0]         io_r_payload_id;
wire [1:0]         io_r_payload_resp;
wire               io_r_payload_last;
wire [1:0]         io_b_payload_resp;
wire               native_ram_rdwr;
wire               native_ram_en;
wire [AXI_DBW-1:0] native_wr_data;
wire [AXI_SBW-1:0] native_wr_datamask;
wire [31:0]        native_ram_address;
wire               native_wr_en;
wire [10:0]        native_ram_burst_len;
wire               native_wr_buf_ready;
wire [AXI_DBW-1:0] native_rd_data;
wire               native_rd_valid;
wire               native_ctrl_idle;
wire               dyn_pll_phase_en;     
wire [2:0]         dyn_pll_phase_sel;
wire [23:0]        hbc_cal_debug_info;//extended
wire [2:0]         hbc_cal_SHIFT_int;
wire [2:0]         hbc_cal_SHIFT_int_HI;
wire [2:0]         hbc_cal_SHIFT_int_LO;
wire               hbc_cal_SHIFT_ENA_int;
wire               override;
wire [28:0]        clk_monitor;

assign reset             = ~( io_asyncReset & hbramClk_pll_locked);
assign hbramClk_pll_rstn = 1'b1;
assign sysClk_pll_rstn   = 1'b1;
assign intosc_en         = 1'b1;
assign hbc_cal_done = hbc_cal_debug_info[0];

    if (AXI_IF == 1 && DUAL_RAM == 1) begin
        hyperram hbram_top_inst (
            .rst                  (reset),
            .ram_clk              (hbramClk), 
            .ram_clk_cal          (hbramClk_cal),
            .ram_clk_cal_2        (hbramClk_cal_2), //new
            .io_axi_clk           (clk),
            .io_arw_valid         (io_arw_valid),
            .io_arw_ready         (io_arw_ready),
            .io_arw_payload_addr  (io_arw_payload_addr),
            .io_arw_payload_id    (io_arw_payload_id),
            .io_arw_payload_len   (io_arw_payload_len),
            .io_arw_payload_size  (io_arw_payload_size),
            .io_arw_payload_burst (io_arw_payload_burst),
            .io_arw_payload_lock  (io_arw_payload_lock),
            .io_arw_payload_write (io_arw_payload_write),
            .io_w_payload_id      (io_w_payload_id),
            .io_w_valid           (io_w_valid),
            .io_w_ready           (io_w_ready),
            .io_w_payload_data    (io_w_payload_data),
            .io_w_payload_strb    (io_w_payload_strb),
            .io_w_payload_last    (io_w_payload_last),
            .io_b_valid           (io_b_valid),
            .io_b_ready           (io_b_ready),
            .io_b_payload_id      (io_b_payload_id),
            .io_r_valid           (io_r_valid),
            .io_r_ready           (io_r_ready),
            .io_r_payload_data    (io_r_payload_data),
            .io_r_payload_id      (io_r_payload_id),
            .io_r_payload_resp    (io_r_payload_resp),
            .io_r_payload_last    (io_r_payload_last),
            .dyn_pll_phase_en     (dyn_pll_phase_en),
            .dyn_pll_phase_sel    (dyn_pll_phase_sel),
            .hbc_cal_SHIFT_ENA    (hbc_cal_SHIFT_ENA_int),
            .hbc_cal_SHIFT        (hbc_cal_SHIFT_int),
            .hbc_cal_SHIFT_SEL    (hbc_cal_SHIFT_SEL),
            //.hbc_cal_SHIFT_HI     (hbc_cal_SHIFT_int_HI),//new
            //.hbc_cal_SHIFT_SEL_HI (hbc_cal_SHIFT_SEL_HI),//new
            //.hbc_cal_SHIFT_LO     (hbc_cal_SHIFT_int_LO),//new
            //.hbc_cal_SHIFT_SEL_LO (hbc_cal_SHIFT_SEL_LO),//new
            .hbc_cal_pass         (hbc_cal_pass),
            .hbc_cal_debug_info   (hbc_cal_debug_info),
            .hbc_rst_n            (hbc_rst_n), 
            .hbc_cs_n             (hbc_cs_n),
            .hbc_ck_p_HI          (hbc_ck_p_HI),
            .hbc_ck_p_LO          (hbc_ck_p_LO),
            .hbc_ck_n_HI          (hbc_ck_n_HI),
            .hbc_ck_n_LO          (hbc_ck_n_LO),
            .hbc_rwds_OUT_HI      (hbc_rwds_OUT_HI),
            .hbc_rwds_OUT_LO      (hbc_rwds_OUT_LO),
            .hbc_rwds_IN_HI       (hbc_rwds_IN_HI),
            .hbc_rwds_IN_LO       (hbc_rwds_IN_LO),
            .hbc_rwds_OE          (hbc_rwds_OE),
            .hbc_dq_OUT_HI        (hbc_dq_OUT_HI),
            .hbc_dq_OUT_LO        (hbc_dq_OUT_LO),
            .hbc_dq_IN_HI         (hbc_dq_IN_HI),
            .hbc_dq_IN_LO         (hbc_dq_IN_LO),
            .hbc_dq_OE            (hbc_dq_OE),
            .hbc_rst_n_2            (hbc_rst_n_2),
            .hbc_cs_n_2            (hbc_cs_n_2),
            .hbc_ck_p_HI_2         (hbc_ck_p_HI_2),
            .hbc_ck_p_LO_2         (hbc_ck_p_LO_2),
            .hbc_ck_n_HI_2         (hbc_ck_n_HI_2),
            .hbc_ck_n_LO_2         (hbc_ck_n_LO_2),
            .hbc_rwds_OUT_HI_2     (hbc_rwds_OUT_HI_2),
            .hbc_rwds_OUT_LO_2     (hbc_rwds_OUT_LO_2),
            .hbc_rwds_IN_HI_2      (hbc_rwds_IN_HI_2),
            .hbc_rwds_IN_LO_2      (hbc_rwds_IN_LO_2),
            .hbc_rwds_OE_2         (hbc_rwds_OE_2),
            .hbc_dq_OUT_HI_2       (hbc_dq_OUT_HI_2),
            .hbc_dq_OUT_LO_2       (hbc_dq_OUT_LO_2),
            .hbc_dq_IN_HI_2        (hbc_dq_IN_HI_2),
            .hbc_dq_IN_LO_2        (hbc_dq_IN_LO_2),
            .hbc_dq_OE_2           (hbc_dq_OE_2)
        );
	end
	else if (AXI_IF == 1 && DUAL_RAM == 0) begin
		hyperram hbram_top_inst (
            .rst                  (reset),
            .ram_clk              (hbramClk), 
            .ram_clk_cal          (hbramClk_cal),
            //.ram_clk_cal_2        (hbramClk_cal_2), //new
            .io_axi_clk           (clk),
            .io_arw_valid         (io_arw_valid),
            .io_arw_ready         (io_arw_ready),
            .io_arw_payload_addr  (io_arw_payload_addr),
            .io_arw_payload_id    (io_arw_payload_id),
            .io_arw_payload_len   (io_arw_payload_len),
            .io_arw_payload_size  (io_arw_payload_size),
            .io_arw_payload_burst (io_arw_payload_burst),
            .io_arw_payload_lock  (io_arw_payload_lock),
            .io_arw_payload_write (io_arw_payload_write),
            .io_w_payload_id      (io_w_payload_id),
            .io_w_valid           (io_w_valid),
            .io_w_ready           (io_w_ready),
            .io_w_payload_data    (io_w_payload_data),
            .io_w_payload_strb    (io_w_payload_strb),
            .io_w_payload_last    (io_w_payload_last),
            .io_b_valid           (io_b_valid),
            .io_b_ready           (io_b_ready),
            .io_b_payload_id      (io_b_payload_id),
            .io_r_valid           (io_r_valid),
            .io_r_ready           (io_r_ready),
            .io_r_payload_data    (io_r_payload_data),
            .io_r_payload_id      (io_r_payload_id),
            .io_r_payload_resp    (io_r_payload_resp),
            .io_r_payload_last    (io_r_payload_last),
            .dyn_pll_phase_en     (dyn_pll_phase_en),
            .dyn_pll_phase_sel    (dyn_pll_phase_sel),
            .hbc_cal_SHIFT_ENA    (hbc_cal_SHIFT_ENA_int),
            .hbc_cal_SHIFT        (hbc_cal_SHIFT_int),
            .hbc_cal_SHIFT_SEL    (hbc_cal_SHIFT_SEL),
            //.hbc_cal_SHIFT_HI     (hbc_cal_SHIFT_int_HI),//new
            //.hbc_cal_SHIFT_SEL_HI (hbc_cal_SHIFT_SEL_HI),//new
            //.hbc_cal_SHIFT_LO     (hbc_cal_SHIFT_int_LO),//new
            //.hbc_cal_SHIFT_SEL_LO (hbc_cal_SHIFT_SEL_LO),//new
            .hbc_cal_pass         (hbc_cal_pass),
            .hbc_cal_debug_info   (hbc_cal_debug_info),
            .hbc_rst_n            (hbc_rst_n), 
            .hbc_cs_n             (hbc_cs_n),
            .hbc_ck_p_HI          (hbc_ck_p_HI),
            .hbc_ck_p_LO          (hbc_ck_p_LO),
            .hbc_ck_n_HI          (hbc_ck_n_HI),
            .hbc_ck_n_LO          (hbc_ck_n_LO),
            .hbc_rwds_OUT_HI      (hbc_rwds_OUT_HI),
            .hbc_rwds_OUT_LO      (hbc_rwds_OUT_LO),
            .hbc_rwds_IN_HI       (hbc_rwds_IN_HI),
            .hbc_rwds_IN_LO       (hbc_rwds_IN_LO),
            .hbc_rwds_OE          (hbc_rwds_OE),
            .hbc_dq_OUT_HI        (hbc_dq_OUT_HI),
            .hbc_dq_OUT_LO        (hbc_dq_OUT_LO),
            .hbc_dq_IN_HI         (hbc_dq_IN_HI),
            .hbc_dq_IN_LO         (hbc_dq_IN_LO),
            .hbc_dq_OE            (hbc_dq_OE)
		);
    end
	else if (AXI_IF == 0 && DUAL_RAM == 0) begin
        hyperram hbram_top_inst (
            .rst                  (reset),
            .ram_clk              (hbramClk), 
            .ram_clk_cal          (hbramClk_cal),
            .native_clk           (clk),
            .native_ram_rdwr      (native_ram_rdwr),
            .native_ram_en        (native_ram_en),
            .native_ram_address   (native_ram_address),
            .native_ram_burst_len (native_ram_burst_len),
            .native_wr_data       (native_wr_data),
            .native_wr_datamask   (native_wr_datamask),
            .native_wr_en         (native_wr_en),
            .native_wr_buf_ready  (native_wr_buf_ready),
            .native_rd_data       (native_rd_data),
            .native_rd_valid      (native_rd_valid),
            .native_ctrl_idle     (native_ctrl_idle),
            .dyn_pll_phase_en     (dyn_pll_phase_en),
            .dyn_pll_phase_sel    (dyn_pll_phase_sel),
            .hbc_cal_SHIFT_ENA    (hbc_cal_SHIFT_ENA_int),
            .hbc_cal_SHIFT        (hbc_cal_SHIFT_int),
            .hbc_cal_SHIFT_SEL    (hbc_cal_SHIFT_SEL),
            .hbc_cal_pass         (hbc_cal_pass),
            .hbc_cal_debug_info   (hbc_cal_debug_info),
            .hbc_rst_n            (hbc_rst_n), 
            .hbc_cs_n             (hbc_cs_n),
            .hbc_ck_p_HI          (hbc_ck_p_HI),
            .hbc_ck_p_LO          (hbc_ck_p_LO),
            .hbc_ck_n_HI          (hbc_ck_n_HI),
            .hbc_ck_n_LO          (hbc_ck_n_LO),
            .hbc_rwds_OUT_HI      (hbc_rwds_OUT_HI),
            .hbc_rwds_OUT_LO      (hbc_rwds_OUT_LO),
            .hbc_rwds_IN_HI       (hbc_rwds_IN_HI),
            .hbc_rwds_IN_LO       (hbc_rwds_IN_LO),
            .hbc_rwds_OE          (hbc_rwds_OE),
            .hbc_dq_OUT_HI        (hbc_dq_OUT_HI),
            .hbc_dq_OUT_LO        (hbc_dq_OUT_LO),
            .hbc_dq_IN_HI         (hbc_dq_IN_HI),
            .hbc_dq_IN_LO         (hbc_dq_IN_LO),
            .hbc_dq_OE            (hbc_dq_OE)
        );
	end
    else begin
	hyperram hbram_top_inst (
	    .rst                  (reset),
            .ram_clk              (hbramClk), 
            .ram_clk_cal          (hbramClk_cal),
			.ram_clk_cal_2		  (hbramClk_cal_2),
            .native_clk           (clk),
            .native_ram_rdwr      (native_ram_rdwr),
            .native_ram_en        (native_ram_en),
            .native_ram_address   (native_ram_address),
            .native_ram_burst_len (native_ram_burst_len),
            .native_wr_data       (native_wr_data),
            .native_wr_datamask   (native_wr_datamask),
            .native_wr_en         (native_wr_en),
            .native_wr_buf_ready  (native_wr_buf_ready),
            .native_rd_data       (native_rd_data),
            .native_rd_valid      (native_rd_valid),
            .native_ctrl_idle     (native_ctrl_idle),
            .dyn_pll_phase_en     (dyn_pll_phase_en),
            .dyn_pll_phase_sel    (dyn_pll_phase_sel),
            .hbc_cal_SHIFT_ENA    (hbc_cal_SHIFT_ENA_int),
            .hbc_cal_SHIFT        (hbc_cal_SHIFT_int),
            .hbc_cal_SHIFT_SEL    (hbc_cal_SHIFT_SEL),
            .hbc_cal_pass         (hbc_cal_pass),
            .hbc_cal_debug_info   (hbc_cal_debug_info),
            .hbc_rst_n            (hbc_rst_n), 
            .hbc_cs_n             (hbc_cs_n),
            .hbc_ck_p_HI          (hbc_ck_p_HI),
            .hbc_ck_p_LO          (hbc_ck_p_LO),
            .hbc_ck_n_HI          (hbc_ck_n_HI),
            .hbc_ck_n_LO          (hbc_ck_n_LO),
            .hbc_rwds_OUT_HI      (hbc_rwds_OUT_HI),
            .hbc_rwds_OUT_LO      (hbc_rwds_OUT_LO),
            .hbc_rwds_IN_HI       (hbc_rwds_IN_HI),
            .hbc_rwds_IN_LO       (hbc_rwds_IN_LO),
            .hbc_rwds_OE          (hbc_rwds_OE),
            .hbc_dq_OUT_HI        (hbc_dq_OUT_HI),
            .hbc_dq_OUT_LO        (hbc_dq_OUT_LO),
            .hbc_dq_IN_HI         (hbc_dq_IN_HI),
            .hbc_dq_IN_LO         (hbc_dq_IN_LO),
            .hbc_dq_OE            (hbc_dq_OE),
            .hbc_rst_n_2            (hbc_rst_n_2),
            .hbc_cs_n_2            (hbc_cs_n_2),
            .hbc_ck_p_HI_2         (hbc_ck_p_HI_2),
            .hbc_ck_p_LO_2         (hbc_ck_p_LO_2),
            .hbc_ck_n_HI_2         (hbc_ck_n_HI_2),
            .hbc_ck_n_LO_2         (hbc_ck_n_LO_2),
            .hbc_rwds_OUT_HI_2     (hbc_rwds_OUT_HI_2),
            .hbc_rwds_OUT_LO_2     (hbc_rwds_OUT_LO_2),
            .hbc_rwds_IN_HI_2      (hbc_rwds_IN_HI_2),
            .hbc_rwds_IN_LO_2      (hbc_rwds_IN_LO_2),
            .hbc_rwds_OE_2         (hbc_rwds_OE_2),
            .hbc_dq_OUT_HI_2       (hbc_dq_OUT_HI_2),
            .hbc_dq_OUT_LO_2       (hbc_dq_OUT_LO_2),
            .hbc_dq_IN_HI_2        (hbc_dq_IN_HI_2),
            .hbc_dq_IN_LO_2        (hbc_dq_IN_LO_2),
            .hbc_dq_OE_2           (hbc_dq_OE_2)
        );
    end

always @ (posedge clk or posedge reset) begin
    if (reset) begin
        start <= 2'b00;
    end
    else begin
        start <= {start[0],hbc_cal_pass};
    end
end

generate
    if (AXI_IF) begin
        `ifdef SIM
        localparam STOP_ADDRESS = 32'd65536;
        `else
        localparam STOP_ADDRESS = 32'd33550336;
        `endif
        
        efx_ed_hyper_ram_axi_tc #(
            .AXI_DBW    (AXI_DBW),
            .START_ADDR (32'h00000000),
            .STOP_ADDR  (STOP_ADDRESS),
            .AWR_LEN    (AWR_LEN)
        ) efx_ed_hyper_ram_axi_tc_inst (                
            .axi_clk    (clk),
            .rstn       (~reset),
            .start      (start[1]),
            .aid        (io_arw_payload_id),
            .aaddr      (io_arw_payload_addr),
            .alen       (io_arw_payload_len),
            .asize      (io_arw_payload_size),
            .aburst     (io_arw_payload_burst),
            .alock      (io_arw_payload_lock),
            .avalid     (io_arw_valid),
            .aready     (io_arw_ready),
            .atype      (io_arw_payload_write),
            .wid        (io_w_payload_id),
            .wdata      (io_w_payload_data),
            .wstrb      (io_w_payload_strb),
            .wlast      (io_w_payload_last),
            .wvalid     (io_w_valid),
            .wready     (io_w_ready), 
            .rid        (io_r_payload_id),
            .rdata      (io_r_payload_data),
            .rlast      (io_r_payload_last),
            .rvalid     (io_r_valid),
            .rready     (io_r_ready),
            .rresp      (io_r_payload_resp),
            .bid        (io_b_payload_id),
            .bvalid     (io_b_valid),
            .bready     (io_b_ready),
            .one_round  (one_round),
            .test_fail  (test_fail),
            .test_good  (test_good)
        );
    end
    else begin
        efx_ed_hyper_ram_native_tc # (
            .USER_DBW       (AXI_DBW),
            .RAM_DBW        (RAM_DBW_NATIVE)//(RAM_DBW)
        ) efx_ed_hyper_ram_native_tc_inst (
            .clk            (clk),
            .rst_n          (~reset),
            .cal_done       (start[1]),
            .ctrl_idle      (native_ctrl_idle),
            .wr_buf_ready   (native_wr_buf_ready),
            .burst_len      (native_ram_burst_len),
            .wr_data        (native_wr_data),
            .wr_datamask    (native_wr_datamask),
            .wr_address     (native_ram_address),
            .wr_en          (native_wr_en),
            .ram_rdwr       (native_ram_rdwr),
            .ram_en         (native_ram_en),
            .rd_data        (native_rd_data),
            .rd_valid       (native_rd_valid),
            .one_round      (one_round),
            .test_good      (test_good),
            .test_fail      (test_fail)
        );
    end
endgenerate

generate
    if (CAL_MODE > 1) begin
    `ifndef SIM
        edb_top edb_top_inst (
            .bscan_CAPTURE (jtag_inst1_CAPTURE),
            .bscan_DRCK    (jtag_inst1_DRCK),
            .bscan_RESET   (jtag_inst1_RESET),
            .bscan_RUNTEST (jtag_inst1_RUNTEST),
            .bscan_SEL     (jtag_inst1_SEL),
            .bscan_SHIFT   (jtag_inst1_SHIFT),
            .bscan_TCK     (jtag_inst1_TCK),
            .bscan_TDI     (jtag_inst1_TDI),
            .bscan_TMS     (jtag_inst1_TMS),
            .bscan_UPDATE  (jtag_inst1_UPDATE),
            .bscan_TDO     (jtag_inst1_TDO),
            .vio0_clk      (clk),
            .vio0_s0_Mode           ( override ),
            .vio0_s1_ShiftCtrl_en   ( dyn_pll_phase_en ),
            .vio0_s2_PLL_Shift      ( dyn_pll_phase_sel ),
            .vio0_p0_ShiftCtrl_en   ( hbc_cal_SHIFT_ENA ),
            .vio0_p1_PLL_Shift      ( hbc_cal_SHIFT ),
            .vio0_p2_Status         ({test_good,test_fail,hbc_cal_pass}),
            .vio0_p3_Freq           ( clk_monitor ),
            .vio0_p4_Window_Lock    ( hbc_cal_debug_info[15:5])
        );
        assign hbc_cal_SHIFT     = override ? dyn_pll_phase_sel : hbc_cal_SHIFT_int;
        assign hbc_cal_SHIFT_ENA = override ? dyn_pll_phase_en  : hbc_cal_SHIFT_ENA_int;
        assign hbc_cal_SHIFT_HI     = override ? dyn_pll_phase_sel : hbc_cal_SHIFT_int_HI;
        //assign hbc_cal_SHIFT_ENA_HI = override ? dyn_pll_phase_en  : hbc_cal_SHIFT_ENA_int_HI;
        assign hbc_cal_SHIFT_LO     = override ? dyn_pll_phase_sel : hbc_cal_SHIFT_int_LO;
       // assign hbc_cal_SHIFT_ENA_LO = override ? dyn_pll_phase_en  : hbc_cal_SHIFT_ENA_int_LO;

        efx_clk_monitor # (
            .REFCLK_FREQ (45)
        ) xefx_clk_monitor (
            .refclk  (intosc_clkout),
            .inclk   (hbramClk),
            .rst_n   (~reset),
            .out_mhz (clk_monitor)
        );
    `else
        assign dyn_pll_phase_en  = 1'b1;
        assign dyn_pll_phase_sel = 3'b010;
        assign hbc_cal_SHIFT     =  hbc_cal_SHIFT_int;
        assign hbc_cal_SHIFT_ENA =  hbc_cal_SHIFT_ENA_int;
        assign hbc_cal_SHIFT_HI     = hbc_cal_SHIFT_int_HI;
        //assign hbc_cal_SHIFT_ENA_HI = hbc_cal_SHIFT_ENA_int_HI;
        assign hbc_cal_SHIFT_LO     = hbc_cal_SHIFT_int_LO;
        //assign hbc_cal_SHIFT_ENA_LO = hbc_cal_SHIFT_ENA_int_LO;
    `endif
    end
endgenerate
endmodule

//////////////////////////////////////////////////////////////////////////////
// Copyright (C) 2013-2021 Efinix Inc. All rights reserved.
//
// This   document  contains  proprietary information  which   is
// protected by  copyright. All rights  are reserved.  This notice
// refers to original work by Efinix, Inc. which may be derivitive
// of other work distributed under license of the authors.  In the
// case of derivative work, nothing in this notice overrides the
// original author's license agreement.  Where applicable, the 
// original license agreement is included in it's original 
// unmodified form immediately below this header.
//
// WARRANTY DISCLAIMER.  
//     THE  DESIGN, CODE, OR INFORMATION ARE PROVIDED “AS IS” AND 
//     EFINIX MAKES NO WARRANTIES, EXPRESS OR IMPLIED WITH 
//     RESPECT THERETO, AND EXPRESSLY DISCLAIMS ANY IMPLIED WARRANTIES, 
//     INCLUDING, WITHOUT LIMITATION, THE IMPLIED WARRANTIES OF 
//     MERCHANTABILITY, NON-INFRINGEMENT AND FITNESS FOR A PARTICULAR 
//     PURPOSE.  SOME STATES DO NOT ALLOW EXCLUSIONS OF AN IMPLIED 
//     WARRANTY, SO THIS DISCLAIMER MAY NOT APPLY TO LICENSEE.
//
// LIMITATION OF LIABILITY.  
//     NOTWITHSTANDING ANYTHING TO THE CONTRARY, EXCEPT FOR BODILY 
//     INJURY, EFINIX SHALL NOT BE LIABLE WITH RESPECT TO ANY SUBJECT 
//     MATTER OF THIS AGREEMENT UNDER TORT, CONTRACT, STRICT LIABILITY 
//     OR ANY OTHER LEGAL OR EQUITABLE THEORY (I) FOR ANY INDIRECT, 
//     SPECIAL, INCIDENTAL, EXEMPLARY OR CONSEQUENTIAL DAMAGES OF ANY 
//     CHARACTER INCLUDING, WITHOUT LIMITATION, DAMAGES FOR LOSS OF 
//     GOODWILL, DATA OR PROFIT, WORK STOPPAGE, OR COMPUTER FAILURE OR 
//     MALFUNCTION, OR IN ANY EVENT (II) FOR ANY AMOUNT IN EXCESS, IN 
//     THE AGGREGATE, OF THE FEE PAID BY LICENSEE TO EFINIX HEREUNDER 
//     (OR, IF THE FEE HAS BEEN WAIVED, $100), EVEN IF EFINIX SHALL HAVE 
//     BEEN INFORMED OF THE POSSIBILITY OF SUCH DAMAGES.  SOME STATES DO 
//     NOT ALLOW THE EXCLUSION OR LIMITATION OF INCIDENTAL OR 
//     CONSEQUENTIAL DAMAGES, SO THIS LIMITATION AND EXCLUSION MAY NOT 
//     APPLY TO LICENSEE.
//
/////////////////////////////////////////////////////////////////////////////
