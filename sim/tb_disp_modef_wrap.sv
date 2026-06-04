// tb_disp_modef_wrap.sv — reproduce the GR.8 (ANTIC mode F) right-edge
// horizontal-WRAP ghost in the DISPLAY path (plane_fetch + plane_compositor),
// with the DDR surface KNOWN-GOOD (seeded directly).
//
// Mirrors the real XL-plane config (scale 3, centred window, src_w-wide source,
// stride = src_w*4) at sim scale, with src_w chosen so n_bursts > 1 — the
// condition under which plane_fetch's stale-burst_idx bug fires (the existing
// tb_plane_fetch / tb_plane_vscale use src_w<=16 => n_bursts==1, which masks it).
//
// Root cause exercised: plane_fetch S_IDLE issues burst 0's AR using
//   m_axi_araddr <= burst_addr     (= row_base + burst_idx*BURST_BYTES)
// while burst_idx<=0 is a *non-blocking* assignment, so burst_addr still holds
// the PREVIOUS row's final burst_idx (= n_bursts-1).  Burst 0 therefore reads
// the LAST chunk of the row (the right edge) into the FIRST line-buffer words
// (the left edge) => the right-edge content ghosts onto the left of the line.
//
// Each source row r is seeded so GREEN = (r+1)<<2 (=> rgb_g recovers r+1, the
// source-row id) and RED = 0xF8 only on row RBAR's right-edge bar columns.  The
// test asserts no lit (RED) pixel appears in the LEFT half of any window line.

`default_nettype none
`timescale 1ns / 1ps

module tb_disp_modef_wrap;

    localparam int SCALE    = 3;
    localparam int SRC_W    = 64;                   // n_bursts = ceil(64/16) = 4 > 1
    localparam int SRC_H    = 8;
    localparam int WIN_W    = SRC_W * SCALE;        // 192
    localparam int WIN_H    = SRC_H * SCALE;        // 24
    localparam int H_ACTIVE = WIN_W + 40;
    localparam int V_ACTIVE = WIN_H + 12;
    localparam int CX0      = (H_ACTIVE - WIN_W) / 2;
    localparam int CX1      = CX0 + WIN_W;
    localparam int CY0      = (V_ACTIVE - WIN_H) / 2;
    localparam int CY1      = CY0 + WIN_H;

    localparam [31:0] BASE  = 32'h0000_1000;
    localparam [15:0] STRIDE= 16'(SRC_W*4);

    localparam int RBAR     = 3;                    // row carrying the right bar
    localparam int BAR_C0   = SRC_W - 14;           // bar src cols [SRC_W-14 .. SRC_W-1]

    logic clk_pix = 1'b0; always #5 clk_pix = ~clk_pix;
    logic clk_sys = 1'b0; always #3 clk_sys = ~clk_sys;
    logic rst_pix = 1'b1, rst_sys = 1'b1;

    wire [11:0] h_count, v_count;
    wire        de, hsync, vsync, line_start, frame_start;
    vbeam #(
        .H_ACTIVE (H_ACTIVE), .H_FRONT_PORCH (2), .H_SYNC_WIDTH (4), .H_BACK_PORCH (2),
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

    localparam int N = 2;
    wire [N-1:0]    pl_enable   = 2'b11;
    wire [N*12-1:0] pl_origin_x = {12'(CX0), 12'd0};
    wire [N*12-1:0] pl_origin_y = {12'(CY0), 12'd0};
    wire [N*3-1:0]  pl_scale    = {3'(SCALE), 3'd1};
    wire [N*4-1:0]  pl_depth    = {4'd1,   4'd0};
    wire [N*12-1:0] pl_clip_x0  = {12'(CX0), 12'd0};
    wire [N*12-1:0] pl_clip_y0  = {12'(CY0), 12'd0};
    wire [N*12-1:0] pl_clip_x1  = {12'(CX1), 12'(H_ACTIVE)};
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

    wire [31:0] bg_pixel = 32'h00_00_00_00;

    wire [31:0] araddr; wire [7:0] arlen; wire [2:0] arsize; wire [1:0] arburst;
    wire        arvalid, arready, rvalid, rlast, rready; wire [63:0] rdata;
    wire [31:0] xl_pixel;
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

    axi_slave_mem u_mem (
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

    task automatic seed_surface;
        logic [31:0] a; logic [7:0] rr;
        for (int r = 0; r < SRC_H; r++)
            for (int c = 0; c < SRC_W; c++) begin
                a  = BASE + r*STRIDE + c*4;
                rr = (r == RBAR && c >= BAR_C0) ? 8'hF8 : 8'h00;
                u_mem.seed_byte(a+0, 8'hFF);                  // A
                u_mem.seed_byte(a+1, 8'h00);                  // B
                u_mem.seed_byte(a+2, 8'(((r+1)<<2) & 8'hFF)); // G = (r+1)<<2 -> rgb_g==r+1
                u_mem.seed_byte(a+3, rr);                     // R = bar marker
            end
    endtask

    // Capture displayed pixels (output lags h_count by 2) on one stable frame.
    logic [11:0] v_d1, v_d2, h_d1, h_d2;
    always_ff @(posedge clk_pix) begin
        v_d1 <= v_count; v_d2 <= v_d1;
        h_d1 <= h_count; h_d2 <= h_d1;
    end
    logic [5:0] grn [0:V_ACTIVE-1][0:WIN_W-1];
    logic       lit [0:V_ACTIVE-1][0:WIN_W-1];
    logic       seen[0:V_ACTIVE-1];
    int         frame_no = 0;
    always_ff @(posedge clk_pix) if (frame_start) frame_no <= frame_no + 1;
    always_ff @(posedge clk_pix) begin
        if (frame_no == 4 && de_o && v_d2 < V_ACTIVE[11:0]
            && h_d2 >= CX0[11:0] && h_d2 < CX1[11:0]) begin
            int oc; oc = int'(h_d2) - CX0;
            grn[v_d2][oc] <= rgb_g;
            lit[v_d2][oc] <= (rgb_r != 5'd0);
            seen[v_d2]    <= 1'b1;
        end
    end

    int ghost = 0;
    initial begin
        $display("=== DISPLAY-PATH MODE-F RIGHT-EDGE WRAP (scale %0d, src_w %0d, n_bursts %0d) ===",
                 SCALE, SRC_W, (SRC_W+15)/16);
        $display("window cols [%0d,%0d) rows [%0d,%0d); right bar on src row %0d cols [%0d,%0d)",
                 CX0, CX1, CY0, CY1, RBAR, BAR_C0, SRC_W);
        for (int i = 0; i < V_ACTIVE; i++) seen[i] = 1'b0;
        seed_surface;

        repeat (4) @(posedge clk_pix);
        rst_sys = 1'b0; rst_pix = 1'b0;
        repeat (7*(H_ACTIVE+8)*(V_ACTIVE+5)) @(posedge clk_pix);   // ~7 frames

        for (int v = CY0; v < CY1; v++) begin
            int srow; string litcols;
            if (!seen[v]) continue;
            srow = (v - CY0) / SCALE;
            litcols = "";
            for (int oc = 0; oc < WIN_W; oc++)
                if (lit[v][oc]) begin
                    $sformat(litcols, "%s %0d(g=%0d)", litcols, oc, grn[v][oc]);
                    // any lit pixel in the LEFT half is a wrap of the right bar.
                    if (oc < WIN_W/2) ghost++;
                end
            $display("outline v=%0d (src row %0d): lit outcols:%s", v, srow, litcols);
        end

        $display("---- summary ----");
        $display("ghost (lit pixels in the LEFT half of any window line) = %0d", ghost);
        if (ghost == 0) begin
            $display("*** DISP_MODEF_WRAP OK *** no left-edge wrap of the right bar");
            $finish;
        end else begin
            $display("*** DISP_MODEF_WRAP FAIL *** right-edge bar ghosts onto the left (%0d px)", ghost);
            $fatal(1);
        end
    end

    initial begin
        #60_000_000;
        $display("FAIL: watchdog"); $fatal(1);
    end

endmodule

`default_nettype wire
