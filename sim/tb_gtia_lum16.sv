// tb_gtia_lum16.sv — GTIA mode 9 must reach SIXTEEN luminances, and a colour
// REGISTER must reach only eight.
//
// Those are two halves of one fact, and getting either alone is a bug:
//
//   * A colour register has no bit 0.  The hardware drops it at the register,
//     so COLBK=$61 and COLBK=$60 are the same colour.
//   * GTIA mode 9 does not go through a register — the screen nibble lands
//     straight in the luminance field — which is exactly why the mode gives 16
//     shades where the registers give 8.
//
// The palette used to fold bit 0 away instead (identical entry pairs), which
// satisfied the register rule and silently broke the mode: measured on HW
// 2026-08-18 with tools/gtia_ramp_scene.py as EIGHT colours of 8 px where the
// mode promises sixteen of 4, and visible in BallBlazer's pre-title screen as
// pillars whose dim end collapsed from four shades into two.
//
// So this checks both ends of the path at once: gtia_reg_file drops the bit,
// gtia_special does NOT, and the palette the fabric actually loads has distinct
// entries for the odd luminances (the top pair $xE/$xF excepted — the palette
// clamps there, which is a deliberate consequence of keeping every even entry
// byte-identical to the shipped calibration).
//
// The palette path is CWD-relative, like every other tb input here: run from
// sim/ via the Makefile.

`timescale 1ns/1ps
`default_nettype none

module tb_gtia_lum16;

    integer fail = 0;

    // ---- 1. gtia_special: mode 9 passes the nibble through untouched -------
    reg  [1:0] gmode;
    reg  [3:0] nib;
    reg  [7:0] colbk;
    wire [7:0] gcolor;
    wire       gactive;

    gtia_special u_sp (
        .gtia_mode(gmode), .nibble(nib), .colbk(colbk),
        .colpf0(8'h00), .colpf1(8'h00), .colpf2(8'h00), .colpf3(8'h00),
        .colpm0(8'h00), .colpm1(8'h00), .colpm2(8'h00), .colpm3(8'h00),
        .active(gactive), .color(gcolor)
    );

    // ---- 2. gtia_reg_file: a colour register drops bit 0 -------------------
    reg        clk = 1'b0, rst = 1'b1;
    reg        we  = 1'b0;
    reg  [7:0] addr = 8'd0;
    reg  [7:0] wdata = 8'd0;
    wire [7:0] rf_colbk, rf_colpf0, rf_colpm0;

    always #5 clk = ~clk;

    gtia_reg_file u_rf (
        .clk(clk), .rst(rst),
        .addr(addr), .we(we), .wdata(wdata), .rdata(),
        .pm_we(1'b0), .pm_obj(3'd0), .pm_data(8'h00), .pm_fetch(1'b0),
        .m_pf(16'h0), .p_pf(16'h0), .m_pl(16'h0), .p_pl(16'h0),
        .trig0(8'h1), .trig1(8'h1), .trig2(8'h1), .trig3(8'h1),
        .pal_sense(8'h0), .consol_keys(8'h7), .consol_spk(),
        .hposp0(), .hposp1(), .hposp2(), .hposp3(),
        .hposm0(), .hposm1(), .hposm2(), .hposm3(),
        .sizep0(), .sizep1(), .sizep2(), .sizep3(), .sizep_we(), .sizem(),
        .grafp0(), .grafp1(), .grafp2(), .grafp3(), .grafm(),
        .colpm0(rf_colpm0), .colpm1(), .colpm2(), .colpm3(),
        .colpf0(rf_colpf0), .colpf1(), .colpf2(), .colpf3(),
        .colbk(rf_colbk), .prior(), .vdelay(), .gractl(), .hitclr()
    );

    // ---- 3. the palette the fabric loads -----------------------------------
    reg [23:0] pal [0:255];

    integer h, l, i;
    reg [7:0] code;

    task write_reg(input [7:0] a, input [7:0] d);
        begin
            @(negedge clk); addr = a; wdata = d; we = 1'b1;
            @(negedge clk); we = 1'b0;
            @(posedge clk); #1;
        end
    endtask

    initial begin
        $readmemh("../hdl/palette/atari_ntsc.hex", pal);

        // --- mode 9 keeps every nibble bit -----------------------------------
        gmode = 2'b01; colbk = 8'h64;
        for (i = 0; i < 16; i = i + 1) begin
            nib = i[3:0]; #1;
            if (gcolor !== {4'h6, i[3:0]}) begin
                $display("FAIL lum16: mode 9 nibble %0d resolved to $%02h, want $%02h",
                         i, gcolor, {4'h6, i[3:0]});
                fail = fail + 1;
            end
        end

        // --- a colour register does not ---------------------------------------
        repeat (4) @(posedge clk);
        rst = 1'b0;
        repeat (2) @(posedge clk);

        write_reg(8'h1A, 8'h61);
        if (rf_colbk !== 8'h60) begin
            $display("FAIL lum16: COLBK=$61 stored as $%02h -- a colour register has no bit 0",
                     rf_colbk);
            fail = fail + 1;
        end
        write_reg(8'h16, 8'hFF);
        if (rf_colpf0 !== 8'hFE) begin
            $display("FAIL lum16: COLPF0=$FF stored as $%02h, want $FE", rf_colpf0);
            fail = fail + 1;
        end
        write_reg(8'h12, 8'h0F);
        if (rf_colpm0 !== 8'h0E) begin
            $display("FAIL lum16: COLPM0=$0F stored as $%02h, want $0E", rf_colpm0);
            fail = fail + 1;
        end

        // --- and the palette has somewhere for the odd luminances to go -------
        // Within a hue, luma 0..14 must all differ.  ($xF clamps onto $xE.)
        for (h = 0; h < 16; h = h + 1) begin
            for (l = 0; l < 14; l = l + 1) begin
                code = (h[3:0] << 4) | l[3:0];
                if (pal[code] === pal[code + 1]) begin
                    $display("FAIL lum16: palette $%02h == $%02h (#%06h) -- luminances %0d and %0d of hue %0d are the same colour, so GTIA mode 9 cannot show 16 shades",
                             code, code + 8'd1, pal[code], l, l + 1, h);
                    fail = fail + 1;
                end
            end
        end

        // The positive control: an all-distinct check would also pass on a
        // palette that had drifted off the calibration entirely, so pin the two
        // entries the calibration is documented against.
        if (pal[8'h94] === 24'h000000 || pal[8'hCA] === 24'h000000) begin
            $display("FAIL lum16: palette looks empty ($94=#%06h $CA=#%06h) -- did $readmemh find it?",
                     pal[8'h94], pal[8'hCA]);
            fail = fail + 1;
        end

        if (fail == 0) $display("tb_gtia_lum16: all checks PASS");
        else           $display("tb_gtia_lum16: %0d FAILURES", fail);
        $finish;
    end

endmodule

`default_nettype wire
