/////////////////////////////////////////////////////////////////////////////
//
// Copyright (C) 2013-2021 Efinix Inc. All rights reserved.
//
// Description:
// ------------------------------------------------------------------------------
// REVISION:
//  $Snapshot: $
//  $Id:$
//
// History:
/////////////////////////////////////////////////////////////////////////////////
`timescale 100ps/10ps

module tb_hbram ();
`include "hyperram_define.svh"

wire test_done;
wire test_fail;

initial begin
`ifdef XRUN
    $shm_open("waveform.shm");
    $shm_probe(tb_hbram,"ACMTF"); 
`endif
    @ (posedge test_done)
    if (test_fail === 1'b0) begin
        $display("===============================================");
        $display("=============== SIMULATION DONE ===============");
        $display("===============================================");
    end
    else begin
        $display("===============================================");
        $display("=============== SIMULATION FAIL ===============");
        $display("===============================================");
    end
    # 10000;
    
    $finish;
end

localparam	TCYC	 = 1000000/MHZ;
localparam      TS       = TCYC/100;//at 200Mhz -> 5000/100=50
localparam      U_DLY    = 0;
/////////////////////////////////////////////////////////////////////////////
reg				my_pll_locked		= 1'b0;
reg				clk_pll_locked		= 1'b0;
//define system signal
reg				io_rst;
wire				io_rst_n;
reg            			rst;
wire           			rst_n;
wire				io_clk;
wire           			clk;
wire           			clk_90;
reg				checkerd		= 'b0;
reg				checkerp		= 'b0;
//AXI3 signals
reg	            		io_arw_valid 		= 'h0;
wire            		io_arw_ready;
reg    [31:0]  			io_arw_payload_addr	= 'h0;
reg    [7:0]   			io_arw_payload_id	= 'h0;
reg    [7:0]   			io_arw_payload_len	= 'h0;
reg    [2:0]   			io_arw_payload_size	= 'h0;
reg    [1:0]   			io_arw_payload_burst	= 'h0;
reg    [1:0]   			io_arw_payload_lock	= 'h0;
reg            			io_arw_payload_write	= 'h0;
reg    [7:0]   			io_w_payload_id		= 'h0;
reg            			io_w_valid		= 'h0;
wire            		io_w_ready;
reg    [AXI_DBW-1:0]  		io_w_payload_data	= 'h0;
reg    [AXI_DBW/8-1:0]   	io_w_payload_strb	= 'h0;
reg            			io_w_payload_last	= 'h0;
wire           			io_b_valid;
reg	            		io_b_ready		= 'h1;
wire   	[7:0]   		io_b_payload_id;
wire     	       		io_r_valid;
reg				io_r_ready		= 'h1;
wire	[AXI_DBW-1:0]  		io_r_payload_data;
wire	[7:0]   		io_r_payload_id;
wire	[1:0]   		io_r_payload_resp;
wire		       		io_r_payload_last;
wire	[1:0]			io_b_payload_resp;
//hyperbus signals
wire     			hbc_rst_n;
wire     			hbc_cs_n;
wire         			hbc_ck_p_HI;
wire         			hbc_ck_p_LO;
wire         			hbc_ck_n_HI;
wire         			hbc_ck_n_LO;
wire     [RAM_DBW/8-1:0] 	hbc_rwds_OUT_HI;
wire     [RAM_DBW/8-1:0] 	hbc_rwds_OUT_LO;
wire     [RAM_DBW/8-1:0] 	hbc_rwds_IN_HI;
wire     [RAM_DBW/8-1:0] 	hbc_rwds_IN_LO;
wire     [RAM_DBW/8-1:0] 	hbc_rwds_IN;
wire     [RAM_DBW/8-1:0] 	hbc_rwds_IN_delay;
wire     [RAM_DBW/8-1:0] 	hbc_rwds_OE;
wire     [RAM_DBW-1:0]   	hbc_dq_OUT_HI;
wire     [RAM_DBW-1:0]   	hbc_dq_OUT_LO;
wire     [RAM_DBW-1:0]   	hbc_dq_IN_HI;
wire     [RAM_DBW-1:0]   	hbc_dq_IN_LO;
wire     [RAM_DBW-1:0]   	hbc_dq_IN;
wire     [RAM_DBW-1:0]   	hbc_dq_OE;
wire	 [2:0]				hbc_cal_SHIFT;
wire	 [4:0]				hbc_cal_SHIFT_SEL;
wire	 [2:0]				hbc_cal_SHIFT_HI;
wire	 [4:0]				hbc_cal_SHIFT_SEL_HI;
wire	 [2:0]				hbc_cal_SHIFT_LO;
wire	 [4:0]				hbc_cal_SHIFT_SEL_LO;
wire						hbc_cal_SHIFT_ENA;
wire						hbc_cal_pass;
wire     [2:0] 				rwds_delay;
//hyperbus ram signals
wire          			ram_rst_n;
wire          			ram_cs_n;
wire          			ram_ck_p;
wire          			ram_ck_n;
wire     [RAM_DBW/8-1:0]  	ram_rwds;
reg      [RAM_DBW/8-1:0] 	ram_rds;
reg      [RAM_DBW/8-1:0] 	ram_rds_2;//second clock for individual calibration
wire     [RAM_DBW-1:0]   	ram_dq;

//hyperbus 2 signals
wire     					hbc_rst_n_2;
wire     					hbc_cs_n_2;
wire         				hbc_ck_p_HI_2;
wire         				hbc_ck_p_LO_2;
wire         				hbc_ck_n_HI_2;
wire         				hbc_ck_n_LO_2;
wire     [RAM_DBW/8-1:0] 	hbc_rwds_OUT_HI_2;
wire     [RAM_DBW/8-1:0] 	hbc_rwds_OUT_LO_2;
wire     [RAM_DBW/8-1:0] 	hbc_rwds_IN_HI_2;
wire     [RAM_DBW/8-1:0] 	hbc_rwds_IN_LO_2;
wire     [RAM_DBW/8-1:0] 	hbc_rwds_IN_2;
wire     [RAM_DBW/8-1:0] 	hbc_rwds_IN_delay_2;
wire     [RAM_DBW/8-1:0] 	hbc_rwds_OE_2;
wire     [RAM_DBW-1:0]   	hbc_dq_OUT_HI_2;
wire     [RAM_DBW-1:0]   	hbc_dq_OUT_LO_2;
wire     [RAM_DBW-1:0]   	hbc_dq_IN_HI_2;
wire     [RAM_DBW-1:0]   	hbc_dq_IN_LO_2;
wire     [RAM_DBW-1:0]   	hbc_dq_IN_2;
wire     [RAM_DBW-1:0]   	hbc_dq_OE_2;
//hyperbus ram 2 signals
wire          				ram_rst_n_2;
wire          				ram_cs_n_2;
wire          				ram_ck_p_2;
wire          				ram_ck_n_2;
wire     [RAM_DBW/8-1:0]  	ram_rwds_2;
wire     [RAM_DBW-1:0]   	ram_dq_2;



//parameter
localparam LINEAR = 1'b1;
localparam WAPPED = 1'b0;
localparam REG    = 1'b1;
localparam MEM    = 1'b0;
localparam IR0    = 'b0000_0000_0000_0000;
localparam IR1    = 'b0000_0000_0000_0001;
localparam CR0    = 'b0000_1000_0000_0000;
localparam CR1    = 'b0000_1000_0000_0001;
integer	i,j;
/////////////////////////////////////////////////////////////////////////////
//system reset
initial begin
     rst = 1;
     io_rst = 1;
     #(100*TS);
     rst = 0;
     io_rst = 0;
end

//system clock
clock_gen #(
        .FREQ_CLK_MHZ(MHZ)
) clock_gen_inst (
        .rst            (rst   	  ),
        .clk_out0       (clk   	  ),
        .clk_out45      (      	  ),
        .clk_out90      (clk_90	  ),
        .clk_out135     (      	  ),
        .locked         (rst_n 	  )
);

clock_gen #(
        .FREQ_CLK_MHZ(MHZ)
) clock_gen2_inst (
        .rst            (io_rst   ),
        .clk_out0       (io_clk   ),
        .clk_out45      (      	  ),
        .clk_out90      (	  ),
        .clk_out135     (      	  ),
        .locked         (io_rst_n )
);

generate 
if (CAL_MODE == 1) begin
    wire                    hbc_cal_pass;
    initial begin
    wait (hbc_cal_pass);
    $display($time,,"-----------------------------------------");
    $display($time,,"[EFX_INFO]: HBRAM CALIBRATION PASS");
    $display($time,,"-----------------------------------------");
    end

    always @ ( * ) begin //soft logic calibration SHIFTS
        case(soft_dut.DUT.hbram_top_inst.soft_cal_block.hbram_cal_axi_top_inst.hbc_rwds_delay)
          3'b000:	ram_rds <= #(0*TS/8) hbc_rwds_IN;
          3'b001:	ram_rds <= #(4*TS/8) hbc_rwds_IN;
          3'b010:	ram_rds <= #(5*TS/8) hbc_rwds_IN;
          3'b011:	ram_rds <= #(6*TS/8) hbc_rwds_IN;
          3'b100:	ram_rds <= #(7*TS/8) hbc_rwds_IN;
          3'b101:	ram_rds <= #(3*TS/8) hbc_rwds_IN;
          3'b110:	ram_rds <= #(2*TS/8) hbc_rwds_IN;
          3'b111:	ram_rds <= #(7*TS/8) hbc_rwds_IN;
          default	:ram_rds <= #(0*TS/8) hbc_rwds_IN;
        endcase
    end
    assign hbc_rwds_IN_delay = ram_rds;
end
	else if (CAL_MODE == 2 || CAL_MODE == 3) begin
			initial begin
				wait (hbc_cal_pass);
				$display($time,,"-----------------------------------------");
				$display($time,,"[EFX_INFO]: HBRAM CALIBRATION PASS");
				$display($time,,"-----------------------------------------");
				//#50000;
				//$finish;
			end
		
			always @ ( * ) begin //auto acibration normal
				case(hbc_cal_SHIFT) //just to select the hbc_cal_SHIFT we had fixed
				  3'b000:	ram_rds <= #(0*TS/8) clk;
				  3'b001:	ram_rds <= #(1*TS/8) clk;
				  3'b010:	ram_rds <= #(2*TS/8) clk;
				  3'b011:	ram_rds <= #(3*TS/8) clk;
				  3'b100:	ram_rds <= #(4*TS/8) clk;
				  3'b101:	ram_rds <= #(5*TS/8) clk;
				  3'b110:	ram_rds <= #(6*TS/8) clk;
				  3'b111:	ram_rds <= #(7*TS/8) clk;
				  default	:ram_rds <= #(0*TS/8) clk;
				endcase
			end
			
			always @ ( * ) begin //skew dq
				case(hbc_cal_SHIFT) //just to select the hbc_cal_SHIFT we had fixed
				  3'b000:	ram_rds_2 <= #(0*TS/8) clk;
				  3'b001:	ram_rds_2 <= #(1*TS/8) clk;
				  3'b010:	ram_rds_2 <= #(2*TS/8) clk;
				  3'b011:	ram_rds_2 <= #(3*TS/8) clk;
				  3'b100:	ram_rds_2 <= #(4*TS/8) clk;
				  3'b101:	ram_rds_2 <= #(5*TS/8) clk;
				  3'b110:	ram_rds_2 <= #(6*TS/8) clk;
				  3'b111:	ram_rds_2 <= #(7*TS/8) clk;
				  default	:ram_rds_2 <= #(0*TS/8) clk;
				endcase
			end
	end
endgenerate

//RST_N
assign ram_rst_n = hbc_rst_n;
assign ram_rst_n_2 = hbc_rst_n_2;
                   
wire hbc_cal_done;
initial
begin:system
	$display($time,,"-----------------------------------------");
	$display($time,,"[EFX_INFO]: Start HBRAM TEST");
	$display($time,,"-----------------------------------------");
	clk_pll_locked	= 1'b0;
	my_pll_locked 	= 1'b0;
	#3000
	clk_pll_locked	= 1'b1;
	#5000;
	my_pll_locked 	= 1'b1;
	#5000;
    io_rst = 1;
    #2000;
    io_rst = 0;
    wait (hbc_cal_done);

    repeat (100) begin @(posedge clk); end
    if(hbc_cal_pass == 0) begin
    $display($time,,"-----------------------------------------");
	$display($time,,"CALIBRATION FAILED");
	$display($time,,"-----------------------------------------");
	$finish;
    end
end

generate
    if (CAL_MODE == 1) begin: soft_dut
        top DUT (
            .hbc_cal_pass           (hbc_cal_pass       	),
            .hbramClk           	(clk            		),
            .hbramClk_pll_locked    (1'b1     				),
            .hbramClk_pll_rstn      (           			),
            .clk                	(io_clk         		),
            .io_asyncReset          (~io_rst       			),
            .hbc_rst_n              (hbc_rst_n              ),
            .hbc_cs_n               (hbc_cs_n               ),
            .hbc_ck_p_HI            (hbc_ck_p_HI            ),
            .hbc_ck_p_LO            (hbc_ck_p_LO            ),
            .hbc_ck_n_HI            (hbc_ck_n_HI            ),
            .hbc_ck_n_LO            (hbc_ck_n_LO            ),
            .hbc_rwds_OUT_HI        (hbc_rwds_OUT_HI        ),
            .hbc_rwds_OUT_LO        (hbc_rwds_OUT_LO        ),
            .hbc_rwds_IN_HI         (hbc_rwds_IN_delay      ),
            .hbc_rwds_IN_LO         (                       ),
            .hbc_rwds_OE            (hbc_rwds_OE            ),
            .hbc_dq_OUT_HI          (hbc_dq_OUT_HI          ),
            .hbc_dq_OUT_LO          (hbc_dq_OUT_LO          ),
            .hbc_dq_IN_HI           (hbc_dq_IN              ),
            .hbc_dq_OE              (hbc_dq_OE              ),
            // ========== Monitor Output ==========	
            .one_round           (test_done),
            .test_fail           (test_fail)
        );
    end
    else if (CAL_MODE == 0 || CAL_MODE == 2) begin: hard_dut
        top //# 
        //`ifdef SIM
        //(
        //	.AXI_DBW        (AXI_DBW),
        //	.AWR_LEN (AWR_LEN)
        //)
        //`endif
        DUT (
            .hbramClk            (clk),
            .hbramClk_cal        (ram_rds[0]),//LO
            .hbramClk_cal_2      (ram_rds_2[0]),//HI
            .hbramClk_pll_locked (1'b1),
            .hbramClk_pll_rstn   (),
            .sysClk_pll_rstn     (),
            .clk                 (io_clk),
            .io_asyncReset       (~io_rst),
            .hbc_cal_SHIFT_ENA   (hbc_cal_SHIFT_ENA),
            .hbc_cal_SHIFT       (hbc_cal_SHIFT),
            //.hbc_cal_SHIFT_HI    (hbc_cal_SHIFT_HI),
            //.hbc_cal_SHIFT_LO    (hbc_cal_SHIFT_LO),
            .hbc_cal_SHIFT_SEL   (hbc_cal_SHIFT_SEL),
            .hbc_cal_SHIFT_SEL_HI (hbc_cal_SHIFT_SEL_HI),
            .hbc_cal_SHIFT_SEL_LO (hbc_cal_SHIFT_SEL_LO),
            .hbc_cal_pass        (hbc_cal_pass),
            .hbc_cal_done		 (hbc_cal_done),
            //hyperbus_1
            .hbc_rst_n           (hbc_rst_n), 
            .hbc_cs_n            (hbc_cs_n),
            .hbc_ck_p_HI         (hbc_ck_p_HI),
            .hbc_ck_p_LO         (hbc_ck_p_LO),
            .hbc_ck_n_HI         (hbc_ck_n_HI),
            .hbc_ck_n_LO         (hbc_ck_n_LO),
            .hbc_rwds_OUT_HI     (hbc_rwds_OUT_HI),
            .hbc_rwds_OUT_LO     (hbc_rwds_OUT_LO),
            .hbc_rwds_IN_HI      (hbc_rwds_IN_HI),
            .hbc_rwds_IN_LO      (hbc_rwds_IN_LO),
            .hbc_rwds_OE         (hbc_rwds_OE),
            .hbc_dq_OUT_HI       (hbc_dq_OUT_HI),
            .hbc_dq_OUT_LO       (hbc_dq_OUT_LO),
            .hbc_dq_IN_HI        (hbc_dq_IN_HI),
            .hbc_dq_IN_LO        (hbc_dq_IN_LO),
            .hbc_dq_OE           (hbc_dq_OE),
            //hyperbus_2
            .hbc_rst_n_2           (hbc_rst_n_2), 
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
            .hbc_dq_OE_2           (hbc_dq_OE_2),
            // ========== Monitor Output ==========	
            .one_round           (test_done),
            .test_good           (),
            .test_fail           (test_fail)
        );
    end
endgenerate

/////////////////////////////////////////////////////////////////////////////////
//CS_N
EFX_GPIO_model #(
	.BUS_WIDTH   (1     	  ), // define ddio bus width
	.TYPE        ("OUT" 	  ), // "IN"=input "OUT"=output "INOUT"=inout
	.OUT_REG     (1     	  ), // 1: enable 0: disable
	.OUT_DDIO    (0     	  ), // 1: enable 0: disable
	.OUT_RESYNC  (0     	  ), // 1: enable 0: disable
	.OUTCLK_INV  (0     	  ), // 1: enable 0: disable
	.OE_REG      (0     	  ), // 1: enable 0: disable
	.IN_REG      (0     	  ), // 1: enable 0: disable
	.IN_DDIO     (0     	  ), // 1: enable 0: disable
	.IN_RESYNC   (0     	  ), // 1: enable 0: disable
	.INCLK_INV   (0     	  )  // 1: enable 0: disable
) cs_n_inst (
	.out_HI      (hbc_cs_n    ), // tx HI data input from internal logic
	.out_LO      (1'b0 	      ), // tx LO data input from internal logic
	.outclk      (clk         ), // tx data clk input from internal logic
	.oe          (1'b1        ), // tx data output enable from internal logic
	.in_HI       (            ), // rx HI data output to internal logic
	.in_LO       (            ), // rx LO data output to internal logic
	.inclk       (1'b0        ), // rx data clk input from internal logic
	.io          (ram_cs_n    )  // outside io signal
);
//CK_P
EFX_GPIO_model #(
	.BUS_WIDTH   (1     	  ), 
	.TYPE        ("OUT" 	  ), 
	.OUT_REG     (1     	  ), 
	.OUT_DDIO    (1     	  ), 
	.OUT_RESYNC  (0     	  ), 
	.OUTCLK_INV  (1     	  ), 
	.OE_REG      (0     	  ), 
	.IN_REG      (0     	  ), 
	.IN_DDIO     (0     	  ), 
	.IN_RESYNC   (0     	  ), 
	.INCLK_INV   (0     	  )  
) ck_p_inst (
	.out_HI      (hbc_ck_p_HI ), 
	.out_LO      (hbc_ck_p_LO ), 
	.outclk      (clk_90      ), 
	.oe          (1'b1        ), 
	.in_HI       (            ), 
	.in_LO       (            ), 
	.inclk       (1'b0        ), 
	.io          (ram_ck_p    )  
);
//CK_N
EFX_GPIO_model #(
	.BUS_WIDTH   (1           ), 
	.TYPE        ("OUT"       ), 
	.OUT_REG     (1           ), 
	.OUT_DDIO    (1           ), 
	.OUT_RESYNC  (0           ), 
	.OUTCLK_INV  (1           ), 
	.OE_REG      (0           ), 
	.IN_REG      (0           ), 
	.IN_DDIO     (0           ), 
	.IN_RESYNC   (0           ), 
	.INCLK_INV   (0           )  
) ck_n_inst (
	.out_HI      (hbc_ck_n_HI ), 
	.out_LO      (hbc_ck_n_LO ), 
	.outclk      (clk_90      ), 
	.oe          (1'b1        ), 
	.in_HI       (            ), 
	.in_LO       (            ), 
	.inclk       (1'b0        ), 
	.io          (ram_ck_n    )  
);

generate 
if(CAL_MODE == 1)
begin
//RWDS
EFX_GPIO_model #(
	.BUS_WIDTH   (RAM_DBW/8  ), 
	.TYPE        ("INOUT"     ), 
	.OUT_REG     (1           ), 
	.OUT_DDIO    (1           ), 
	.OUT_RESYNC  (0           ), 
	.OUTCLK_INV  (0           ), 
	.OE_REG      (1           ), 
	.IN_REG      (0           ), 
	.IN_DDIO     (0           ), 
	.IN_RESYNC   (0           ), 
	.INCLK_INV   (0           )  
) rwds_inst (
	.out_HI      (hbc_rwds_OUT_HI), 
	.out_LO      (hbc_rwds_OUT_LO), 
	.outclk      (clk            ), 
	.oe          (hbc_rwds_OE[0] ), 
	.in_HI       (hbc_rwds_IN    ), 
	.in_LO       (		     ), 
	.inclk       (1'b0	     ), 
	.io          (ram_rwds       )  
);

//DQ
EFX_GPIO_model #(
	.BUS_WIDTH   (RAM_DBW   ), 
	.TYPE        ("INOUT"    ), 
	.OUT_REG     (1          ), 
	.OUT_DDIO    (1          ), 
	.OUT_RESYNC  (0          ), 
	.OUTCLK_INV  (1          ), 
	.OE_REG      (1          ), 
	.IN_REG      (0          ), 
	.IN_DDIO     (0          ), 
	.IN_RESYNC   (0          ), 
	.INCLK_INV   (0          )  
) dq_inst (
	.out_HI      (hbc_dq_OUT_HI ), 
	.out_LO      (hbc_dq_OUT_LO ), 
	.outclk      (clk           ), 
	.oe          (hbc_dq_OE[0]  ), 
	.in_HI       (hbc_dq_IN	    ), 
	.in_LO       (		    ), 
	.inclk       (1'b0	    ), 
	.io          (ram_dq        )  
);
end
else
begin
//RWDS
EFX_GPIO_model #(
	.BUS_WIDTH   (RAM_DBW/8  ), 
	.TYPE        ("INOUT"     ), 
	.OUT_REG     (1           ), 
	.OUT_DDIO    (1           ), 
	.OUT_RESYNC  (0           ), 
	.OUTCLK_INV  (0           ), 
	.OE_REG      (1           ), 
	.IN_REG      (1           ), 
	.IN_DDIO     (1           ), 
	.IN_RESYNC   (1           ), 
	.INCLK_INV   (0           )  
) rwds_inst (
	.out_HI      (hbc_rwds_OUT_HI), 
	.out_LO      (hbc_rwds_OUT_LO), 
	.outclk      (clk            ), 
	.oe          (hbc_rwds_OE[0] ), 
	.in_HI       (hbc_rwds_IN_HI ), 
	.in_LO       (hbc_rwds_IN_LO ), 
	.inclk       (ram_rds[0]     ), 
	.io          (ram_rwds       )  
);

//DQ
EFX_GPIO_model #(
	.BUS_WIDTH   (RAM_DBW   ), 
	.TYPE        ("INOUT"    ), 
	.OUT_REG     (1          ), 
	.OUT_DDIO    (1          ), 
	.OUT_RESYNC  (0          ), 
	.OUTCLK_INV  (1          ), 
	.OE_REG      (1          ), 
	.IN_REG      (1          ), 
	.IN_DDIO     (1          ), 
	.IN_RESYNC   (1          ), 
	.INCLK_INV   (0          )  
) dq_inst (
	.out_HI      (hbc_dq_OUT_HI ), 
	.out_LO      (hbc_dq_OUT_LO ), 
	.outclk      (clk           ), 
	.oe          (hbc_dq_OE[0]  ), 
	.in_HI       (hbc_dq_IN_HI  ), 
	.in_LO       (hbc_dq_IN_LO  ), 
	.inclk       (ram_rds[0]    ), 
	.io          (ram_dq        )  
);
end
endgenerate

/////////////////////////////////////////////////////////////////////////////////
//Hyperbus RAM_1
generate
     pullup p0 (ram_cs_n   );
     pullup p1 (ram_rst_n  );
	if (RAM_DBW == 8) begin
	W958D8NW Winbond_ram_x8_inst(
	.adq	(ram_dq		), 		
	.clk	(ram_ck_p	),		
	.clk_n	(ram_ck_n	),//(1'b0		),      
	.csb	(ram_cs_n	),		
	.rwds	(ram_rwds	),        
	.VCC	(1'b1		),
	.VSS	(1'b0		),
	.resetb	(ram_rst_n	)
	);
	end
	else begin
	W958D6NKY ram_x16_inst(
	.adq	(ram_dq		), 		
	.clk	(ram_ck_p	),		
	.clk_n	(1'b0		),      
	.csb	(ram_cs_n	),		
	.rwds	(ram_rwds	),        
	.VCC	(1'b1		),
	.VSS	(1'b0		),
	.resetb	(ram_rst_n	),
	.die_stack	(1'b0		),
	.optddp	(1'b0		)
	);
	end
endgenerate 

/////////////////////////////////////////////////
//DQ32 test
//Second hyperram
/////////////////////////////////////////////////
generate 
	if (DUAL_RAM == 1) begin
//CS_N
EFX_GPIO_model #(
	.BUS_WIDTH   (1     	  ), // define ddio bus width
	.TYPE        ("OUT" 	  ), // "IN"=input "OUT"=output "INOUT"=inout
	.OUT_REG     (1     	  ), // 1: enable 0: disable
	.OUT_DDIO    (0     	  ), // 1: enable 0: disable
	.OUT_RESYNC  (0     	  ), // 1: enable 0: disable
	.OUTCLK_INV  (0     	  ), // 1: enable 0: disable
	.OE_REG      (0     	  ), // 1: enable 0: disable
	.IN_REG      (0     	  ), // 1: enable 0: disable
	.IN_DDIO     (0     	  ), // 1: enable 0: disable
	.IN_RESYNC   (0     	  ), // 1: enable 0: disable
	.INCLK_INV   (0     	  )  // 1: enable 0: disable
) cs_n_inst_2 (
	.out_HI      (hbc_cs_n_2    ), // tx HI data input from internal logic
	.out_LO      (1'b0 	      ), // tx LO data input from internal logic
	.outclk      (clk         ), // tx data clk input from internal logic
	.oe          (1'b1        ), // tx data output enable from internal logic
	.in_HI       (            ), // rx HI data output to internal logic
	.in_LO       (            ), // rx LO data output to internal logic
	.inclk       (1'b0        ), // rx data clk input from internal logic
	.io          (ram_cs_n_2    )  // outside io signal
);
//CK_P
EFX_GPIO_model #(
	.BUS_WIDTH   (1     	  ), 
	.TYPE        ("OUT" 	  ), 
	.OUT_REG     (1     	  ), 
	.OUT_DDIO    (1     	  ), 
	.OUT_RESYNC  (0     	  ), 
	.OUTCLK_INV  (1     	  ), 
	.OE_REG      (0     	  ), 
	.IN_REG      (0     	  ), 
	.IN_DDIO     (0     	  ), 
	.IN_RESYNC   (0     	  ), 
	.INCLK_INV   (0     	  )  
) ck_p_inst_2 (
	.out_HI      (hbc_ck_p_HI_2 ), 
	.out_LO      (hbc_ck_p_LO_2 ), 
	.outclk      (clk_90      ), 
	.oe          (1'b1        ), 
	.in_HI       (            ), 
	.in_LO       (            ), 
	.inclk       (1'b0        ), 
	.io          (ram_ck_p_2    )  
);
//CK_N
EFX_GPIO_model #(
	.BUS_WIDTH   (1           ), 
	.TYPE        ("OUT"       ), 
	.OUT_REG     (1           ), 
	.OUT_DDIO    (1           ), 
	.OUT_RESYNC  (0           ), 
	.OUTCLK_INV  (1           ), 
	.OE_REG      (0           ), 
	.IN_REG      (0           ), 
	.IN_DDIO     (0           ), 
	.IN_RESYNC   (0           ), 
	.INCLK_INV   (0           )  
) ck_n_inst_2 (
	.out_HI      (hbc_ck_n_HI_2 ), 
	.out_LO      (hbc_ck_n_LO_2 ), 
	.outclk      (clk_90      ), 
	.oe          (1'b1        ), 
	.in_HI       (            ), 
	.in_LO       (            ), 
	.inclk       (1'b0        ), 
	.io          (ram_ck_n_2    )  
);
end
endgenerate

generate 
if(DUAL_RAM == 1) begin
	if(CAL_MODE == 1)
	begin
	//RWDS
	EFX_GPIO_model #(
		.BUS_WIDTH   (RAM_DBW/8  ), 
		.TYPE        ("INOUT"     ), 
		.OUT_REG     (1           ), 
		.OUT_DDIO    (1           ), 
		.OUT_RESYNC  (0           ), 
		.OUTCLK_INV  (0           ), 
		.OE_REG      (1           ), 
		.IN_REG      (0           ), 
		.IN_DDIO     (0           ), 
		.IN_RESYNC   (1            ), 
		.INCLK_INV   (0           )  
	) rwds_inst_2 (
		.out_HI      (hbc_rwds_OUT_HI_2), 
		.out_LO      (hbc_rwds_OUT_LO_2), 
		.outclk      (clk            ), 
		.oe          (hbc_rwds_OE_2[0] ), 
		.in_HI       (hbc_rwds_IN_2    ), 
		.in_LO       (		     ), 
		.inclk       (1'b0	     ), 
		.io          (ram_rwds_2       )  
	);
	
	//DQ
	EFX_GPIO_model #(
		.BUS_WIDTH   (RAM_DBW   ), 
		.TYPE        ("INOUT"    ), 
		.OUT_REG     (1          ), 
		.OUT_DDIO    (1          ), 
		.OUT_RESYNC  (0          ), 
		.OUTCLK_INV  (1          ), 
		.OE_REG      (1          ), 
		.IN_REG      (0          ), 
		.IN_DDIO     (0          ), 
		.IN_RESYNC   (1           ), 
		.INCLK_INV   (0          )  
	) dq_inst_2 (
		.out_HI      (hbc_dq_OUT_HI_2 ), 
		.out_LO      (hbc_dq_OUT_LO_2 ), 
		.outclk      (clk           ), 
		.oe          (hbc_dq_OE_2[0]  ), 
		.in_HI       (hbc_dq_IN_2	    ), 
		.in_LO       (		    ), 
		.inclk       (1'b0	    ), 
		.io          (ram_dq_2        )  
	);
	end
	else if (INDIVI_DUAL_CAL == 1) begin
	//RWDS
	EFX_GPIO_model #(
		.BUS_WIDTH   (RAM_DBW/8  ), 
		.TYPE        ("INOUT"     ), 
		.OUT_REG     (1           ), 
		.OUT_DDIO    (1           ), 
		.OUT_RESYNC  (0           ), 
		.OUTCLK_INV  (0           ), 
		.OE_REG      (1           ), 
		.IN_REG      (1           ), 
		.IN_DDIO     (1           ), 
		.IN_RESYNC   (1            ), 
		.INCLK_INV   (0           )  
	) rwds_inst_2 (
		.out_HI      (hbc_rwds_OUT_HI_2), 
		.out_LO      (hbc_rwds_OUT_LO_2), 
		.outclk      (clk            ), 
		.oe          (hbc_rwds_OE_2[0] ), 
		.in_HI       (hbc_rwds_IN_HI_2 ), 
		.in_LO       (hbc_rwds_IN_LO_2 ), 
		.inclk       (ram_rds_2[0]     ), 
		.io          (ram_rwds_2       )  
	);
	
	//DQ
	EFX_GPIO_model #(
		.BUS_WIDTH   (RAM_DBW   ), 
		.TYPE        ("INOUT"    ), 
		.OUT_REG     (1          ), 
		.OUT_DDIO    (1          ), 
		.OUT_RESYNC  (0          ), 
		.OUTCLK_INV  (1          ), 
		.OE_REG      (1          ), 
		.IN_REG      (1          ), 
		.IN_DDIO     (1          ), 
		.IN_RESYNC   (1           ), 
		.INCLK_INV   (0          )  
	) dq_inst_2 (
		.out_HI      (hbc_dq_OUT_HI_2 ), 
		.out_LO      (hbc_dq_OUT_LO_2 ), 
		.outclk      (clk           ), 
		.oe          (hbc_dq_OE_2[0]  ), 
		.in_HI       (hbc_dq_IN_HI_2  ), 
		.in_LO       (hbc_dq_IN_LO_2  ), 
		.inclk       (ram_rds_2[0]    ), 
		.io          (ram_dq_2        )  
	);
	end
else
	begin
	//RWDS
	EFX_GPIO_model #(
		.BUS_WIDTH   (RAM_DBW/8  ), 
		.TYPE        ("INOUT"     ), 
		.OUT_REG     (1           ), 
		.OUT_DDIO    (1           ), 
		.OUT_RESYNC  (1),//(0           ), 
		.OUTCLK_INV  (0           ), 
		.OE_REG      (1           ), 
		.IN_REG      (1           ), 
		.IN_DDIO     (1           ), 
		.IN_RESYNC   (1           ), 
		.INCLK_INV   (0           )  
	) rwds_inst_2 (
		.out_HI      (hbc_rwds_OUT_HI_2), 
		.out_LO      (hbc_rwds_OUT_LO_2), 
		.outclk      (clk            ), 
		.oe          (hbc_rwds_OE_2[0] ), 
		.in_HI       (hbc_rwds_IN_HI_2 ), 
		.in_LO       (hbc_rwds_IN_LO_2 ), 
		.inclk       (ram_rds[0]     ), 
		.io          (ram_rwds_2       )  
	);
	
	//DQ
	EFX_GPIO_model #(
		.BUS_WIDTH   (RAM_DBW   ), 
		.TYPE        ("INOUT"    ), 
		.OUT_REG     (1          ), 
		.OUT_DDIO    (1          ), 
		.OUT_RESYNC  (1),//(0          ), 
		.OUTCLK_INV  (1          ), 
		.OE_REG      (1          ), 
		.IN_REG      (1          ), 
		.IN_DDIO     (1          ), 
		.IN_RESYNC   (1          ), 
		.INCLK_INV   (0          )  
	) dq_inst_2 (
		.out_HI      (hbc_dq_OUT_HI_2 ), 
		.out_LO      (hbc_dq_OUT_LO_2 ), 
		.outclk      (clk           ), 
		.oe          (hbc_dq_OE_2[0]  ), 
		.in_HI       (hbc_dq_IN_HI_2  ), 
		.in_LO       (hbc_dq_IN_LO_2  ), 
		.inclk       (ram_rds[0]    ), 
		.io          (ram_dq_2        )  
	);
	end
end
endgenerate
//Hyperbus RAM_2
generate
	if(DUAL_RAM == 1)begin
		pullup p0 (ram_cs_n_2   );
		pullup p1 (ram_rst_n_2  );
		if (RAM_DBW == 8) begin
		W958D8NW Winbond_ram_x8_inst2(
		.adq	(ram_dq_2	), 		
		.clk	(ram_ck_p_2	),		
		.clk_n	(ram_ck_n_2	),//(1'b0		),      
		.csb	(ram_cs_n_2	),		
		.rwds	(ram_rwds_2	),        
		.VCC	(1'b1		),
		.VSS	(1'b0		),
		.resetb	(ram_rst_n_2	)
    		 );
		 end
		 else begin
		 W958D6NKY ram_x16_inst_2(
		.adq	(ram_dq_2	), 		
		.clk	(ram_ck_p_2	),		
		.clk_n	(ram_ck_n_2	),      
		.csb	(ram_cs_n_2	),		
		.rwds	(ram_rwds_2	),        
		.VCC	(1'b1		),
		.VSS	(1'b0		),
		.resetb	(ram_rst_n_2	),
		.die_stack	(1'b0		),
		.optddp	(1'b0		)
		);
		end
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
