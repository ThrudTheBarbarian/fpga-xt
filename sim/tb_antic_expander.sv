`timescale 1ns/1ps
`default_nettype none
//
// tb_antic_expander — line buffer -> palette -> RGBA32, end to end.
//
// Chains the real antic_line_buf and palette_lut behind the expander, so this
// exercises the whole plumbing path: the beam writes a line, a swap hands it
// over, and the expander must emit exactly PIXELS pixels in order with the
// right colours and the right DDR base address.
//
// The pixel COUNT check matters as much as the values: the read path has two
// clocks of latency, so an off-by-one in the drain either drops the last pixels
// or emits stale ones past the end of the line.
//
module tb_antic_expander;

    localparam int PIXELS = 32;         // small line keeps the test readable

    logic clk = 0, rst = 1;
    always #5 clk = ~clk;

    // ---- line buffer ----------------------------------------------------
    logic       lb_line_start, lb_wr_stb, lb_swap;
    logic [7:0] lb_wr_color;
    wire  [9:0] lb_addr;
    wire  [7:0] lb_color;

    antic_line_buf #(.PIXELS(PIXELS)) u_lb (
        .clk(clk), .rst(rst),
        .line_start(lb_line_start), .wr_stb(lb_wr_stb), .wr_color(lb_wr_color),
        .wr_index(), .rd_addr(lb_addr), .rd_color(lb_color), .swap(lb_swap)
    );

    // ---- palette --------------------------------------------------------
    // Declared BEFORE the instantiation: iverilog rejects declaration-after-use
    // even where Vivado tolerates it (same trap as line_end_pulse_bus).
    logic        pal_we;
    logic [7:0]  pal_waddr;
    logic [23:0] pal_wdata;
    wire [7:0]  pal_addr;
    wire [23:0] pal_rgb;

    palette_lut #(.ADDR_W(8), .INIT_FILE("")) u_pal (
        .clk(clk), .we(pal_we), .waddr(pal_waddr), .wdata(pal_wdata),
        .raddr(pal_addr), .rdata(pal_rgb)
    );

    // ---- expander -------------------------------------------------------
    logic        line_done;
    logic [11:0] line_no;
    wire         wr_en, flush, busy;
    wire [11:0]  wr_col, flush_w;
    wire [31:0]  wr_pixel, flush_base;

    antic_expander #(.PIXELS(PIXELS)) dut (
        .clk(clk), .rst(rst),
        .line_done(line_done), .line_no(line_no),
        .lb_addr(lb_addr), .lb_color(lb_color),
        .pal_addr(pal_addr), .pal_rgb(pal_rgb),
        .wr_en(wr_en), .wr_col(wr_col), .wr_pixel(wr_pixel),
        .flush(flush), .flush_base(flush_base), .flush_w(flush_w),
        .writer_busy(1'b0),
        .fb_base(32'h1000_0000), .fb_stride(16'd2048),
        .busy(busy)
    );

    int fail = 0;
    int emitted = 0;
    logic [31:0] seen [0:63];
    logic [11:0] seen_col [0:63];

    always @(posedge clk) if (!rst && wr_en) begin
        if (emitted < 64) begin seen[emitted] = wr_pixel; seen_col[emitted] = wr_col; end
        emitted++;
    end

    task automatic pal_write(input [7:0] a, input [23:0] rgb);
        begin
            @(negedge clk); pal_we = 1'b1; pal_waddr = a; pal_wdata = rgb;
            @(negedge clk); pal_we = 1'b0;
        end
    endtask

    task automatic emit_px(input [7:0] c);
        begin
            @(negedge clk); lb_wr_color = c; lb_wr_stb = 1'b1;
            @(negedge clk); lb_wr_stb = 1'b0;
        end
    endtask

    initial begin
        lb_line_start = 0; lb_wr_stb = 0; lb_swap = 0; lb_wr_color = 0;
        pal_we = 0; pal_waddr = 0; pal_wdata = 0;
        line_done = 0; line_no = 0;
        repeat (3) @(posedge clk);
        rst = 0;
        @(posedge clk);

        // Palette: colour byte N -> RGB 0xNN0000 + N, so every entry is
        // distinguishable and a wrong lookup is obvious.
        for (int i = 0; i < 32; i++) pal_write(8'(i), {8'(i), 8'h00, 8'(i)});

        // ---- beam draws a line: colour byte == pixel index ---------------
        @(negedge clk); lb_line_start = 1'b1; @(negedge clk); lb_line_start = 1'b0;
        for (int i = 0; i < PIXELS; i++) emit_px(8'(i));
        @(negedge clk); lb_swap = 1'b1; @(negedge clk); lb_swap = 1'b0;

        // ---- expand it ----------------------------------------------------
        emitted = 0;
        line_no = 12'd3;
        @(negedge clk); line_done = 1'b1;
        @(negedge clk); line_done = 1'b0;

        wait (flush == 1'b1);
        @(negedge clk);

        // ---- T1: exactly PIXELS pixels, no more, no fewer -----------------
        if (emitted !== PIXELS) begin
            $display("FAIL T1: emitted %0d pixels, expected %0d", emitted, PIXELS);
            fail++;
        end

        // ---- T2: in order, column 0..PIXELS-1 -----------------------------
        for (int i = 0; i < PIXELS && i < emitted; i++)
            if (seen_col[i] !== 12'(i)) begin
                $display("FAIL T2: pixel %0d went to column %0d", i, seen_col[i]);
                fail++;
            end

        // ---- T3: each pixel is its palette entry, opaque ------------------
        for (int i = 0; i < PIXELS && i < emitted; i++)
            if (seen[i] !== {8'hFF, 8'(i), 8'h00, 8'(i)}) begin
                $display("FAIL T3: pixel %0d = $%08h expected $%08h",
                         i, seen[i], {8'hFF, 8'(i), 8'h00, 8'(i)});
                fail++;
            end

        // ---- T4: the DDR base is row * stride ----------------------------
        if (flush_base !== 32'h1000_0000 + 3*2048) begin
            $display("FAIL T4: flush_base=$%08h expected $%08h",
                     flush_base, 32'h1000_0000 + 3*2048);
            fail++;
        end
        if (flush_w !== 12'(PIXELS)) begin
            $display("FAIL T4b: flush_w=%0d expected %0d", flush_w, PIXELS); fail++;
        end

        // ---- T5: it returns to idle and can run again --------------------
        @(negedge clk);
        if (busy) begin $display("FAIL T5: still busy after flush"); fail++; end

        emitted = 0;
        line_no = 12'd7;
        @(negedge clk); line_done = 1'b1;
        @(negedge clk); line_done = 1'b0;
        wait (flush == 1'b1);
        @(negedge clk);
        if (emitted !== PIXELS) begin
            $display("FAIL T5b: second line emitted %0d, expected %0d", emitted, PIXELS);
            fail++;
        end
        if (flush_base !== 32'h1000_0000 + 7*2048) begin
            $display("FAIL T5c: second base=$%08h expected $%08h",
                     flush_base, 32'h1000_0000 + 7*2048);
            fail++;
        end

        if (fail == 0) $display("tb_antic_expander: all checks PASS");
        else           $display("tb_antic_expander: %0d FAIL", fail);
        $finish;
    end

    initial begin
        #200000;
        $display("FAIL: timeout — expander never flushed");
        $finish;
    end

endmodule

`default_nettype wire
