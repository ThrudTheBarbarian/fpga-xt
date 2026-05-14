module efx_clk_monitor # (
    parameter REFCLK_FREQ = 100
) (
    input  wire        refclk,
    input  wire        inclk,
    input  wire        rst_n,
    output wire [28:0] out_mhz
);

reg        clear;
reg [28:0] refclk_cnt;
reg [28:0] inclk_cnt;
reg [28:0] out_freq;

localparam TARGET = REFCLK_FREQ * 1000000;

assign out_mhz = out_freq;

always @ (posedge refclk or negedge rst_n) begin
    if (~rst_n) begin
        refclk_cnt <= 'd0;
    end
    else if (clear) begin
        refclk_cnt <= 'd0;
    end
    else begin
        refclk_cnt <= refclk_cnt + 1'd1;
    end
end

always @ (posedge inclk or negedge rst_n) begin
    if (~rst_n) begin
        inclk_cnt <= 'd0;
    end
    else if (clear) begin
        inclk_cnt <= 'd0;
    end
    else begin
        inclk_cnt <= inclk_cnt + 1'd1;
    end
end

always @ (posedge refclk or negedge rst_n) begin
    if (~rst_n) begin
        clear    <= 1'b0;
        out_freq <= 'd0;
    end
    else if (refclk_cnt == TARGET) begin
        clear    <= 1'b1;
        out_freq <= inclk_cnt;
    end
    else begin
        clear    <= 1'b0;
        out_freq <= out_freq;
    end
end
endmodule
