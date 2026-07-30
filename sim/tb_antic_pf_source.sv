`timescale 1ns/1ps
`default_nettype none
//
// tb_antic_pf_source — pixel index -> playfield source.
//
// Driven through the REAL antic_mode_tbl, so the cases are mode names rather
// than hand-set flags.
//
// The check that matters most is T1: in hi-res modes the background is COLPF2,
// NOT COLBK, and a lit pixel is a DISTINCT source from PF2 even though it
// collides as PF2. Collapsing those two is what made antic_charcontrol report
// $00 where $10 was expected.
//
module tb_antic_pf_source;

    logic [3:0] mode;
    wire        is_char, descender, is_display;
    wire [1:0]  bpp;
    wire [3:0]  px_width;
    wire [4:0]  rows;

    antic_mode_tbl u_tbl (
        .mode(mode), .is_char(is_char), .bpp(bpp), .px_width(px_width),
        .rows(rows), .descender(descender), .is_display(is_display)
    );

    logic [1:0] px_val;
    logic [7:0] char_code;
    wire  [2:0] pf_src;
    wire        is_hires = (px_width == 4'd1) && (bpp == 2'd1);

    antic_pf_source dut (
        .is_char(is_char), .bpp(bpp), .is_hires(is_hires),
        .px_val(px_val), .char_code(char_code), .pf_src(pf_src)
    );

    localparam logic [2:0] SRC_BK=3'd0, SRC_PF0=3'd1, SRC_PF1=3'd2,
                           SRC_PF2=3'd3, SRC_PF3=3'd4, SRC_HIRES=3'd5;

    int fail = 0;
    // Module scope: iverilog rejects `automatic` locals in procedural blocks.
    int m8 [0:3];

    task automatic chk(input [3:0] m, input [1:0] v, input [7:0] cc,
                       input [2:0] want, input string tag);
        begin
            mode = m; px_val = v; char_code = cc; #1;
            if (pf_src !== want) begin
                $display("FAIL %s: mode %0X idx %b cc $%02h -> src %0d, expected %0d",
                         tag, m, v, cc, pf_src, want);
                fail++;
            end
        end
    endtask

    initial begin
        // ---- T1: hi-res modes — background is PF2, lit is DISTINCT --------
        // If lit collapsed to SRC_PF2 the display would lose the luma trick;
        // if background collapsed to SRC_BK the wrong register would show.
        chk(4'h2, 2'b00, 8'h00, SRC_PF2,   "T1 mode2 bg");
        chk(4'h2, 2'b01, 8'h00, SRC_HIRES, "T1 mode2 lit");
        chk(4'h3, 2'b00, 8'h00, SRC_PF2,   "T1 mode3 bg");
        chk(4'h3, 2'b01, 8'h00, SRC_HIRES, "T1 mode3 lit");
        chk(4'hF, 2'b00, 8'h00, SRC_PF2,   "T1 modeF bg");
        chk(4'hF, 2'b01, 8'h00, SRC_HIRES, "T1 modeF lit");

        // ---- T2: 2bpp bitmap modes — the plain mapping --------------------
        m8[0] = 8; m8[1] = 10; m8[2] = 13; m8[3] = 14;
        for (int i = 0; i < 4; i++)
            for (int k = 0; k < 4; k++)
                chk(4'(m8[k]), 2'(i), 8'h00,
                    (i == 0) ? SRC_BK : (i == 1) ? SRC_PF0 :
                    (i == 2) ? SRC_PF1 : SRC_PF2, "T2 bitmap2bpp");

        // ---- T3: 1bpp bitmap modes — BK or PF0 ----------------------------
        chk(4'h9, 2'b00, 8'h00, SRC_BK,  "T3 mode9 off");
        chk(4'h9, 2'b01, 8'h00, SRC_PF0, "T3 mode9 on");
        chk(4'hB, 2'b01, 8'h00, SRC_PF0, "T3 modeB on");
        chk(4'hC, 2'b01, 8'h00, SRC_PF0, "T3 modeC on");

        // ---- T4: char 2bpp (4/5) — bit 7 promotes 11 to PF3 ---------------
        chk(4'h4, 2'b11, 8'h00, SRC_PF2, "T4 mode4 11 no-bit7");
        chk(4'h4, 2'b11, 8'h80, SRC_PF3, "T4 mode4 11 bit7");
        chk(4'h5, 2'b11, 8'h80, SRC_PF3, "T4 mode5 11 bit7");
        // ...and bit 7 must NOT affect the other pairs
        chk(4'h4, 2'b01, 8'h80, SRC_PF0, "T4 mode4 01 bit7 ignored");
        chk(4'h4, 2'b10, 8'h80, SRC_PF1, "T4 mode4 10 bit7 ignored");
        chk(4'h4, 2'b00, 8'h80, SRC_BK,  "T4 mode4 00 bit7 ignored");

        // ---- T5: char 1bpp (6/7) — code bits [7:6] pick the playfield -----
        chk(4'h6, 2'b01, 8'h00, SRC_PF0, "T5 mode6 cc00");
        chk(4'h6, 2'b01, 8'h40, SRC_PF1, "T5 mode6 cc01");
        chk(4'h6, 2'b01, 8'h80, SRC_PF2, "T5 mode6 cc10");
        chk(4'h6, 2'b01, 8'hC0, SRC_PF3, "T5 mode6 cc11");
        chk(4'h7, 2'b01, 8'hC0, SRC_PF3, "T5 mode7 cc11");
        // an unlit pixel is background whatever the code says
        chk(4'h6, 2'b00, 8'hC0, SRC_BK,  "T5 mode6 unlit");

        // ---- T6: bitmap modes ignore char_code entirely -------------------
        // A bitmap mode that responded to char_code would corrupt the display
        // whenever the previous character happened to have a high bit set.
        chk(4'hE, 2'b11, 8'hFF, SRC_PF2, "T6 modeE ignores cc");
        chk(4'h8, 2'b11, 8'hC0, SRC_PF2, "T6 mode8 ignores cc");
        chk(4'hC, 2'b01, 8'hFF, SRC_PF0, "T6 modeC ignores cc");

        if (fail == 0) $display("tb_antic_pf_source: all checks PASS");
        else           $display("tb_antic_pf_source: %0d FAIL", fail);
        $finish;
    end

endmodule

`default_nettype wire
