// tb_legacy_upscale.sv — unit test for the 1080p pillarbox upscaler.
//
// Runs at a tiny raster (40x24, 4x4 Atari image, 4x scale -> 16x16 centred)
// so a full check is fast.  Window: h in [12,28), v in [4,20).  The scaling
// logic is parameter-generic, so verifying the small case validates the
// 1920x1080 / 384x240 instance.
//
// Mapping: in-window native (h,v) -> atari_col=(h-12)>>2, atari_row=(v-4)>>2.
//
// Checks: in-window pixels resolve to palette[frame_store[row][col]];
// pillarbox/letterbox bar pixels are black with de still active; window
// edges map correctly; the 4x4 native block per Atari pixel is uniform.

`default_nettype none
`timescale 1ns / 1ps

module tb_legacy_upscale;

    localparam int H_ACTIVE = 40;
    localparam int V_ACTIVE = 24;
    localparam int ATARI_W  = 4;
    localparam int ATARI_H  = 4;

    logic clk_pix = 1'b0;
    always #5 clk_pix = ~clk_pix;

    logic        rst_pix = 1'b1;
    logic [11:0] h_count = 0, v_count = 0;
    logic        de = 0, hsync = 0, vsync = 0;
    logic        wr_en = 0;
    logic [8:0]  wr_row = 0, wr_col = 0;
    logic [7:0]  wr_index = 0;
    logic        pal_we = 0;
    logic [7:0]  pal_waddr = 0;
    logic [23:0] pal_wdata = 0;
    wire  [4:0]  rgb_r;
    wire  [5:0]  rgb_g;
    wire  [4:0]  rgb_b;
    wire         de_o, hsync_o, vsync_o;

    legacy_upscale #(
        .H_ACTIVE (H_ACTIVE), .V_ACTIVE (V_ACTIVE),
        .ATARI_W  (ATARI_W),  .ATARI_H  (ATARI_H),
        .H_SHIFT  (2),        .V_SHIFT  (2)
    ) u_dut (
        .clk_pix (clk_pix), .rst_pix (rst_pix),
        .h_count (h_count), .v_count (v_count),
        .de (de), .hsync (hsync), .vsync (vsync),
        .wr_clk (clk_pix), .wr_en (wr_en),
        .wr_row (wr_row), .wr_col (wr_col), .wr_index (wr_index),
        .pal_we (pal_we), .pal_waddr (pal_waddr), .pal_wdata (pal_wdata),
        .rgb_r (rgb_r), .rgb_g (rgb_g), .rgb_b (rgb_b),
        .de_o (de_o), .hsync_o (hsync_o), .vsync_o (vsync_o)
    );

    int fail_count = 0;
    task automatic expect_eq(input string label, input [31:0] got, input [31:0] want);
        if (got !== want) begin
            $display("FAIL %s: got=$%0h expected=$%0h", label, got, want);
            fail_count++;
        end
    endtask

    task automatic fs_write(input [8:0] row, input [8:0] col, input [7:0] idx);
        @(negedge clk_pix);
        wr_en = 1; wr_row = row; wr_col = col; wr_index = idx;
        @(posedge clk_pix);
        @(negedge clk_pix);
        wr_en = 0;
    endtask

    task automatic pal_write(input [7:0] idx, input [23:0] rgb);
        @(negedge clk_pix);
        pal_we = 1; pal_waddr = idx; pal_wdata = rgb;
        @(posedge clk_pix);
        @(negedge clk_pix);
        pal_we = 0;
    endtask

    // Hold a raster position stable, let the 2-stage pipe settle, then check.
    // de tracks the active raster (h<H_ACTIVE && v<V_ACTIVE); bar pixels are
    // still active (de_o=1) but black.
    task automatic probe(input string label, input [11:0] h, input [11:0] v,
                         input [4:0] er, input [5:0] eg, input [4:0] eb);
        @(negedge clk_pix);
        h_count = h; v_count = v;
        de = (h < H_ACTIVE) && (v < V_ACTIVE);
        repeat (4) @(posedge clk_pix);
        #1;
        expect_eq({label, ".r"},  rgb_r, er);
        expect_eq({label, ".g"},  rgb_g, eg);
        expect_eq({label, ".b"},  rgb_b, eb);
        expect_eq({label, ".de"}, de_o, 1'b1);   // all probed points are active video
    endtask

    initial begin
        $display("=== LEGACY_UPSCALE TEST ===");
        repeat (4) @(posedge clk_pix);
        rst_pix = 1'b0;
        @(posedge clk_pix);

        // Frame store: 4 corner Atari pixels (row, col, index).
        fs_write(0, 0, 8'd5);    // top-left
        fs_write(3, 0, 8'd7);    // bottom-left
        fs_write(0, 3, 8'd11);   // top-right
        fs_write(3, 3, 8'd9);    // bottom-right

        // Palette (RGB888).  RGB565 truncation r=[7:3] g=[7:2] b=[7:3]:
        //   FFFFFF->1F,3F,1F ; F80000->1F,0,0 ; 0000F8->0,0,1F ; 00FF00->0,3F,0
        pal_write(8'd5,  24'hFF_FF_FF);   // white
        pal_write(8'd7,  24'hF8_00_00);   // red
        pal_write(8'd11, 24'h00_00_F8);   // blue
        pal_write(8'd9,  24'h00_FF_00);   // green

        // ---- In-window corners (top-left native px of each 4x4 block) ----
        probe("TL",  12'd12, 12'd4,  5'h1F, 6'h3F, 5'h1F);  // atari(0,0) white
        probe("BL",  12'd12, 12'd16, 5'h1F, 6'h00, 5'h00);  // atari(3,0) red
        probe("TR",  12'd24, 12'd4,  5'h00, 6'h00, 5'h1F);  // atari(0,3) blue
        probe("BR",  12'd24, 12'd16, 5'h00, 6'h3F, 5'h00);  // atari(3,3) green

        // ---- 4x4 block uniformity (interior native px map to same Atari px)
        probe("TL.in", 12'd15, 12'd7,  5'h1F, 6'h3F, 5'h1F);  // ->atari(0,0) white
        probe("BR.in", 12'd27, 12'd19, 5'h00, 6'h3F, 5'h00);  // ->atari(3,3) green

        // ---- Bars: black, de still active ----
        probe("bar.topleft", 12'd0,  12'd0,  5'h0, 6'h0, 5'h0);  // both out
        probe("bar.Hleft",   12'd11, 12'd4,  5'h0, 6'h0, 5'h0);  // h just left of window
        probe("bar.Hright",  12'd28, 12'd4,  5'h0, 6'h0, 5'h0);  // h just right of window
        probe("bar.Vtop",    12'd12, 12'd3,  5'h0, 6'h0, 5'h0);  // v just above window
        probe("bar.Vbot",    12'd12, 12'd20, 5'h0, 6'h0, 5'h0);  // v just below window

        if (fail_count == 0) begin
            $display("*** LEGACY_UPSCALE OK *** scale + centering + pillarbox bars");
            $finish;
        end else begin
            $display("*** LEGACY_UPSCALE FAIL *** %0d failures", fail_count);
            $fatal(1);
        end
    end

    initial begin
        #500_000;
        $display("FAIL: tb_legacy_upscale watchdog");
        $fatal(1);
    end

endmodule

`default_nettype wire
