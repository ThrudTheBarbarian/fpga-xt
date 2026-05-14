module efx_ed_hyper_ram_native_tc # (
    parameter USER_DBW = 128,
    parameter RAM_DBW  = 32
)(
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire                    cal_done,
    input  wire                    ctrl_idle,
    input  wire                    wr_buf_ready,
    input  wire [USER_DBW-1:0]     rd_data,
    input  wire                    rd_valid,
    output wire [USER_DBW-1:0]     wr_data,
    output reg  [(USER_DBW/8)-1:0] wr_datamask,
    output reg  [31:0]             wr_address,
    output wire [10:0]             burst_len,
    output wire                    ram_rdwr,
    output wire                    wr_en,
    output wire                    ram_en,
    output wire                    one_round,
    output reg                     test_good,
    output reg                     test_fail
);

reg                 wr_mode;
reg                 wr_ram_en;
reg                 rd_ram_en;
reg                 test_done;
reg                 next_traffic;
reg                 rd_latch;
reg [3:0]           state;
reg [3:0]           next_state;
reg [10:0]          w_burst_cnt;
reg [31:0]          receive_cnt;
reg [23:0]          rd_cnt;
reg [31:0]          wr_data_gen;
`ifdef SIM
reg [4:0]           traffic_cnt;
reg [4:0]           toggle_cnt;
`else
reg [12:0]          traffic_cnt;
reg [25:0]          toggle_cnt;
`endif

wire                burst_len_hit;
wire                rd_cnt_hit;
wire                traffic_cnt_hit;
wire                rd_mismatch;
wire [31:0]         crc_data;
wire [31:0]         rd_crc_data;

parameter IDLE              = 0,
          DATA_LOAD         = 1,
          PRE_WRITE         = 2,
          TRIGGER_WRITE     = 3,
          POST_WRITE        = 4,
          WAIT_WR_CTRL_IDLE = 5,
          TRIGGER_READ      = 6,
          POST_READ         = 7,
          WAIT_RD_CTRL_IDLE = 8,
          NEXT_BURST        = 9,
          DONE              = 10;

localparam USER2RAM_DRATIO = USER_DBW/(RAM_DBW*2);

assign burst_len     = /*11'd1*//*11'd768*/11'd128;
assign ram_rdwr      = wr_mode ? 1'b0 : 1'b1;
assign wr_en         = cal_done & wr_buf_ready & ~burst_len_hit;
assign burst_len_hit = w_burst_cnt >= (burst_len/USER2RAM_DRATIO);
assign ram_en        = wr_ram_en | rd_ram_en;
assign rd_cnt_hit    = rd_cnt >= (burst_len/USER2RAM_DRATIO);
assign one_round     = test_done;

generate
    if (USER_DBW == 256) begin
        assign wr_data     = {crc_data,~crc_data,~wr_data_gen,wr_data_gen,wr_data_gen,~wr_data_gen,~crc_data,crc_data};
        assign rd_mismatch = rd_valid ? rd_data != {rd_crc_data,~rd_crc_data,~receive_cnt,receive_cnt,receive_cnt,32'h0,~rd_crc_data,rd_crc_data}: 1'b0;
    end
    else if (USER_DBW == 128) begin
        assign wr_data = {wr_data_gen,~wr_data_gen,~crc_data,crc_data};
        assign rd_mismatch = rd_valid ? rd_data != {receive_cnt,~receive_cnt,~rd_crc_data,rd_crc_data}: 1'b0;
    end
    else if (USER_DBW ==64) begin
        assign wr_data = {wr_data_gen,crc_data};
        assign rd_mismatch = rd_valid ? rd_data != {receive_cnt,rd_crc_data}: 1'b0;
    end
    else if (USER_DBW == 32) begin
        assign wr_data = {crc_data};
        assign rd_mismatch = rd_valid ? rd_data != {rd_crc_data}: 1'b0;
    end
endgenerate


always @ (posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        state <= IDLE;
    end
    else begin
        state <= next_state;
    end
end

always @ (*) begin
     case (state)
     IDLE              : begin if (cal_done)        next_state <= DATA_LOAD;         else next_state <= IDLE;              end
     DATA_LOAD         : begin if (burst_len_hit)           next_state <= PRE_WRITE;         else next_state <= DATA_LOAD;         end
     PRE_WRITE         : begin                              next_state <= TRIGGER_WRITE;                                           end
     TRIGGER_WRITE     : begin                              next_state <= POST_WRITE;                                              end
     POST_WRITE        : begin if (~ctrl_idle)              next_state <= WAIT_WR_CTRL_IDLE; else next_state <= POST_WRITE;        end
     WAIT_WR_CTRL_IDLE : begin if (ctrl_idle)               next_state <= TRIGGER_READ;      else next_state <= WAIT_WR_CTRL_IDLE; end
     TRIGGER_READ      : begin                              next_state <= POST_READ;                                               end
     POST_READ         : begin if (~ctrl_idle)              next_state <= WAIT_RD_CTRL_IDLE; else next_state <= POST_READ;         end
     WAIT_RD_CTRL_IDLE : begin if (ctrl_idle && rd_cnt_hit) next_state <= NEXT_BURST;        else next_state <= WAIT_RD_CTRL_IDLE; end 
     NEXT_BURST        : begin if (&traffic_cnt)            next_state <= DONE;              else next_state <= DATA_LOAD;         end
     DONE              : begin                              next_state <= IDLE;                                                    end
     endcase
end

always @ (*) begin
    wr_mode        = 1'b0;
    wr_ram_en      = 1'b0;
    rd_ram_en      = 1'b0;
    next_traffic   = 1'b0;
    test_done      = 1'b0;
    case (state)
    PRE_WRITE     : begin wr_mode        = 1'b1;                      end
    TRIGGER_WRITE : begin wr_mode        = 1'b1; wr_ram_en    = 1'b1; end
    TRIGGER_READ  : begin wr_mode        = 1'b0; rd_ram_en    = 1'b1; end
    NEXT_BURST    : begin next_traffic   = 1'b1;                      end
    DONE          : begin test_done      = 1'b1;                      end
    endcase
end

always @ (posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        traffic_cnt <= 'd0;
    end
    else if (test_done) begin
        traffic_cnt <= 'd0;
    end
    else if (next_traffic) begin
        traffic_cnt <= traffic_cnt + 1'd1;
    end
end

efx_crc32 tx_datagen_crc32 (
    .clk     (clk),
    .reset_n (rst_n),
    .clear   (test_done),
    .crc_en  (wr_en),
    .data_in (wr_data_gen),
    .crc_out (crc_data)
);

always @ (posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        wr_data_gen <= 'd0;
    end
    else if (test_done) begin
        wr_data_gen <= 'd0;
    end
    else if (cal_done && wr_buf_ready && ~burst_len_hit) begin
        wr_data_gen <= wr_data_gen + 1'd1;
    end
end

always @ (posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        w_burst_cnt <= 'd0;
    end
    else if (test_done || (wr_ram_en && !(&traffic_cnt))) begin
        w_burst_cnt <= 'd0;
    end
    else if (cal_done && wr_buf_ready && ~burst_len_hit) begin
        w_burst_cnt <= w_burst_cnt + 1'd1;
    end
end

always @ (posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        wr_address   <= {2'b10,30'd0};
        wr_datamask  <= 'hffff;
    end
    else if (test_done) begin
        wr_address   <= {2'b10,30'd0};
        wr_datamask  <= 'hffff;
    end
    else if (cal_done && next_traffic) begin
        wr_address   <= wr_address + burst_len;
        wr_datamask  <= wr_datamask;
    end
end

always @ (posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        receive_cnt <= 'd0;
    end
    else if (test_done) begin
        receive_cnt <= 'd0;
    end
    else if (cal_done && rd_valid) begin
        receive_cnt <= receive_cnt + 1'b1;
    end
end

always @ (posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        rd_cnt <= 'd0;
    end
    else if (next_traffic) begin
        rd_cnt <= 'd0;
    end
    else if (cal_done && rd_valid) begin
        rd_cnt <= rd_cnt + 1'b1;
    end
end

efx_crc32 rx_dataver_crc32 (
    .clk     (clk),
    .reset_n (rst_n),
    .clear   (test_done),
    .crc_en  (rd_valid),
    .data_in (receive_cnt),
    .crc_out (rd_crc_data)
);

always @ (posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        rd_latch <= 1'b0;
    end
    else if (rd_valid || test_done) begin
        rd_latch <= 1'b1;
    end
end

always @ (posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        test_fail <= 1'b0;
    end
    else if (rd_mismatch || (~rd_latch && test_done)) begin
        test_fail <= 1'b1;
    end
end

always @ (posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        toggle_cnt <= 'd0;
    end
    else begin
        toggle_cnt <= toggle_cnt + 1'd1;
    end
end

always @ (posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        test_good <= 1'b0;
    end
    else if (test_fail || !rd_latch) begin
        test_good <= 1'b0;
    end
    else if (&toggle_cnt) begin
        test_good <= ~test_good;
    end
end
endmodule
