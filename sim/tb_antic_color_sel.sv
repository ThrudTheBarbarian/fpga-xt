`timescale 1ns/1ps
`default_nettype none
//
// tb_antic_color_sel — winning source -> Atari colour byte.
//
// T3 is the one that matters: the hi-res trick. A lit hi-res pixel takes its
// HUE from COLPF2 and only its LUMINANCE from COLPF1, which is why hi-res text
// can change brightness but not colour against its background. Getting this
// backwards produces a display that looks plausible and is wrong in exactly the
// way antic_hiresbug detects.
//
module tb_antic_color_sel;

    logic [3:0] src;
    logic [7:0] colbk, colpf0, colpf1, colpf2, colpf3;
    logic [7:0] colpm0, colpm1, colpm2, colpm3;
    wire  [7:0] color;

    antic_color_sel dut (
        .src(src),
        .colbk(colbk), .colpf0(colpf0), .colpf1(colpf1),
        .colpf2(colpf2), .colpf3(colpf3),
        .colpm0(colpm0), .colpm1(colpm1), .colpm2(colpm2), .colpm3(colpm3),
        .color(color)
    );

    int fail = 0;

    task automatic chk(input [3:0] s, input [7:0] want, input string tag);
        begin
            src = s; #1;
            if (color !== want) begin
                $display("FAIL %s: src %0d -> $%02h, expected $%02h", tag, s, color, want);
                fail++;
            end
        end
    endtask

    initial begin
        // Distinct values so any mis-wiring shows up as an obvious swap.
        colbk  = 8'h10; colpf0 = 8'h20; colpf1 = 8'h34;
        colpf2 = 8'hA8; colpf3 = 8'h50;
        colpm0 = 8'h60; colpm1 = 8'h70; colpm2 = 8'h80; colpm3 = 8'h90;

        // ---- T1: the straight playfield/background sources ----------------
        chk(4'd0, 8'h10, "T1 BK");
        chk(4'd1, 8'h20, "T1 PF0");
        chk(4'd2, 8'h34, "T1 PF1");
        chk(4'd3, 8'hA8, "T1 PF2");
        chk(4'd4, 8'h50, "T1 PF3");

        // ---- T2: the player sources ---------------------------------------
        chk(4'd6, 8'h60, "T2 PM0");
        chk(4'd7, 8'h70, "T2 PM1");
        chk(4'd8, 8'h80, "T2 PM2");
        chk(4'd9, 8'h90, "T2 PM3");

        // ---- T3: THE HI-RES TRICK -----------------------------------------
        // COLPF2 = $A8 -> hue $A.  COLPF1 = $34 -> luma bits [3:1] = 010.
        // Result must be hue $A with luma 010, bit 0 clear: $A4.
        chk(4'd5, 8'hA4, "T3 hires lit");

        // It must follow COLPF1's LUMA, not its hue...
        colpf1 = 8'hFE;            // luma bits [3:1] = 111
        chk(4'd5, 8'hAE, "T3b hires luma follows PF1");

        // ...and COLPF2's HUE, not its luma.
        colpf2 = 8'h2F;            // hue $2, luma bits all set
        chk(4'd5, 8'h2E, "T3c hires hue follows PF2");

        // A common way to get this wrong is to emit COLPF1 outright.
        if (color === 8'hFE) begin
            $display("FAIL T3d: hi-res emitted COLPF1 whole, losing PF2's hue");
            fail++;
        end
        // ...or COLPF2 outright.
        if (color === 8'h2F) begin
            $display("FAIL T3e: hi-res emitted COLPF2 whole, losing PF1's luma");
            fail++;
        end

        // ---- T4: bit 0 is always clear ------------------------------------
        // The Atari colour byte has no bit 0; leaving PF1's bit 0 in would put
        // a stray bit into the palette index.
        colpf1 = 8'hFF; colpf2 = 8'h5F;
        chk(4'd5, 8'h5E, "T4 bit0 clear");

        // ---- T5: undefined sources fall back to background ----------------
        // Safer than X-propagating into the line buffer and the palette.
        chk(4'd10, 8'h10, "T5 undefined -> BK");
        chk(4'd15, 8'h10, "T5b undefined -> BK");

        if (fail == 0) $display("tb_antic_color_sel: all checks PASS");
        else           $display("tb_antic_color_sel: %0d FAIL", fail);
        $finish;
    end

endmodule

`default_nettype wire
