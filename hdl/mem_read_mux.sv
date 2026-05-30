// mem_read_mux.sv — read-side adapter that lets dl_parser /
// compositor talk to either the system-RAM shadow (BRAM via bram_shim)
// or dma_master (multi-cycle 6502-bus master) without caring which is
// providing the data.
//
// Controlled by `dma_mode`:
//   0 — snoop mode. caller_req is forwarded to sh_req (a 1-cycle
//       pulse on the shadow side). caller_rdata = sh_rdata;
//       caller_ready follows sh_ready (and is gated low while
//       caller_req is asserting a new request, mirroring the DMA
//       path). This matches the multi-cycle handshake exposed by
//       bram_shim's read ports.
//   1 — DMA mode. On caller_req, the adapter latches caller_raddr,
//       fires a single DMA fetch via dma_master, and drops
//       caller_ready=0 until dma_data_valid lands. The captured
//       byte is held on caller_rdata for as long as needed; on the
//       next caller_req it's overwritten by a fresh fetch.
//
// `caller_req` is an explicit "start a read" pulse from the
// consumer (rather than address-change detection) so back-to-back
// reads at the same address still trigger a fresh fetch.
//
// The shadow side uses a req/ready handshake (sh_ready / sh_req) to
// carry multi-cycle read latency. Tests that wire a plain BRAM into
// this adapter pin sh_ready=1.

`default_nettype none

module mem_read_mux #(
    parameter int ADDR_W = 16
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        dma_mode,

    // Caller (dl_parser / compositor) side.
    input  wire [ADDR_W-1:0] caller_raddr,
    input  wire              caller_req,    // 1-cycle pulse: start a read
    output wire [7:0]        caller_rdata,
    output wire              caller_ready,

    // Shadow (system-RAM) side. With bram_shim this is its
    // req/ready/rdata read-port handshake. With a plain BRAM (in tests),
    // sh_ready is tied 1.
    output wire [ADDR_W-1:0] sh_raddr,
    output wire              sh_req,
    input  wire  [7:0]       sh_rdata,
    input  wire              sh_ready,

    // dma_master side.
    output logic             dma_req,
    output logic [15:0]      dma_addr,
    input  wire              dma_ack,
    input  wire              dma_data_valid,
    input  wire  [7:0]       dma_rdata,
    input  wire              dma_busy
);

    // ---- Snoop path (handshake forward) --------------------------------
    assign sh_raddr        = caller_raddr;
    assign sh_req          = caller_req && !dma_mode;
    wire [7:0] snoop_rdata = sh_rdata;

    // ---- DMA path FSM --------------------------------------------------
    // Two states:
    //   D_READY — last fetch's rdata is held; ready=1.
    //   D_BUSY  — fetch in flight; ready=0.
    typedef enum logic { D_READY = 1'b0, D_BUSY = 1'b1 } dma_state_t;

    dma_state_t   dma_state;
    logic [7:0]   dma_rdata_q;     // captured from dma_master

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            dma_state   <= D_READY;
            dma_rdata_q <= 8'h00;
            dma_req     <= 1'b0;
            dma_addr    <= 16'h0;
        end else begin
            dma_req <= 1'b0;       // single-cycle pulse by default

            unique case (dma_state)
                D_READY: begin
                    if (caller_req && dma_mode) begin
                        dma_addr  <= 16'(caller_raddr);
                        dma_req   <= 1'b1;
                        dma_state <= D_BUSY;
                    end
                end

                D_BUSY: begin
                    if (dma_data_valid) begin
                        dma_rdata_q <= dma_rdata;
                        dma_state   <= D_READY;
                    end
                end

                default: dma_state <= D_READY;
            endcase
        end
    end

    // ---- Output mux ----------------------------------------------------
    // Snoop mode: pass-through. caller_ready always 1 (BRAM is always
    // 1-cycle-ready, which the consumer's existing WAIT state handles).
    //
    // DMA mode: caller_rdata = the latched DMA byte; caller_ready = 1
    // only when the FSM is in D_READY AND caller_req isn't ALSO firing
    // a new fetch this cycle. The latter prevents a same-cycle race
    // where the consumer's WAIT state would otherwise see the still-
    // asserted ready-from-last-fetch and advance, missing the new
    // DMA's data.
    assign caller_rdata = dma_mode ? dma_rdata_q : snoop_rdata;
    assign caller_ready = dma_mode
                          ? ((dma_state == D_READY) && !caller_req)
                          : (sh_ready && !caller_req);

endmodule

`default_nettype wire
