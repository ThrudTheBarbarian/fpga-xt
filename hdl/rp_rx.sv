// rp_rx.sv — FPGA-side receiver for RP->FPGA bus.
//
// Accepts 16-bit beats (one per clk when bus_valid is high) and
// queues them in a small FIFO. The host pops responses on rsp_pop;
// rsp_valid indicates a response is available.
//
// In production the bus is source-synchronous on rp_rx_clk (RP-driven)
// and a 2-flop synchroniser lands beats in this module's clock
// domain. For M3 sim we run everything on a single clock.

`default_nettype none

module rp_rx #(
    parameter int FIFO_DEPTH = 16
) (
    input  wire        clk,
    input  wire        rst,

    // Bus input (RP-driven).
    input  wire [15:0] bus_payload,
    input  wire        bus_valid,

    // Host-side response pop interface.
    output wire [15:0] rsp_data,
    output wire        rsp_valid,
    input  wire        rsp_pop,

    // Trap counter: bus_valid asserted when FIFO is full → dropped beat.
    output logic [31:0] rx_drop_count
);

    localparam int PTR_W = $clog2(FIFO_DEPTH);

    logic [15:0]       fifo [0:FIFO_DEPTH-1];
    logic [PTR_W-1:0]  wptr, rptr;
    logic [PTR_W:0]    fill;        // 0..FIFO_DEPTH

    wire fifo_empty = (fill == 0);
    wire fifo_full  = (fill == FIFO_DEPTH[PTR_W:0]);

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            wptr          <= '0;
            rptr          <= '0;
            fill          <= '0;
            rx_drop_count <= 32'h0;
        end else begin
            // Push.
            if (bus_valid) begin
                if (fifo_full) begin
                    rx_drop_count <= rx_drop_count + 32'd1;
                end else begin
                    fifo[wptr] <= bus_payload;
                    wptr       <= wptr + 1'b1;
                end
            end
            // Pop.
            if (rsp_pop && !fifo_empty) begin
                rptr <= rptr + 1'b1;
            end
            // Fill update — handle simultaneous push+pop.
            case ({bus_valid && !fifo_full, rsp_pop && !fifo_empty})
                2'b10: fill <= fill + 1'b1;
                2'b01: fill <= fill - 1'b1;
                default: ;
            endcase
        end
    end

    assign rsp_data  = fifo[rptr];
    assign rsp_valid = !fifo_empty;

endmodule

`default_nettype wire
