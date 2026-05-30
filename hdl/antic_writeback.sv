// antic_writeback.sv — ANTIC render -> DDR3 XL surface writeback orchestrator.
//
// docs/video-architecture.md section 5 (phase 2).  Taps ANTIC's per-pixel-pair
// render stream (clk_bus), palette-resolves the 8-bit Atari colour codes to
// RGBA8888, accumulates a scanline, and DMAs it to a double-buffered DDR3
// surface via axi_line_writer.  front_sel tells the compositor which buffer
// to read; it flips on ANTIC vblank so the compositor always reads a complete
// frame while the next is being written.
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
    input  wire        frame_done,     // pulse (vbi): flip the front buffer

    // ---- Palette writes (clk_bus origin) --------------------------------
    input  wire        pal_we,
    input  wire [7:0]  pal_idx,
    input  wire [23:0] pal_rgb,        // {R,G,B}

    // ---- Config ----------------------------------------------------------
    input  wire [31:0] base_a,
    input  wire [31:0] base_b,
    input  wire [15:0] stride_bytes,
    input  wire [11:0] src_w,

    // ---- Status ----------------------------------------------------------
    output reg         front_sel,      // 0 = compositor reads base_a (writeback -> base_b)

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

    // ---- Pixel-pair resolve FSM ------------------------------------------
    // Per pix_valid: read palette for color_lo (col 2*pair), then color_hi
    // (col 2*pair+1), writing RGBA into the writer's row buffer.
    // R_SETUP covers palette_lut's 1-cycle read latency before R_LO samples.
    typedef enum logic [1:0] { R_IDLE, R_SETUP, R_LO, R_HI } rstate_t;
    rstate_t rstate;
    logic [7:0] pair_q, chi_q;
    logic [7:0] row_q;          // row being filled (captured from atari_row)
    logic       row_dirty;      // ≥1 pixel written this row

    always_ff @(posedge clk_sys or posedge rst_sys) begin
        if (rst_sys) begin
            rstate    <= R_IDLE;
            pal_raddr <= 8'd0;
            lw_wr_en  <= 1'b0;
            lw_wr_col <= 12'd0;
            lw_wr_pixel <= 32'd0;
            pair_q    <= 8'd0;
            chi_q     <= 8'd0;
            row_q     <= 8'd0;
        end else begin
            lw_wr_en <= 1'b0;
            unique case (rstate)
                R_IDLE: begin
                    if (pix_valid) begin
                        pair_q    <= pix_pair;
                        chi_q     <= color_hi;
                        row_q     <= atari_row;
                        pal_raddr <= color_lo;     // start even-pixel resolve
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

    // ---- Row flush + double-buffer ---------------------------------------
    // writeback writes the BACK buffer (the one the compositor isn't reading).
    wire [31:0] wb_base   = front_sel ? base_a : base_b;
    wire [31:0] row_addr  = wb_base + (32'(row_q) * 32'(stride_bytes));

    always_ff @(posedge clk_sys or posedge rst_sys) begin
        if (rst_sys) begin
            lw_flush      <= 1'b0;
            lw_flush_base <= 32'd0;
            front_sel     <= 1'b0;
            row_dirty     <= 1'b0;
        end else begin
            lw_flush <= 1'b0;
            // Flush the just-completed row (resolve FSM idle, writer free, row
            // has data) when row_flush fires.
            if (row_flush && row_dirty && !lw_busy && rstate == R_IDLE) begin
                lw_flush_base <= row_addr;
                lw_flush      <= 1'b1;
            end
            // row_dirty: set when a pixel arrives, cleared once a flush fires.
            if (lw_flush)         row_dirty <= 1'b0;
            else if (pix_valid)   row_dirty <= 1'b1;
            // Flip the front buffer at end of frame.
            if (frame_done) front_sel <= ~front_sel;
        end
    end

endmodule

`default_nettype wire
