// plane_fetch.sv — per-plane DDR3 line fetch unit (video-arch phase 1b).
//
// docs/video-architecture.md section 4/11.  An AXI-read + ping-pong
// line-buffer per-plane source: it
// fetches one source ROW of a DDR3 surface into a line buffer, and serves the
// compositor a pixel read indexed by source COLUMN.  One instance per plane.
//
//   clk_sys: AXI4 read master (16-beat bursts, 8-byte beats = 2 RGBA px).
//            n_bursts = ceil(src_w/32); over-fetches up to 31 px (unused).
//            Row base = surface_base + fetch_row*stride_bytes.
//   clk_pix: line buffer read at rd_col -> rd_pixel (registered 1 clk).
//
// Pipeline: the row latched at line_start is fetched
// into the WRITE ping-pong half during that line; the READ half flips at the
// next line_start.  So drive `fetch_row` with the row that should DISPLAY on
// the NEXT line (the compositor's src_row_next).  `enable`=0 idles the AXI
// master (read returns stale/zero — the compositor gates via plane enable).
//
// CDC: line_start (clk_pix->clk_sys) via toggle + 2-FF + edge detect;
// fetch_row is stable between line_starts, carried by a 2-FF sync and sampled
// only after the synchronised line_start edge (stable-data + sync-flag).

`default_nettype none

module plane_fetch #(
    parameter int LB_WORDS = 1024     // 64-bit words per ping-pong half (2048 px)
) (
    // ---- AXI / fetch domain (clk_sys) ------------------------------------
    input  wire        clk_sys,
    input  wire        rst_sys,
    input  wire        enable,
    input  wire [31:0] surface_base,
    input  wire [15:0] stride_bytes,
    input  wire [11:0] src_w,         // source pixels per row

    output reg  [31:0] m_axi_araddr,
    output wire [7:0]  m_axi_arlen,
    output wire [2:0]  m_axi_arsize,
    output wire [1:0]  m_axi_arburst,
    output reg         m_axi_arvalid,
    input  wire        m_axi_arready,
    input  wire [63:0] m_axi_rdata,
    input  wire        m_axi_rvalid,
    input  wire        m_axi_rlast,
    output wire        m_axi_rready,

    // ---- Raster domain (clk_pix) -----------------------------------------
    input  wire        clk_pix,
    input  wire        rst_pix,
    input  wire        line_start,
    input  wire [11:0] fetch_row,     // source row to display NEXT line
    input  wire [11:0] rd_col,        // source column to read this pixel
    output wire [31:0] rd_pixel       // RGBA8888, registered 1 clk after rd_col
);

    localparam int BEATS_PER_BURST = 16;

    // FSM state — declared early so the combinational wr_en below can use it.
    typedef enum logic [1:0] { S_IDLE, S_AR, S_R, S_DONE } state_t;
    state_t      state;
    logic [6:0]  burst_idx;

    // ---- Line buffer (clk_sys write / clk_pix read) ----------------------
    (* ram_style = "block" *)
    logic [63:0] line_buf [0:2*LB_WORDS-1];

    // Double-buffered: rd and wr flip on the SAME event (line_start) but
    // start in opposite phase, so the read half is always the one the
    // previous line's fetch completed, and the write half is the other.
    logic        ping_pong_wr;        // clk_sys (init 1)
    logic        ping_pong_rd;        // clk_pix (init 0)
    logic [10:0] wr_idx;
    // Combinational write strobe so each beat lands in its own slot on the
    // cycle it arrives (a registered wr_en would drop the first beat).
    wire         wr_en = (state == S_R) && m_axi_rvalid;
    always_ff @(posedge clk_sys) begin
        if (wr_en) line_buf[{ping_pong_wr, wr_idx[9:0]}] <= m_axi_rdata;
    end

    // Read port (clk_pix): word at rd_col[10:1], half by rd_col[0] (1-cyc).
    logic [63:0] rd_word_q;
    logic        rd_lsb_q;
    always_ff @(posedge clk_pix) begin
        rd_word_q <= line_buf[{ping_pong_rd, rd_col[10:1]}];
        rd_lsb_q  <= rd_col[0];
    end
    assign rd_pixel = rd_lsb_q ? rd_word_q[63:32] : rd_word_q[31:0];

    // ---- line_start + fetch_row CDC (clk_pix -> clk_sys) -----------------
    logic       ls_toggle_pix;
    logic [11:0] fetch_row_pix;
    always_ff @(posedge clk_pix or posedge rst_pix) begin
        if (rst_pix) begin
            ls_toggle_pix <= 1'b0;
            fetch_row_pix <= 12'd0;
            ping_pong_rd  <= 1'b0;
        end else if (line_start) begin
            ls_toggle_pix <= ~ls_toggle_pix;
            fetch_row_pix <= fetch_row;
            ping_pong_rd  <= ~ping_pong_rd;
        end
    end

    logic [1:0] ls_sync;
    logic       ls_sync_prev;
    logic [11:0] fetch_row_s0, fetch_row_s1;
    always_ff @(posedge clk_sys) begin
        if (rst_sys) begin
            ls_sync      <= 2'b0;
            ls_sync_prev <= 1'b0;
            fetch_row_s0 <= 12'd0;
            fetch_row_s1 <= 12'd0;
        end else begin
            ls_sync      <= {ls_sync[0], ls_toggle_pix};
            ls_sync_prev <= ls_sync[1];
            fetch_row_s0 <= fetch_row_pix;   // stable between line_starts
            fetch_row_s1 <= fetch_row_s0;
        end
    end
    wire line_start_sys = ls_sync[1] ^ ls_sync_prev;

    // ---- Fetch bookkeeping (clk_sys) -------------------------------------
    // n_bursts = ceil(src_w / 32): 32 px = 16 beats × 2 px/beat.
    wire [6:0] n_bursts = 7'((src_w + 12'd31) >> 5);
    logic [11:0] row_to_fetch;
    logic        line_pending;
    logic        fetch_done;     // 1-cycle pulse when a line's fetch completes

    always_ff @(posedge clk_sys) begin
        if (rst_sys) begin
            row_to_fetch <= 12'd0;
            line_pending <= 1'b0;
            ping_pong_wr <= 1'b1;        // opposite phase to ping_pong_rd (init 0)
        end else begin
            if (line_start_sys) begin
                row_to_fetch <= fetch_row_s1;
                line_pending <= 1'b1;
                ping_pong_wr <= ~ping_pong_wr;   // flip with the read, opposite phase
            end else if (fetch_done) begin
                line_pending <= 1'b0;
            end
        end
    end

    // Row byte base = surface_base + row*stride (one multiply per line).
    wire [31:0] row_base = surface_base + (32'(row_to_fetch) * 32'(stride_bytes));

    // ---- AXI read FSM (clk_sys) ------------------------------------------
    assign m_axi_arsize  = 3'b011;     // 8 bytes/beat
    assign m_axi_arburst = 2'b01;      // INCR
    assign m_axi_arlen   = 8'(BEATS_PER_BURST - 1);
    assign m_axi_rready  = 1'b1;

    // burst byte offset = burst_idx * 128 (16 beats × 8 bytes)
    wire [31:0] burst_addr = row_base + (32'(burst_idx) << 7);

    always_ff @(posedge clk_sys) begin
        if (rst_sys) begin
            state         <= S_IDLE;
            burst_idx     <= 7'd0;
            wr_idx        <= 11'd0;
            fetch_done    <= 1'b0;
            m_axi_arvalid <= 1'b0;
            m_axi_araddr  <= 32'd0;
        end else begin
            fetch_done <= 1'b0;

            unique case (state)
                S_IDLE: begin
                    if (line_pending && enable) begin
                        burst_idx     <= 7'd0;
                        wr_idx        <= 11'd0;
                        m_axi_araddr  <= burst_addr;     // burst_idx = 0
                        m_axi_arvalid <= 1'b1;
                        state         <= S_AR;
                    end
                end
                S_AR: begin
                    if (m_axi_arready) begin
                        m_axi_arvalid <= 1'b0;
                        state         <= S_R;
                    end
                end
                S_R: begin
                    if (m_axi_rvalid) begin
                        // wr_en is combinational (asserts this cycle); just
                        // advance the slot for the next beat.
                        wr_idx <= wr_idx + 11'd1;
                        if (m_axi_rlast) begin
                            if (burst_idx == n_bursts - 7'd1) begin
                                state <= S_DONE;
                            end else begin
                                burst_idx     <= burst_idx + 7'd1;
                                m_axi_araddr  <= row_base + (32'(burst_idx + 7'd1) << 7);
                                m_axi_arvalid <= 1'b1;
                                state         <= S_AR;
                            end
                        end
                    end
                end
                S_DONE: begin
                    fetch_done <= 1'b1;
                    state      <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
