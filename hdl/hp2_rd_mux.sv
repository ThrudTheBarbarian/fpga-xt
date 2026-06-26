// hp2_rd_mux.sv — 2:1 AXI read-channel arbiter for the shared HP2 read port.
//
// HP2's WRITE channel carries antic_writeback (write-only), so its READ channel
// is otherwise free.  Two read-only masters share it here:
//   s0 = drag-overlay plane_fetch  (active only during a window drag, overlay_en)
//   s1 = sprite_engine line fetcher
// Neither is the constant full-desktop plane_fetch (that owns HP0), so the
// combined demand fits HP2's read bandwidth comfortably (a 32x32 cursor sprite is
// ~2 bursts/line; the overlay reads one window's width only while dragging).
//
// MULTI-OUTSTANDING by design: the drag-overlay relies on PIPELINED AR (several
// in flight) to hide read latency — serialising it would re-introduce the drag
// tearing we fixed.  So both masters keep ARs in flight.  All ARs leave as a
// single-ID stream, so the HP slave returns R bursts strictly in AR-accept order;
// a small order-FIFO records which master each accepted AR belonged to and routes
// the returning burst back to it (and preserves each master's own burst order).
//
// s0 (overlay) wins AR arbitration when both request — cheap insurance that a
// live drag is never starved; the sprite's modest demand slots into the gaps.
`default_nettype none

module hp2_rd_mux #(
    parameter int OUTSTANDING = 8          // max ARs in flight; MUST be a power of 2
) (
    input  wire        clk,
    input  wire        rst,                // active-high, synchronous

    // ---- s0: drag-overlay read master (AR priority) ---------------------
    input  wire [31:0] s0_araddr,
    input  wire [7:0]  s0_arlen,
    input  wire [2:0]  s0_arsize,
    input  wire [1:0]  s0_arburst,
    input  wire        s0_arvalid,
    output wire        s0_arready,
    output wire [63:0] s0_rdata,
    output wire        s0_rvalid,
    output wire        s0_rlast,
    input  wire        s0_rready,

    // ---- s1: sprite-engine read master ----------------------------------
    input  wire [31:0] s1_araddr,
    input  wire [7:0]  s1_arlen,
    input  wire [2:0]  s1_arsize,
    input  wire [1:0]  s1_arburst,
    input  wire        s1_arvalid,
    output wire        s1_arready,
    output wire [63:0] s1_rdata,
    output wire        s1_rvalid,
    output wire        s1_rlast,
    input  wire        s1_rready,

    // ---- m: shared HP2 read channel (to the PS HP slave) ----------------
    output wire [31:0] m_araddr,
    output wire [7:0]  m_arlen,
    output wire [2:0]  m_arsize,
    output wire [1:0]  m_arburst,
    output wire        m_arvalid,
    input  wire        m_arready,
    input  wire [63:0] m_rdata,
    input  wire        m_rvalid,
    input  wire        m_rlast,
    output wire        m_rready
);
    localparam int AW = $clog2(OUTSTANDING);

    // ---- order-FIFO: one bit per outstanding AR (0 = s0, 1 = s1) --------
    logic            id_fifo [0:OUTSTANDING-1];
    logic [AW-1:0]   wr_ptr, rd_ptr;
    logic [AW:0]     count;                       // 0 .. OUTSTANDING
    wire             fifo_full  = (count == OUTSTANDING[AW:0]);
    wire             fifo_empty = (count == '0);

    // ---- AR arbitration (s0 wins ties), gated on FIFO room --------------
    // ar_pick: 0 -> s0, 1 -> s1.  Selection is stable across the handshake
    // because each master holds arvalid (and payload) until arready, and s0
    // priority only changes if s0 drops arvalid — which it won't mid-accept.
    wire ar_pick = ~s0_arvalid;
    wire ar_go   = (s0_arvalid | s1_arvalid) & ~fifo_full;

    assign m_arvalid  = ar_go;
    assign m_araddr   = ar_pick ? s1_araddr  : s0_araddr;
    assign m_arlen    = ar_pick ? s1_arlen   : s0_arlen;
    assign m_arsize   = ar_pick ? s1_arsize  : s0_arsize;
    assign m_arburst  = ar_pick ? s1_arburst : s0_arburst;
    assign s0_arready = ar_go & ~ar_pick & m_arready;
    assign s1_arready = ar_go &  ar_pick & m_arready;

    wire ar_accept = m_arvalid & m_arready;

    // ---- R demux by FIFO head (the master that owns the current burst) --
    wire owner = id_fifo[rd_ptr];                 // valid only when !fifo_empty
    assign s0_rvalid = m_rvalid & ~fifo_empty & ~owner;
    assign s1_rvalid = m_rvalid & ~fifo_empty &  owner;
    assign s0_rdata  = m_rdata;
    assign s1_rdata  = m_rdata;
    assign s0_rlast  = m_rlast;
    assign s1_rlast  = m_rlast;
    assign m_rready  = ~fifo_empty & (owner ? s1_rready : s0_rready);

    wire r_burst_done = m_rvalid & m_rready & m_rlast;

    // ---- FIFO bookkeeping -----------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            wr_ptr <= '0;
            rd_ptr <= '0;
            count  <= '0;
        end else begin
            if (ar_accept) begin
                id_fifo[wr_ptr] <= ar_pick;
                wr_ptr <= wr_ptr + 1'b1;          // wraps (OUTSTANDING power-of-2)
            end
            if (r_burst_done) begin
                rd_ptr <= rd_ptr + 1'b1;
            end
            unique case ({ar_accept, r_burst_done})
                2'b10:   count <= count + 1'b1;
                2'b01:   count <= count - 1'b1;
                default: count <= count;           // 00 / 11 = no net change
            endcase
        end
    end
endmodule

`default_nettype wire
