// tb_plane_vscale.sv — integration test for the scan-out VERTICAL row addressing
// at scale 3 (the real XL-plane config), reproducing the on-HW symptoms:
//   * a wrong/garbage line at the TOP of the window,
//   * content/blank alternation,
//   * a shifted last line / tearing at the BASE.
//
// vbeam -> plane_compositor (accumulator + prefetch) -> real plane_fetch
// (ping-pong + AXI) -> axi_slave_mem.  The XL plane (plane 1) is scale 3,
// clipped vertically to [CY0, CY1).  Source row r is seeded so its pixels carry
// rgb_r == r+1 (1..SRC_H), distinct per row; the border (plane 0) carries a
// fixed value.  We capture the displayed rgb_r for every output line and assert
// that line v in [CY0, CY1) shows src_row floor((v-CY0)/3) — i.e. each source
// row spans exactly its 3 output lines, none dropped, duplicated or offset, and
// no border/garbage bleeds into the window.

`default_nettype none
`timescale 1ns / 1ps

module tb_plane_vscale #(
    // DDR read-latency model (override from iverilog with
    // -Ptb_plane_vscale.RD_LAT=N -Ptb_plane_vscale.RD_LAT_JIT=M).  RD_LAT=0
    // is the original zero-latency memory.  Cranking these emulates real
    // PL->DDR read latency + arbiter/writeback contention, the conditions
    // under which a per-line fetch can finish late and the ping-pong read
    // half is served stale/partial (the on-HW row-128 rainbow-dash line).
    parameter int RD_LAT     = 0,
    parameter int RD_LAT_JIT = 0,
    // Geometry is parameterised so the same tb runs as a PESSIMISTIC stress
    // case (default: tiny line, fetch fills it) AND a REALISTIC-margin case
    // (large H_BP: fetch completes early in the line, like HW).  Override with
    // -Ptb_plane_vscale.H_ACTIVE=.. -Ptb_plane_vscale.SRC_W=.. -Ptb_plane_vscale.H_BP=..
    parameter int H_ACTIVE   = 16,
    parameter int SRC_W      = 16,
    parameter int H_BP       = 2          // horizontal back porch (line slack)
);

    localparam int V_ACTIVE = 30;
    localparam int SCALE    = 3;
    localparam int CY0      = 6;          // window top  (origin_y)
    localparam int SRC_H    = 6;          // source rows 0..5
    localparam int CY1      = CY0 + SRC_H*SCALE;   // 24, exclusive
    localparam [31:0] BASE  = 32'h0000_1000;
    localparam [15:0] STRIDE= 16'(SRC_W*4);

    logic clk_pix = 1'b0; always #5 clk_pix = ~clk_pix;
    logic clk_sys = 1'b0; always #3 clk_sys = ~clk_sys;
    logic rst_pix = 1'b1, rst_sys = 1'b1;

    // ---- raster ----------------------------------------------------------
    wire [11:0] h_count, v_count;
    wire        de, hsync, vsync, line_start, frame_start;
    vbeam #(
        .H_ACTIVE (H_ACTIVE), .H_FRONT_PORCH (2), .H_SYNC_WIDTH (4), .H_BACK_PORCH (H_BP),
        .V_ACTIVE (V_ACTIVE), .V_FRONT_PORCH (1), .V_SYNC_WIDTH (2), .V_BACK_PORCH (2),
        .ANTIC_LINES_NATIVE (V_ACTIVE)
    ) u_vbeam (
        .clk_pix (clk_pix), .rst (rst_pix),
        .h_count (h_count), .v_count (v_count),
        .in_active (de), .h_active (), .v_active (),
        .hsync (hsync), .vsync (vsync), .de (),
        .line_start (line_start), .frame_start (frame_start),
        .vbi_start (), .atari_row (), .vcount ()
    );

    // ---- plane config: plane0 = bg full-screen scale1; plane1 = XL scale3 ---
    localparam int N = 2;
    wire [N-1:0]    pl_enable   = 2'b11;
    wire [N*12-1:0] pl_origin_x = {12'd0,  12'd0};
    wire [N*12-1:0] pl_origin_y = {12'(CY0), 12'd0};
    wire [N*3-1:0]  pl_scale    = {3'(SCALE), 3'd1};
    wire [N*4-1:0]  pl_depth    = {4'd1,   4'd0};
    wire [N*12-1:0] pl_clip_x0  = {12'd0,  12'd0};
    wire [N*12-1:0] pl_clip_y0  = {12'(CY0), 12'd0};
    wire [N*12-1:0] pl_clip_x1  = {12'(H_ACTIVE), 12'(H_ACTIVE)};
    wire [N*12-1:0] pl_clip_y1  = {12'(CY1), 12'(V_ACTIVE)};
    wire [23:0]     bg_color    = 24'h00_00_00;

    wire [N*12-1:0] src_col_o, src_row_o, src_row_next_o;
    logic [N*32-1:0] src_pixel_i;

    wire [4:0] rgb_r; wire [5:0] rgb_g; wire [4:0] rgb_b;
    wire       de_o, hsync_o, vsync_o;

    plane_compositor #(.N_PLANES(N), .H_ACTIVE(H_ACTIVE), .V_ACTIVE(V_ACTIVE)) u_cmp (
        .clk_pix (clk_pix), .rst_pix (rst_pix),
        .h_count (h_count), .v_count (v_count),
        .de (de), .hsync (hsync), .vsync (vsync), .line_start (line_start),
        .pl_enable (pl_enable), .pl_origin_x (pl_origin_x), .pl_origin_y (pl_origin_y),
        .pl_scale (pl_scale), .pl_depth (pl_depth),
        .pl_clip_x0 (pl_clip_x0), .pl_clip_y0 (pl_clip_y0),
        .pl_clip_x1 (pl_clip_x1), .pl_clip_y1 (pl_clip_y1),
        .bg_color (bg_color),
        .src_col_o (src_col_o), .src_row_o (src_row_o),
        .src_row_next_o (src_row_next_o), .src_pixel_i (src_pixel_i),
        .rgb_r (rgb_r), .rgb_g (rgb_g), .rgb_b (rgb_b),
        .de_o (de_o), .hsync_o (hsync_o), .vsync_o (vsync_o)
    );

    // plane 0 (bg): constant marker pixel (rgb_r = 0x1F so it's distinct from
    // any in-window source row 1..6).
    wire [31:0] bg_pixel = 32'hF8_00_00_00;   // R=0xF8 -> rgb_r 0x1F

    // plane 1 (XL): real plane_fetch reading the seeded DDR surface.
    wire [31:0] araddr; wire [7:0] arlen; wire [2:0] arsize; wire [1:0] arburst;
    wire        arvalid, arready, rvalid, rlast, rready; wire [63:0] rdata;
    wire [31:0] xl_pixel;

    // fetch_row = NEXT-line source row for plane 1 (the prefetch hint).
    wire [11:0] xl_fetch_row = src_row_next_o[1*12 +: 12];

    plane_fetch u_fetch (
        .clk_sys (clk_sys), .rst_sys (rst_sys), .enable (1'b1),
        .surface_base (BASE), .stride_bytes (STRIDE), .src_w (SRC_W[11:0]),
        .m_axi_araddr (araddr), .m_axi_arlen (arlen), .m_axi_arsize (arsize),
        .m_axi_arburst (arburst), .m_axi_arvalid (arvalid), .m_axi_arready (arready),
        .m_axi_rdata (rdata), .m_axi_rvalid (rvalid), .m_axi_rlast (rlast),
        .m_axi_rready (rready),
        .clk_pix (clk_pix), .rst_pix (rst_pix),
        .line_start (line_start), .fetch_row (xl_fetch_row),
        .rd_col (src_col_o[1*12 +: 12]), .rd_pixel (xl_pixel)
    );

    assign src_pixel_i = {xl_pixel, bg_pixel};

    axi_slave_mem #(.RD_LAT(RD_LAT), .RD_LAT_JIT(RD_LAT_JIT)) u_mem (
        .clk (clk_sys), .rst (rst_sys),
        .s_axi_awaddr (32'd0), .s_axi_awlen (8'd0), .s_axi_awsize (3'd0),
        .s_axi_awburst (2'd0), .s_axi_awvalid (1'b0), .s_axi_awready (),
        .s_axi_wdata (64'd0), .s_axi_wstrb (8'd0), .s_axi_wlast (1'b0),
        .s_axi_wvalid (1'b0), .s_axi_wready (), .s_axi_bvalid (), .s_axi_bready (1'b1),
        .s_axi_araddr (araddr), .s_axi_arlen (arlen), .s_axi_arsize (arsize),
        .s_axi_arburst (arburst), .s_axi_arvalid (arvalid), .s_axi_arready (arready),
        .s_axi_rdata (rdata), .s_axi_rvalid (rvalid), .s_axi_rlast (rlast),
        .s_axi_rready (rready)
    );

    // Seed source row r: rgb_r byte = (r+1)<<3  ->  composited rgb_r = r+1.
    task automatic seed_row(input int r);
        logic [31:0] a, p;
        for (int c = 0; c < SRC_W; c++) begin
            a = BASE + r*STRIDE + c*4;
            p = {8'(((r+1)<<3) & 8'hFF), 8'h00, 8'h00, 8'h00};   // {R,G,B,A} bytes
            u_mem.seed_byte(a+0, p[7:0]);   u_mem.seed_byte(a+1, p[15:8]);
            u_mem.seed_byte(a+2, p[23:16]); u_mem.seed_byte(a+3, p[31:24]);
        end
    endtask

    // capture displayed rgb_r per output line (output lags h_count by 2), PER
    // FRAME, so we can catch a line whose row ALTERNATES frame-to-frame (the
    // per-frame ping-pong-phase blend — invisible to a single-frame check).
    logic [11:0] v_d1, v_d2;
    always_ff @(posedge clk_pix) begin v_d1 <= v_count; v_d2 <= v_d1; end
    int frame_no = 0;
    always_ff @(posedge clk_pix) if (frame_start) frame_no <= frame_no + 1;
    logic [4:0] line_r [0:V_ACTIVE-1];      // latest frame (single-frame check)
    logic [4:0] line_a [0:V_ACTIVE-1];      // frame 5
    logic [4:0] line_b [0:V_ACTIVE-1];      // frame 6 (consecutive)
    logic       line_seen [0:V_ACTIVE-1];
    always_ff @(posedge clk_pix) begin
        if (de_o && v_d2 < V_ACTIVE[11:0] && h_count == 12'd8) begin
            line_r[v_d2]    <= rgb_r;
            line_seen[v_d2] <= 1'b1;
            if (frame_no == 5) line_a[v_d2] <= rgb_r;
            if (frame_no == 6) line_b[v_d2] <= rgb_r;
        end
    end

    // ---- ping-pong collision / overrun monitor --------------------------
    // collision = a fetch write beat lands in the half the scan-out is
    // CURRENTLY reading (ping_pong_wr == ping_pong_rd) — i.e. the read sees a
    // half mid-write -> partial/stale pixels (the rainbow-dash line).  This
    // is the wr/rd CDC catch-up window; a late (high-latency) fetch widens the
    // window of opportunity.  overrun = fetch still pending at the next line.
    int collision_cnt = 0;
    int overrun_cnt   = 0;
    always_ff @(posedge clk_sys) begin
        if (!rst_sys) begin
            if (u_fetch.wr_en && (u_fetch.wr_buf_q === u_fetch.rd_buf))
                collision_cnt <= collision_cnt + 1;
            if (u_fetch.fetch_overrun)
                overrun_cnt <= overrun_cnt + 1;
        end
    end

    int fail_count = 0;
    int exp_row, exp_r;
    initial begin
        $display("=== PLANE_VSCALE TEST (scale %0d, window [%0d,%0d), V_TOTAL parity matters) ===", SCALE, CY0, CY1);
        for (int i = 0; i < V_ACTIVE; i++) line_seen[i] = 1'b0;
        for (int r = 0; r < SRC_H; r++) seed_row(r);

        repeat (4) @(posedge clk_pix);
        rst_sys = 1'b0; rst_pix = 1'b0;
        repeat (9*(H_ACTIVE+8)*(V_ACTIVE+5)) @(posedge clk_pix);  // ~9 frames

        // (1) single-frame correctness (latest frame).
        for (int v = 0; v < V_ACTIVE; v++) begin
            if (!line_seen[v]) continue;
            if (v >= CY0 && v < CY1) begin
                exp_row = (v - CY0) / SCALE;
                exp_r   = exp_row + 1;
                if (line_r[v] !== exp_r[4:0]) begin
                    $display("FAIL line %0d (window): got rgb_r=%0d expected src_row=%0d (rgb_r=%0d)",
                             v, line_r[v], exp_row, exp_r);
                    fail_count++;
                end
            end else if (line_r[v] !== 5'h1F) begin
                $display("FAIL line %0d (border): got rgb_r=%0d expected bg(0x1F)", v, line_r[v]);
                fail_count++;
            end
        end

        // (2) PER-FRAME STABILITY: frame 5 vs frame 6 must be identical.  A
        // line that differs is one whose source row alternates frame-to-frame
        // -> the blend on HW (eye/camera averages the two rows).
        for (int v = 0; v < V_ACTIVE; v++) begin
            if (line_seen[v] && (line_a[v] !== line_b[v])) begin
                $display("FAIL line %0d ALTERNATES across frames: frame5=%0d frame6=%0d (the blend!)",
                         v, line_a[v], line_b[v]);
                fail_count++;
            end
        end

        $write("frame5: "); for (int v=0;v<V_ACTIVE;v++) $write("%0d ", line_a[v]); $write("\n");
        $write("frame6: "); for (int v=0;v<V_ACTIVE;v++) $write("%0d ", line_b[v]); $write("\n");

        $display("MONITOR: RD_LAT=%0d RD_LAT_JIT=%0d  collisions=%0d  overruns=%0d",
                 RD_LAT, RD_LAT_JIT, collision_cnt, overrun_cnt);

        if (fail_count == 0) $display("*** PLANE_VSCALE OK *** vertical addressing clean + frame-stable at scale %0d", SCALE);
        else                 $display("*** PLANE_VSCALE FAIL *** %0d issue(s)", fail_count);
        if (fail_count) $fatal(1); else $finish;
    end

    initial begin
        #20_000_000;
        $display("FAIL: tb_plane_vscale watchdog");
        $fatal(1);
    end

endmodule

`default_nettype wire
