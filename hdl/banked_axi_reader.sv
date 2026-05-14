// banked_axi_reader.sv — AXI4 burst read master with 1-line prefetch
// buffer for the SALLY banked-window port (DDR3 on Zynq AXI HP).
//
// v2b (sally-mem-v2.md): the buffer holds the last 64-byte line read
// from DDR3. Sequential banked-window accesses hit the buffer with
// combinational req_ready and no SALLY stall; only line-cross events
// trigger a full AXI burst (8 beats × 8 bytes = 64 B). Expected to
// bring banked-code effective rate from ~24 MHz (v2a, no buffer) back
// near full clock for sequential workloads.
//
// Trade-off vs v2a: a 26-bit address comparator now sits combinationally
// on the SALLY busy path. If post-route timing shows this becoming the
// new critical path, register the hit signal (1-cycle stall per hit,
// still better than the v2a 25-40 cycle stall per access).
//
// Interface
// ---------
//
// SALLY-side: req_valid + req_ready handshake (held by caller for the
// duration of the access; ready is high when rdata is valid).
//
// AXI4 burst read master (compatible with Zynq HP slave):
//   m_axi_araddr  — line base address (= req_addr & ~63)
//   m_axi_arlen   — beat-count-minus-one; tied to 8'd7 (8 beats)
//   m_axi_arsize  — 3'd3 (8 bytes per beat; HP native data width)
//   m_axi_arburst — 2'b01 (INCR)
//   m_axi_arvalid / arready — request handshake
//   m_axi_rdata   — 64-bit beat
//   m_axi_rvalid / rready — data handshake
//   m_axi_rlast   — last beat of the burst
//
// arid / rid / arlock / arprot / arcache / arqos / rresp aren't exposed:
// the Zynq HP slave tolerates them tied off, and they're not on any
// fmax-critical path in the master.
//
// Line buffer
// -----------
//
// 8 × 64-bit array, indexed by req_addr[5:3]. Byte sub-selection by
// req_addr[2:0]. Vivado infers this as either distributed (LUT) RAM
// or a single 18Kb BRAM — both fit easily.
//
// Hit logic:
//   hit = req_valid && line_valid_q && (req_addr[31:6] == line_addr_q[31:6])
//
// On hit: req_ready combinational, line[req_addr[5:3]] muxed to req_rdata.
// On miss: req_ready de-asserted; FSM walks IDLE -> AR -> R -> IDLE;
//          line_valid_q goes 0 during fill, snaps to 1 on rlast, and
//          the same cycle drives req_ready+req_rdata for the originally
//          requested byte.

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

    // AXI4 burst read master
    output wire [AXI_ADDR_W-1:0]  m_axi_araddr,
    output wire [7:0]             m_axi_arlen,
    output wire [2:0]             m_axi_arsize,
    output wire [1:0]             m_axi_arburst,
    output wire                   m_axi_arvalid,
    input  wire                   m_axi_arready,
    input  wire [63:0]            m_axi_rdata,
    input  wire                   m_axi_rvalid,
    input  wire                   m_axi_rlast,
    output wire                   m_axi_rready
);

    // ---- State machine -------------------------------------------------
    typedef enum logic [1:0] { IDLE, AR, R } state_t;
    state_t state_q;

    // Line buffer + bookkeeping
    logic [63:0]              line_q [0:7];
    logic [AXI_ADDR_W-1:6]    line_addr_q;
    logic                     line_valid_q;
    logic [2:0]               beat_q;

    // Captured request fields (used during fill to deliver the
    // originally requested byte on completion).
    logic [AXI_ADDR_W-1:0]    pending_addr_q;
    logic [2:0]               pending_byte_sel_q;

    // ---- Hit detection (combinational) --------------------------------
    wire   line_match    = (req_addr[AXI_ADDR_W-1:6] == line_addr_q);
    wire   hit_w         = req_valid && line_valid_q && line_match && (state_q == IDLE);

    // The burst-just-completed cycle also delivers the originally
    // requested byte; check separately so we don't gate it through
    // the comparator (the fill addr already matches by construction).
    wire   fill_deliver  = (state_q == R) && m_axi_rvalid && m_axi_rlast;

    // ---- State transitions --------------------------------------------
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state_q           <= IDLE;
            line_addr_q       <= '0;
            line_valid_q      <= 1'b0;
            beat_q            <= '0;
            pending_addr_q    <= '0;
            pending_byte_sel_q<= '0;
        end else begin
            unique case (state_q)

                IDLE: begin
                    // On a miss (req_valid && !hit), capture request
                    // metadata and kick the burst.
                    if (req_valid && !hit_w) begin
                        line_valid_q       <= 1'b0;
                        pending_addr_q     <= req_addr;
                        pending_byte_sel_q <= req_addr[2:0];
                        beat_q             <= '0;
                        state_q            <= AR;
                    end
                end

                AR: begin
                    if (m_axi_arready) begin
                        state_q <= R;
                    end
                end

                R: begin
                    if (m_axi_rvalid) begin
                        line_q[beat_q] <= m_axi_rdata;
                        beat_q         <= beat_q + 3'd1;
                        if (m_axi_rlast) begin
                            line_addr_q  <= pending_addr_q[AXI_ADDR_W-1:6];
                            line_valid_q <= 1'b1;
                            state_q      <= IDLE;
                        end
                    end
                end

                default: state_q <= IDLE;
            endcase
        end
    end

    // ---- AXI driver assignments ---------------------------------------
    // The address presented on AR is the line base (low 6 bits zeroed),
    // computed from pending_addr_q (set when the miss kicked off).
    wire [AXI_ADDR_W-1:0] line_base = {pending_addr_q[AXI_ADDR_W-1:6], 6'b0};

    assign m_axi_araddr  = line_base;
    assign m_axi_arlen   = 8'd7;       // 8 beats per burst
    assign m_axi_arsize  = 3'd3;       // 8 bytes per beat (HP native width)
    assign m_axi_arburst = 2'b01;      // INCR
    assign m_axi_arvalid = (state_q == AR);
    assign m_axi_rready  = (state_q == R);

    // ---- Read-data path -----------------------------------------------
    // Byte selection from the addressed beat of the line buffer (hit path)
    // or directly from the last beat's m_axi_rdata (fill-deliver path).
    wire [2:0]  hit_beat_idx  = req_addr[5:3];
    wire [2:0]  hit_byte_idx  = req_addr[2:0];
    wire [63:0] hit_beat      = line_q[hit_beat_idx];
    wire [7:0]  hit_byte      = hit_beat[hit_byte_idx * 8 +: 8];

    wire [7:0]  fill_byte     = m_axi_rdata[pending_byte_sel_q * 8 +: 8];

    // Note: on the fill_deliver cycle, hit_w is 0 (state_q != IDLE) so the
    // mux below picks fill_byte cleanly. On a hit cycle, fill_deliver is 0.
    assign req_rdata = fill_deliver ? fill_byte : hit_byte;
    assign req_ready = hit_w || fill_deliver;

endmodule

`default_nettype wire
