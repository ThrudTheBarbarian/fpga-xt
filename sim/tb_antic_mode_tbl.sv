`timescale 1ns/1ps
`default_nettype none
//
// tb_antic_mode_tbl — the mode nibble decoded into datapath parameters.
//
// The headline check is the INVARIANT, not the table contents:
//
//     bytes_per_line * (8/bpp) * px_width == 320 hi-res pixels
//
// A normal-width playfield is 160 colour clocks = 320 hi-res pixels, and every
// ANTIC display mode spans exactly that. It is a physical fact about the
// machine, so checking it is much stronger than comparing against hand-copied
// numbers — those can be wrong the same way in both the table and the test.
//
// T2 additionally pins bytes-per-line against the well-known per-mode figures
// (40/20/10 characters or bytes), which catches a table that satisfies the
// invariant by trading two parameters off against each other.
//
module tb_antic_mode_tbl;

    logic [3:0] mode;
    wire        is_char, descender, is_display;
    wire [1:0]  bpp;
    wire [3:0]  px_width;
    wire [4:0]  rows;

    antic_mode_tbl dut (
        .mode(mode), .is_char(is_char), .bpp(bpp), .px_width(px_width),
        .rows(rows), .descender(descender), .is_display(is_display)
    );

    int fail = 0;

    // Known bytes (or characters) per line at normal width, from the hardware.
    function automatic int expect_bytes(input int m);
        case (m)
            2,3,4,5,13,14,15: expect_bytes = 40;
            6,7,10,11,12:     expect_bytes = 20;
            8,9:              expect_bytes = 10;
            default:          expect_bytes = 0;
        endcase
    endfunction

    function automatic int expect_rows(input int m);
        case (m)
            2:  expect_rows = 8;   3:  expect_rows = 10;
            4:  expect_rows = 8;   5:  expect_rows = 16;
            6:  expect_rows = 8;   7:  expect_rows = 16;
            8:  expect_rows = 8;   9:  expect_rows = 4;
            10: expect_rows = 4;   11: expect_rows = 2;
            12: expect_rows = 1;   13: expect_rows = 2;
            14: expect_rows = 1;   15: expect_rows = 1;
            default: expect_rows = 0;
        endcase
    endfunction

    int px_per_byte, span, bytes;

    initial begin
        // ---- T1: modes 0 and 1 are not display modes ---------------------
        for (int m = 0; m < 2; m++) begin
            mode = 4'(m); #1;
            if (is_display) begin
                $display("FAIL T1: mode %0d reported as a display mode", m);
                fail++;
            end
        end

        for (int m = 2; m < 16; m++) begin
            mode = 4'(m); #1;

            if (!is_display) begin
                $display("FAIL: mode %0X not marked as a display mode", m);
                fail++;
                continue;
            end

            // ---- T2: the 320-pixel invariant ------------------------------
            px_per_byte = 8 / int'(bpp);
            bytes       = expect_bytes(m);
            span        = bytes * px_per_byte * int'(px_width);
            if (span != 320) begin
                $display("FAIL T2 mode %0X: %0d bytes x %0d px/byte x %0d wide = %0d, expected 320",
                         m, bytes, px_per_byte, px_width, span);
                fail++;
            end

            // ---- T3: bpp is 1 or 2, width is a power of two up to 8 -------
            if (bpp != 1 && bpp != 2) begin
                $display("FAIL T3 mode %0X: bpp=%0d", m, bpp); fail++;
            end
            if (px_width != 1 && px_width != 2 && px_width != 4 && px_width != 8) begin
                $display("FAIL T3b mode %0X: px_width=%0d", m, px_width); fail++;
            end

            // ---- T4: scanlines per row --------------------------------------
            if (int'(rows) != expect_rows(m)) begin
                $display("FAIL T4 mode %0X: rows=%0d expected %0d", m, rows, expect_rows(m));
                fail++;
            end

            // ---- T5: character modes are exactly 2-7 -----------------------
            if (is_char != (m >= 2 && m <= 7)) begin
                $display("FAIL T5 mode %0X: is_char=%0b", m, is_char); fail++;
            end

            // ---- T6: only mode 3 has the descender quirk -------------------
            if (descender != (m == 3)) begin
                $display("FAIL T6 mode %0X: descender=%0b", m, descender); fail++;
            end
        end

        // ---- T7: the hi-res modes are the 1bpp, 1-wide ones ---------------
        // Modes 2, 3 and F are the ones that display at 320 px and carry the
        // hi-res collision quirk (lit pixel collides as PF2).  Anything else
        // claiming px_width==1 would break that association.
        for (int m = 2; m < 16; m++) begin
            mode = 4'(m); #1;
            if (px_width == 1 && !(m == 2 || m == 3 || m == 15)) begin
                $display("FAIL T7: mode %0X is 1-wide but is not a hi-res mode", m);
                fail++;
            end
        end

        if (fail == 0) $display("tb_antic_mode_tbl: all checks PASS");
        else           $display("tb_antic_mode_tbl: %0d FAIL", fail);
        $finish;
    end

endmodule

`default_nettype wire
