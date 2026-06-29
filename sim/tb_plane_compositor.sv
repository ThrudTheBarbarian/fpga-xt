// tb_plane_compositor.sv — unit test for the multi-plane compositor core.
//
// Reduced raster (40x24 active, 48x29 total via vbeam) so a few frames are
// fast.  Two planes:
//   plane 0: full-screen background, scale 1, depth 0  -> solid blue
//   plane 1: window at screen (12,4)..(28,20), scale 2, depth 1, src 8x8
// Inside the window plane 1 wins (depth 1 > 0), so every window pixel also
// exercises the depth priority (plane 0 covers it too).  Mock frame stores
// feed the per-plane source interface with a 1-cycle registered read.
//
// Output is 2 clk_pix behind h_count (source read + output reg); the capture
// scoreboard tags each output with h/v delayed by 2 so probes are exact.

`default_nettype none
`timescale 1ns / 1ps

module tb_plane_compositor;

    localparam int H_ACTIVE = 40, V_ACTIVE = 24;

    logic clk_pix = 1'b0;
    always #5 clk_pix = ~clk_pix;
    logic rst_pix = 1'b1;

    // ---- raster ----------------------------------------------------------
    wire [11:0] h_count, v_count;
    wire        de, hsync, vsync, line_start, frame_start;

    vbeam #(
        .H_ACTIVE (40), .H_FRONT_PORCH (2), .H_SYNC_WIDTH (4), .H_BACK_PORCH (2),
        .V_ACTIVE (24), .V_FRONT_PORCH (1), .V_SYNC_WIDTH (2), .V_BACK_PORCH (2),
        .ANTIC_LINES_NATIVE (24)
    ) u_vbeam (
        .clk_pix (clk_pix), .rst (rst_pix),
        .h_count (h_count), .v_count (v_count),
        .in_active (de), .h_active (), .v_active (),
        .hsync (hsync), .vsync (vsync), .de (),
        .line_start (line_start), .frame_start (frame_start),
        .vbi_start (), .atari_row (), .vcount ()
    );

    // ---- plane config (2 planes) -----------------------------------------
    localparam int N = 2;
    wire [N-1:0]      pl_enable   = 2'b11;
    wire [N-1:0]      pl_alpha_en = 2'b10;   // plane 1 (window) alpha-blends; plane 0 opaque
    wire [N*12-1:0]   pl_origin_x = {12'd12, 12'd0};
    wire [N*12-1:0]   pl_origin_y = {12'd4,  12'd0};
    wire [N*3-1:0]    pl_scale    = {3'd2,   3'd1};
    wire [N*4-1:0]    pl_depth    = {4'd1,   4'd0};
    wire [N*12-1:0]   pl_clip_x0  = {12'd12, 12'd0};
    wire [N*12-1:0]   pl_clip_y0  = {12'd4,  12'd0};
    wire [N*12-1:0]   pl_clip_x1  = {12'd28, 12'd40};
    wire [N*12-1:0]   pl_clip_y1  = {12'd20, 12'd24};
    wire [23:0]       bg_color    = 24'h00_00_00;

    wire [N*12-1:0]   src_col_o, src_row_o, src_row_next_o;
    logic [N*32-1:0]  src_pixel_i;

    wire [4:0] rgb_r; wire [5:0] rgb_g; wire [4:0] rgb_b;
    wire       de_o, hsync_o, vsync_o;

    plane_compositor #(.N_PLANES(N), .H_ACTIVE(40), .V_ACTIVE(24)) u_dut (
        .clk_pix (clk_pix), .rst_pix (rst_pix),
        .h_count (h_count), .v_count (v_count),
        .de (de), .hsync (hsync), .vsync (vsync), .line_start (line_start),
        .pl_enable (pl_enable), .pl_alpha_en (pl_alpha_en),
        .pl_origin_x (pl_origin_x), .pl_origin_y (pl_origin_y),
        .pl_scale (pl_scale), .pl_depth (pl_depth),
        .pl_clip_x0 (pl_clip_x0), .pl_clip_y0 (pl_clip_y0),
        .pl_clip_x1 (pl_clip_x1), .pl_clip_y1 (pl_clip_y1),
        .bg_color (bg_color),
        .src_col_o (src_col_o), .src_row_o (src_row_o),
        .src_row_next_o (src_row_next_o), .src_pixel_i (src_pixel_i),
        .rgb_r (rgb_r), .rgb_g (rgb_g), .rgb_b (rgb_b),
        .de_o (de_o), .hsync_o (hsync_o), .vsync_o (vsync_o)
    );

    // ---- mock per-plane frame stores (1-cycle registered read) -----------
    logic [31:0] frame0 [0:63][0:63];   // background (scale 1)
    logic [31:0] frame1 [0:63][0:63];   // window source (8x8 used)
    logic [31:0] p0, p1;
    always_ff @(posedge clk_pix) begin
        p0 <= frame0[ src_row_o[0*12 +: 12] ][ src_col_o[0*12 +: 12] ];
        p1 <= frame1[ src_row_o[1*12 +: 12] ][ src_col_o[1*12 +: 12] ];
    end
    assign src_pixel_i = {p1, p0};

    // ---- capture scoreboard (output is now 4 clk behind: read + 3 pipe) ---
    logic [11:0] h_d1, h_d2, h_d3, h_d4, v_d1, v_d2, v_d3, v_d4;
    always_ff @(posedge clk_pix) begin
        h_d1 <= h_count; h_d2 <= h_d1; h_d3 <= h_d2; h_d4 <= h_d3;
        v_d1 <= v_count; v_d2 <= v_d1; v_d3 <= v_d2; v_d4 <= v_d3;
    end
    logic [15:0] cap [0:23][0:39];
    always_ff @(posedge clk_pix) begin
        if (de_o && v_d4 < 24 && h_d4 < 40)
            cap[v_d4][h_d4] <= {rgb_r, rgb_g, rgb_b};
    end

    // ---- src_row_next_o scoreboard: it must predict next line's src_row_o --
    // Sample mid-line (h_count==20, settled, v_count stable) per scanline.
    logic [11:0] cur_row0 [0:31], next_row0 [0:31];
    logic [11:0] cur_row1 [0:31], next_row1 [0:31];
    always_ff @(posedge clk_pix) begin
        if (h_count == 12'd20 && v_count < 24) begin
            cur_row0[v_count]  <= src_row_o[0*12 +: 12];
            next_row0[v_count] <= src_row_next_o[0*12 +: 12];
            cur_row1[v_count]  <= src_row_o[1*12 +: 12];
            next_row1[v_count] <= src_row_next_o[1*12 +: 12];
        end
    end

    int fail_count = 0;
    task automatic chk(input string label, input [11:0] x, input [11:0] y,
                       input [4:0] er, input [5:0] eg, input [4:0] eb);
        logic [15:0] got;
        got = cap[y][x];
        if (got !== {er, eg, eb}) begin
            $display("FAIL %s (%0d,%0d): got=%04h expected=%04h", label, x, y, got, {er,eg,eb});
            fail_count++;
        end
    endtask

    initial begin
        for (int r = 0; r < 64; r++)
            for (int c = 0; c < 64; c++) begin
                frame0[r][c] = 32'h00_00_F8_00;   // blue (R,G,B,A); plane 0 opaque (alpha ignored)
                frame1[r][c] = 32'hF8_00_00_FF;    // red, OPAQUE (a=FF) — default window pixel
            end
        frame1[0][0] = 32'hFF_FF_FF_FF;            // white  -> native (0,0), opaque
        frame1[7][7] = 32'h00_FF_00_FF;            // green  -> native (7,7), opaque
        frame1[2][2] = 32'hF8_00_00_80;            // red @ a=0x80 -> blends over plane 0 blue
        frame1[3][3] = 32'hF8_00_00_00;            // a=0 -> fully transparent, shows plane 0 blue
    end

    initial begin
        $display("=== PLANE_COMPOSITOR TEST ===");
        repeat (4) @(posedge clk_pix);
        rst_pix = 1'b0;
        // Run ~3 frames (48*29 each) so accumulators settle and cap fills.
        repeat (3*48*29) @(posedge clk_pix);

        // window corners + interior (plane 1, scale 2, depth wins over bg)
        chk("win TL",      12'd12, 12'd4,  5'h1F, 6'h3F, 5'h1F);  // white
        chk("win TL blk",  12'd13, 12'd5,  5'h1F, 6'h3F, 5'h1F);  // same 2x2 block
        chk("win BR",      12'd26, 12'd18, 5'h00, 6'h3F, 5'h00);  // green
        chk("win BR blk",  12'd27, 12'd19, 5'h00, 6'h3F, 5'h00);
        chk("win mid",     12'd20, 12'd10, 5'h1F, 6'h00, 5'h00);  // native(4,3)=red, opaque

        // alpha-blend: native(2,2) red @ a=0x80 over plane-0 blue -> purple.
        // r = 0 + 128*(248-0)/256 = 124 -> 565 [7:3]=0x0F; b = 248 + 128*(0-248)/256
        // = 124 -> [7:3]=0x0F; g = 0.  Screen (16,8)..(17,9) (scale 2).
        chk("blend",       12'd16, 12'd8,  5'h0F, 6'h00, 5'h0F);
        chk("blend blk",   12'd17, 12'd9,  5'h0F, 6'h00, 5'h0F);
        // fully transparent: native(3,3) a=0 -> plane-0 blue shows through.
        chk("transparent", 12'd18, 12'd10, 5'h00, 6'h00, 5'h1F);

        // background (plane 0) outside the window + at the clip edges
        chk("bg origin",   12'd0,  12'd0,  5'h00, 6'h00, 5'h1F);  // blue
        chk("bg left",     12'd11, 12'd4,  5'h00, 6'h00, 5'h1F);
        chk("bg right",    12'd28, 12'd4,  5'h00, 6'h00, 5'h1F);  // clip_x1 exclusive
        chk("bg above",    12'd12, 12'd3,  5'h00, 6'h00, 5'h1F);
        chk("bg below",    12'd12, 12'd20, 5'h00, 6'h00, 5'h1F);  // clip_y1 exclusive
        chk("bg corner",   12'd39, 12'd23, 5'h00, 6'h00, 5'h1F);

        // src_row_next_o[v] must equal src_row_o[v+1] (the prefetch contract).
        // plane 0 (scale 1, full screen): holds for every line.
        for (int v = 0; v <= 22; v++)
            if (next_row0[v] !== cur_row0[v+1]) begin
                $display("FAIL next-row p0 v=%0d: next=%0d cur[v+1]=%0d",
                         v, next_row0[v], cur_row0[v+1]);
                fail_count++;
            end
        // plane 1 (scale 2, window rows [4,20)): check entry line .. last
        // interior line, where both v and v+1 carry meaningful rows.
        for (int v = 3; v <= 18; v++)
            if (next_row1[v] !== cur_row1[v+1]) begin
                $display("FAIL next-row p1 v=%0d: next=%0d cur[v+1]=%0d",
                         v, next_row1[v], cur_row1[v+1]);
                fail_count++;
            end

        if (fail_count == 0) begin
            $display("*** PLANE_COMPOSITOR OK *** planes + depth + scale + clip");
            $finish;
        end else begin
            $display("*** PLANE_COMPOSITOR FAIL *** %0d failures", fail_count);
            $fatal(1);
        end
    end

    initial begin
        #5_000_000;
        $display("FAIL: tb_plane_compositor watchdog");
        $fatal(1);
    end

endmodule

`default_nettype wire
