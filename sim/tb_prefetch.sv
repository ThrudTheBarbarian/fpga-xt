// tb_prefetch.sv — M4 line-buffer prefetch loop closes.
//
// Pre-populates the RP-side mock framebuffer with a per-atari-row
// constant pattern (`fb[r * 1024 + x] = r[7:0]` for x in [0, 384)).
// Then runs vbeam for 2 frames at 640×480@60. The prefetch fills the
// line buffer's off-bank with each atari row's data; scan-out reads
// the on-bank and drives pix_r/g/b.
//
// Verification: during atari row r's active scan, pix_r should equal
// r[7:0] at every native pixel. (No palette LUT yet at M4.)
//
// Single clock domain at pix_clk = 25.175 MHz — bus_clk and rp_*_clk
// are merged for sim simplicity. M19 adds proper CDC.

`default_nettype none
`timescale 1ns / 1ps

`include "bus_opcodes.vh"

module tb_prefetch;

    // Single sim clock at 25.175 MHz.
    logic clk = 1'b0;
    always #19.860 clk = ~clk;

    logic rst = 1'b1;

    // ---- Vbeam ----------------------------------------------------------
    wire [11:0] h_count, v_count;
    wire        in_active, h_active, v_active;
    wire        hsync, vsync, de;
    wire        line_start, frame_start, vbi_start;
    wire [15:0] atari_row;
    wire [7:0]  vcount;

    vbeam u_vbeam (
        .clk_pix     (clk),
        .rst         (rst),
        .h_count     (h_count),
        .v_count     (v_count),
        .in_active   (in_active),
        .h_active    (h_active),
        .v_active    (v_active),
        .hsync       (hsync),
        .vsync       (vsync),
        .de          (de),
        .line_start  (line_start),
        .frame_start (frame_start),
        .vbi_start   (vbi_start),
        .atari_row   (atari_row),
        .vcount      (vcount)
    );

    // ---- Line buffer ----------------------------------------------------
    localparam int LB_WIDTH    = 384;
    localparam int LB_PAIR_AW  = 8;     // ceil(log2(192))
    localparam int LB_RD_AW    = 9;     // ceil(log2(384))

    wire                  lb_swap;
    wire                  lb_wr_en;
    wire [LB_PAIR_AW-1:0] lb_wr_addr;
    wire [15:0]           lb_wr_data;
    wire [LB_RD_AW-1:0]   lb_rd_addr;
    wire [7:0]            lb_rd_data;

    line_buffer #(.WIDTH(LB_WIDTH)) u_line_buffer (
        .clk      (clk),
        .rst      (rst),
        .wr_en    (lb_wr_en),
        .wr_addr  (lb_wr_addr),
        .wr_data  (lb_wr_data),
        .rd_addr  (lb_rd_addr),
        .rd_data  (lb_rd_data),
        .swap     (lb_swap)
    );

    // ---- rp_tx / rp_rx / rp_bus_mock ------------------------------------
    wire [1:0]  cmd_tag;
    wire [23:0] cmd_addr;
    wire [15:0] cmd_data;
    wire        cmd_valid;
    wire        cmd_ready;
    wire [15:0] rsp_data;
    wire        rsp_data_valid;
    wire        rsp_pop;

    wire [1:0]  bus_tag;
    wire [23:0] bus_payload;
    wire [15:0] mock_rsp_payload;
    wire        mock_rsp_valid;
    wire [31:0] tx_set_misalign_count;
    wire [31:0] mock_fetch_count, mock_set_count, mock_draw_count;
    wire [31:0] mock_bad_tag_count, mock_set_misalign_count;
    wire [31:0] rx_drop_count;

    rp_tx u_tx (
        .clk                   (clk),
        .rst                   (rst),
        .cmd_tag               (cmd_tag),
        .cmd_addr              (cmd_addr),
        .cmd_data              (cmd_data),
        .cmd_valid             (cmd_valid),
        .cmd_ready             (cmd_ready),
        .bus_tag               (bus_tag),
        .bus_payload           (bus_payload),
        .tx_set_misalign_count (tx_set_misalign_count)
    );

    // For sim speed, allocate only enough FB to cover the validated
    // rows. Atari rows beyond N_FB_ROWS get FETCHes that the mock
    // returns as 0 (out-of-range), and we restrict verification to
    // rows 0..N_FB_ROWS-1.
    localparam int FB_ROW_STRIDE = 1024;
    localparam int N_FB_ROWS     = 32;
    localparam int FB_BYTES      = N_FB_ROWS * FB_ROW_STRIDE;

    rp_bus_mock #(
        .FB_BYTES      (FB_BYTES),
        .FETCH_LATENCY (4)
    ) u_mock (
        .clk                     (clk),
        .rst                     (rst),
        .bus_tag                 (bus_tag),
        .bus_payload             (bus_payload),
        .rsp_payload             (mock_rsp_payload),
        .rsp_valid               (mock_rsp_valid),
        .mock_fetch_count        (mock_fetch_count),
        .mock_set_count          (mock_set_count),
        .mock_draw_count         (mock_draw_count),
        .mock_bad_tag_count      (mock_bad_tag_count),
        .mock_set_misalign_count (mock_set_misalign_count)
    );

    rp_rx u_rx (
        .clk           (clk),
        .rst           (rst),
        .bus_payload   (mock_rsp_payload),
        .bus_valid     (mock_rsp_valid),
        .rsp_data      (rsp_data),
        .rsp_valid     (rsp_data_valid),
        .rsp_pop       (rsp_pop),
        .rx_drop_count (rx_drop_count)
    );

    // ---- Prefetch -------------------------------------------------------
    prefetch #(
        .FB_ROW_STRIDE   (FB_ROW_STRIDE),
        .LB_WIDTH        (LB_WIDTH),
        .LB_PAIR_AW      (LB_PAIR_AW),
        .FB_ADDR_W       (24)
    ) u_prefetch (
        .clk             (clk),
        .rst             (rst),
        .vbi_start       (vbi_start),
        .atari_row       (atari_row),
        .prefetch_offset (16'h0),         // M4 stub: no LMS slide / HSCROL margin
        .cmd_tag         (cmd_tag),
        .cmd_addr        (cmd_addr),
        .cmd_data        (cmd_data),
        .cmd_valid       (cmd_valid),
        .cmd_ready       (cmd_ready),
        .rsp_data        (rsp_data),
        .rsp_valid       (rsp_data_valid),
        .rsp_pop         (rsp_pop),
        .lb_wr_en        (lb_wr_en),
        .lb_wr_addr      (lb_wr_addr),
        .lb_wr_data      (lb_wr_data),
        .swap            (lb_swap)
    );

    // ---- Scan-out -------------------------------------------------------
    wire [7:0] pix_r, pix_g, pix_b;
    wire       pix_de, pix_hsync, pix_vsync;

    scan_out #(
        .LB_RD_AW  (LB_RD_AW)
    ) u_scan_out (
        .clk_pix     (clk),
        .rst         (rst),
        .in_active   (in_active),
        .h_active    (h_active),
        .hsync       (hsync),
        .vsync       (vsync),
        .h_count     (h_count),
        .line_hscrol (4'h0),               // M4 stub
        .lb_rd_addr  (lb_rd_addr),
        .lb_rd_data  (lb_rd_data),
        .pix_r       (pix_r),
        .pix_g       (pix_g),
        .pix_b       (pix_b),
        .pix_de      (pix_de),
        .pix_hsync   (pix_hsync),
        .pix_vsync   (pix_vsync)
    );

    // ---- Backdoor populate of mock framebuffer --------------------------
    // The mock's own initial block zeros fb at sim-start. We schedule the
    // populate one delta-time later so the zeroing finishes first.
    initial begin
        #1;
        for (int r = 0; r < N_FB_ROWS; r++) begin
            for (int x = 0; x < FB_ROW_STRIDE; x++) begin
                u_mock.fb[r * FB_ROW_STRIDE + x] = r[7:0];
            end
        end
        $display("[prefetch] FB populated: %0d rows × %0d bytes = %0d bytes",
                 N_FB_ROWS, FB_ROW_STRIDE, FB_BYTES);
    end

    // ---- Verification ---------------------------------------------------
    int fail_count        = 0;
    int verified_pixels   = 0;
    int frame_count       = 0;
    logic [7:0] last_atari_row_seen [0:1];     // most recent atari row for {frame=0, frame=1}

    // Sample pix_r at each pix_clk during the active region. Expected
    // value: low byte of the current atari row index. Scan-out has a
    // 1-cycle latency from h_count to pix_r.
    //
    // Frame 0 is bootstrap: prefetch's first vbi_start arrives at the
    // END of frame 0's visible region, so frame 0's data is invalid
    // (line buffer banks unwritten). Skip frame 0; verify frame 1+.
    // Skip the first 4 native pixels of each scanline. The line_buffer
    // has a 2-cycle pipeline (rd_word + rd_hi_q registers) and the
    // bank_select swap is itself registered, so at the start of each
    // atari row the pix_r output reflects the previous bank for ~3
    // pixels until the pipeline fills with new-bank data. Production
    // (M19+) shrinks line_buffer's read latency to 0 cycles via a
    // combinational read; until then the testbench masks the leading
    // edge.
    always @(posedge clk) begin
        if (!rst && pix_de && frame_count >= 1 && h_count > 12'd4) begin
            if (atari_row !== 16'hFFFF && atari_row < N_FB_ROWS) begin
                if (pix_r !== atari_row[7:0]) begin
                    if (fail_count < 16) begin
                        $display("FAIL pix_r mismatch: frame=%0d atari_row=%0d, h_count=%0d, got pix_r=$%02h, expected $%02h",
                                 frame_count, atari_row, h_count, pix_r, atari_row[7:0]);
                    end
                    fail_count++;
                end
                verified_pixels++;
            end
        end
    end

    // ---- Main test sequence ---------------------------------------------
    initial begin
        $display("[prefetch] start");
        repeat (4) @(posedge clk);
        rst = 1'b0;

        // Run for 2 full frames. 640x480@60: 525 lines × 800 px = 420000 cycles per frame.
        wait (frame_count == 2);

        // Drain pipeline.
        repeat (1000) @(posedge clk);

        // Sanity: we should have verified roughly 2 × 240 atari rows × 320 visible
        // pix_clks × 2 native scanlines per atari row = ~307200 pixels per frame
        // × 2 frames = ~614 K. Allow some slack — what we want is a meaningful
        // sample size, not exact alignment.
        // Frame 1 contributes 32 atari rows × 320 visible × 2 native = 20480
        // verified pixels (less than the full 245760 because we only
        // populated 32 of the 192 atari rows). Allow some slack.
        if (verified_pixels < 10_000) begin
            $display("FAIL: only %0d pixels verified, expected ≥ 10K",
                     verified_pixels);
            fail_count++;
        end
        if (mock_bad_tag_count != 32'h0) begin
            $display("FAIL: mock_bad_tag_count=%0d", mock_bad_tag_count); fail_count++;
        end
        if (rx_drop_count != 32'h0) begin
            $display("FAIL: rx_drop_count=%0d", rx_drop_count); fail_count++;
        end
        if (tx_set_misalign_count != 32'h0) begin
            $display("FAIL: tx_set_misalign_count=%0d", tx_set_misalign_count);
            fail_count++;
        end

        if (fail_count == 0) begin
            $display("*** PREFETCH OK *** verified %0d pixels across %0d frames; mock_fetches=%0d",
                     verified_pixels, frame_count, mock_fetch_count);
            $finish;
        end else begin
            $display("*** PREFETCH FAIL *** %0d failures (verified %0d pixels, mock_fetches=%0d)",
                     fail_count, verified_pixels, mock_fetch_count);
            $fatal(1);
        end
    end

    // Frame counter.
    always @(posedge clk) begin
        if (!rst && frame_start) frame_count++;
    end

    // Watchdog.
    initial begin
        #50_000_000;
        $display("FAIL: tb_prefetch watchdog expired (frame_count=%0d, verified_pixels=%0d)",
                 frame_count, verified_pixels);
        $fatal(1);
    end

endmodule

`default_nettype wire
