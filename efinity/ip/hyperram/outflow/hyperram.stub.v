
module hyperram (ram_clk_cal, ram_clk, rst, hbc_cal_pass, hbc_ck_n_LO, 
            hbc_ck_n_HI, hbc_ck_p_LO, hbc_ck_p_HI, hbc_cs_n, hbc_rst_n, 
            hbc_cal_SHIFT_SEL, hbc_cal_SHIFT, hbc_cal_SHIFT_ENA, native_clk, 
            native_ram_en, native_ram_address, native_ctrl_idle, native_rd_valid, 
            native_wr_buf_ready, native_ram_burst_len, native_wr_en, native_ram_rdwr, 
            hbc_dq_OE, hbc_dq_IN_LO, hbc_dq_IN_HI, hbc_dq_OUT_LO, hbc_dq_OUT_HI, 
            hbc_rwds_OE, hbc_rwds_IN_LO, hbc_rwds_IN_HI, hbc_rwds_OUT_LO, 
            hbc_rwds_OUT_HI, native_wr_data, native_wr_datamask, native_rd_data, 
            hbc_cal_debug_info, dyn_pll_phase_sel, dyn_pll_phase_en);
    input ram_clk_cal;
    input ram_clk;
    input rst;
    output hbc_cal_pass;
    output hbc_ck_n_LO;
    output hbc_ck_n_HI;
    output hbc_ck_p_LO;
    output hbc_ck_p_HI;
    output hbc_cs_n;
    output hbc_rst_n;
    output [4:0]hbc_cal_SHIFT_SEL;
    output [2:0]hbc_cal_SHIFT;
    output hbc_cal_SHIFT_ENA;
    input native_clk;
    input native_ram_en;
    input [31:0]native_ram_address;
    output native_ctrl_idle;
    output native_rd_valid;
    output native_wr_buf_ready;
    input [10:0]native_ram_burst_len;
    input native_wr_en;
    input native_ram_rdwr;
    output [7:0]hbc_dq_OE;
    input [7:0]hbc_dq_IN_LO;
    input [7:0]hbc_dq_IN_HI;
    output [7:0]hbc_dq_OUT_LO;
    output [7:0]hbc_dq_OUT_HI;
    output [0:0]hbc_rwds_OE;
    input [0:0]hbc_rwds_IN_LO;
    input [0:0]hbc_rwds_IN_HI;
    output [0:0]hbc_rwds_OUT_LO;
    output [0:0]hbc_rwds_OUT_HI;
    input [63:0]native_wr_data;
    input [7:0]native_wr_datamask;
    output [63:0]native_rd_data;
    output [26:0]hbc_cal_debug_info;
    input [2:0]dyn_pll_phase_sel;
    input dyn_pll_phase_en;
    
endmodule







































































































































































