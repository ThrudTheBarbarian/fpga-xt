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
// The capture window is the HW-calibrated one (X0=96, ROW0=31 — see the
// module's parameter comments for both derivations), and T6 exercises the
// runtime overscan bit: rows 8..247 into a 240-row surface.
//
module tb_antic_wb_adapt;

    logic clk = 0, rst = 1;
    always #5 clk = ~clk;

    logic       lb_wr, lb_line_start;
    logic [7:0] lb_color;
    logic [8:0] line;
    logic       overscan;

    wire       pix_valid, row_flush;
    wire [7:0] pix_pair, color_lo, color_hi, atari_row;

    antic_wb_adapt dut (
        .clk(clk), .rst(rst),
        .overscan(overscan),
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
        overscan = 0;
        npairs = 0; nflush = 0; last_row = 8'hFF;

        repeat (3) @(posedge clk);
        rst = 0;
        @(posedge clk);

        // ---- T1: exactly 320 pixels captured, as 160 pairs ----------------
        do_line(31);
        npairs = 0;
        do_line(32);                    // the flush for line 31 lands here
        if (npairs != 160) begin
            $display("FAIL T1: %0d pairs captured, expected 160", npairs); fail++;
        end

        // ---- T2: the window is buffer pixels 96..415 ----------------------
        // Colour equals buffer index (mod 256), so pair 0 must be pixels
        // 96/97 and pair 159 must be 414/415 -> $9E/$9F.
        if (got_lo[0] !== 8'd96 || got_hi[0] !== 8'd97) begin
            $display("FAIL T2: pair 0 is $%02h/$%02h, expected 96/97",
                     got_lo[0], got_hi[0]);
            fail++;
        end
        if (got_lo[159] !== 8'(414) || got_hi[159] !== 8'(415)) begin
            $display("FAIL T2b: pair 159 is $%02h/$%02h, expected %0d/%0d",
                     got_lo[159], got_hi[159], 414 & 255, 415 & 255);
            fail++;
        end
        if (got_lo[0] === 8'd0) begin
            $display("FAIL T2c: the window started at pixel 0, not 96"); fail++;
        end

        // ---- T3: the flush reports the row that just FINISHED --------------
        // lb_line_start arrives four pixels into the next line, so `line` has
        // already advanced when the flush fires.  Row = line - 31.
        nflush = 0;
        do_line(40);                    // rewinds, reporting line 32 -> row 1
        if (nflush != 1 || last_row !== 8'd1) begin
            $display("FAIL T3: flush reported row %0d after finishing line 32, expected row 1",
                     last_row);
            fail++;
        end
        nflush = 0;
        do_line(41);                    // rewinds, reporting line 40 -> row 9
        if (last_row !== 8'd9) begin
            $display("FAIL T3b: flush reported row %0d after finishing line 40, expected 9",
                     last_row);
            fail++;
        end

        // ---- T4: rows outside the captured band produce no flush ----------
        nflush = 0;
        do_line(20);                    // reports line 41 -> row 10, valid
        do_line(21);                    // reports line 20 -> above ROW0, none
        if (nflush != 1) begin
            $display("FAIL T4: %0d flushes for one valid row and one above the band",
                     nflush);
            fail++;
        end
        nflush = 0;
        do_line(250);                   // reports line 21, above the band
        do_line(251);                   // reports line 250, below it (>= 223)
        if (nflush != 0) begin
            $display("FAIL T4b: %0d flushes for rows outside the band", nflush);
            fail++;
        end

        // ---- T5: a full band of rows all report -----------------------------
        nflush = 0;
        for (int r = 31; r < 35; r++) do_line(r);
        do_line(35);
        if (nflush != 4) begin
            $display("FAIL T5: %0d flushes for four captured rows", nflush); fail++;
        end
        if (last_row !== 8'd3) begin
            $display("FAIL T5b: last row reported %0d, expected 3", last_row); fail++;
        end

        // ---- T6: overscan widens the band to 8..247, rows re-based to 8 ----
        overscan = 1;
        nflush = 0;
        do_line(8);                     // reports line 35 -> row 27, valid
        do_line(9);                     // reports line 8  -> row 0
        if (last_row !== 8'd0) begin
            $display("FAIL T6: overscan flush for line 8 reported row %0d, expected 0",
                     last_row);
            fail++;
        end
        nflush = 0;
        do_line(247);                   // reports line 9   -> row 1
        do_line(248);                   // reports line 247 -> row 239 (last)
        do_line(249);                   // reports line 248 -> outside
        if (nflush != 2 || last_row !== 8'd239) begin
            $display("FAIL T6b: overscan band end wrong (nflush=%0d last=%0d, expected 2/239)",
                     nflush, last_row);
            fail++;
        end
        // A standard-band row far outside the 192 window is captured now.
        overscan = 0;
        nflush = 0;
        do_line(230);                   // reports line 249, outside either band
        do_line(231);                   // reports line 230, outside standard band
        if (nflush != 0) begin
            $display("FAIL T6c: %0d flushes with overscan back off for row 230", nflush);
            fail++;
        end

        if (fail == 0) $display("tb_antic_wb_adapt: all checks PASS");
        else           $display("tb_antic_wb_adapt: %0d FAIL", fail);
        $finish;
    end

    initial begin
        #8000000;
        $display("FAIL: timeout");
        $finish;
    end

endmodule

`default_nettype wire
