`timescale 1ns/1ps
`default_nettype none
//
// tb_gtia_stage — one colour clock of GTIA, object walk through colour.
//
// T1 is not about pixels at all: it measures how many fabric clocks the stage
// takes and fails if the pair is not resolved within the 28 available at
// 100 MHz. Every other check here could pass while the design silently did not
// fit in real time, so the schedule is tested first and explicitly.
//
// T5 is why GTIA's unit is a PAIR and not a pixel: object presence changes once
// per colour clock, but a mode F colour clock can have one hi-res half lit and
// the other not, so priority has to resolve twice against the same presence.
//
module tb_gtia_stage;

    localparam int CC_CLOCKS = 28;      // fabric clocks per colour clock

    logic clk = 0, rst = 1;
    always #5 clk = ~clk;

    logic       line_start, cc_tick, active, hitclr;
    logic [7:0] cc_pos;
    logic [2:0] pf_src_a, pf_src_b;

    logic [7:0] hposp0, hposp1, hposp2, hposp3;
    logic [7:0] hposm0, hposm1, hposm2, hposm3;
    logic [1:0] sizep0, sizep1, sizep2, sizep3;
    logic [7:0] sizem, grafm;
    logic [7:0] grafp0, grafp1, grafp2, grafp3;
    logic [7:0] prior;
    logic [7:0] colbk, colpf0, colpf1, colpf2, colpf3;
    logic [7:0] colpm0, colpm1, colpm2, colpm3;

    wire        out_valid;
    wire [7:0]  out_color_a, out_color_b;
    wire [15:0] m_pf, p_pf, m_pl, p_pl;

    gtia_stage dut (
        .clk(clk), .rst(rst),
        .line_start(line_start), .cc_tick(cc_tick), .cc_pos(cc_pos),
        .active(active), .hitclr(hitclr),
        .pf_src_a(pf_src_a), .pf_src_b(pf_src_b),
        .hposp0(hposp0), .hposp1(hposp1), .hposp2(hposp2), .hposp3(hposp3),
        .hposm0(hposm0), .hposm1(hposm1), .hposm2(hposm2), .hposm3(hposm3),
        .sizep0(sizep0), .sizep1(sizep1), .sizep2(sizep2), .sizep3(sizep3),
        .sizem(sizem),
        .grafp0(grafp0), .grafp1(grafp1), .grafp2(grafp2), .grafp3(grafp3),
        .grafm(grafm), .prior(prior),
        .colbk(colbk), .colpf0(colpf0), .colpf1(colpf1),
        .colpf2(colpf2), .colpf3(colpf3),
        .colpm0(colpm0), .colpm1(colpm1), .colpm2(colpm2), .colpm3(colpm3),
        .out_valid(out_valid), .out_color_a(out_color_a), .out_color_b(out_color_b),
        .m_pf(m_pf), .p_pf(p_pf), .m_pl(m_pl), .p_pl(p_pl)
    );

    int fail = 0;
    int cc;
    int worst_latency;

    logic [7:0] got_a, got_b;

    // Run one colour clock and measure how long the stage took to answer.
    task automatic step_cc(input [2:0] pa, input [2:0] pb);
        int n;
        begin
            pf_src_a = pa; pf_src_b = pb; cc_pos = 8'(cc);
            @(negedge clk); cc_tick = 1'b1;
            @(negedge clk); cc_tick = 1'b0;
            n = 1;
            while (!out_valid && n < 200) begin @(negedge clk); n++; end
            if (n >= 200) begin
                $display("FAIL: the stage never answered at cc %0d", cc);
                fail++;
            end
            if (n > worst_latency) worst_latency = n;
            got_a = out_color_a; got_b = out_color_b;
            cc++;
            // Let the rest of the colour clock elapse, as the real beam would.
            while (n < CC_CLOCKS) begin @(negedge clk); n++; end
        end
    endtask

    task automatic new_line;
        begin
            @(negedge clk); line_start = 1'b1;
            @(negedge clk); line_start = 1'b0;
            cc = 0;
        end
    endtask

    task automatic clear_hits;
        begin
            @(negedge clk); hitclr = 1'b1;
            @(negedge clk); hitclr = 1'b0;
        end
    endtask

    task automatic chk(input [7:0] got, input [7:0] want, input string tag);
        begin
            if (got !== want) begin
                $display("FAIL %s: colour $%02h, expected $%02h", tag, got, want);
                fail++;
            end
        end
    endtask

    initial begin
        line_start = 0; cc_tick = 0; active = 1; hitclr = 0;
        cc_pos = 0; pf_src_a = 3'd0; pf_src_b = 3'd0; cc = 0; worst_latency = 0;
        hposp0 = 8'd200; hposp1 = 8'd200; hposp2 = 8'd200; hposp3 = 8'd200;
        hposm0 = 8'd200; hposm1 = 8'd200; hposm2 = 8'd200; hposm3 = 8'd200;
        sizep0 = 0; sizep1 = 0; sizep2 = 0; sizep3 = 0; sizem = 0;
        grafp0 = 0; grafp1 = 0; grafp2 = 0; grafp3 = 0; grafm = 0;
        prior  = 8'h01;
        colbk  = 8'h00; colpf0 = 8'h28; colpf1 = 8'h3A; colpf2 = 8'h94;
        colpf3 = 8'h56;
        colpm0 = 8'h30; colpm1 = 8'h44; colpm2 = 8'h68; colpm3 = 8'h7A;

        repeat (3) @(posedge clk);
        rst = 0;
        @(posedge clk);

        // ================================================================
        // T2: the playfield alone
        // ================================================================
        new_line();
        step_cc(3'd0, 3'd0);  chk(got_a, colbk,  "T2 background A");
                              chk(got_b, colbk,  "T2b background B");
        step_cc(3'd1, 3'd1);  chk(got_a, colpf0, "T2c PF0");
        step_cc(3'd4, 3'd4);  chk(got_a, colpf3, "T2d PF3");
        // A lit hi-res pixel takes COLPF2's hue and COLPF1's luma: $94 hue 9,
        // $3A luma bits [3:1] = 101 -> $9A.
        step_cc(3'd5, 3'd5);  chk(got_a, 8'h9A,  "T2e hi-res lit");

        // ================================================================
        // T3: a player over the background, and over the playfield
        // ================================================================
        new_line();
        hposp0 = 8'd4; grafp0 = 8'hFF; prior = 8'h01;
        step_cc(3'd0, 3'd0);                    // cc 0: before the player
        chk(got_a, colbk, "T3 before the player");
        step_cc(3'd0, 3'd0);                    // cc 1
        step_cc(3'd0, 3'd0);                    // cc 2
        step_cc(3'd0, 3'd0);                    // cc 3
        step_cc(3'd1, 3'd1);                    // cc 4: the player, over PF0
        chk(got_a, colpm0, "T3b player over PF0 under PRIOR $01");
        chk(got_b, colpm0, "T3c both halves");
        // ...and under $04 the playfield wins instead.
        prior = 8'h04;
        step_cc(3'd1, 3'd1);                    // cc 5: still the player
        chk(got_a, colpf0, "T3d PF0 over the player under PRIOR $04");
        prior = 8'h01;

        // ================================================================
        // T5: the two halves of a colour clock resolve independently
        // ================================================================
        // A hi-res colour clock with one half lit and the other not, under a
        // player: the player wins both halves in $01...
        new_line();
        hposp0 = 8'd0; grafp0 = 8'hFF; prior = 8'h01;
        step_cc(3'd5, 3'd3);
        chk(got_a, colpm0, "T5 player over a lit hi-res half");
        chk(got_b, colpm0, "T5b player over the unlit half");
        // ...and in $04 the playfield wins, so the two halves differ.
        new_line();
        prior = 8'h04;
        step_cc(3'd5, 3'd3);
        chk(got_a, 8'h9A,  "T5c lit half is the hi-res blend");
        chk(got_b, colpf2, "T5d unlit half is plain PF2");
        if (got_a === got_b) begin
            $display("FAIL T5e: both halves came out the same — the pair is not resolving independently");
            fail++;
        end
        prior = 8'h01;

        // ================================================================
        // T6: multi-colour players
        // ================================================================
        new_line();
        hposp0 = 8'd0; hposp1 = 8'd0; grafp0 = 8'hFF; grafp1 = 8'hFF;
        prior = 8'h01;
        step_cc(3'd0, 3'd0);
        chk(got_a, colpm0, "T6 P0/P1 overlap without the multi bit");
        new_line();
        prior = 8'h21;
        step_cc(3'd0, 3'd0);
        chk(got_a, colpm0 | colpm1, "T6b P0/P1 overlap with the multi bit");
        grafp1 = 8'h00; hposp1 = 8'd200; prior = 8'h01;

        // ================================================================
        // T7: conflicting orderings come out black
        // ================================================================
        new_line();
        hposp0 = 8'd0; grafp0 = 8'hFF;
        prior = 8'h05;                          // $01 and $04 together
        step_cc(3'd1, 3'd1);
        chk(got_a, 8'h00, "T7 player over playfield under PRIOR $05");
        // Where they agree, the colour is normal.
        step_cc(3'd0, 3'd0);
        chk(got_a, colpm0, "T7b player over background under $05");
        prior = 8'h01;

        // ================================================================
        // T8: collisions accumulate as the stage runs
        // ================================================================
        new_line();
        clear_hits();
        hposp0 = 8'd0; hposp1 = 8'd0; grafp0 = 8'hFF; grafp1 = 8'hFF;
        step_cc(3'd2, 3'd2);                    // both players over PF1
        if (p_pf[3:0] !== 4'b0010) begin
            $display("FAIL T8: P0PF %04b, expected PF1", p_pf[3:0]); fail++;
        end
        if (p_pl[3:0] !== 4'b0010) begin
            $display("FAIL T8b: P0PL %04b, expected P1", p_pl[3:0]); fail++;
        end
        // Nothing accumulates off an active line.
        clear_hits();
        active = 1'b0;
        step_cc(3'd2, 3'd2);
        if (p_pf !== 16'h0 || p_pl !== 16'h0) begin
            $display("FAIL T8c: collisions accumulated with active low"); fail++;
        end
        active = 1'b1;
        grafp1 = 8'h00; hposp1 = 8'd200;

        // ================================================================
        // T1: the schedule fits in a colour clock
        // ================================================================
        // Checked last so it covers every case above, and it is the one that
        // matters most: everything else could pass while the design silently
        // failed to fit in real time.
        if (worst_latency > CC_CLOCKS) begin
            $display("FAIL T1: the stage took %0d fabric clocks, only %0d are available",
                     worst_latency, CC_CLOCKS);
            fail++;
        end else begin
            $display("  gtia_stage worst case: %0d of %0d fabric clocks",
                     worst_latency, CC_CLOCKS);
        end

        if (fail == 0) $display("tb_gtia_stage: all checks PASS");
        else           $display("tb_gtia_stage: %0d FAIL", fail);
        $finish;
    end

    initial begin
        #4000000;
        $display("FAIL: timeout");
        $finish;
    end

endmodule

`default_nettype wire
