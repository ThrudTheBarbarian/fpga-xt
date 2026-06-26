// tb_sprite_fetcher.sv — exercise the sprite line fetcher + cache.
//
// Plants known pixel patterns into the AXI slave (acting as PS DDR3),
// programs a sprite descriptor that points at the planted region, kicks a
// line_start pulse, waits for the fetcher to drain, then verifies the
// line cache contents via hierarchical reference into u_cache.g_sprite[N].mem.
//
// Three cases:
//   A) 32-bit RGBA-8888 sprite, fully visible, screen_x = 0.
//   B) 16-bit RGBA-5:5:5:1 sprite — verifies the upconvert.
//   C) 32-bit sprite with screen_x < 0 (left clip — skip first N pixels).
//
// Each case uses a small log2_size = 4 → 16×16 sprite so a single 64-byte
// burst fills the visible width.  ARENA_BASE is parameterised down to 0
// so the planted data fits inside the slave's 256 KB backing store.

`timescale 1ns/1ps

module tb_sprite_fetcher;

    // ----------------------------------------------------------------------
    // Clocks & reset
    // ----------------------------------------------------------------------
    logic clk_fetch = 1'b0;
    logic clk_pix   = 1'b0;
    logic rst       = 1'b1;

    always #3   clk_fetch = ~clk_fetch;   // ~166 MHz
    always #3.4 clk_pix   = ~clk_pix;     // ~147 MHz

    // ----------------------------------------------------------------------
    // DUT signals
    // ----------------------------------------------------------------------
    logic        reg_we;
    logic [7:0]  reg_addr;
    logic [7:0]  reg_wdata;
    wire  [7:0]  reg_rdata;

    logic [11:0] h_count_pix = 12'd0;
    logic [11:0] v_count_pix = 12'd0;
    logic        line_start_pix = 1'b0;
    logic        frame_start_pix = 1'b0;

    wire [31:0]  m_axi_araddr;
    wire [7:0]   m_axi_arlen;
    wire [2:0]   m_axi_arsize;
    wire [1:0]   m_axi_arburst;
    wire         m_axi_arvalid;
    wire         m_axi_arready;
    wire [63:0]  m_axi_rdata;
    wire         m_axi_rvalid;
    wire         m_axi_rlast;
    wire         m_axi_rready;

    sprite_engine #(
        .ARENA_BASE (32'h0000_0000),     // collapse to AXI slave's 256 KB window
        .N_SPRITES  (16)
    ) u_dut (
        .clk_fetch    (clk_fetch),
        .clk_pix      (clk_pix),
        .rst          (rst),
        .h_count      (h_count_pix),
        .v_count      (v_count_pix),
        .line_start   (line_start_pix),
        .frame_start  (frame_start_pix),
        .reg_we       (reg_we),
        .reg_addr     (reg_addr),
        .reg_wdata    (reg_wdata),
        .reg_rdata    (reg_rdata),
        .fb_pixel     (16'h0000),
        .fb_de        (1'b0),
        .fb_hsync     (1'b0),
        .fb_vsync     (1'b0),
        .rgb_r        (),
        .rgb_g        (),
        .rgb_b        (),
        .rgb_de       (),
        .rgb_hsync    (),
        .rgb_vsync    (),
        .m_axi_araddr (m_axi_araddr),
        .m_axi_arlen  (m_axi_arlen),
        .m_axi_arsize (m_axi_arsize),
        .m_axi_arburst(m_axi_arburst),
        .m_axi_arvalid(m_axi_arvalid),
        .m_axi_arready(m_axi_arready),
        .m_axi_rdata  (m_axi_rdata),
        .m_axi_rvalid (m_axi_rvalid),
        .m_axi_rlast  (m_axi_rlast),
        .m_axi_rready (m_axi_rready)
    );

    // ----------------------------------------------------------------------
    // AXI slave (sprite arena)
    // ----------------------------------------------------------------------
    axi_slave_mem #(
        .ADDR_W (32),
        .DATA_W (64)
    ) u_axi_slave (
        .clk          (clk_fetch),
        .rst          (rst),
        // AW channel — unused (read-only)
        .s_axi_awaddr (32'd0),
        .s_axi_awlen  (8'd0),
        .s_axi_awsize (3'd0),
        .s_axi_awburst(2'd0),
        .s_axi_awvalid(1'b0),
        .s_axi_awready(),
        .s_axi_wdata  (64'd0),
        .s_axi_wstrb  (8'h00),
        .s_axi_wlast  (1'b0),
        .s_axi_wvalid (1'b0),
        .s_axi_wready (),
        .s_axi_bvalid (),
        .s_axi_bready (1'b1),
        // AR channel — driven by fetcher
        .s_axi_araddr (m_axi_araddr),
        .s_axi_arlen  (m_axi_arlen),
        .s_axi_arsize (m_axi_arsize),
        .s_axi_arburst(m_axi_arburst),
        .s_axi_arvalid(m_axi_arvalid),
        .s_axi_arready(m_axi_arready),
        .s_axi_rdata  (m_axi_rdata),
        .s_axi_rvalid (m_axi_rvalid),
        .s_axi_rlast  (m_axi_rlast),
        .s_axi_rready (m_axi_rready)
    );

    // ----------------------------------------------------------------------
    // Register-write helper (clk_fetch domain)
    // ----------------------------------------------------------------------
    task automatic write_reg(input [7:0] addr, input [7:0] data);
        @(posedge clk_fetch); #1;
        reg_we    = 1'b1;
        reg_addr  = addr;
        reg_wdata = data;
        @(posedge clk_fetch); #1;
        reg_we    = 1'b0;
    endtask

    // ----------------------------------------------------------------------
    // Plant a 32-bit RGBA-8888 pixel into the arena at (arena_x, arena_y)
    // using 16 KB row stride.
    // ----------------------------------------------------------------------
    task automatic plant_pixel32(input int x, input int y, input [31:0] pix);
        int unsigned base;
        base = (y << 14) + (x << 2);
        u_axi_slave.seed_byte(base + 0, pix[7:0]);
        u_axi_slave.seed_byte(base + 1, pix[15:8]);
        u_axi_slave.seed_byte(base + 2, pix[23:16]);
        u_axi_slave.seed_byte(base + 3, pix[31:24]);
    endtask

    task automatic plant_pixel16(input int x, input int y, input [15:0] pix);
        int unsigned base;
        base = (y << 13) + (x << 1);
        u_axi_slave.seed_byte(base + 0, pix[7:0]);
        u_axi_slave.seed_byte(base + 1, pix[15:8]);
    endtask

    // ----------------------------------------------------------------------
    // Descriptor programming helper.
    //   B0..B7 layout matches sprite_engine.sv $D4D1..$D4D8.
    // ----------------------------------------------------------------------
    task automatic program_sprite(input [3:0] idx,
                                  input [4:0] prio,
                                  input [3:0] log2sz,
                                  input [11:0] arena_x,
                                  input [11:0] arena_y,
                                  input signed [11:0] screen_x,
                                  input signed [11:0] screen_y,
                                  input bit fmt);
        // SPRITE_SEL = idx
        write_reg(8'hD0, {4'h0, idx});
        // B0: priority
        write_reg(8'hD1, {3'b000, prio});
        // B1: log2_size
        write_reg(8'hD2, {4'h0, log2sz});
        // B2: arena_y[7:0]
        write_reg(8'hD3, arena_y[7:0]);
        // B3: {arena_x[11:8], arena_y[11:8]}
        write_reg(8'hD4, {arena_x[11:8], arena_y[11:8]});
        // B4: arena_x[7:0]
        write_reg(8'hD5, arena_x[7:0]);
        // B5: screen_y[7:0]
        write_reg(8'hD6, screen_y[7:0]);
        // B6: {screen_x[11:8], screen_y[11:8]}
        write_reg(8'hD7, {screen_x[11:8], screen_y[11:8]});
        // B7: screen_x[7:0]  (commit)
        write_reg(8'hD8, screen_x[7:0]);
        // Per-sprite control: en + format
        write_reg({4'hA, idx}, {2'b00, fmt, 4'b0000, 1'b1});
    endtask

    // ----------------------------------------------------------------------
    // Pulse line_start on clk_pix domain with a given v_count.
    // The DUT will start fetching for line v + 1.
    // ----------------------------------------------------------------------
    task automatic kick_line(input [11:0] v);
        @(posedge clk_pix); #1;
        v_count_pix    = v;
        line_start_pix = 1'b1;
        @(posedge clk_pix); #1;
        line_start_pix = 1'b0;
    endtask

    int errors = 0;

    // ----------------------------------------------------------------------
    // Wait for the fetcher to leave IDLE (line_start has propagated through
    // CDC) and then return to IDLE.
    // ----------------------------------------------------------------------
    task automatic wait_fetch_idle;
        int wd;
        // Phase 1: wait for FSM to leave IDLE.
        wd = 0;
        while (u_dut.fstate == u_dut.F_IDLE) begin
            @(posedge clk_fetch);
            wd = wd + 1;
            if (wd > 200) begin
                $display("FAIL: FSM never left IDLE after line_start");
                errors = errors + 1;
                return;
            end
        end
        // Phase 2: wait for FSM to return to IDLE.
        wd = 0;
        while (u_dut.fstate != u_dut.F_IDLE) begin
            @(posedge clk_fetch);
            wd = wd + 1;
            if (wd > 20000) begin
                $display("FAIL: fetcher did not return to IDLE");
                errors = errors + 1;
                return;
            end
        end
    endtask

    // ----------------------------------------------------------------------
    // Read cache via hierarchical ref.  iverilog can't dynamically index a
    // generate-loop scope, so we switch on the literal sprite id.
    // ----------------------------------------------------------------------
    function automatic logic [31:0] cache_peek32(input [3:0] sid, input int lx);
        // The line cache is double-buffered (ping-pong): the fetcher fills bank
        // ~fetch_line_toggle.  Peek that bank (offset = bank * LINE_WIDTH=1024).
        int a;
        a = (u_dut.fetch_line_toggle ? 0 : 1024) + lx;
        case (sid)
            4'd0:  cache_peek32 = u_dut.u_cache.g_sprite[0 ].mem[a];
            4'd1:  cache_peek32 = u_dut.u_cache.g_sprite[1 ].mem[a];
            4'd2:  cache_peek32 = u_dut.u_cache.g_sprite[2 ].mem[a];
            4'd3:  cache_peek32 = u_dut.u_cache.g_sprite[3 ].mem[a];
            4'd4:  cache_peek32 = u_dut.u_cache.g_sprite[4 ].mem[a];
            4'd5:  cache_peek32 = u_dut.u_cache.g_sprite[5 ].mem[a];
            4'd6:  cache_peek32 = u_dut.u_cache.g_sprite[6 ].mem[a];
            4'd7:  cache_peek32 = u_dut.u_cache.g_sprite[7 ].mem[a];
            4'd8:  cache_peek32 = u_dut.u_cache.g_sprite[8 ].mem[a];
            4'd9:  cache_peek32 = u_dut.u_cache.g_sprite[9 ].mem[a];
            4'd10: cache_peek32 = u_dut.u_cache.g_sprite[10].mem[a];
            4'd11: cache_peek32 = u_dut.u_cache.g_sprite[11].mem[a];
            4'd12: cache_peek32 = u_dut.u_cache.g_sprite[12].mem[a];
            4'd13: cache_peek32 = u_dut.u_cache.g_sprite[13].mem[a];
            4'd14: cache_peek32 = u_dut.u_cache.g_sprite[14].mem[a];
            4'd15: cache_peek32 = u_dut.u_cache.g_sprite[15].mem[a];
            default: cache_peek32 = 32'hxxxx_xxxx;
        endcase
    endfunction

    task automatic check_cache32(input [3:0] sid, input int lx, input [31:0] want, input string msg);
        logic [31:0] got;
        got = cache_peek32(sid, lx);
        if (got !== want) begin
            $display("FAIL: %s  sprite=%0d lx=%0d got=%08h want=%08h",
                     msg, sid, lx, got, want);
            errors = errors + 1;
        end
    endtask

    // Expected RGBA-8888 for a 5:5:5:1 source pixel — match expand_5551 fn.
    function automatic logic [31:0] expand_5551(input logic [15:0] p);
        logic [4:0] r5, g5, b5;
        logic       a1;
        r5 = p[15:11];
        g5 = p[10:6];
        b5 = p[5:1];
        a1 = p[0];
        expand_5551 = {{r5, r5[4:2]}, {g5, g5[4:2]}, {b5, b5[4:2]}, {8{a1}}};
    endfunction

    // ----------------------------------------------------------------------
    // Test sequence
    // ----------------------------------------------------------------------
    initial begin
        reg_we    = 1'b0;
        reg_addr  = 8'h00;
        reg_wdata = 8'h00;
        v_count_pix    = 12'd0;
        line_start_pix = 1'b0;
        repeat (10) @(posedge clk_fetch);
        rst <= 1'b0;
        repeat (10) @(posedge clk_fetch);

        // Enable the sprite engine globally.
        write_reg(8'hDF, 8'h01);

        // ------------------------------------------------------------------
        // CASE A — 32-bit sprite, log2_size=4 (16×16), at arena (0, 0),
        // screen position (0, 10), full visibility.
        // ------------------------------------------------------------------
        $display("[A] 32-bit sprite, fully visible at screen_y=10");
        // Plant one scanline of pixels at arena row 5 (next line after
        // screen_y=10 will be line 11, local_y = 11 - 10 = 1 → arena row 1).
        // Set the kick to v_count=10 → next_vcount = 11, local_y = 1, arena
        // row = arena_y + local_y = 0 + 1 = 1.
        for (int x = 0; x < 16; x = x + 1)
            plant_pixel32(x, 1, 32'hDEAD_BE00 + x);     // unique per-pixel value

        program_sprite(.idx     (4'd3),
                       .prio    (5'd10),
                       .log2sz  (4'd4),                  // 16×16
                       .arena_x (12'd0),
                       .arena_y (12'd0),
                       .screen_x(12'sd0),
                       .screen_y(12'sd10),
                       .fmt     (1'b1));                 // 32-bit RGBA-8888

        kick_line(12'd10);
        wait_fetch_idle();

        for (int x = 0; x < 16; x = x + 1)
            check_cache32(4'd3, x, 32'hDEAD_BE00 + x, $sformatf("A: sprite 3 pixel %0d", x));

        // ------------------------------------------------------------------
        // CASE B — 16-bit sprite (RGBA-5:5:5:1), 8 pixels wide, fully
        // visible.  Verifies the upconvert.
        // ------------------------------------------------------------------
        $display("[B] 16-bit sprite, fully visible, upconvert check");

        // Use sprite slot 5.  16-bit arena stride = 8 KB.
        // Plant 8 unique pixels at arena row 2.
        for (int x = 0; x < 8; x = x + 1)
            plant_pixel16(x, 2, 16'((x * 16'h1111) | 16'h0001));   // alpha=1

        program_sprite(.idx     (4'd5),
                       .prio    (5'd11),
                       .log2sz  (4'd3),                  // 8×8
                       .arena_x (12'd0),
                       .arena_y (12'd0),
                       .screen_x(12'sd0),
                       .screen_y(12'sd20),
                       .fmt     (1'b0));                 // 16-bit

        // local_y = 21 - 20 = 1 → arena row 1 in arena's row count starting at arena_y.
        // We planted at arena row 2 — adjust: set arena_y so arena_row = 2 on next line.
        // arena_row = arena_y + local_y → arena_y = arena_row - local_y = 2 - 1 = 1.
        // Re-program with arena_y=1.
        write_reg(8'hD0, 8'd5);
        write_reg(8'hD3, 8'd1);                          // arena_y[7:0] = 1
        write_reg(8'hD4, 8'h00);                         // arena_x[11:8]=0, arena_y[11:8]=0
        write_reg(8'hD8, 12'sd0);                        // re-commit B7 (screen_x[7:0]=0)

        kick_line(12'd20);
        wait_fetch_idle();

        for (int x = 0; x < 8; x = x + 1) begin
            logic [15:0] src;
            src = 16'((x * 16'h1111) | 16'h0001);
            check_cache32(4'd5, x, expand_5551(src), $sformatf("B: sprite 5 pixel %0d", x));
        end

        // ------------------------------------------------------------------
        // CASE C — 32-bit sprite, log2_size=4 (16×16), screen_x = -3 →
        // clip_left=3: pixels at arena local_x [3..15] go to cache slots
        // [3..15] of the sprite.  Slots [0..2] stay at whatever was there.
        // ------------------------------------------------------------------
        $display("[C] 32-bit sprite with left clip (screen_x=-3)");

        // Plant arena row 3 with marker pixels.
        for (int x = 0; x < 16; x = x + 1)
            plant_pixel32(x, 3, 32'hCAFE_0000 + x);

        program_sprite(.idx     (4'd9),
                       .prio    (5'd12),
                       .log2sz  (4'd4),
                       .arena_x (12'd0),
                       .arena_y (12'd2),                 // local_y=1 → arena_row=3
                       .screen_x(-12'sd3),               // clip left 3 pixels
                       .screen_y(12'sd30),
                       .fmt     (1'b1));

        kick_line(12'd30);
        wait_fetch_idle();

        // Pixels [3..15] in cache should match arena [3..15].
        for (int x = 3; x < 16; x = x + 1)
            check_cache32(4'd9, x, 32'hCAFE_0000 + x, $sformatf("C: sprite 9 pixel %0d", x));

        // ------------------------------------------------------------------
        // Summary
        // ------------------------------------------------------------------
        if (errors == 0) $display("*** SPRITE_FETCHER OK ***");
        else             $display("FAIL: tb_sprite_fetcher reported %0d error(s)", errors);
        $finish;
    end

    // Watchdog
    initial begin
        #2_000_000;
        $display("FAIL: tb_sprite_fetcher watchdog");
        $finish;
    end

endmodule
