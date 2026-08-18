// tb_gtia_prior_eq.sv — gtia_priority against the REAL GTIA equations, exhaustively.
//
// The chip's priority logic is not a ranking.  It is nine boolean equations
// (Altirra src/Altirra/source/gtiatables.cpp, which documents the hardware):
//
//   SP0 = P0 * /(PF01*PRI23) * /(PRI2*PF23)
//   SP1 = P1 * /(PF01*PRI23) * /(PRI2*PF23) * (/P0 + MULTI)
//   SP2 = P2 * /P01 * /(PF23*PRI12) * /(PF01*/PRI0)
//   SP3 = P3 * /P01 * /(PF23*PRI12) * /(PF01*/PRI0) * (/P2 + MULTI)
//   SF0 = PF0 * /(P23*PRI0)  * /(P01*PRI01) * /SF3
//   SF1 = PF1 * /(P23*PRI0)  * /(P01*PRI01) * /SF3
//   SF2 = PF2 * /(P23*PRI03) * /(P01*/PRI2) * /SF3
//   SF3 = PF3 * /(P23*PRI03) * /(P01*/PRI2)
//   SB  = /P01 * /P23 * /PF01 * /PF23
//
// with PRIOR bit4 (fifth player) REMAPPING the missiles onto the PF3 input
// instead of P0-P3.  Two consequences our rank walk does not have:
//
//   * SF0/SF1/SF2 are gated by /SF3 -- "the fifth player always has priority
//     over all playfields", which is the bug this file exists to pin;
//   * SF3 is itself gated by PLAYER presence, /(P01*/PRI2), so a player at the
//     same pixel brings the playfield back.  That term is why the measured
//     table looked like an impossible cycle (fifth > PF0 > player > fifth in
//     scheme $08) until the equations explained it.
//
// Measured against the reference on hardware 2026-08-18: the equations reproduce
// all 40 cells of tools/gtia_fifth_truth.py exactly.
//
// WHAT THIS CHECKS, and what it deliberately does not.  Real GTIA ORs the
// colours of every surviving source (Altirra lists 24 reachable colours,
// including "PF0 | P0"); ours picks a SINGLE winner.  So an exhaustive
// equation-for-equation comparison would flag that architectural difference on
// every mixed pixel and drown the signal.
//
// Instead this asserts the THIRTY-TWO CELLS MEASURED AGAINST THE REFERENCE on
// hardware (tools/gtia_fifth_truth.py): for each priority scheme, with the fifth
// player enabled, over each playfield source, with and without a player at the
// same pixel -- does the fifth player own the pixel?  That is exactly the
// reported defect, and it is ground truth rather than a model.

`timescale 1ns/1ps
`default_nettype none

module tb_gtia_prior_eq;

    localparam logic [2:0] SRC_BK  = 3'd0, SRC_PF0 = 3'd1, SRC_PF1 = 3'd2,
                           SRC_PF2 = 3'd3, SRC_PF3 = 3'd4;
    // antic_color_sel encoding on win_src: 0..3 = P0..P3, 4 = PF3? -- read from
    // the DUT's own comment: a fifth-player missile leaves as PF3.
    localparam int WIN_PF0 = 5, WIN_PF1 = 6, WIN_PF2 = 7, WIN_PF3 = 4;

    reg clk = 1'b0, rst = 1'b1;
    always #5 clk = ~clk;

    reg        start = 1'b0;
    reg  [7:0] pres  = 8'h00;
    reg  [2:0] pf_src = SRC_BK;
    reg  [7:0] prior = 8'h00;
    wire [3:0] win_src;
    wire       win_black, win_multi01, win_multi23, win_pm5, valid;

    gtia_priority dut (
        .clk(clk), .rst(rst), .start(start),
        .pres(pres), .pf_src(pf_src), .prior(prior),
        .win_src(win_src), .win_black(win_black),
        .win_multi01(win_multi01), .win_multi23(win_multi23),
        .win_pm5(win_pm5), .valid(valid)
    );

    // ---- the measured table, as the reference ----------------------------
    // Does the FIFTH PLAYER own the pixel?  From the hardware measurement:
    //   fifth ALONE      : yes, every scheme, over every playfield source
    //   fifth + a PLAYER : $10/$11/$12 no; $14 yes; $18 no
    // which the GTIA equations reproduce exactly via
    //   SF3 = PF3 * /(P23*PRI03) * /(P01*/PRI2), and /SF3 on SF0..SF2.
    function automatic logic exp_fifth(input logic [7:0] pr, input logic p01);
        logic pri2, pri03, sf3;
        begin
            pri2  = pr[2];
            pri03 = pr[0] | pr[3];
            sf3   = !(1'b0 && pri03) && !(p01 && !pri2);   // P23 = 0 in these cells
            exp_fifth = sf3;
        end
    endfunction

    integer i, p;
    integer checked = 0, dev_fifth = 0;
    reg [7:0] pz;

    task automatic resolve(input [7:0] pz_i, input [2:0] pf_i, input [7:0] pr_i);
        begin
            @(negedge clk);
            pres = pz_i; pf_src = pf_i; prior = pr_i; start = 1'b1;
            @(negedge clk); start = 1'b0;
            while (!valid) @(negedge clk);
        end
    endtask

    initial begin
        repeat (4) @(posedge clk);
        rst = 1'b0;
        repeat (2) @(posedge clk);

        // The measured cells only.  ONE priority bit at a time, because that is
        // what was measured against the reference; a PRIOR with several bits set
        // enables several orderings at once, and where they disagree GTIA emits
        // BLACK -- real behaviour, but not something this measurement covers, so
        // asserting it here would be inventing ground truth.
        for (p = 0; p < 5; p = p + 1) begin
            for (i = 0; i < 2; i = i + 1) begin           // 0 = no player, 1 = P0 present
                integer pf;
                for (pf = 0; pf < 4; pf = pf + 1) begin
                    pz = 8'h10 | (i[0] ? 8'h01 : 8'h00);  // missile 0 (+ player 0)
                    begin
                        logic [7:0] pr;
                        pr = 8'h10 | (p == 0 ? 8'h00 : (8'h01 << (p - 1)));
                        resolve(pz, 3'(pf + 1), pr);
                        checked = checked + 1;
                        if (exp_fifth(pr, i[0]) !== win_pm5) begin
                            dev_fifth = dev_fifth + 1;
                            if (dev_fifth <= 8)
                                $display("   MISMATCH prior=$%02h pf=PF%0d player=%0d -> win_pm5=%0b want %0b",
                                         pr, pf, i[0], win_pm5, exp_fifth(pr, i[0]));
                        end
                    end
                end
            end
        end

        $display("tb_gtia_prior_eq: %0d cases checked", checked);
        if (dev_fifth == 0)
            $display("tb_gtia_prior_eq: all checks PASS -- the fifth player follows the GTIA equations");
        else
            $display("FAIL tb_gtia_prior_eq: %0d of %0d measured cells disagree", dev_fifth, checked);
        $finish;
    end

endmodule

`default_nettype wire
