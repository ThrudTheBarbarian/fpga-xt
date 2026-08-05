`timescale 1ns/1ps
//
// tb_antic_emit_win -- the display window, driven by the REAL geometry block.
//
// The window numbers are not invented here: antic_pf_geom is instantiated and
// asked for them, so this tests the pair rather than a transcription of what
// antic_pf_geom was believed to say.  What it checks is that the right NUMBER
// of pixels is emitted for each width, that a width of zero emits nothing, and
// that HSCROL moves the window without changing its length.
//
module tb_antic_emit_win;

    logic clk = 0, rst = 1;
    always #5 clk = ~clk;

    logic       line_start = 0, px_tick = 0;
    logic [1:0] pf_width = 2'd2;
    logic       hscrol_en = 0;
    logic [3:0] hscrol = 4'd0;

    wire [8:0] px_start, px_stop, px_pos;
    wire       emit_en;

    antic_pf_geom u_geom (
        .pf_width(pf_width), .hscrol_en(hscrol_en), .hscrol(hscrol),
        .is_char(1'b0), .bpp(2'd0), .px_width(4'd1),
        .pf_on(), .bytes_per_line(), .pf_step(),
        .dma_start(), .dma_stop(), .disp_start(), .disp_stop(),
        .px_start(px_start), .px_stop(px_stop), .hs_delay(), .hs_fine()
    );

    antic_emit_win dut (
        .clk(clk), .rst(rst),
        .line_start(line_start), .px_tick(px_tick),
        .px_start(px_start), .px_stop(px_stop),
        .emit_en(emit_en), .px_pos(px_pos)
    );

    integer errors = 0;
    integer count;
    integer first_px;

    // One scanline: 114 machine cycles of 4 hi-res pixels each.
    task run_line;
        integer k;
        begin
            count = 0; first_px = -1;
            @(posedge clk);
            line_start <= 1'b1; @(posedge clk); line_start <= 1'b0;
            for (k = 0; k < 456; k = k + 1) begin
                px_tick <= 1'b1;
                @(posedge clk);
                if (emit_en) begin
                    if (first_px < 0) first_px = px_pos;
                    count = count + 1;
                end
                px_tick <= 1'b0;
                @(posedge clk);
            end
        end
    endtask

    task check(input [255:0] what, input integer got, input integer exp);
        begin
            if (got !== exp) begin
                $display("  FAIL %0s: got %0d expected %0d", what, got, exp);
                errors = errors + 1;
            end else $display("  PASS %0s = %0d", what, got);
        end
    endtask

    integer narrow_n, normal_n, wide_n, shifted_first;

    initial begin
        repeat (4) @(posedge clk);
        rst = 0;

        // The lengths come from the geometry block itself, so this asserts the
        // RELATIONSHIP -- narrow < normal < wide, and each a whole number of
        // 4-pixel machine cycles -- rather than three magic numbers.
        pf_width <= 2'd1; @(posedge clk); run_line(); narrow_n = count;
        $display("narrow: %0d pixels from %0d", narrow_n, first_px);
        pf_width <= 2'd2; @(posedge clk); run_line(); normal_n = count;
        $display("normal: %0d pixels from %0d", normal_n, first_px);
        pf_width <= 2'd3; @(posedge clk); run_line(); wide_n = count;
        $display("wide:   %0d pixels from %0d", wide_n, first_px);

        check("narrow is 128 colour clocks of hi-res pixels", narrow_n, 256);
        check("normal is 160", normal_n, 320);
        check("wide is 192",   wide_n,   384);

        if (!(narrow_n < normal_n && normal_n < wide_n)) begin
            $display("  FAIL widths do not increase");
            errors = errors + 1;
        end else $display("  PASS widths increase narrow < normal < wide");

        // A width of zero is not a width: nothing is displayed at all.
        pf_width <= 2'd0; @(posedge clk); run_line();
        check("width zero emits nothing", count, 0);

        // HSCROL moves the window without lengthening it.  The scrolled row
        // fetches wider so it has something to scroll in, but it SHOWS the same
        // rectangle -- that is the distinction this whole module exists for.
        pf_width <= 2'd2; hscrol_en <= 1'b1; hscrol <= 4'd0;
        @(posedge clk); run_line();
        shifted_first = first_px;
        check("scrolled, hscrol 0: same length as normal", count, normal_n);

        hscrol <= 4'd4; @(posedge clk); run_line();
        check("scrolled, hscrol 4: still the same length", count, normal_n);
        if (first_px === shifted_first) begin
            $display("  FAIL hscrol 4 did not move the window (still %0d)", first_px);
            errors = errors + 1;
        end else
            $display("  PASS hscrol moved the window: %0d -> %0d",
                     shifted_first, first_px);

        if (errors == 0) $display("tb_antic_emit_win: all checks PASS");
        else             $display("tb_antic_emit_win: %0d FAIL", errors);
        $finish;
    end

endmodule
