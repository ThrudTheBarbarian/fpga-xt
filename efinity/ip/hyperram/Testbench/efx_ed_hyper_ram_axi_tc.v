module efx_ed_hyper_ram_axi_tc # (
    parameter AXI_DBW     = 128,
    parameter AXI_SBW     = AXI_DBW/8,
    parameter NUM_OF_WORD = AXI_DBW/32,
    parameter AWR_SIZE    = 4,
    parameter AWR_LEN     = 127,
    parameter ADDR_BURST  = (AXI_DBW * (AWR_LEN+1))/8,
    parameter START_ADDR  = 0,
    parameter STOP_ADDR   = 33550336/*33554428 - ADDR_BURST*/
)(

input axi_clk,
input rstn,
input start,

output wire [7:0] aid,
output wire [31:0] aaddr,
output wire [7:0] alen,
output wire [2:0] asize,
output wire [1:0] aburst,
output wire [1:0] alock,
output wire avalid,
input  wire aready,
output wire atype,

output wire [7:0] wid,
output wire [AXI_DBW-1:0] wdata,
output wire [AXI_SBW-1:0] wstrb,
output wire wlast,
output wire wvalid,
input  wire wready,

input  wire [7:0]rid,
input  wire [AXI_DBW-1:0] rdata,
input  wire rlast,
input  wire rvalid,
output wire rready,
input  wire [1:0] rresp,

input  wire [7:0] bid,
input  wire bvalid,
output wire bready,

output wire one_round,
output reg  test_fail,
output reg  test_good
);

localparam IDLE           = 0, 
           WRITE          = 1,
           WAIT_BVALID    = 2,
           UPDATE_WR_ADDR = 3,
           CHECK_WR_ADDR  = 4,
           PRE_READ       = 5,
           READ           = 6,
           READ_STREAM    = 7,
           UPDATE_RD_ADDR = 8,
           CYCLE_END      = 9,
           COOLING_PERIOD = 10,
           FAIL_STUCK     = 11;
   
localparam TOTAL_BURST    = $ceil(STOP_ADDR / ((AXI_DBW * (AWR_LEN + 1))/8));

reg [3:0]   state;
reg [3:0]   next_state;
reg [31:0]  data_reg;
reg         mid_clear;
reg         op_idle;
reg         wr_req;
reg         rd_op;
reg         rd_req;
reg         rd_compare;
reg         updata_addr;
reg         cycle_done;
//reg         loop_en;
reg         burst_hit_r;

reg [19:0]  burst_cnt;
reg [31:0]  addr_counter;
reg [9:0]   wlast_counter;

`ifdef SIM 
reg [3:0]   toggle_cnt;
`else
reg [25:0]  toggle_cnt;
`endif

wire        addr_hit;
wire        loop_hit;
wire        burst_hit;
wire        axi_slave_wr_idle;
//wire        rd_mismatch;
reg rd_mismatch;
wire        burst_hit_pulse;
wire        crc_clear;
wire        crc_en;
wire [31:0] crc_data;
reg			rready_r;	

always @(posedge axi_clk or negedge rstn) begin
	if (!rstn) begin
		rready_r <= 'b0;
	end
	else if (rvalid && rready_r) begin
		rready_r <= 'b0;
	end
	else begin
		rready_r <= ~rready_r;
	end
end

assign rready = rready_r;//1'b1;
assign aaddr  = addr_counter;
assign asize  = AWR_SIZE;
assign alen   = AWR_LEN;
assign avalid = wr_req | rd_req;
assign atype  = rd_req ? 1'b0 : 1'b1;
assign aburst = 2'h1;
assign alock  = 2'h0;
assign aid = 8'b0;

assign bready = 1'b0;

assign wid    = 8'd0;

assign one_round = cycle_done;

always @(posedge axi_clk or negedge rstn) begin
    if (!rstn) begin
        state <= IDLE;
    end 
    else begin
        state <= next_state;
    end
end

always @ (*) begin
    case(state) 
    IDLE            : begin if (start)     next_state = WRITE;          else next_state = IDLE;           end
    WRITE           : begin if (aready)    next_state = UPDATE_WR_ADDR; else next_state = WRITE;          end
    UPDATE_WR_ADDR  : begin if (addr_hit)  next_state = PRE_READ;       else next_state = WRITE;          end
    PRE_READ        : begin                                                 next_state = READ;           end
    READ            : begin if (aready)    next_state = READ_STREAM;    else next_state = READ;           end
    READ_STREAM     : begin if (rlast)     next_state = UPDATE_RD_ADDR; else next_state = READ_STREAM;    end
    UPDATE_RD_ADDR  : begin if (addr_hit)  next_state = CYCLE_END;      else next_state = READ;           end
    CYCLE_END       : begin if (test_fail) next_state = FAIL_STUCK;     else next_state = IDLE; end
    //COOLING_PERIOD  : begin if (loop_hit) next_state = IDLE;           else next_state = COOLING_PERIOD; end
    FAIL_STUCK      : begin                                                 next_state = FAIL_STUCK;     end
    default         : begin                                                 next_state = IDLE;           end
    endcase
end

always @(*) begin
    op_idle      = 1'b0;
    wr_req       = 1'b0;
    updata_addr  = 1'b0;
    rd_op        = 1'b0;
    rd_req       = 1'b0;
    rd_compare   = 1'b0;
    mid_clear    = 1'b0;
    cycle_done   = 1'b0;
    //loop_en      = 1'b0;
    case(state) 
    IDLE            : begin op_idle     = 1'b1; end
    WRITE           : begin wr_req      = 1'b1; end
    WAIT_BVALID     : begin                     end
    UPDATE_WR_ADDR  : begin updata_addr = 1'b1; end
    PRE_READ        : begin mid_clear   = 1'b1; end
    READ            : begin rd_req      = 1'b1; rd_op = 1'b1; end
    READ_STREAM     : begin rd_compare  = 1'b1; rd_op = 1'b1; end
    UPDATE_RD_ADDR  : begin updata_addr = 1'b1; end
    CYCLE_END       : begin cycle_done  = 1'b1; end
    //COOLING_PERIOD  : begin loop_en     = 1'b1; end
    endcase
end

assign addr_hit = (rd_compare | rd_req) ? (addr_counter >= STOP_ADDR) : (addr_counter >= STOP_ADDR-((AXI_DBW * (AWR_LEN + 1))/8));

always @ (posedge axi_clk or negedge rstn) begin
    if (!rstn) begin
        addr_counter <= START_ADDR;
    end
    else if (mid_clear || cycle_done) begin
        addr_counter <= START_ADDR;
    end
    else if (updata_addr) begin
        addr_counter <= addr_counter + ((AXI_DBW * (AWR_LEN + 1))/8);  
    end
end 

assign axi_slave_wr_idle = ~op_idle & wready;
assign wvalid            = axi_slave_wr_idle && ~burst_hit;
assign burst_hit         = (burst_cnt == TOTAL_BURST);
assign burst_hit_pulse   = burst_hit & ~burst_hit_r;

always @ (posedge axi_clk or negedge rstn) begin
    if (!rstn) begin
        burst_hit_r <= 1'b0; 
    end
    else begin
        burst_hit_r <= burst_hit;   
    end      
end 

always @ (posedge axi_clk or negedge rstn) begin
    if (!rstn) begin
        burst_cnt <= 1'b0; 
    end
    else if (cycle_done) begin
        burst_cnt <= 1'b0; 
    end
    else if (wlast) begin
        burst_cnt <= burst_cnt + 1'd1;   
    end      
end    

generate 
    if (AWR_SIZE == 5) begin
        assign wdata = {crc_data,~crc_data,32'h0,data_reg,data_reg,32'h0,~crc_data,crc_data};
        assign wstrb = {256{1'b1}};
        assign wlast = (wlast_counter == AWR_LEN) && wvalid;
    end
    else if (AWR_SIZE == 4) begin 
        assign wdata = {data_reg,32'h0,~crc_data,crc_data};
        assign wstrb = {128{1'b1}};
        assign wlast = (wlast_counter == AWR_LEN) && wvalid;
    end
    else if (AWR_SIZE == 3) begin
        assign wdata = {data_reg,crc_data};
        assign wstrb = {64{1'b1}};
        assign wlast = (wlast_counter == AWR_LEN) && wvalid;
    end
    else if (AWR_SIZE == 2) begin
        assign wdata = {crc_data};
        assign wstrb = {32{1'b1}};
        assign wlast = (wlast_counter == AWR_LEN) && wvalid;
    end

    always @(posedge axi_clk or negedge rstn) begin
        if (!rstn) begin
            wlast_counter <= 'd0;
        end 
        else if (wvalid && wlast_counter == AWR_LEN) begin
            wlast_counter <= 'd0;      
        end
        else if (wvalid && wlast_counter <= AWR_LEN) begin
            wlast_counter <= wlast_counter + 1'd1;      
        end
    end
endgenerate

always @ (posedge axi_clk or negedge rstn) begin
    if (!rstn) begin
        data_reg <= 32'h0;
    end
    else if (burst_hit_pulse || cycle_done) begin
        data_reg <= 32'h0;
    end
    else if ((axi_slave_wr_idle && wvalid) || (rvalid && rready)) begin
        data_reg <= data_reg + 'd1;
    end
end

assign crc_en      = (axi_slave_wr_idle & wvalid) | (rvalid && rready_r);
assign crc_clear   = burst_hit_pulse | cycle_done;

efx_crc32 crc32_inst(
    .clk     (axi_clk),
    .reset_n (rstn),
    .clear   (crc_clear),
    .crc_en  (crc_en),
    .data_in (data_reg),
    .crc_out (crc_data)
);

//assign rd_mismatch = rd_compare && rvalid ? (rdata != wdata) : 1'b0;
always @ (posedge axi_clk or negedge rstn) begin
    if (!rstn) begin
        rd_mismatch <= 1'b0;
    end
    else if (rd_compare && rvalid && rready_r) begin
        if (rdata != wdata) begin
    		rd_mismatch <= 1'b1;
    	end
    	else begin
    		rd_mismatch <= 1'b0;
    	end
    end
    else begin
    	rd_mismatch <= 1'b0;
    end
end


/*
assign loop_hit    = &loop_counter;

always @ (posedge axi_clk or negedge rstn) begin
    if (!rstn) begin
        fail <= 1'b0;
    end
    else if (rd_mismatch) begin
        fail <= 1'b1;
    end
end

always @ (posedge axi_clk or negedge rstn) begin
    if (!rstn) begin
        loop_counter <= 'd0;
    end
    else if (mid_clear) begin
        loop_counter <= 'd0;
    end
    else if (loop_en) begin
        loop_counter <= loop_counter + 1'd1;
    end
end

always @ (posedge axi_clk or negedge rstn) begin
    if (!rstn) begin
        done <= 'b0;
    end
    else if (loop_hit && ~fail) begin
        done <= ~done;
    end
end
*/

always @ (posedge axi_clk or negedge rstn) begin
    if (!rstn) begin
        test_fail <= 1'b0;
    end
    else if (rd_mismatch) begin
        test_fail <= 1'b1;
    end
end

always @ (posedge axi_clk or negedge rstn) begin
    if (~rstn) begin
        toggle_cnt <= 'd0;
    end
    else begin
        toggle_cnt <= toggle_cnt + 1'd1;
    end
end

always @ (posedge axi_clk or negedge rstn) begin
    if (!rstn) begin
        test_good <= 1'b0;
    end
    else if (test_fail) begin
        test_good <= 1'b0;
    end
    else if (&toggle_cnt) begin
        test_good <= ~test_good;
    end
end

endmodule
