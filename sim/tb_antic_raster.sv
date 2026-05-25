// tb_antic_raster.sv — unit test for the phi2-paced ANTIC native raster timer.
//
// Drives phi2_tick (1 in 4 clks) and verifies, over a couple of frames:
//   - line_start fires exactly CYC_PER_LINE phi2 cycles apart,
//   - LINES_PER_FRAME line_starts per frame, scanline wraps,
//   - vbi_start fires once per frame, at scanline == VBI_LINE,
//   - atari_row = scanline-DISPLAY_TOP in the active band, else 0xFF,
//   - vcount = scanline >> 1,
//   - phi2_in_line spans 0..CYC_PER_LINE-1.

`default_nettype none
`timescale 1ns / 1ps

module tb_antic_raster;

    localparam int CYC = 114, LINES = 262, TOP = 8, ACTIVE = 192, VBI = 248;

    logic clk = 1'b0;  always #5 clk = ~clk;
    logic rst = 1'b1;

    // phi2_tick: 1-cycle pulse every 4 clks.
    logic [1:0] div = 2'd0;
    logic       phi2_tick;
    always_ff @(posedge clk) div <= div + 2'd1;
    assign phi2_tick = (div == 2'd0);

    wire [8:0] scanline;
    wire [7:0] phi2_in_line, atari_row, vcount;
    wire       line_start, vbi_start;

    antic_raster #(
        .CYC_PER_LINE(CYC), .LINES_PER_FRAME(LINES),
        .DISPLAY_TOP(TOP), .ACTIVE_LINES(ACTIVE), .VBI_LINE(VBI)
    ) u_dut (
        .clk(clk), .rst(rst), .phi2_tick(phi2_tick),
        .scanline(scanline), .phi2_in_line(phi2_in_line),
        .line_start(line_start), .vbi_start(vbi_start),
        .atari_row(atari_row), .vcount(vcount)
    );

    int fail = 0;
    int phi2_since_ls = 0;       // phi2 ticks since last line_start
    int ls_count = 0, vbi_count = 0;
    int prev_scanline = -1;
    int exp;
    bit first_ls = 1;

    // Count phi2 ticks; on each line_start, the gap must be CYC ticks.
    always_ff @(posedge clk) begin
        if (!rst) begin
            if (phi2_tick) phi2_since_ls <= phi2_since_ls + 1;
            if (line_start) begin
                if (!first_ls && phi2_since_ls != CYC) begin
                    $display("FAIL line gap: %0d phi2 (expected %0d) at scanline %0d",
                             phi2_since_ls, CYC, scanline);
                    fail++;
                end
                first_ls      <= 1'b0;
                phi2_since_ls <= 0;
                ls_count++;

                // scanline must advance by 1 (or wrap to 0).
                if (prev_scanline >= 0) begin
                    exp = (prev_scanline == LINES-1) ? 0 : prev_scanline + 1;
                    if (scanline != exp) begin
                        $display("FAIL scanline step: got %0d expected %0d", scanline, exp);
                        fail++;
                    end
                end
                prev_scanline <= scanline;

                // atari_row / vcount checks at each new line.
                if (scanline >= TOP && scanline < TOP+ACTIVE) begin
                    if (atari_row != scanline - TOP) begin
                        $display("FAIL atari_row: scanline %0d got %0d", scanline, atari_row);
                        fail++;
                    end
                end else if (atari_row != 8'hFF) begin
                    $display("FAIL atari_row blank: scanline %0d got %02h", scanline, atari_row);
                    fail++;
                end
                if (vcount != scanline[8:1]) begin
                    $display("FAIL vcount: scanline %0d got %0d", scanline, vcount);
                    fail++;
                end
            end
            if (vbi_start) begin
                vbi_count++;
                if (scanline != VBI) begin
                    $display("FAIL vbi at scanline %0d (expected %0d)", scanline, VBI);
                    fail++;
                end
            end
            if (phi2_in_line >= CYC) begin
                $display("FAIL phi2_in_line out of range: %0d", phi2_in_line);
                fail++;
            end
        end
    end

    initial begin
        $display("=== ANTIC_RASTER TEST ===");
        repeat (4) @(posedge clk);
        rst = 1'b0;

        // Run ~2.1 frames worth of phi2 ticks (×4 clks/tick).
        repeat (2 * LINES * CYC * 4 + LINES*CYC*4/2) @(posedge clk);

        // Over ~2 frames we expect ~2 vbi pulses and ~2*LINES line_starts.
        if (vbi_count < 2) begin
            $display("FAIL vbi_count=%0d (expected >=2)", vbi_count); fail++;
        end
        if (ls_count < 2*LINES) begin
            $display("FAIL ls_count=%0d (expected >=%0d)", ls_count, 2*LINES); fail++;
        end

        if (fail == 0) begin
            $display("*** ANTIC_RASTER OK *** %0d line_starts, %0d vbi over the run",
                     ls_count, vbi_count);
            $finish;
        end else begin
            $display("*** ANTIC_RASTER FAIL *** %0d failures", fail);
            $fatal(1);
        end
    end

    initial begin
        #80_000_000;
        $display("FAIL: tb_antic_raster watchdog");
        $fatal(1);
    end

endmodule

`default_nettype wire
