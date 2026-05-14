// banked_axi_reader.sv — AXI4 burst read master with 1-line prefetch
// buffer + write-through write path for the SALLY banked-window port
// (DDR3 on Zynq AXI HP).
//
// v2c (sally-mem-v2.md): the read path is unchanged from v2b. The
// write path adds AW + W + B AXI channels:
//   - SALLY writes to a banked-window address with req_we=1
//   - banked_axi_reader issues a single-beat 8-byte AXI write with
//     wstrb selecting just the targeted byte
//   - if the written address falls in the buffered line, invalidate
//     (no read-modify-write — simpler than maintaining coherency)
//   - CPU stalls for the AXI round-trip (~AW + W + B handshakes)
//
// Module naming note: the file is still called banked_axi_reader.sv,
// but the module is now a read-and-write master. Rename pending.
//
// Interface
// ---------
//
// SALLY-side handshake:
//   req_valid — high while SALLY is presenting a banked-window access
//   req_we    — 1 = write, 0 = read
//   req_addr  — full DDR3 byte address
//   req_wdata — byte to write (ignored when req_we = 0)
//   req_rdata — byte read (ignored when req_we = 1)
//   req_ready — 1 on hit-cycle (read) or burst-complete (read miss) or
//               B-response (write). Pulses one cycle.
//
// AXI4 burst master (compatible with Zynq HP slave):
//   AR channel: araddr, arlen, arsize, arburst, arvalid, arready
//   R channel : rdata, rvalid, rready, rlast
//   AW channel: awaddr, awlen, awsize, awburst, awvalid, awready
//   W channel : wdata, wstrb, wlast, wvalid, wready
//   B channel : bvalid, bready
//
// IDs / locks / cache / prot / qos / resp are tied off externally.
// bresp is dropped (silent failure on bus error — bring-up state).
//
// Line buffer + bookkeeping unchanged from v2b. Writes invalidate
// the buffer if they land in the cached line; reads (after an
// invalidation) refetch on the next access.

`default_nettype none

module banked_axi_reader #(
    parameter int unsigned AXI_ADDR_W = 32
) (
    input  wire                   clk,
    input  wire                   rst,

    // SALLY-side request
    input  wire [AXI_ADDR_W-1:0]  req_addr,
    input  wire                   req_valid,
    input  wire                   req_we,
    input  wire [7:0]             req_wdata,
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
    output wire                   m_axi_rready,

    // AXI4 single-beat write master
    output wire [AXI_ADDR_W-1:0]  m_axi_awaddr,
    output wire [7:0]             m_axi_awlen,
    output wire [2:0]             m_axi_awsize,
    output wire [1:0]             m_axi_awburst,
    output wire                   m_axi_awvalid,
    input  wire                   m_axi_awready,
    output wire [63:0]            m_axi_wdata,
    output wire [7:0]             m_axi_wstrb,
    output wire                   m_axi_wlast,
    output wire                   m_axi_wvalid,
    input  wire                   m_axi_wready,
    input  wire                   m_axi_bvalid,
    output wire                   m_axi_bready
);

    // ---- State machine -------------------------------------------------
    typedef enum logic [2:0] { IDLE, AR, R, AW, W, B } state_t;
    state_t state_q;

    // Line buffer + bookkeeping
    logic [63:0]              line_q [0:7];
    logic [AXI_ADDR_W-1:6]    line_addr_q;
    logic                     line_valid_q;
    logic [2:0]               beat_q;

    // Captured request fields (used during fill / write to deliver the
    // originally requested byte / drive the AXI write).
    logic [AXI_ADDR_W-1:0]    pending_addr_q;
    logic [2:0]               pending_byte_sel_q;
    logic [7:0]               pending_wdata_q;

    // ---- Hit detection (combinational, read path) ---------------------
    wire   line_match    = (req_addr[AXI_ADDR_W-1:6] == line_addr_q);
    wire   read_hit_w    = req_valid && !req_we && line_valid_q && line_match && (state_q == IDLE);

    // Read burst delivers original byte on the rlast beat.
    wire   fill_deliver  = (state_q == R) && m_axi_rvalid && m_axi_rlast;

    // Write completes on bvalid.
    wire   write_done    = (state_q == B) && m_axi_bvalid;

    // ---- State transitions --------------------------------------------
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state_q            <= IDLE;
            line_addr_q        <= '0;
            line_valid_q       <= 1'b0;
            beat_q             <= '0;
            pending_addr_q     <= '0;
            pending_byte_sel_q <= '0;
            pending_wdata_q    <= '0;
        end else begin
            unique case (state_q)

                IDLE: begin
                    if (req_valid && !req_we && !read_hit_w) begin
                        // Read miss — kick burst read.
                        line_valid_q       <= 1'b0;
                        pending_addr_q     <= req_addr;
                        pending_byte_sel_q <= req_addr[2:0];
                        beat_q             <= '0;
                        state_q            <= AR;
                    end else if (req_valid && req_we) begin
                        // Write — invalidate line if it matches, then
                        // walk the AW -> W -> B sequence.
                        if (line_valid_q && line_match) line_valid_q <= 1'b0;
                        pending_addr_q     <= req_addr;
                        pending_byte_sel_q <= req_addr[2:0];
                        pending_wdata_q    <= req_wdata;
                        state_q            <= AW;
                    end
                end

                AR: begin
                    if (m_axi_arready) state_q <= R;
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

                AW: begin
                    if (m_axi_awready) state_q <= W;
                end

                W: begin
                    if (m_axi_wready) state_q <= B;
                end

                B: begin
                    if (m_axi_bvalid) state_q <= IDLE;
                end

                default: state_q <= IDLE;
            endcase
        end
    end

    // ---- AXI driver assignments ---------------------------------------
    // Read channel
    wire [AXI_ADDR_W-1:0] line_base = {pending_addr_q[AXI_ADDR_W-1:6], 6'b0};
    assign m_axi_araddr  = line_base;
    assign m_axi_arlen   = 8'd7;        // 8 beats per burst (64 B / 8 B)
    assign m_axi_arsize  = 3'd3;        // 8 bytes per beat
    assign m_axi_arburst = 2'b01;       // INCR
    assign m_axi_arvalid = (state_q == AR);
    assign m_axi_rready  = (state_q == R);

    // Write channel — single beat, 8-byte aligned, wstrb selects byte.
    wire [AXI_ADDR_W-1:0] write_addr_aligned = {pending_addr_q[AXI_ADDR_W-1:3], 3'b0};
    wire [63:0]           write_data_lane    = {8{pending_wdata_q}};
    wire [7:0]            write_strb         = 8'b1 << pending_byte_sel_q;

    assign m_axi_awaddr  = write_addr_aligned;
    assign m_axi_awlen   = 8'd0;        // single beat
    assign m_axi_awsize  = 3'd3;        // 8 bytes per beat (HP native width)
    assign m_axi_awburst = 2'b01;
    assign m_axi_awvalid = (state_q == AW);
    assign m_axi_wdata   = write_data_lane;
    assign m_axi_wstrb   = write_strb;
    assign m_axi_wlast   = 1'b1;        // always last of single-beat burst
    assign m_axi_wvalid  = (state_q == W);
    assign m_axi_bready  = (state_q == B);

    // ---- Read-data path -----------------------------------------------
    wire [2:0]  hit_beat_idx = req_addr[5:3];
    wire [2:0]  hit_byte_idx = req_addr[2:0];
    wire [63:0] hit_beat     = line_q[hit_beat_idx];
    wire [7:0]  hit_byte     = hit_beat[hit_byte_idx * 8 +: 8];

    wire [7:0]  fill_byte    = m_axi_rdata[pending_byte_sel_q * 8 +: 8];

    assign req_rdata = fill_deliver ? fill_byte : hit_byte;
    assign req_ready = read_hit_w || fill_deliver || write_done;

endmodule

`default_nettype wire
