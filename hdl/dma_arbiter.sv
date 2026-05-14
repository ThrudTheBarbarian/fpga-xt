// dma_arbiter.sv — fold two mem_read_mux DMA-side ports onto the
// single dma_master.
//
// dl_parser and compositor each have their own mem_read_mux instance
// (so the snoop-mode read path stays parallel via cpu_shadow's
// dual-port BRAM), but share one dma_master because the FPGA only
// has one set of A/D pins to drive. The arbiter resolves contention
// with simple priority — port 0 (dl_parser) wins over port 1
// (compositor) on simultaneous req. dl_parser finishes its DL walk
// before compositor's row walk normally starts, so contention is
// rare in practice.
//
// Once a port wins, the arbiter holds the grant until that port's
// dma_data_valid lands; the other port's mem_read_mux just keeps
// stalling in BUSY until its grant comes around.

`default_nettype none

module dma_arbiter (
    input  wire        clk,
    input  wire        rst,

    // Port 0 (dl_parser).
    input  wire        p0_req,
    input  wire [15:0] p0_addr,
    output wire        p0_ack,
    output wire        p0_data_valid,
    output wire  [7:0] p0_rdata,

    // Port 1 (compositor).
    input  wire        p1_req,
    input  wire [15:0] p1_addr,
    output wire        p1_ack,
    output wire        p1_data_valid,
    output wire  [7:0] p1_rdata,

    // Combined dma_master interface.
    output logic       dma_req,
    output logic [15:0] dma_addr,
    input  wire        dma_ack,
    input  wire        dma_data_valid,
    input  wire  [7:0] dma_rdata,
    input  wire        dma_busy
);

    // Active grantee selected by FSM. While IDLE we route either
    // port's req → dma_master (priority: p0). Once we accept, we
    // remember which port to route the response back to.
    typedef enum logic {A_IDLE = 1'b0, A_BUSY = 1'b1} arb_state_t;
    arb_state_t arb_state;
    logic       grant;          // 0 = port 0, 1 = port 1

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            arb_state <= A_IDLE;
            grant     <= 1'b0;
        end else begin
            case (arb_state)
                A_IDLE: begin
                    if (p0_req) begin
                        grant     <= 1'b0;
                        arb_state <= A_BUSY;
                    end else if (p1_req) begin
                        grant     <= 1'b1;
                        arb_state <= A_BUSY;
                    end
                end
                A_BUSY: begin
                    if (dma_data_valid) arb_state <= A_IDLE;
                end
                default: arb_state <= A_IDLE;
            endcase
        end
    end

    // Drive dma_master from whichever port wins. While IDLE we route
    // the would-be winner's req combinationally; once BUSY we hold
    // the address (dma_master latches it on its own ack).
    always_comb begin
        if (arb_state == A_IDLE && p0_req) begin
            dma_req  = 1'b1;
            dma_addr = p0_addr;
        end else if (arb_state == A_IDLE && p1_req) begin
            dma_req  = 1'b1;
            dma_addr = p1_addr;
        end else begin
            dma_req  = 1'b0;
            dma_addr = 16'h0;
        end
    end

    // ack to the granted port; data_valid + rdata likewise routed.
    assign p0_ack         = (arb_state == A_IDLE) && p0_req && dma_ack;
    assign p1_ack         = (arb_state == A_IDLE) && !p0_req && p1_req && dma_ack;
    assign p0_data_valid  = (arb_state == A_BUSY) && (grant == 1'b0) && dma_data_valid;
    assign p1_data_valid  = (arb_state == A_BUSY) && (grant == 1'b1) && dma_data_valid;
    assign p0_rdata       = dma_rdata;
    assign p1_rdata       = dma_rdata;

endmodule

`default_nettype wire
