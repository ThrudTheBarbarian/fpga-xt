// bram_shim.sv — lightweight dual-port BRAM reader for in-fabric ANTIC
// DMA reads.
//
// Provides two read ports (dl_parser + compositor) into a single backing
// BRAM (sally_mem's second port).  Each port has request/ready handshake
// with 1-cycle registered read latency.
//
// The shim arbitrates between two requestors on a priority basis:
//   Port A (dl_parser) has higher priority — display list parsing is
//   on the critical path for frame start.
//   Port B (compositor) runs during the compose phase and can tolerate
//   one cycle of arbitration delay.

`default_nettype none

module bram_shim #(
    parameter int ADDR_W = 16
) (
    input  wire         clk,
    input  wire         rst,

    // Backing BRAM (sally_mem's second port)
    output wire [ADDR_W-1:0] bram_addr,
    input  wire [7:0]        bram_rdata,

    // Port A — dl_parser (higher priority)
    input  wire              req_a,
    input  wire [ADDR_W-1:0] raddr_a,
    output wire [7:0]        rdata_a,
    output wire              ready_a,

    // Port B — compositor (lower priority)
    input  wire              req_b,
    input  wire [ADDR_W-1:0] raddr_b,
    output wire [7:0]        rdata_b,
    output wire              ready_b
);

    // State machine: IDLE / SERVE_A / SERVE_B / LATENCY
    typedef enum logic [1:0] {
        IDLE    = 2'b00,
        SERVE_A = 2'b01,
        SERVE_B = 2'b10,
        LATENCY = 2'b11     // wait state for BRAM read latency
    } state_t;

    state_t state_q;
    logic [ADDR_W-1:0] result_addr_q;
    logic              result_port_q;    // 0 = A, 1 = B
    logic [7:0]        rdata_a_q;        // per-port result holds: each client's
    logic [7:0]        rdata_b_q;        // byte survives the OTHER port's traffic

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state_q        <= IDLE;
            result_addr_q  <= '0;
            result_port_q  <= 1'b0;
            rdata_a_q      <= 8'h00;
            rdata_b_q      <= 8'h00;
        end else begin
            unique case (state_q)

                IDLE: begin
                    if (req_a) begin
                        // Port A wins arbitration.
                        state_q       <= LATENCY;
                        result_addr_q <= raddr_a;
                        result_port_q <= 1'b0;     // A
                    end else if (req_b) begin
                        state_q       <= LATENCY;
                        result_addr_q <= raddr_b;
                        result_port_q <= 1'b1;     // B
                    end
                end

                LATENCY: begin
                    // One cycle for BRAM read.  bram_rdata is valid this cycle
                    // (registered on posedge in sally_mem's always_ff).  Latch
                    // into the PER-PORT hold register and return to IDLE.
                    if (!result_port_q) rdata_a_q <= bram_rdata;
                    else                rdata_b_q <= bram_rdata;
                    state_q <= IDLE;
                end

                default: state_q <= IDLE;
            endcase
        end
    end

    // Drive BRAM address combinationaly — the address is valid the same
    // cycle we enter LATENCY, and stays valid until the BRAM clock edge.
    assign bram_addr = (state_q == IDLE)
                     ? (req_a ? raddr_a : raddr_b)
                     : result_addr_q;

    // Output data: the FRESH byte (bram_rdata) is presented during the
    // serving port's ready cycle, and the per-port hold register carries it
    // afterwards until that port's NEXT completion.  Consumers that sample
    // on ready and consumers that sample one cycle later therefore both get
    // the right byte, and one port's traffic can never leak into the other
    // (board-measured: interleaved compositor bytes reached dl_parser's
    // one-cycle-late opcode consumption via the old shared register — the
    // DLI-cluster garbage-row parse corruption).
    assign rdata_a = (state_q == LATENCY && !result_port_q) ? bram_rdata : rdata_a_q;
    assign rdata_b = (state_q == LATENCY &&  result_port_q) ? bram_rdata : rdata_b_q;

    // ready_a fires on the cycle we exit LATENCY with result_port_q=0
    // (the result is valid).  ready_b similarly.
    // We also fire ready on the same cycle if req_a was the only requestor
    // in IDLE (no arbitration wait).
    logic ready_a_w, ready_b_w;

    always_comb begin
        ready_a_w = 1'b0;
        ready_b_w = 1'b0;
        if (state_q == IDLE) begin
            // When entering LATENCY from IDLE, the requestor gets ready
            // on the NEXT cycle (the one where state_q transitions to IDLE).
            // We assert ready on the LATENCY→IDLE transition.
        end
        if (state_q == LATENCY) begin
            // Next cycle will be IDLE; result_port_q holds which port
            // was served.
            if (!result_port_q) ready_a_w = 1'b1;
            else                ready_b_w = 1'b1;
        end
    end

    assign ready_a = ready_a_w;
    assign ready_b = ready_b_w;

endmodule

`default_nettype wire
