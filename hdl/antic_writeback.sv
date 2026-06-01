// antic_writeback.sv — ANTIC render -> DDR3 XL surface writeback orchestrator.
//
// docs/video/video-architecture.md section 5 (phase 2).  Taps ANTIC's per-pixel-pair
// render stream (clk_bus), palette-resolves the 8-bit Atari colour codes to
// RGBA8888, accumulates a scanline, and DMAs it to a TRIPLE-buffered DDR3
// surface via axi_line_writer.  The buffer rotation lives in xl_buffer_ctrl,
// which hands us `write_idx` (the slot to fill) and decouples the writeback
// from the clk_pix scan-out so the compositor always reads a complete, stable
// frame — no mid-frame swap (the ~1 Hz tear) and no reading a buffer being
// written (the moving ghost lines).
//
// Timing assumption: a row's DMA completes before the next row's pixels
// arrive (ANTIC pixels are phi2-paced — slow vs clk_sys, and the DMA is a few
// hundred cycles).  If hardware shows overlap, add a ping-pong row buffer.
// pix_valid (fills) and row_flush (DMA) never overlap by construction.

`default_nettype none

// Default code->RGB palette contents baked into the scan-out palette_lut.  The
// XT $D483-$D486 chiplet port (CDC'd into pal_we/pal_idx/pal_rgb) can overwrite
// entries at runtime, but nothing loads it at boot today, so without this the
// scan-out RGB is all-zero (black).  A string LITERAL (not a parameter) so the
// $readmemh path passes cleanly through palette_lut's INIT_FILE under iverilog.
// Override with `-D ANTIC_PALETTE_HEX=...` (e.g. sim from sim/ uses "../hdl/...").
`ifndef ANTIC_PALETTE_HEX
  `define ANTIC_PALETTE_HEX "hdl/palette/atari_ntsc.hex"
`endif

module antic_writeback #(
    parameter int MAX_W = 1024
) (
    input  wire        clk_sys,        // = antic clk_bus
    input  wire        rst_sys,

    // ---- Render tap (per pixel-pair) -------------------------------------
    input  wire        pix_valid,      // a compositor pixel-pair was produced
    input  wire [7:0]  pix_pair,       // pair index within the line (col/2)
    input  wire [7:0]  color_lo,       // 8-bit Atari colour code, even column
    input  wire [7:0]  color_hi,       //                          odd column
    input  wire [7:0]  atari_row,      // row being rendered
    input  wire        row_flush,      // pulse: current row complete -> DMA it

    // ---- Palette writes (clk_bus origin) --------------------------------
    input  wire        pal_we,
    input  wire [7:0]  pal_idx,
    input  wire [23:0] pal_rgb,        // {R,G,B}

    // ---- Config ----------------------------------------------------------
    input  wire [31:0] base0,          // triple-buffer slot bases (xl_buffer_ctrl
    input  wire [31:0] base1,          //   selects via write_idx; rotation lives
    input  wire [31:0] base2,          //   there, not here)
    input  wire [1:0]  write_idx,      // slot to write this frame (clk_sys, stable
                                       //   between frames)
    input  wire [15:0] stride_bytes,
    input  wire [11:0] src_w,

    // ---- AXI4 write master (to a Zynq HP port) ---------------------------
    output wire [31:0] m_axi_awaddr,
    output wire [7:0]  m_axi_awlen,
    output wire [2:0]  m_axi_awsize,
    output wire [1:0]  m_axi_awburst,
    output wire        m_axi_awvalid,
    input  wire        m_axi_awready,
    output wire [63:0] m_axi_wdata,
    output wire [7:0]  m_axi_wstrb,
    output wire        m_axi_wlast,
    output wire        m_axi_wvalid,
    input  wire        m_axi_wready,
    input  wire        m_axi_bvalid,
    output wire        m_axi_bready
);

    // ---- Writeback palette (mirrors ANTIC's; resolves code -> RGB888) ----
    logic [7:0]  pal_raddr;
    wire [23:0]  pal_rdata;
    palette_lut #(.ADDR_W(8), .INIT_FILE(`ANTIC_PALETTE_HEX)) u_pal (
        .clk   (clk_sys),
        .we    (pal_we),
        .waddr (pal_idx),
        .wdata (pal_rgb),
        .raddr (pal_raddr),
        .rdata (pal_rdata)
    );

    // ---- axi_line_writer (the row DMA) -----------------------------------
    logic        lw_wr_en;
    logic [11:0] lw_wr_col;
    logic [31:0] lw_wr_pixel;
    logic        lw_flush;
    logic [31:0] lw_flush_base;
    wire         lw_busy;

    axi_line_writer #(.MAX_W(MAX_W)) u_writer (
        .clk_sys (clk_sys), .rst_sys (rst_sys),
        .wr_en (lw_wr_en), .wr_col (lw_wr_col), .wr_pixel (lw_wr_pixel),
        .flush (lw_flush), .flush_base (lw_flush_base), .flush_w (src_w), .busy (lw_busy),
        .m_axi_awaddr (m_axi_awaddr), .m_axi_awlen (m_axi_awlen), .m_axi_awsize (m_axi_awsize),
        .m_axi_awburst (m_axi_awburst), .m_axi_awvalid (m_axi_awvalid),
        .m_axi_awready (m_axi_awready), .m_axi_wdata (m_axi_wdata), .m_axi_wstrb (m_axi_wstrb),
        .m_axi_wlast (m_axi_wlast), .m_axi_wvalid (m_axi_wvalid), .m_axi_wready (m_axi_wready),
        .m_axi_bvalid (m_axi_bvalid), .m_axi_bready (m_axi_bready)
    );

    // ---- Tap FIFO --------------------------------------------------------
    // ANTIC delivers resolved colour pairs at up to 1 per clk_sys cycle, but
    // the resolve FSM below takes 4 cycles per pair.  Without buffering, 3 of
    // every 4 pairs are dropped and the surface renders 2 lit + 6 black columns
    // per 8 (the column-stripe artifact seen on HW).  This per-line FIFO
    // captures every delivered pair; the resolve drains it (~640 cyc for a
    // 160-pair GR.0 line) inside the long inter-line gap (~9500 cyc), so no
    // pixel is lost.  The line-writer (proven write path) is unchanged.
    localparam int TF_DEPTH = 256;
    localparam int TF_AW    = $clog2(TF_DEPTH);
    (* ram_style = "distributed" *)
    logic [23:0]      tf_mem [0:TF_DEPTH-1];     // {pair[7:0], color_hi, color_lo}
    logic [TF_AW-1:0] tf_wr, tf_rd;
    wire              tf_empty = (tf_wr == tf_rd);
    wire              tf_full  = (TF_AW'(tf_wr + 1'b1) == tf_rd);
    wire              tf_push  = pix_valid && !tf_full;
    wire [23:0]       tf_dout  = tf_mem[tf_rd];

    // ---- Pixel-pair resolve FSM ------------------------------------------
    // Pops one pair from the FIFO, reads the palette for color_lo (col 2*pair)
    // then color_hi (col 2*pair+1), writing RGBA into the writer's row buffer.
    // R_SETUP covers palette_lut's 1-cycle read latency before R_LO samples.
    // Held off while the writer is DMA-ing (lw_busy) so the next row can't
    // overwrite row_buf mid-flush (the FIFO holds the pairs meanwhile).
    typedef enum logic [1:0] { R_IDLE, R_SETUP, R_LO, R_HI } rstate_t;
    rstate_t rstate;
    logic [7:0] pair_q, chi_q;
    logic       row_dirty;      // ≥1 pixel delivered this row (driven below)
    logic [7:0] row_capt;       // atari_row captured at the FIRST pixel of the
                                // row.  The DMA destination MUST use this, not
                                // the live atari_row: row_flush is line_start of
                                // the NEXT scanline, by which point antic_raster
                                // has already advanced atari_row to row+1.  Using
                                // the live value wrote row R to buffer R+1, left
                                // buffer row 0 unwritten (the stale "white line"
                                // at the top) and dropped row 191.
    wire        tf_pop = (rstate == R_IDLE) && !tf_empty && !lw_busy;

    always_ff @(posedge clk_sys or posedge rst_sys) begin
        if (rst_sys) begin
            rstate    <= R_IDLE;
            pal_raddr <= 8'd0;
            lw_wr_en  <= 1'b0;
            lw_wr_col <= 12'd0;
            lw_wr_pixel <= 32'd0;
            pair_q    <= 8'd0;
            chi_q     <= 8'd0;
            tf_wr     <= '0;
            tf_rd     <= '0;
        end else begin
            lw_wr_en <= 1'b0;

            // FIFO push (tap) / pop (resolve accept).
            if (tf_push) begin
                tf_mem[tf_wr] <= {pix_pair, color_hi, color_lo};
                tf_wr <= TF_AW'(tf_wr + 1'b1);
            end
            if (tf_pop) tf_rd <= TF_AW'(tf_rd + 1'b1);

            unique case (rstate)
                R_IDLE: begin
                    if (!tf_empty && !lw_busy) begin
                        pair_q    <= tf_dout[23:16];
                        chi_q     <= tf_dout[15:8];
                        pal_raddr <= tf_dout[7:0];     // color_lo -> even-pixel resolve
                        rstate    <= R_SETUP;
                    end
                end
                R_SETUP: begin
                    // even-pixel read in flight; set up the odd-pixel read.
                    pal_raddr <= chi_q;
                    rstate    <= R_LO;
                end
                R_LO: begin
                    // pal_rdata = resolve(color_lo) (valid now). Write even col.
                    lw_wr_en    <= 1'b1;
                    lw_wr_col   <= {3'd0, pair_q, 1'b0};      // 2*pair
                    lw_wr_pixel <= {pal_rdata, 8'hFF};        // {R,G,B,A}
                    rstate      <= R_HI;
                end
                R_HI: begin
                    lw_wr_en    <= 1'b1;
                    lw_wr_col   <= {3'd0, pair_q, 1'b1};      // 2*pair+1
                    lw_wr_pixel <= {pal_rdata, 8'hFF};
                    rstate      <= R_IDLE;
                end
                default: rstate <= R_IDLE;
            endcase
        end
    end

    // ---- Row flush + triple-buffer write target --------------------------
    // The writeback fills the slot xl_buffer_ctrl picked (write_idx) — never the
    // one the compositor is displaying.  The flush is LATCHED at row-complete
    // (row_flush) and fired only once the tap FIFO has fully drained into the row
    // buffer and the writer is free, so a row is never DMA'd before all its
    // pixels are resolved.  The destination (base + row) is snapshotted at latch
    // time; write_idx is stable between frames so the snapshot is consistent.
    logic        flush_pending;
    logic [31:0] flush_base_q;

    // write_idx → slot base.  write_idx only changes at frame boundaries (in
    // xl_buffer_ctrl), so this is stable across a frame's row flushes.
    logic [31:0] write_base;
    always_comb begin
        unique case (write_idx)
            2'd0:    write_base = base0;
            2'd1:    write_base = base1;
            default: write_base = base2;
        endcase
    end

    always_ff @(posedge clk_sys or posedge rst_sys) begin
        if (rst_sys) begin
            lw_flush      <= 1'b0;
            lw_flush_base <= 32'd0;
            row_dirty     <= 1'b0;
            row_capt      <= 8'd0;
            flush_pending <= 1'b0;
            flush_base_q  <= 32'd0;
        end else begin
            lw_flush <= 1'b0;

            // Capture the row on EVERY pixel — every pixel of a row arrives
            // while atari_row holds that row, so row_capt always tracks the row
            // currently being delivered.  row_flush (line_start of the NEXT
            // scanline) samples row_capt BEFORE that next row's first pixel
            // arrives, so it reads the just-completed row's index.  NOT gated on
            // !row_dirty: row_dirty is cleared by the (possibly-late) flush, and
            // gating on it would skip the capture if the flush lagged the next
            // row's first pixel — collapsing/skipping rows (the alternating-row
            // artifact).
            if (pix_valid)
                row_capt <= atari_row;

            // Latch the request + snapshot the destination at row-complete.
            if (row_flush && row_dirty) begin
                flush_pending <= 1'b1;
                flush_base_q  <= write_base
                                 + (32'(row_capt) * 32'(stride_bytes));
            end

            // Fire the DMA once the FIFO is drained and resolve+writer are idle.
            if (flush_pending && tf_empty && (rstate == R_IDLE) && !lw_busy && !lw_flush) begin
                lw_flush_base <= flush_base_q;
                lw_flush      <= 1'b1;
                flush_pending <= 1'b0;
            end

            // row_dirty: set when a pixel is delivered, cleared once flush fires.
            if (lw_flush)         row_dirty <= 1'b0;
            else if (pix_valid)   row_dirty <= 1'b1;
        end
    end

endmodule

`default_nettype wire
