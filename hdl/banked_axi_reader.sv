// banked_axi_reader.sv — minimal AXI4-Lite-class read master for the
// SALLY banked-window port (DDR3 on Zynq AXI HP).
//
// v2a baseline (sally-mem-v2.md): single-beat reads, no prefetch
// buffer, no write path. Every banked-window CPU access stalls SALLY
// for the full AXI round-trip (~25-40 cycles on Zynq HP @ same clock
// as SALLY). The point is to prove that *removing the cache* recovers
// the fmax we lost to its 12-logic-level critical paths; whether
// banked code runs at full speed is a v2b/v2c concern.
//
// Interface
// ---------
//
// SALLY-side:
//   req_addr   — full DDR3-side address (sally_mem composes from bank
//                base + bank_id + offset; this module just reads it).
//   req_valid  — pulse high for one cycle when the CPU is accessing a
//                banked window AND the access is a read (rw=1).
//   req_ready  — combinationally low while a transaction is in flight;
//                pulses high for one cycle when rdata is available.
//                Drives sally_mem's `busy` -> sally_clock's RDY gate.
//   req_rdata  — the requested byte. Latched from rdata until the next
//                req_valid arrives (caller should sample on req_ready=1).
//
// AXI4-Lite read channel (compatible with AXI4 by simple wiring):
//   m_axi_araddr  — 32-bit byte address, naturally aligned
//   m_axi_arvalid — request handshake
//   m_axi_arready — slave accepts request
//   m_axi_rdata   — 64-bit data (HP port native width)
//   m_axi_rvalid  — data handshake
//   m_axi_rready  — master accepts data
//   m_axi_rlast   — last beat of burst (always 1 for single-beat)
//
// (No write channel in v2a. arlen / arsize / arburst not exposed —
// implied single-beat 64-bit. The Zynq PS slave-side AXI accepts a
// stripped-down master if the higher-order signals are tied off; the
// synth wrapper exposes m_axi_* at the pad boundary so a real AXI HP
// connection can be added later without touching this module.)
//
// Pipeline
// --------
// IDLE  : await req_valid. On req_valid, latch req_addr -> ar_addr;
//         go to AR.
// AR    : drive m_axi_arvalid=1 with the latched address. On arready,
//         go to R.
// R     : drive m_axi_rready=1. On rvalid, latch the requested byte
//         from the right lane of m_axi_rdata; pulse req_ready=1 for one
//         cycle; go to IDLE.
//
// The byte select takes m_axi_rdata's 64 bits and picks the byte at
// {req_addr[2:0], 3'b000}+:8. Zynq AXI HP returns the addressed beat
// with byte-strobe-style positioning, so a 1-byte read from address
// e.g. 0x12345607 returns m_axi_rdata[63:56]. We do not assert WSTRB
// (this is read-only).

`default_nettype none

module banked_axi_reader #(
    parameter int unsigned AXI_ADDR_W = 32
) (
    input  wire                   clk,
    input  wire                   rst,

    // SALLY-side request
    input  wire [AXI_ADDR_W-1:0]  req_addr,
    input  wire                   req_valid,
    output wire [7:0]             req_rdata,
    output wire                   req_ready,

    // AXI4-Lite-class read master
    output wire [AXI_ADDR_W-1:0]  m_axi_araddr,
    output wire                   m_axi_arvalid,
    input  wire                   m_axi_arready,
    input  wire [63:0]            m_axi_rdata,
    input  wire                   m_axi_rvalid,
    input  wire                   m_axi_rlast,    // unused for single-beat
    output wire                   m_axi_rready
);

    typedef enum logic [1:0] { IDLE, AR, R, DONE } state_t;
    state_t state_q;

    logic [AXI_ADDR_W-1:0] addr_q;
    logic [2:0]            byte_sel_q;
    logic [7:0]            rdata_q;
    logic                  ready_q;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state_q    <= IDLE;
            addr_q     <= '0;
            byte_sel_q <= '0;
            rdata_q    <= 8'h00;
            ready_q    <= 1'b0;
        end else begin
            ready_q <= 1'b0;
            unique case (state_q)
                IDLE: begin
                    if (req_valid) begin
                        addr_q     <= req_addr;
                        byte_sel_q <= req_addr[2:0];
                        state_q    <= AR;
                    end
                end
                AR: begin
                    if (m_axi_arready) begin
                        state_q <= R;
                    end
                end
                R: begin
                    if (m_axi_rvalid) begin
                        rdata_q <= m_axi_rdata[byte_sel_q * 8 +: 8];
                        ready_q <= 1'b1;
                        state_q <= IDLE;
                    end
                end
                default: state_q <= IDLE;
            endcase
        end
    end

    assign m_axi_araddr  = addr_q;
    assign m_axi_arvalid = (state_q == AR);
    assign m_axi_rready  = (state_q == R);

    assign req_rdata = rdata_q;
    assign req_ready = ready_q;

    // `unused` taps so lint stays clean while we ignore single-beat-
    // implicit signals from a real AXI4 burst master.
    wire _unused = &{1'b0, m_axi_rlast};

endmodule

`default_nettype wire
