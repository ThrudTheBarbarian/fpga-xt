`timescale 1ns/1ps
`default_nettype none
//
// tb_gtia_special — GTIA modes 9, 10 and 11.
//
// T2 and T4 are the pair that catch the easy mistake: mode 9 puts the nibble in
// the LUMA and takes the hue from COLBK, mode 11 does the opposite. Swap them
// and both still produce a plausible picture, just the wrong one — 16 shades of
// the wrong thing.
//
// T3b checks that mode 10's table really does stop at nine. There are only nine
// colour registers to point at, so values 8-15 all give COLBK; extending the
// table to sixteen entries would be inventing hardware.
//
module tb_gtia_special;

    logic [1:0] gtia_mode;
    logic [3:0] nibble;
    logic [7:0] colbk, colpf0, colpf1, colpf2, colpf3;
    logic [7:0] colpm0, colpm1, colpm2, colpm3;

    wire       active;
    wire [7:0] color;

    gtia_special dut (
        .gtia_mode(gtia_mode), .nibble(nibble), .colbk(colbk),
        .colpf0(colpf0), .colpf1(colpf1), .colpf2(colpf2), .colpf3(colpf3),
        .colpm0(colpm0), .colpm1(colpm1), .colpm2(colpm2), .colpm3(colpm3),
        .active(active), .color(color)
    );

    int fail = 0;

    task automatic chk(input [1:0] m, input [3:0] n, input [7:0] want,
                       input string tag);
        begin
            gtia_mode = m; nibble = n; #1;
            if (color !== want) begin
                $display("FAIL %s: mode %0d nibble $%01h -> $%02h, expected $%02h",
                         tag, m, n, color, want);
                fail++;
            end
        end
    endtask

    initial begin
        // Distinct values so any mis-wiring shows as an obvious swap.
        colbk  = 8'h5A;                 // hue 5, luma A
        colpf0 = 8'h10; colpf1 = 8'h20; colpf2 = 8'h30; colpf3 = 8'h40;
        colpm0 = 8'h60; colpm1 = 8'h70; colpm2 = 8'h80; colpm3 = 8'h90;
        gtia_mode = 2'b00; nibble = 4'd0; #1;

        // ---- T1: mode 00 is not a GTIA mode -------------------------------
        if (active) begin
            $display("FAIL T1: PRIOR[7:6] = 00 reported as a GTIA mode"); fail++;
        end
        gtia_mode = 2'b01; #1;
        if (!active) begin
            $display("FAIL T1b: mode 9 not reported active"); fail++;
        end
        gtia_mode = 2'b10; #1;
        if (!active) begin $display("FAIL T1c: mode 10 not active"); fail++; end
        gtia_mode = 2'b11; #1;
        if (!active) begin $display("FAIL T1d: mode 11 not active"); fail++; end

        // ---- T2: mode 9 — the nibble is the LUMA --------------------------
        // COLBK $5A: hue 5.  Every pixel keeps that hue and varies only in
        // brightness.
        for (int n = 0; n < 16; n++)
            chk(2'b01, 4'(n), {4'h5, 4'(n)}, "T2");
        // The hue must follow COLBK, not stay put.
        colbk = 8'hC3;
        chk(2'b01, 4'd7, 8'hC7, "T2b mode 9 hue follows COLBK");
        colbk = 8'h5A;

        // ---- T3: mode 10 — nine colours ------------------------------------
        chk(2'b10, 4'd0, colpm0, "T3 nibble 0 -> COLPM0");
        chk(2'b10, 4'd1, colpm1, "T3b");
        chk(2'b10, 4'd2, colpm2, "T3c");
        chk(2'b10, 4'd3, colpm3, "T3d");
        chk(2'b10, 4'd4, colpf0, "T3e nibble 4 -> COLPF0");
        chk(2'b10, 4'd5, colpf1, "T3f");
        chk(2'b10, 4'd6, colpf2, "T3g");
        chk(2'b10, 4'd7, colpf3, "T3h");
        chk(2'b10, 4'd8, colbk,  "T3i nibble 8 -> COLBK");
        // ...and there is nothing beyond nine.
        for (int n = 9; n < 16; n++)
            chk(2'b10, 4'(n), colbk, "T3j beyond the nine");

        // ---- T4: mode 11 — the nibble is the HUE ---------------------------
        // The exact mirror of mode 9: COLBK $5A supplies luma A.
        for (int n = 0; n < 16; n++)
            chk(2'b11, 4'(n), {4'(n), 4'hA}, "T4");
        colbk = 8'hC3;
        chk(2'b11, 4'd7, 8'h73, "T4b mode 11 luma follows COLBK");
        colbk = 8'h5A;

        // ---- T5: 9 and 11 are not each other -------------------------------
        // The mistake that produces a plausible but wrong picture.
        chk(2'b01, 4'd7, 8'h57, "T5 mode 9");
        chk(2'b11, 4'd7, 8'h7A, "T5b mode 11");
        gtia_mode = 2'b01; nibble = 4'd7; #1;
        if (color === 8'h7A) begin
            $display("FAIL T5c: mode 9 produced mode 11's answer — luma and hue are swapped");
            fail++;
        end

        if (fail == 0) $display("tb_gtia_special: all checks PASS");
        else           $display("tb_gtia_special: %0d FAIL", fail);
        $finish;
    end

endmodule

`default_nettype wire
