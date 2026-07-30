`timescale 1ns/1ps
`default_nettype none
//
// tb_antic_wb_adapt — the rewrite's line buffer onto the writeback tap.
//
// T3 is the one worth having: `lb_line_start` arrives four hi-res pixels into
// the NEXT line, so the row reported with a flush is the one that has just
// finished, not the one now starting. Getting that wrong tears the display by
// exactly one row, which reads as a rendering bug rather than an off-by-one.
//
module tb_antic_wb_adapt;

    logic clk = 0, rst = 1;
    always #5 clk = ~clk;

    logic       lb_wr, lb_line_start;
    logic [7:0] lb_color;
    logic [8:0] line;

    wire       pix_valid, row_flush;
    wire [7:0] pix_pair, color_lo, color_hi, atari_row;

    antic_wb_adapt dut (
        .clk(clk), .rst(rst),
        .lb_wr(lb_wr), .lb_color(lb_color), .lb_line_start(lb_line_start),
        .line(line),
        .pix_valid(pix_valid), .pix_pair(pix_pair),
        .color_lo(color_lo), .color_hi(color_hi),
        .atari_row(atari_row), .row_flush(row_flush)
    );

    int fail = 0;

    // What the writeback saw.
    logic [7:0] got_lo [0:255];
    logic [7:0] got_hi [0:255];
    int npairs;
    int nflush;
    logic [7:0] last_row;

    always_ff @(posedge clk) if (!rst) begin
        if (pix_valid) begin
            got_lo[pix_pair] <= color_lo;
            got_hi[pix_pair] <= color_hi;
            npairs <= npairs + 1;
        end
        if (row_flush) begin
            last_row <= atari_row;
            nflush   <= nflush + 1;
        end
    end

    // One scanline: rewind, then 456 pixels whose colour is their index.
    task automatic do_line(input int ln);
        begin
            @(negedge clk); line = 9'(ln); lb_line_start = 1'b1;
            @(negedge clk); lb_line_start = 1'b0;
            for (int i = 0; i < 456; i++) begin
                lb_color = 8'(i);
                lb_wr    = 1'b1;
                @(negedge clk);
                lb_wr    = 1'b0;
                @(negedge clk);
            end
        end
    endtask

    initial begin
        lb_wr = 0; lb_line_start = 0; lb_color = 0; line = 0;
        npairs = 0; nflush = 0; last_row = 8'hFF;

        repeat (3) @(posedge clk);
        rst = 0;
        @(posedge clk);

        // ---- T1: exactly 320 pixels captured, as 160 pairs ----------------
        do_line(8);
        npairs = 0;
        do_line(9);                     // the flush for line 8 lands here
        if (npairs != 160) begin
            $display("FAIL T1: %0d pairs captured, expected 160", npairs); fail++;
        end

        // ---- T2: the window is buffer pixels 80..399 ----------------------
        // Colour equals buffer index, so pair 0 must be pixels 80 and 81 and
        // pair 159 must be 398 and 399.
        if (got_lo[0] !== 8'd80 || got_hi[0] !== 8'd81) begin
            $display("FAIL T2: pair 0 is $%02h/$%02h, expected 80/81",
                     got_lo[0], got_hi[0]);
            fail++;
        end
        if (got_lo[159] !== 8'((398)) || got_hi[159] !== 8'((399))) begin
            $display("FAIL T2b: pair 159 is $%02h/$%02h, expected %0d/%0d",
                     got_lo[159], got_hi[159], 398 & 255, 399 & 255);
            fail++;
        end
        // The border either side is not captured at all.
        if (got_lo[0] === 8'd0) begin
            $display("FAIL T2c: the window started at pixel 0, not 80"); fail++;
        end

        // ---- T3: the flush reports the row that just FINISHED --------------
        // lb_line_start arrives four pixels into the next line, so `line` has
        // already advanced when the flush fires.
        nflush = 0;
        do_line(20);                    // rewinds, reporting line 9
        if (nflush != 1 || last_row !== 8'd1) begin
            $display("FAIL T3: flush reported row %0d after finishing line 9, expected row 1",
                     last_row);
            fail++;
        end
        nflush = 0;
        do_line(21);                    // rewinds, reporting line 20
        if (last_row !== 8'd12) begin
            $display("FAIL T3b: flush reported row %0d after finishing line 20, expected 12",
                     last_row);
            fail++;
        end

        // ---- T4: rows outside the captured band produce no flush ----------
        nflush = 0;
        do_line(3);                     // reports line 21 -> row 13, valid
        do_line(4);                     // reports line 3  -> above ROW0, none
        if (nflush != 1) begin
            $display("FAIL T4: %0d flushes for one valid row and one above the band",
                     nflush);
            fail++;
        end
        nflush = 0;
        do_line(250);                   // reports line 4, above the band
        do_line(251);                   // reports line 250, below it
        if (nflush != 0) begin
            $display("FAIL T4b: %0d flushes for rows outside the band", nflush);
            fail++;
        end

        // ---- T5: a full band of rows all report -----------------------------
        nflush = 0;
        for (int r = 8; r < 12; r++) do_line(r);
        do_line(12);
        if (nflush != 4) begin
            $display("FAIL T5: %0d flushes for four captured rows", nflush); fail++;
        end
        if (last_row !== 8'd3) begin
            $display("FAIL T5b: last row reported %0d, expected 3", last_row); fail++;
        end

        if (fail == 0) $display("tb_antic_wb_adapt: all checks PASS");
        else           $display("tb_antic_wb_adapt: %0d FAIL", fail);
        $finish;
    end

    initial begin
        #4000000;
        $display("FAIL: timeout");
        $finish;
    end

endmodule

`default_nettype wire
