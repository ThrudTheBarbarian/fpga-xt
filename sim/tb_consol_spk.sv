// tb_consol_spk.sv — CONSOL ($D01F) bit 3 is the CONSOLE SPEAKER (the XL key click).
//
// The click is the OS pulsing bit 3.  gtia_reg_file used to latch the write as
// wdata[2:0], so the speaker bit was discarded at the register and reached
// nothing — which is why the click worked on an earlier board (the legacy
// gtia_regs latches all 8 bits) and silently disappeared once antic2's
// gtia_reg_file became the live GTIA.  This bench pins the contract: bit 3 must
// reach consol_spk, and it must NOT disturb the console-key reads that the OS
// key scan and the ACID console-key vectors depend on.
//
// (Kept separate from tb_gtia_reg_file.sv on purpose: that bench no longer
// elaborates — it binds a `pm_mask` port the DUT dropped when VDELAY moved
// inside gtia_reg_file — so it could not host this test.)
`timescale 1ns/1ps
`default_nettype none

module tb_consol_spk;
    logic clk = 0, rst = 1;
    always #5 clk = ~clk;

    logic [7:0] addr = 0, wdata = 0;
    logic       we = 0;
    wire  [7:0] rdata;
    logic [7:0] consol_keys = 8'hFF;
    wire        consol_spk;
    int fail = 0;

    gtia_reg_file dut (
        .clk(clk), .rst(rst),
        .addr(addr), .we(we), .wdata(wdata), .rdata(rdata),
        .pm_we(1'b0), .pm_obj(3'd0), .pm_data(8'h00), .pm_fetch(1'b0),
        .m_pf(16'd0), .p_pf(16'd0), .m_pl(16'd0), .p_pl(16'd0),
        .trig0(8'hFF), .trig1(8'hFF), .trig2(8'hFF), .trig3(8'hFF),
        .pal_sense(8'h0E), .consol_keys(consol_keys), .consol_spk(consol_spk),
        .hposp0(), .hposp1(), .hposp2(), .hposp3(),
        .hposm0(), .hposm1(), .hposm2(), .hposm3(),
        .sizep0(), .sizep1(), .sizep2(), .sizep3(), .sizem(),
        .grafp0(), .grafp1(), .grafp2(), .grafp3(), .grafm(),
        .colpm0(), .colpm1(), .colpm2(), .colpm3(),
        .colpf0(), .colpf1(), .colpf2(), .colpf3(),
        .colbk(), .prior(), .vdelay(), .gractl(), .hitclr()
    );

    task automatic wr(input [7:0] a, input [7:0] d);
        begin
            @(negedge clk); addr = a; wdata = d; we = 1'b1;
            @(negedge clk); we = 1'b0;
        end
    endtask
    task automatic rd(input [7:0] a, output [7:0] o);
        begin
            @(negedge clk); addr = a; #1 o = rdata;
        end
    endtask
    task automatic chk(input string s, input got, input exp);
        if (got !== exp) begin $display("FAIL %s: got %b want %b", s, got, exp); fail++; end
        else $display("  ok  %s", s);
    endtask

    initial begin
        repeat (4) @(negedge clk); rst = 0; repeat (2) @(negedge clk);
        begin logic [7:0] v;
            wr(8'h1F, 8'h00);
            chk("speaker low with bit3 clear", consol_spk, 1'b0);

            wr(8'h1F, 8'h08);                       // speaker bit only
            chk("bit3 reaches consol_spk",     consol_spk, 1'b1);
            rd(8'h1F, v);
            if (v[2:0] !== 3'b111) begin
                $display("FAIL bit3 disturbed the key lines (%03b)", v[2:0]); fail++;
            end else $display("  ok  key lines undisturbed by bit3");

            wr(8'h1F, 8'h0F);                       // speaker + all three pulled
            rd(8'h1F, v);
            if (consol_spk !== 1'b1 || v[2:0] !== 3'b000) begin
                $display("FAIL spk=%b lines=%03b, want 1/000", consol_spk, v[2:0]); fail++;
            end else $display("  ok  speaker and key lines are independent");

            wr(8'h1F, 8'h00);                       // the click's other half
            chk("speaker returns low",         consol_spk, 1'b0);

            consol_keys = 8'hFB;                    // OPTION held
            wr(8'h1F, 8'h08);
            rd(8'h1F, v);
            if (v[2:0] !== 3'b011 || consol_spk !== 1'b1) begin
                $display("FAIL held key with speaker on: %03b spk=%b", v[2:0], consol_spk); fail++;
            end else $display("  ok  a held key still reads correctly with the speaker on");
        end
        if (fail == 0) $display("*** CONSOL_SPK OK ***");
        else           $display("*** CONSOL_SPK FAIL *** %0d", fail);
        $finish;
    end
endmodule
`default_nettype wire
