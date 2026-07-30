`timescale 1ns/1ps
`default_nettype none
//
// tb_antic_char_ctl — CHACTL blank, invert and reflect (antic_charcontrol).
//
// T4 is the one that catches the plausible-but-wrong implementation: blank and
// invert must apply ONLY in modes 2 and 3, where bit 7 of the character code
// means "inverse video". In modes 4/5 that bit picks a colour and in 6/7 the top
// two bits do, so blanking on it would wipe out ordinary coloured text.
//
module tb_antic_char_ctl;

    logic [2:0] chactl;
    logic       is_char;
    logic [1:0] bpp;
    logic [3:0] px_width;
    logic [7:0] char_code;
    logic [2:0] glyph_row_in;
    logic [7:0] glyph_data_in;

    wire [2:0] glyph_row;
    wire [7:0] glyph_data;

    antic_char_ctl dut (
        .chactl(chactl), .is_char(is_char), .bpp(bpp), .px_width(px_width),
        .char_code(char_code), .glyph_row_in(glyph_row_in),
        .glyph_data_in(glyph_data_in),
        .glyph_row(glyph_row), .glyph_data(glyph_data)
    );

    int fail = 0;

    // Mode 2/3 shape: a 1bpp, 1-pixel-wide character mode.
    task automatic mode23; begin is_char = 1; bpp = 2'd1; px_width = 4'd1; end endtask
    task automatic mode45; begin is_char = 1; bpp = 2'd2; px_width = 4'd2; end endtask
    task automatic mode67; begin is_char = 1; bpp = 2'd1; px_width = 4'd2; end endtask
    task automatic bitmap; begin is_char = 0; bpp = 2'd1; px_width = 4'd1; end endtask

    initial begin
        chactl = 3'b000; glyph_row_in = 3'd0; glyph_data_in = 8'h3C;
        char_code = 8'h41; mode23(); #1;

        // ---- T1: CHACTL $00 passes everything straight through -----------
        // The baseline has to be right before any feature applies — that is
        // exactly where antic_charcontrol was failing.
        if (glyph_data !== 8'h3C || glyph_row !== 3'd0) begin
            $display("FAIL T1: chactl $00 altered data $%02h row %0d",
                     glyph_data, glyph_row);
            fail++;
        end
        char_code = 8'hC1; #1;              // inverse-video character
        if (glyph_data !== 8'h3C) begin
            $display("FAIL T1b: chactl $00 altered an inverse char to $%02h", glyph_data);
            fail++;
        end

        // ---- T2: invert ($02), the setting the OS leaves in place ---------
        chactl = 3'b010;
        char_code = 8'h41; #1;              // ordinary character: untouched
        if (glyph_data !== 8'h3C) begin
            $display("FAIL T2: invert altered an ORDINARY char to $%02h", glyph_data);
            fail++;
        end
        char_code = 8'hC1; #1;              // bit 7 set: inverted
        if (glyph_data !== 8'hC3) begin
            $display("FAIL T2b: invert gave $%02h, expected $C3", glyph_data);
            fail++;
        end

        // ---- T3: blank ($01), and blank beats invert ----------------------
        chactl = 3'b001;
        char_code = 8'h41; #1;
        if (glyph_data !== 8'h3C) begin
            $display("FAIL T3: blank altered an ORDINARY char to $%02h", glyph_data);
            fail++;
        end
        char_code = 8'hC1; #1;
        if (glyph_data !== 8'h00) begin
            $display("FAIL T3b: blank gave $%02h, expected $00", glyph_data);
            fail++;
        end
        chactl = 3'b011; #1;                // both: blanking wins
        if (glyph_data !== 8'h00) begin
            $display("FAIL T3c: blank+invert gave $%02h, expected $00 (blank wins)",
                     glyph_data);
            fail++;
        end

        // ---- T4: blank/invert are modes 2 and 3 ONLY ----------------------
        // In 4/5 the top code bit is a colour select; in 6/7 the top two are.
        char_code = 8'hC1;
        chactl = 3'b010;
        mode45(); #1;
        if (glyph_data !== 8'h3C) begin
            $display("FAIL T4: invert fired in a mode 4/5 (got $%02h) — bit 7 there is a COLOUR",
                     glyph_data);
            fail++;
        end
        mode67(); #1;
        if (glyph_data !== 8'h3C) begin
            $display("FAIL T4b: invert fired in a mode 6/7 (got $%02h)", glyph_data);
            fail++;
        end
        chactl = 3'b001;
        mode45(); #1;
        if (glyph_data !== 8'h3C) begin
            $display("FAIL T4c: blank fired in a mode 4/5 (got $%02h)", glyph_data);
            fail++;
        end
        bitmap(); #1;
        if (glyph_data !== 8'h3C) begin
            $display("FAIL T4d: blank fired on a BITMAP byte (got $%02h)", glyph_data);
            fail++;
        end

        // ---- T5: reflect is an address XOR --------------------------------
        chactl = 3'b100; mode23(); char_code = 8'h41;
        for (int r = 0; r < 8; r++) begin
            glyph_row_in = 3'(r); #1;
            if (glyph_row !== 3'(7 - r)) begin
                $display("FAIL T5: reflect row %0d -> %0d, expected %0d",
                         r, glyph_row, 7 - r);
                fail++;
            end
        end
        // Reflect must not touch the DATA...
        glyph_row_in = 3'd0; #1;
        if (glyph_data !== 8'h3C) begin
            $display("FAIL T5b: reflect altered the data to $%02h", glyph_data); fail++;
        end
        // ...and it applies whatever the character mode, since it is not about
        // the inverse-video flag at all.
        mode67(); glyph_row_in = 3'd2; #1;
        if (glyph_row !== 3'd5) begin
            $display("FAIL T5c: reflect did not apply in a mode 6/7 (row %0d)", glyph_row);
            fail++;
        end

        // ---- T6: reflect and invert compose -------------------------------
        chactl = 3'b110; mode23(); char_code = 8'hC1; glyph_row_in = 3'd1; #1;
        if (glyph_row !== 3'd6 || glyph_data !== 8'hC3) begin
            $display("FAIL T6: reflect+invert gave row %0d data $%02h, expected 6/$C3",
                     glyph_row, glyph_data);
            fail++;
        end

        if (fail == 0) $display("tb_antic_char_ctl: all checks PASS");
        else           $display("tb_antic_char_ctl: %0d FAIL", fail);
        $finish;
    end

endmodule

`default_nettype wire
