// tb_alpha_hole.sv — Route-A occlusion proof for the M6 plane-bind design.
//
// Question this answers: can a hardware plane (XL emulator video) be occluded
// by an ARBITRARY-shaped region of ordinary windows WITHOUT a per-plane
// clip-rect-list — using only the compositor's existing winner-over-runner
// alpha blend?  If yes, M6's occlusion ceiling is already in silicon and the
// clip-rect-list upgrade path is unnecessary.
//
// The arrangement is the INVERSE of the shipping one and is the whole of Route A:
//   plane 0 = desktop/gemd : FULL SCREEN, depth 1 (TOP), alpha_en = 1
//   plane 1 = XL           : clipped to the emulator window, depth 0 (BELOW), opaque
// gemd paints alpha=0 over the emulator window's work area (the "hole"); every
// ordinary window it composites on top is opaque (alpha=0xFF), so the visible
// XL region is exactly "hole minus the opaque pixels gemd drew" — per pixel,
// any shape.  Here the occluders carve an L: the window is (8,4)..(32,20), an
// opaque panel covers its right half x[20,32) and another its bottom-left
// y[14,20) of x[8,20) — leaving XL visible only in the top-left x[8,20) y[4,14).
//
// No RTL changes: this drives plane_compositor exactly as-is.  It proves the
// mechanism; the register-driven depth/alpha flip in fpga_xt_top is a separate
// (bitstream) step, de-risked once this passes.
//
// Output is 4 clk_pix behind h_count (source read + 3 pipe stages), matched by
// the h/v delay chain — same scoreboard discipline as tb_plane_compositor.

`default_nettype none
`timescale 1ns / 1ps

module tb_alpha_hole;

    localparam int H_ACTIVE = 40, V_ACTIVE = 24;

    logic clk_pix = 1'b0;
    always #5 clk_pix = ~clk_pix;
    logic rst_pix = 1'b1;

    // ---- raster ----------------------------------------------------------
    wire [11:0] h_count, v_count;
    wire        de, hsync, vsync, line_start, line_start_e, frame_start;

    vbeam #(
        .H_ACTIVE (40), .H_FRONT_PORCH (2), .H_SYNC_WIDTH (4), .H_BACK_PORCH (2),
        .V_ACTIVE (24), .V_FRONT_PORCH (1), .V_SYNC_WIDTH (2), .V_BACK_PORCH (2),
        .ANTIC_LINES_NATIVE (24)
    ) u_vbeam (
        .clk_pix (clk_pix), .rst (rst_pix),
        .h_count (h_count), .v_count (v_count),
        .in_active (de), .h_active (), .v_active (),
        .hsync (hsync), .vsync (vsync), .de (),
        .line_start (line_start), .line_start_e (line_start_e), .frame_start (frame_start),
        .vbi_start (), .atari_row (), .vcount ()
    );

    // ---- the emulator window rect (screen coords) ------------------------
    localparam int WX0 = 8, WY0 = 4, WX1 = 32, WY1 = 20;   // (8,4)..(32,20)

    // ---- plane config: {plane1=XL, plane0=desktop} -----------------------
    // depth: desktop 1 (TOP), XL 0 (BELOW) — the Route-A flip.
    // alpha_en: desktop blends (so its alpha=0 holes reveal XL); XL opaque.
    localparam int N = 2;
    wire [N-1:0]      pl_enable   = 2'b11;
    wire [N-1:0]      pl_alpha_en = 2'b01;             // {XL=0 opaque, desktop=1 blend}
    wire [N*12-1:0]   pl_origin_x = {12'(WX0), 12'd0}; // XL src col 0 lands at WX0; desktop at 0
    wire [N*12-1:0]   pl_origin_y = {12'(WY0), 12'd0};
    wire [N*3-1:0]    pl_scale    = {3'd1,   3'd1};
    wire [N*4-1:0]    pl_depth    = {4'd0,   4'd1};    // {XL back, desktop front}
    wire [N*12-1:0]   pl_clip_x0  = {12'(WX0), 12'd0}; // desktop = full screen; XL = window
    wire [N*12-1:0]   pl_clip_y0  = {12'(WY0), 12'd0};
    wire [N*12-1:0]   pl_clip_x1  = {12'(WX1), 12'd40};
    wire [N*12-1:0]   pl_clip_y1  = {12'(WY1), 12'd24};
    wire [23:0]       bg_color    = 24'h00_00_00;

    wire [N*12-1:0]   src_col_o, src_row_o, src_row_next_o;
    logic [N*32-1:0]  src_pixel_i;

    wire [4:0] rgb_r; wire [5:0] rgb_g; wire [4:0] rgb_b;
    wire       de_o, hsync_o, vsync_o;

    plane_compositor #(.N_PLANES(N), .H_ACTIVE(40), .V_ACTIVE(24)) u_dut (
        .clk_pix (clk_pix), .rst_pix (rst_pix),
        .h_count (h_count), .v_count (v_count),
        .de (de), .hsync (hsync), .vsync (vsync), .line_start (line_start), .line_start_e (line_start_e),
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
    logic [31:0] frame_desk [0:63][0:63];   // plane 0: full-screen desktop (RGBA)
    logic [31:0] frame_xl   [0:63][0:63];   // plane 1: XL window source (RGBA)
    logic [31:0] p0, p1;
    always_ff @(posedge clk_pix) begin
        p0 <= frame_desk[ src_row_o[0*12 +: 12] ][ src_col_o[0*12 +: 12] ];
        p1 <= frame_xl  [ src_row_o[1*12 +: 12] ][ src_col_o[1*12 +: 12] ];
    end
    assign src_pixel_i = {p1, p0};   // {plane1=XL, plane0=desktop}

    // ---- capture scoreboard (output 4 clk behind: read + 3 pipe) ---------
    logic [11:0] h_d1, h_d2, h_d3, h_d4, v_d1, v_d2, v_d3, v_d4;
    always_ff @(posedge clk_pix) begin
        h_d1 <= h_count; h_d2 <= h_d1; h_d3 <= h_d2; h_d4 <= h_d3;
        v_d1 <= v_count; v_d2 <= v_d1; v_d3 <= v_d2; v_d4 <= v_d3;
    end
    logic [15:0] cap [0:23][0:39];
    always_ff @(posedge clk_pix)
        if (de_o && v_d4 < 24 && h_d4 < 40)
            cap[v_d4][h_d4] <= {rgb_r, rgb_g, rgb_b};

    // ---- colours (RGBA8888) and their 565 truncations --------------------
    localparam [31:0] WALL = 32'h00_00_F8_FF;   // desktop wallpaper: blue, OPAQUE
    localparam [31:0] OCCL = 32'h80_80_80_FF;   // an ordinary window: grey, OPAQUE
    localparam [31:0] HOLE = 32'h00_00_00_00;   // alpha=0 -> reveal XL below
    localparam [31:0] XLPX = 32'h00_FF_00_FF;   // XL video: green, opaque
    // 565: wall b=F8>>3=1F ; grey r/b=80>>3=10, g=80>>2=20 ; xl g=FF>>2=3F
    localparam [15:0] C_WALL = {5'h00, 6'h00, 5'h1F};
    localparam [15:0] C_OCCL = {5'h10, 6'h20, 5'h10};
    localparam [15:0] C_XL   = {5'h00, 6'h3F, 5'h00};

    initial begin
        // desktop: opaque wallpaper everywhere...
        for (int r = 0; r < 64; r++)
            for (int c = 0; c < 64; c++)
                frame_desk[r][c] = WALL;
        // ...then punch the alpha=0 hole over the whole emulator work area...
        for (int y = WY0; y < WY1; y++)
            for (int x = WX0; x < WX1; x++)
                frame_desk[y][x] = HOLE;
        // ...then composite two OPAQUE occluder windows on top, carving an L so
        // the visible XL region (top-left, x[8,20) y[4,14)) is NON-rectangular:
        for (int y = WY0; y < WY1; y++)         // occluder A: right half x[20,32)
            for (int x = 20; x < WX1; x++)
                frame_desk[y][x] = OCCL;
        for (int y = 14; y < WY1; y++)          // occluder B: bottom-left y[14,20) x[8,20)
            for (int x = WX0; x < 20; x++)
                frame_desk[y][x] = OCCL;
        // XL source: solid green (window is 24x16; only the visible L shows).
        for (int r = 0; r < 64; r++)
            for (int c = 0; c < 64; c++)
                frame_xl[r][c] = XLPX;
    end

    int fail_count = 0;
    task automatic chk(input string label, input [11:0] x, input [11:0] y, input [15:0] exp);
        logic [15:0] got;
        got = cap[y][x];
        if (got !== exp) begin
            $display("FAIL %s (%0d,%0d): got=%04h expected=%04h", label, x, y, got, exp);
            fail_count++;
        end
    endtask

    initial begin
        $display("=== ALPHA_HOLE TEST (Route-A occlusion) ===");
        repeat (4) @(posedge clk_pix);
        rst_pix = 1'b0;
        repeat (3*48*29) @(posedge clk_pix);   // ~3 frames so accumulators settle

        // 1) XL shows through the un-occluded part of the hole (top-left L).
        chk("xl TL",       12'd8,  12'd4,  C_XL);    // window origin corner
        chk("xl mid",      12'd12, 12'd8,  C_XL);
        chk("xl near-corner",12'd19,12'd13, C_XL);   // last visible px before BOTH occluders

        // 2) opaque occluders HIDE XL — arbitrary shape, per pixel.
        chk("occl right",  12'd25, 12'd10, C_OCCL);
        chk("occl right2", 12'd31, 12'd6,  C_OCCL);  // clip_x1 exclusive edge (31 in, 32 out)
        chk("occl botL",   12'd12, 12'd16, C_OCCL);
        chk("occl botL2",  12'd18, 12'd18, C_OCCL);

        // 3) the L corner is exact: (19,13) XL, one step right OR down -> occluder.
        chk("L corner xl", 12'd19, 12'd13, C_XL);
        chk("L right grey",12'd20, 12'd13, C_OCCL);  // x steps into occluder A
        chk("L down grey", 12'd19, 12'd14, C_OCCL);  // y steps into occluder B

        // 4) wallpaper outside the window is untouched (XL not covered there).
        chk("wall TL",     12'd2,  12'd2,  C_WALL);
        chk("wall left",   12'd5,  12'd10, C_WALL);
        chk("wall right",  12'd35, 12'd22, C_WALL);
        chk("wall above",  12'd12, 12'd3,  C_WALL);  // one row above the window
        chk("wall below",  12'd12, 12'd20, C_WALL);  // clip_y1 exclusive

        if (fail_count == 0) begin
            $display("*** ALPHA_HOLE OK *** arbitrary-shape occlusion, no clip-rect-list");
            $finish;
        end else begin
            $display("*** ALPHA_HOLE FAIL *** %0d failures", fail_count);
            $fatal(1);
        end
    end

    initial begin
        #5_000_000;
        $display("FAIL: tb_alpha_hole watchdog");
        $fatal(1);
    end

endmodule

`default_nettype wire
