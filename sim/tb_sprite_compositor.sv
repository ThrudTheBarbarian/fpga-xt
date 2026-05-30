// tb_sprite_compositor.sv — exercise the sprite_engine pixel compositor.
//
// Pokes line cache contents directly via hierarchical reference (skipping
// the AXI fetcher), programs sprite descriptors, then sweeps h_count
// across a scanline and verifies the output pixel matches expected
// priority + alpha-blend behavior.
//
// Cases:
//   A) Single sprite, fully opaque, screen_x = 100, size = 16.  Verify
//      compositor outputs sprite pixel inside [100..115] and framebuffer
//      pixel outside.
//   B) Two overlapping sprites — verify higher priority wins.
//   C) Alpha-blend: half-alpha sprite over solid red framebuffer.
//
// Pipeline latency = 3 clk_pix cycles input→output, so the test reads
// rgb_* exactly 3 cycles after driving h_count.

`timescale 1ns/1ps

module tb_sprite_compositor;

    // ----------------------------------------------------------------------
    // Clocks & reset
    // ----------------------------------------------------------------------
    logic clk_fetch = 1'b0;
    logic clk_pix   = 1'b0;
    logic rst       = 1'b1;

    always #3   clk_fetch = ~clk_fetch;
    always #3.4 clk_pix   = ~clk_pix;

    // ----------------------------------------------------------------------
    // DUT signals
    // ----------------------------------------------------------------------
    logic        reg_we;
    logic [7:0]  reg_addr;
    logic [7:0]  reg_wdata;
    wire  [7:0]  reg_rdata;

    logic [11:0] h_count = 12'd0;
    logic [11:0] v_count = 12'd0;
    logic        line_start  = 1'b0;
    logic        frame_start = 1'b0;
    logic [15:0] fb_pixel = 16'h0000;
    logic        fb_de    = 1'b1;
    logic        fb_hsync = 1'b0;
    logic        fb_vsync = 1'b0;

    wire [4:0] rgb_r;
    wire [5:0] rgb_g;
    wire [4:0] rgb_b;
    wire       rgb_de;
    wire       rgb_hsync;
    wire       rgb_vsync;

    sprite_engine #(
        .ARENA_BASE (32'h0000_0000),
        .N_SPRITES  (16)
    ) u_dut (
        .clk_fetch    (clk_fetch),
        .clk_pix      (clk_pix),
        .rst          (rst),
        .h_count      (h_count),
        .v_count      (v_count),
        .line_start   (line_start),
        .frame_start  (frame_start),
        .reg_we       (reg_we),
        .reg_addr     (reg_addr),
        .reg_wdata    (reg_wdata),
        .reg_rdata    (reg_rdata),
        .fb_pixel     (fb_pixel),
        .fb_de        (fb_de),
        .fb_hsync     (fb_hsync),
        .fb_vsync     (fb_vsync),
        .rgb_r        (rgb_r),
        .rgb_g        (rgb_g),
        .rgb_b        (rgb_b),
        .rgb_de       (rgb_de),
        .rgb_hsync    (rgb_hsync),
        .rgb_vsync    (rgb_vsync),
        // AXI HP2 dangled — fetcher not exercised here.
        .m_axi_araddr (),
        .m_axi_arlen  (),
        .m_axi_arsize (),
        .m_axi_arburst(),
        .m_axi_arvalid(),
        .m_axi_arready(1'b0),
        .m_axi_rdata  (64'd0),
        .m_axi_rvalid (1'b0),
        .m_axi_rlast  (1'b0),
        .m_axi_rready ()
    );

    int errors = 0;

    // ----------------------------------------------------------------------
    // Helpers
    // ----------------------------------------------------------------------
    task automatic write_reg(input [7:0] addr, input [7:0] data);
        @(posedge clk_fetch); #1;
        reg_we    = 1'b1;
        reg_addr  = addr;
        reg_wdata = data;
        @(posedge clk_fetch); #1;
        reg_we    = 1'b0;
    endtask

    task automatic program_sprite(input [3:0] idx,
                                  input [4:0] prio,
                                  input [3:0] log2sz,
                                  input signed [11:0] screen_x,
                                  input signed [11:0] screen_y);
        write_reg(8'hD0, {4'h0, idx});
        write_reg(8'hD1, {3'b000, prio});
        write_reg(8'hD2, {4'h0, log2sz});
        write_reg(8'hD3, 8'h00);
        write_reg(8'hD4, 8'h00);
        write_reg(8'hD5, 8'h00);
        write_reg(8'hD6, screen_y[7:0]);
        write_reg(8'hD7, {screen_x[11:8], screen_y[11:8]});
        write_reg(8'hD8, screen_x[7:0]);
        // Per-sprite control: en=1, format=1 (32-bit, but we won't care for
        // these direct cache pokes — alpha is what matters).
        write_reg({4'hA, idx}, 8'b0010_0001);
    endtask

    // Poke a single pixel into the cache via hierarchical reference.
    // Uses a case dispatch because iverilog can't dynamically index
    // generate scopes.
    task automatic poke_cache(input [3:0] sid, input int lx, input [31:0] pix);
        case (sid)
            4'd0:  u_dut.u_cache.g_sprite[0 ].mem[lx] = pix;
            4'd1:  u_dut.u_cache.g_sprite[1 ].mem[lx] = pix;
            4'd2:  u_dut.u_cache.g_sprite[2 ].mem[lx] = pix;
            4'd3:  u_dut.u_cache.g_sprite[3 ].mem[lx] = pix;
            4'd4:  u_dut.u_cache.g_sprite[4 ].mem[lx] = pix;
            4'd5:  u_dut.u_cache.g_sprite[5 ].mem[lx] = pix;
            4'd6:  u_dut.u_cache.g_sprite[6 ].mem[lx] = pix;
            4'd7:  u_dut.u_cache.g_sprite[7 ].mem[lx] = pix;
            4'd8:  u_dut.u_cache.g_sprite[8 ].mem[lx] = pix;
            4'd9:  u_dut.u_cache.g_sprite[9 ].mem[lx] = pix;
            4'd10: u_dut.u_cache.g_sprite[10].mem[lx] = pix;
            4'd11: u_dut.u_cache.g_sprite[11].mem[lx] = pix;
            4'd12: u_dut.u_cache.g_sprite[12].mem[lx] = pix;
            4'd13: u_dut.u_cache.g_sprite[13].mem[lx] = pix;
            4'd14: u_dut.u_cache.g_sprite[14].mem[lx] = pix;
            4'd15: u_dut.u_cache.g_sprite[15].mem[lx] = pix;
        endcase
    endtask

    // Drive h_count to a specific column, wait 6 clk_pix cycles for the
    // compositor pipeline to settle, and sample the output.  Compositor
    // depth: stage1 → FF1 (s2) → FF1b (s2b, BRAM clock-out FF aligned) →
    // BRAM OREG read → mid (cycle A of tree) → FF2 (winner) → FF_mul →
    // FF_out (final) = 6 FF stages.
    task automatic probe(input [11:0] hx,
                        output [4:0] gr,
                        output [5:0] gg,
                        output [4:0] gb);
        @(posedge clk_pix); #1;
        h_count = hx;
        @(posedge clk_pix);    // FF1:  s2_hit_q
        @(posedge clk_pix);    // FF1b: s2b_hit_q (cache rd_data_int valid)
        @(posedge clk_pix);    // mid:  l2 candidates (cache rd_data valid)
        @(posedge clk_pix);    // FF2:  s4_winner_pixel_q
        @(posedge clk_pix);    // FF_mul: r/g/b_mul_*_q
        @(posedge clk_pix); #1; // FF_out: rgb_*_q
        gr = rgb_r;
        gg = rgb_g;
        gb = rgb_b;
    endtask

    task automatic check_rgb(input [11:0] hx,
                             input [4:0] wr, input [5:0] wg, input [4:0] wb,
                             input string msg);
        logic [4:0] gr;
        logic [5:0] gg;
        logic [4:0] gb;
        probe(hx, gr, gg, gb);
        if (gr !== wr || gg !== wg || gb !== wb) begin
            $display("FAIL: %s  h=%0d got=(%0d,%0d,%0d) want=(%0d,%0d,%0d)",
                     msg, hx, gr, gg, gb, wr, wg, wb);
            errors = errors + 1;
        end
    endtask

    // ----------------------------------------------------------------------
    // Test sequence
    // ----------------------------------------------------------------------
    initial begin
        reg_we    = 1'b0;
        reg_addr  = 8'h00;
        reg_wdata = 8'h00;
        v_count   = 12'd5;
        repeat (10) @(posedge clk_fetch);
        rst <= 1'b0;
        repeat (10) @(posedge clk_fetch);

        write_reg(8'hDF, 8'h01);             // global_enable = 1

        // ------------------------------------------------------------------
        // CASE A — single opaque sprite at screen_x=100, size=16.
        // FB background = bright green (RGB565 = 0x07E0).
        // Sprite pixels = bright red, opaque (RGBA-8888 = 0xFF0000_FF).
        // ------------------------------------------------------------------
        $display("[A] single opaque sprite, screen_x=100, size=16");
        fb_pixel = 16'h07E0;                 // green

        program_sprite(.idx     (4'd2),
                       .prio    (5'd10),
                       .log2sz  (4'd4),       // 16×16
                       .screen_x(12'sd100),
                       .screen_y(12'sd0));

        // Poke 16 opaque red pixels at sprite 2's cache.
        for (int x = 0; x < 16; x = x + 1)
            poke_cache(4'd2, x, 32'hFF00_00FF);

        // h_count=50: well off the sprite → expect green fb.
        check_rgb(12'd50, 5'd0, 6'd63, 5'd0, "A: h=50 (off sprite, green fb)");
        // h_count=100: first sprite pixel → expect red.
        check_rgb(12'd100, 5'd31, 6'd0, 5'd0, "A: h=100 (sprite, red)");
        // h_count=115: last sprite pixel → still red.
        check_rgb(12'd115, 5'd31, 6'd0, 5'd0, "A: h=115 (sprite, red)");
        // h_count=116: just past sprite → green again.
        check_rgb(12'd116, 5'd0, 6'd63, 5'd0, "A: h=116 (off sprite, green fb)");

        // ------------------------------------------------------------------
        // CASE B — two overlapping sprites, higher priority wins.
        //   sprite 4 (prio=5): blue,  at screen_x=200, size=16.
        //   sprite 6 (prio=20): yellow, at screen_x=205, size=16.
        // Expected at h=210: sprite 6 wins → yellow.
        //                h=200..204: only sprite 4 → blue.
        //                h=216: only sprite 6 → yellow.
        // ------------------------------------------------------------------
        $display("[B] two overlapping sprites, priority wins");
        program_sprite(.idx (4'd4), .prio (5'd5),  .log2sz(4'd4),
                       .screen_x(12'sd200), .screen_y(12'sd0));
        program_sprite(.idx (4'd6), .prio (5'd20), .log2sz(4'd4),
                       .screen_x(12'sd205), .screen_y(12'sd0));

        for (int x = 0; x < 16; x = x + 1) begin
            poke_cache(4'd4, x, 32'h0000_FFFF);   // R=0,G=0,B=255,A=255 (blue)
            poke_cache(4'd6, x, 32'hFFFF_00FF);   // R=255,G=255,B=0,A=255 (yellow)
        end

        check_rgb(12'd202, 5'd0, 6'd0, 5'd31, "B: h=202 (only sprite 4 blue)");
        check_rgb(12'd210, 5'd31, 6'd63, 5'd0, "B: h=210 (sprite 6 yellow wins)");
        check_rgb(12'd218, 5'd31, 6'd63, 5'd0, "B: h=218 (only sprite 6 yellow)");

        // ------------------------------------------------------------------
        // CASE C — alpha blend.  Sprite 8 at half alpha, white pixel,
        // over red framebuffer.  Expected: pinkish (mix of white and red).
        //
        // Formula: out = (sp * a + fb * (255-a) + 128) / 256.
        // sp = 255 (white channels), fb_r = 0xFF (= 31 << 3 | 31 >> 2 ≈ 255),
        //   fb_g = 0,   fb_b = 0.
        // a = 128:
        //   r: (255*128 + 255*127 + 128) >> 8 = (32640 + 32385 + 128) >> 8
        //                                   = 65153 >> 8 = 254
        //   g: (255*128 +   0*127 + 128) >> 8 = 32768 >> 8 = 128
        //   b: same as g = 128
        // RGB565 truncate: r5 = 254>>3 = 31, g6 = 128>>2 = 32, b5 = 128>>3 = 16
        // ------------------------------------------------------------------
        $display("[C] alpha blend, half-alpha white over red fb");
        fb_pixel = 16'hF800;                 // pure red
        program_sprite(.idx (4'd8), .prio (5'd1), .log2sz(4'd4),
                       .screen_x(12'sd300), .screen_y(12'sd0));
        for (int x = 0; x < 16; x = x + 1)
            poke_cache(4'd8, x, 32'hFFFF_FF80);   // white pixel, alpha=0x80=128

        check_rgb(12'd305, 5'd31, 6'd32, 5'd16, "C: half-alpha blend");

        // h=290: outside sprite → pure red fb.
        check_rgb(12'd290, 5'd31, 6'd0, 5'd0, "C: outside sprite (red fb)");

        // ------------------------------------------------------------------
        // Summary
        // ------------------------------------------------------------------
        if (errors == 0) $display("*** SPRITE_COMP OK ***");
        else             $display("FAIL: tb_sprite_compositor reported %0d error(s)", errors);
        $finish;
    end

    initial begin
        #500_000;
        $display("FAIL: tb_sprite_compositor watchdog");
        $finish;
    end

endmodule
