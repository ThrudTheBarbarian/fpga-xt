`timescale 1ns/1ps
`default_nettype none
//
// tb_gtia_stream — the beam-time pixel stage.
//
// The point of these checks is the thing the BURST compositor structurally
// cannot do: change a GTIA register partway along a line and have only the
// pixels from that colour clock onward reflect it. T3 is that test.
//
module tb_gtia_stream;

    logic clk = 0, rst = 1;
    always #5 clk = ~clk;

    logic       cc_valid;
    logic [8:0] cc_index;
    logic [3:0] pf_nibble;
    logic [7:0] pm_presence;
    logic [7:0] prior, colpm0, colpm1, colpm2, colpm3;
    logic [7:0] colpf0, colpf1, colpf2, colpf3, colbk;

    wire [7:0] color_out;
    wire       color_valid;
    wire [8:0] color_cc;

    gtia_stream dut (
        .clk(clk), .rst(rst),
        .cc_valid(cc_valid), .cc_index(cc_index),
        .pf_nibble(pf_nibble), .pm_presence(pm_presence),
        .prior(prior),
        .colpm0(colpm0), .colpm1(colpm1), .colpm2(colpm2), .colpm3(colpm3),
        .colpf0(colpf0), .colpf1(colpf1), .colpf2(colpf2), .colpf3(colpf3),
        .colbk(colbk), .colpf1_luma_only(1'b0),
        .color_out(color_out), .color_valid(color_valid), .color_cc(color_cc)
    );

    int fail = 0;

    // Drive stimulus on the NEGEDGE.  Assigning immediately after @(posedge clk)
    // lands in the same timestep as the edge and races the always_ff, which
    // showed up as every result lagging exactly one step.
    task automatic step_cc(input [8:0] idx);
        begin
            @(negedge clk);
            cc_index = idx; cc_valid = 1'b1;
            @(negedge clk);
            cc_valid = 1'b0;
            @(negedge clk);
        end
    endtask

    task automatic expect_color(input [7:0] want, input string tag);
        begin
            if (color_out !== want) begin
                $display("FAIL %s: color=$%02h expected $%02h", tag, color_out, want);
                fail++;
            end
        end
    endtask

    initial begin
        cc_valid = 0; cc_index = 0; pf_nibble = 4'h0; pm_presence = 8'h00;
        prior = 8'h01;                       // P0..P3 in front of playfield
        colpm0 = 8'h2A; colpm1 = 8'h3A; colpm2 = 8'h4A; colpm3 = 8'h5A;
        colpf0 = 8'h6A; colpf1 = 8'h7A; colpf2 = 8'h8A; colpf3 = 8'h9A;
        colbk  = 8'h00;
        repeat (3) @(posedge clk);
        rst = 0;
        @(posedge clk);

        // ---- T1: background ---------------------------------------------
        pf_nibble = 4'h0; pm_presence = 8'h00;
        step_cc(9'd10);
        expect_color(8'h00, "T1 background");

        // ---- T2: playfield PF2 ------------------------------------------
        pf_nibble = 4'b0100;
        step_cc(9'd11);
        expect_color(8'h8A, "T2 PF2");

        // ---- T3: MID-LINE COLPF2 CHANGE ---------------------------------
        // The whole point.  Same playfield source, colour register rewritten
        // between two colour clocks: the second pixel MUST take the new value.
        // A burst that samples registers once per row cannot express this.
        colpf2 = 8'hC3;
        step_cc(9'd12);
        expect_color(8'hC3, "T3 mid-line COLPF2 change");
        colpf2 = 8'h8A;
        step_cc(9'd13);
        expect_color(8'h8A, "T3b COLPF2 restored");

        // ---- T4: player over playfield, PRIOR=1 -------------------------
        pf_nibble = 4'b0100; pm_presence = 8'b0001_0000;   // P0 present
        step_cc(9'd14);
        expect_color(8'h2A, "T4 P0 in front of PF2");

        // ---- T5: MID-LINE PRIOR CHANGE ----------------------------------
        // PRIOR bit 2 puts the playfield in front of the players, so the SAME
        // presence must now resolve to the playfield colour.
        prior = 8'h04;
        step_cc(9'd15);
        expect_color(8'h8A, "T5 mid-line PRIOR -> playfield in front");
        prior = 8'h01;

        // ---- T6: missile shares its player's slot -----------------------
        pf_nibble = 4'h0; pm_presence = 8'b0000_0001;      // M0 only
        step_cc(9'd16);
        expect_color(8'h2A, "T6 M0 paints in COLPM0");

        // ---- T7: PM5 routes missiles through COLPF3 ---------------------
        prior = 8'h11;                                      // PRIOR[4] = PM5
        step_cc(9'd17);
        expect_color(8'h9A, "T7 PM5 missile -> COLPF3");
        prior = 8'h01;

        // ---- T8: the colour clock index is carried through --------------
        pf_nibble = 4'h0; pm_presence = 8'h00;
        step_cc(9'd200);
        if (color_cc !== 9'd200) begin
            $display("FAIL T8 cc index: %0d expected 200", color_cc);
            fail++;
        end

        if (fail == 0) $display("tb_gtia_stream: all checks PASS");
        else           $display("tb_gtia_stream: %0d FAIL", fail);
        $finish;
    end

endmodule

`default_nettype wire
