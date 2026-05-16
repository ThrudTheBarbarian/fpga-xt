// fb_scanout.sv — 1080p60 framebuffer scan-out from DDR3 via AXI HP.
//
// Reads an RGBA-8888 framebuffer from DDR3 line-by-line through an AXI4
// read master and emits parallel RGB565 + sync to the SiI9022A on the
// Z-Turn SOM.  Alpha is dropped at the output stage (the framebuffer is
// the final composited surface); 8888 → 565 is a simple bit-truncation
// for v0, Bayer dither follows in a separate stage.
//
// Architecture:
//
//   clk_sys  ┌─────────────────────────────────┐
//   ─────────┤ AXI fetch FSM (16-beat bursts,  │
//            │  64 bursts/line, 8 KB/line)     │
//            └────────────────┬────────────────┘
//                             │ writes 64-bit beats
//                             ▼
//                     ┌───────────────┐
//                     │ Ping-pong line│   2 × 1024 × 64 bits = 16 KB
//                     │ buffer (BRAM) │
//                     └───────┬───────┘
//                             │ reads 32-bit pixels
//                             ▼
//   clk_pix  ┌─────────────────────────────────┐
//   ─────────┤ vbeam + read-port + 565 trunc   │ → RGB565 + sync
//            └─────────────────────────────────┘
//
// Per-line fetch budget (1080p60 @ clk_sys=150 MHz):
//   64 × (16-beat AXI3 burst + ~3 cycles AR/turnaround) ≈ 1216 cycles
//                                                       ≈ 8.1 µs
//   Active line period: 1/(60×1125) = 14.81 µs — half-budget headroom.
//
// CDC:
//   line_start (clk_pix → clk_sys): toggle-and-edge-detect through
//                                   2-FF synchroniser.
//   ping_pong selectors: each domain owns its own, synchronised at
//                        boundaries.
//
// Address calculation (no multipliers):
//   araddr = FB_BASE + (fetch_line << 13) + (burst_idx << 7)
//                       (line × 8192 B)    (burst × 128 B = 16 × 8 B)

`default_nettype none

module fb_scanout #(
    parameter logic [31:0] FB_BASE      = 32'h3000_0000,

    // 1080p60 CEA-861 timing (148.5 MHz nominal; we run 148.4375 MHz,
    // −0.042 % error, well inside HDMI ±0.5 % spec).
    parameter int          H_ACTIVE      = 1920,
    parameter int          H_FRONT_PORCH = 88,
    parameter int          H_SYNC_WIDTH  = 44,
    parameter int          H_BACK_PORCH  = 148,
    parameter int          V_ACTIVE      = 1080,
    parameter int          V_FRONT_PORCH = 4,
    parameter int          V_SYNC_WIDTH  = 5,
    parameter int          V_BACK_PORCH  = 36,

    // Bring-up Phase 2: bypass the AXI HP read path and drive a
    // deterministic 8-colour-bar test pattern from h_count.  The
    // AXI master still functions (its read requests just go nowhere
    // useful) but the RGB output is taken from the pattern generator
    // instead of the dithered line-buffer read.  Default 0 so normal
    // builds are unaffected.  See docs/bring-up.md.
    parameter bit          TEST_PATTERN  = 1'b0
) (
    // ---- Clocks & reset --------------------------------------------------
    input  wire        clk_sys,    // AXI HP fetch clock (~150 MHz)
    input  wire        rst_sys,    // active-high, clk_sys domain
    input  wire        clk_pix,    // 148.4375 MHz pixel clock
    input  wire        rst_pix,    // active-high, clk_pix domain

    // ---- Control (clk_sys) -----------------------------------------------
    input  wire        enable,     // 1 = drive video; 0 = output black

    // ---- AXI4 read master (clk_sys) --------------------------------------
    // Targets a Zynq AXI HP slave; arlen is restricted to ≤15 since HP is
    // AXI3-flavoured (UG585).  16-beat bursts of 8-byte beats.
    output logic [31:0] m_axi_araddr,
    output logic [7:0]  m_axi_arlen,
    output logic [2:0]  m_axi_arsize,
    output logic [1:0]  m_axi_arburst,
    output logic        m_axi_arvalid,
    input  wire         m_axi_arready,
    input  wire  [63:0] m_axi_rdata,
    input  wire         m_axi_rvalid,
    input  wire         m_axi_rlast,
    output wire         m_axi_rready,

    // ---- HDMI / SiI9022A output (clk_pix) --------------------------------
    output wire  [4:0]  rgb_r,
    output wire  [5:0]  rgb_g,
    output wire  [4:0]  rgb_b,
    output wire         rgb_hsync,
    output wire         rgb_vsync,
    output wire         rgb_de,
    output wire         rgb_pixclk
);

    // ====================================================================
    // Raster timing (clk_pix)
    // ====================================================================
    wire [11:0] h_count, v_count;
    wire        in_active;
    wire        de_pix, hsync_pix, vsync_pix;
    wire        line_start_pix, frame_start_pix;

    vbeam #(
        .H_ACTIVE          (H_ACTIVE),
        .H_FRONT_PORCH     (H_FRONT_PORCH),
        .H_SYNC_WIDTH      (H_SYNC_WIDTH),
        .H_BACK_PORCH      (H_BACK_PORCH),
        .V_ACTIVE          (V_ACTIVE),
        .V_FRONT_PORCH     (V_FRONT_PORCH),
        .V_SYNC_WIDTH      (V_SYNC_WIDTH),
        .V_BACK_PORCH      (V_BACK_PORCH),
        .ANTIC_LINES_NATIVE(V_ACTIVE),       // unused; satisfy port
        .HSYNC_ACTIVE_LOW  (1'b0),           // CEA-861 1080p60: both positive
        .VSYNC_ACTIVE_LOW  (1'b0)
    ) u_vbeam (
        .clk_pix    (clk_pix),
        .rst        (rst_pix),
        .h_count    (h_count),
        .v_count    (v_count),
        .in_active  (in_active),
        .h_active   (),
        .v_active   (),
        .hsync      (hsync_pix),
        .vsync      (vsync_pix),
        .de         (de_pix),
        .line_start (line_start_pix),
        .frame_start(frame_start_pix),
        .vbi_start  (),
        .atari_row  (),
        .vcount     ()
    );

    // ====================================================================
    // CDC: line_start (clk_pix → clk_sys) — toggle + 2-FF + edge detect
    // ====================================================================
    logic       line_start_toggle_pix;
    always_ff @(posedge clk_pix or posedge rst_pix) begin
        if (rst_pix)             line_start_toggle_pix <= 1'b0;
        else if (line_start_pix) line_start_toggle_pix <= ~line_start_toggle_pix;
    end

    logic [1:0] line_start_sync;
    logic       line_start_sync_prev;
    always_ff @(posedge clk_sys or posedge rst_sys) begin
        if (rst_sys) begin
            line_start_sync      <= 2'b0;
            line_start_sync_prev <= 1'b0;
        end else begin
            line_start_sync      <= {line_start_sync[0], line_start_toggle_pix};
            line_start_sync_prev <= line_start_sync[1];
        end
    end
    wire line_start_sys = line_start_sync[1] ^ line_start_sync_prev;

    // ====================================================================
    // Ping-pong line buffer
    // ====================================================================
    // 2 buffers × 1024 entries × 64 bits = 16 KB ≈ 4 BRAM36.
    // Write side: 64-bit beats, addressed by {ping_pong_wr, wr_idx[9:0]}.
    // Read side : 32-bit pixels — fetch 64-bit word at h_count[10:1],
    //             then mux high/low half by h_count[0] (one cycle delayed).
    (* ram_style = "block" *)
    logic [63:0] line_buf [0:2047];

    logic        ping_pong_wr;          // clk_sys
    logic        ping_pong_rd;          // clk_pix
    logic [9:0]  wr_idx;                // clk_sys, entry within current buffer half
    logic        wr_en;
    always_ff @(posedge clk_sys) begin
        if (wr_en) line_buf[{ping_pong_wr, wr_idx}] <= m_axi_rdata;
    end

    // Read port: 32-bit pixel from line_buf at h_count[10:1]; select half
    // by h_count[0] one cycle later (matches 1-cycle BRAM latency).
    logic [63:0] rd_word_q;
    logic        rd_lsb_q;
    always_ff @(posedge clk_pix) begin
        rd_word_q <= line_buf[{ping_pong_rd, h_count[10:1]}];
        rd_lsb_q  <= h_count[0];
    end
    wire [31:0] rd_pixel = rd_lsb_q ? rd_word_q[63:32] : rd_word_q[31:0];

    // ====================================================================
    // Ping-pong selector — read side flips at each line_start_pix
    // ====================================================================
    always_ff @(posedge clk_pix or posedge rst_pix) begin
        if (rst_pix)              ping_pong_rd <= 1'b0;
        else if (line_start_pix)  ping_pong_rd <= ~ping_pong_rd;
    end

    // ====================================================================
    // Fetch line counter (clk_sys)
    // ====================================================================
    // Increments on every line_start_sys (one per scanline including
    // blanking).  Wraps at V_ACTIVE so subsequent vblank line_starts
    // re-fetch line 0 — harmless duplicate work, simpler bookkeeping.
    logic [10:0] fetch_line;
    logic        line_pending;          // 1 = there's a fetch to do
    logic        fetch_done;             // 1-cycle pulse when a line finishes

    always_ff @(posedge clk_sys or posedge rst_sys) begin
        if (rst_sys) begin
            fetch_line   <= 11'd0;
            line_pending <= 1'b1;       // pre-fetch line 0 after reset
        end else begin
            if (line_start_sys) begin
                fetch_line   <= (fetch_line == V_ACTIVE - 1) ? 11'd0
                                                              : fetch_line + 11'd1;
                line_pending <= 1'b1;
            end else if (fetch_done) begin
                line_pending <= 1'b0;
            end
        end
    end

    // ====================================================================
    // AXI fetch FSM (clk_sys)
    // ====================================================================
    // 64 × 16-beat bursts per line.  burst_idx[5:0] counts bursts; wr_idx
    // accumulates 16 beats per burst × 64 bursts = 1024 entries per line.

    localparam int BURSTS_PER_LINE = 64;
    localparam int BEATS_PER_BURST = 16;

    typedef enum logic [1:0] {
        S_IDLE      = 2'd0,
        S_ISSUE_AR  = 2'd1,
        S_RECV_R    = 2'd2,
        S_LINE_DONE = 2'd3
    } state_t;
    state_t state;

    logic [5:0]  burst_idx;             // 0..63

    // Address: FB_BASE + (fetch_line << 13) + (burst_idx << 7)
    wire [31:0] burst_addr = FB_BASE
                           + (32'(fetch_line) << 13)
                           + (32'(burst_idx)  << 7);

    assign m_axi_arsize  = 3'b011;      // 8 bytes / beat (64-bit)
    assign m_axi_arburst = 2'b01;       // INCR
    assign m_axi_arlen   = 8'd15;       // 16 beats
    assign m_axi_rready  = 1'b1;        // always ready — line_buf accepts every beat

    always_ff @(posedge clk_sys or posedge rst_sys) begin
        if (rst_sys) begin
            state         <= S_IDLE;
            burst_idx     <= 6'd0;
            wr_idx        <= 10'd0;
            wr_en         <= 1'b0;
            fetch_done    <= 1'b0;
            m_axi_arvalid <= 1'b0;
            m_axi_araddr  <= 32'd0;
            ping_pong_wr  <= 1'b0;
        end else begin
            wr_en      <= 1'b0;
            fetch_done <= 1'b0;

            unique case (state)
                S_IDLE: begin
                    if (line_pending && enable) begin
                        burst_idx     <= 6'd0;
                        wr_idx        <= 10'd0;
                        m_axi_araddr  <= burst_addr;       // burst_idx = 0
                        m_axi_arvalid <= 1'b1;
                        state         <= S_ISSUE_AR;
                    end
                end

                S_ISSUE_AR: begin
                    if (m_axi_arready) begin
                        m_axi_arvalid <= 1'b0;
                        state         <= S_RECV_R;
                    end
                end

                S_RECV_R: begin
                    if (m_axi_rvalid) begin
                        wr_en  <= 1'b1;
                        wr_idx <= wr_idx + 10'd1;
                        if (m_axi_rlast) begin
                            if (burst_idx == BURSTS_PER_LINE - 1) begin
                                state <= S_LINE_DONE;
                            end else begin
                                burst_idx     <= burst_idx + 6'd1;
                                m_axi_araddr  <= FB_BASE
                                                + (32'(fetch_line) << 13)
                                                + (32'(burst_idx + 6'd1) << 7);
                                m_axi_arvalid <= 1'b1;
                                state         <= S_ISSUE_AR;
                            end
                        end
                    end
                end

                S_LINE_DONE: begin
                    ping_pong_wr <= ~ping_pong_wr;
                    fetch_done   <= 1'b1;
                    state        <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    // ====================================================================
    // Output stage (clk_pix) — RGBA-8888 → RGB565 with 4×4 Bayer dither
    // ====================================================================
    // Layout: pixel[31:24] = R, [23:16] = G, [15:8] = B, [7:0] = A.
    // Alpha is dropped at scan-out (the framebuffer is the final
    // composited surface).
    //
    // Bayer ordered dither: add a small position-dependent offset before
    // truncating, then saturate at the max code.  Kills the visible
    // banding that pure truncation would leave when downsampling 24-bit
    // colour to 16-bit RGB565.  A custom-board variant that wires all
    // 24 RGB lanes to the SiI9022A would skip this stage and pass 8888
    // through as RGB888 — parameterise OUT_FMT here when that lands.
    //
    // Phase alignment: rd_word_q / rd_lsb_q (and therefore rd_pixel) lag
    // h_count by one cycle due to BRAM read latency.  Delay de / hsync /
    // vsync and the dither row/col index by the matching cycle so
    // everything lines up with the pixel.
    logic       de_q, hsync_q, vsync_q;
    logic [1:0] dither_row_q, dither_col_q;
    always_ff @(posedge clk_pix or posedge rst_pix) begin
        if (rst_pix) begin
            de_q         <= 1'b0;
            hsync_q      <= 1'b0;
            vsync_q      <= 1'b0;
            dither_row_q <= 2'd0;
            dither_col_q <= 2'd0;
        end else begin
            de_q         <= de_pix;
            hsync_q      <= hsync_pix;
            vsync_q      <= vsync_pix;
            dither_row_q <= v_count[1:0];
            dither_col_q <= h_count[1:0];
        end
    end

    // Classic 4×4 Bayer matrix (0..15) packed into a function for
    // synthesis-friendly LUT inference.
    function automatic [3:0] bayer4 (input logic [1:0] row, input logic [1:0] col);
        case ({row, col})
            4'd0:  bayer4 = 4'd0;   4'd1:  bayer4 = 4'd8;
            4'd2:  bayer4 = 4'd2;   4'd3:  bayer4 = 4'd10;
            4'd4:  bayer4 = 4'd12;  4'd5:  bayer4 = 4'd4;
            4'd6:  bayer4 = 4'd14;  4'd7:  bayer4 = 4'd6;
            4'd8:  bayer4 = 4'd3;   4'd9:  bayer4 = 4'd11;
            4'd10: bayer4 = 4'd1;   4'd11: bayer4 = 4'd9;
            4'd12: bayer4 = 4'd15;  4'd13: bayer4 = 4'd7;
            4'd14: bayer4 = 4'd13;  4'd15: bayer4 = 4'd5;
            default: bayer4 = 4'd0;
        endcase
    endfunction
    wire [3:0] bayer_xy = bayer4(dither_row_q, dither_col_q);

    wire [7:0] r8 = rd_pixel[31:24];
    wire [7:0] g8 = rd_pixel[23:16];
    wire [7:0] b8 = rd_pixel[15:8];

    // R8 → R5: lose 3 bits.  Dither offset 0..7 added to R8 in bottom
    // 3 bits' worth of precision, saturate at 0xFF, then take top 5 bits.
    wire [8:0] r_sum = {1'b0, r8} + {6'd0, bayer_xy[3:1]};      // +0..7
    wire [4:0] r5    = r_sum[8] ? 5'h1F : r_sum[7:3];

    // G8 → G6: lose 2 bits.  Dither offset 0..3 (top 2 bits of bayer).
    wire [8:0] g_sum = {1'b0, g8} + {7'd0, bayer_xy[3:2]};      // +0..3
    wire [5:0] g6    = g_sum[8] ? 6'h3F : g_sum[7:2];

    // B8 → B5: same as R.
    wire [8:0] b_sum = {1'b0, b8} + {6'd0, bayer_xy[3:1]};
    wire [4:0] b5    = b_sum[8] ? 5'h1F : b_sum[7:3];

    // ====================================================================
    // Bring-up Phase 2 — colour-bar test pattern (TEST_PATTERN = 1)
    // ====================================================================
    // 8 vertical colour bars (100 %-saturated SMPTE-ish ordering: white /
    // yellow / cyan / green / magenta / red / blue / black).  Each bar is
    // 256 pixels wide; the right-most bar is narrower (1792..1919) which
    // is fine for confirming the RGB565 bit wiring is correct.  h_count_q
    // delays h_count by one cycle to align with de_q (which is itself
    // delayed by one cycle for line-buffer phase alignment above).
    logic [11:0] h_count_q;
    always_ff @(posedge clk_pix or posedge rst_pix)
        if (rst_pix) h_count_q <= '0;
        else         h_count_q <= h_count;

    wire  [2:0] bar_idx = h_count_q[10:8];
    logic [4:0] pattern_r;
    logic [5:0] pattern_g;
    logic [4:0] pattern_b;
    always_comb begin
        unique case (bar_idx)
            3'd0: {pattern_r, pattern_g, pattern_b} = {5'h1F, 6'h3F, 5'h1F}; // white
            3'd1: {pattern_r, pattern_g, pattern_b} = {5'h1F, 6'h3F, 5'h00}; // yellow
            3'd2: {pattern_r, pattern_g, pattern_b} = {5'h00, 6'h3F, 5'h1F}; // cyan
            3'd3: {pattern_r, pattern_g, pattern_b} = {5'h00, 6'h3F, 5'h00}; // green
            3'd4: {pattern_r, pattern_g, pattern_b} = {5'h1F, 6'h00, 5'h1F}; // magenta
            3'd5: {pattern_r, pattern_g, pattern_b} = {5'h1F, 6'h00, 5'h00}; // red
            3'd6: {pattern_r, pattern_g, pattern_b} = {5'h00, 6'h00, 5'h1F}; // blue
            3'd7: {pattern_r, pattern_g, pattern_b} = {5'h00, 6'h00, 5'h00}; // black
        endcase
    end

    // TEST_PATTERN is a build-time constant; the unused branch synthesises
    // away to nothing.  AXI HP master continues to issue reads when
    // TEST_PATTERN=1 (responses get latched but ignored) — keeps the path
    // active for separate validation.
    wire [4:0] out_r5 = TEST_PATTERN ? pattern_r : r5;
    wire [5:0] out_g6 = TEST_PATTERN ? pattern_g : g6;
    wire [4:0] out_b5 = TEST_PATTERN ? pattern_b : b5;

    assign rgb_r      = de_q ? out_r5 : 5'd0;
    assign rgb_g      = de_q ? out_g6 : 6'd0;
    assign rgb_b      = de_q ? out_b5 : 5'd0;
    assign rgb_hsync  = hsync_q;
    assign rgb_vsync  = vsync_q;
    assign rgb_de     = de_q;
    assign rgb_pixclk = clk_pix;

endmodule

`default_nettype wire
