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
    logic [1:0] an_pair;
    logic       pf_win;

    logic [7:0] hposp0, hposp1, hposp2, hposp3;
    logic [7:0] hposm0, hposm1, hposm2, hposm3;
    logic [1:0] sizep0, sizep1, sizep2, sizep3;
    logic [7:0] sizem, grafm;
    // "SIZEP was WRITTEN this colour clock" — dangling here floated x into the
    // resize clock and the 1x-alt lockup that gtia_obj_walk gates on it.
    logic [3:0] resize;
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
        .an_pair(an_pair), .pf_win(pf_win),
        .hposp0(hposp0), .hposp1(hposp1), .hposp2(hposp2), .hposp3(hposp3),
        .hposm0(hposm0), .hposm1(hposm1), .hposm2(hposm2), .hposm3(hposm3),
        .sizep0(sizep0), .sizep1(sizep1), .sizep2(sizep2), .sizep3(sizep3),
        .resize(resize),
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

    // Park the beam at a given colour clock. The collision window is a real
    // horizontal range now, so a test that wants a hit must stand inside it.
    task automatic seek_cc(input int n);
        begin
            cc = n;
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
        an_pair = 2'd0; pf_win = 1'b0;
        hposp0 = 8'd200; hposp1 = 8'd200; hposp2 = 8'd200; hposp3 = 8'd200;
        hposm0 = 8'd200; hposm1 = 8'd200; hposm2 = 8'd200; hposm3 = 8'd200;
        sizep0 = 0; sizep1 = 0; sizep2 = 0; sizep3 = 0; sizem = 0; resize = 0;
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
        seek_cc(60);                            // ON SCREEN — see T8d
        hposp0 = 8'd60; hposp1 = 8'd60; grafp0 = 8'hFF; grafp1 = 8'hFF;
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

        // ----------------------------------------------------------------
        // T8d: the HORIZONTAL window, both halves of the edge.
        // GTIA does not compare in horizontal blank. ACID's gtia_collision
        // reports "P/P collisions were detected in HBLANK on left" when it
        // does, and antic_addresswrap fails too because its pass condition is
        // simply P0PF == $00. HPOS $22 is INSIDE and must register; $21 is
        // outside and must not. This is the check the per-line `active` gate
        // cannot make.
        // ----------------------------------------------------------------
        new_line();
        clear_hits();
        hposp0 = 8'h21; hposp1 = 8'h21;
        seek_cc('h21);
        step_cc(3'd2, 3'd2);
        if (p_pf !== 16'h0 || p_pl !== 16'h0) begin
            $display("FAIL T8d: collided at HPOS $21, outside the window"); fail++;
        end

        new_line();
        clear_hits();
        hposp0 = 8'h22; hposp1 = 8'h22;
        seek_cc('h22);
        step_cc(3'd2, 3'd2);
        if (p_pf[3:0] !== 4'b0010) begin
            $display("FAIL T8e: no PF collision at HPOS $22, on the bound"); fail++;
        end
        if (p_pl[3:0] !== 4'b0010) begin
            $display("FAIL T8f: no P/P collision at HPOS $22"); fail++;
        end

        // HPOS $DD is the RIGHT bound and is INSIDE it. ACID's gtia_collision
        // parks all eight objects there, one colour clock wide (GRAFP=$80,
        // GRAFM=$AA), and requires every missile to collide with every player:
        // "Missing P/M collisions on right at $DD."
        new_line();
        clear_hits();
        hposp0 = 8'hDD; hposp1 = 8'hDD; grafp0 = 8'h80; grafp1 = 8'h80;
        seek_cc('hDD);
        step_cc(3'd2, 3'd2);
        if (p_pl[3:0] !== 4'b0010) begin
            $display("FAIL T8g: no P/P collision at HPOS $DD, ON the right bound (got %04b)", p_pl[3:0]);
            fail++;
        end

        // The assertion ACID actually makes there is about MISSILES:
        // m0pl & m1pl & m2pl & m3pl & $0f == $0f, with GRAFM=$AA so every
        // missile is one colour clock wide at its own HPOS.
        new_line();
        clear_hits();
        hposp0 = 8'hDD; hposp1 = 8'hDD; hposp2 = 8'hDD; hposp3 = 8'hDD;
        hposm0 = 8'hDD; hposm1 = 8'hDD; hposm2 = 8'hDD; hposm3 = 8'hDD;
        grafp0 = 8'h80; grafp1 = 8'h80; grafp2 = 8'h80; grafp3 = 8'h80;
        grafm  = 8'hAA;
        seek_cc('hDD);
        step_cc(3'd2, 3'd2);
        if ((m_pl[3:0] & m_pl[7:4] & m_pl[11:8] & m_pl[15:12]) !== 4'b1111) begin
            $display("FAIL T8g2: missiles at $DD missed players: m_pl=%04h", m_pl);
            fail++;
        end
        grafm = 8'h00;
        hposm0 = 8'd0; hposm1 = 8'd0; hposm2 = 8'd0; hposm3 = 8'd0;
        hposp2 = 8'd0; hposp3 = 8'd0; grafp2 = 8'h00; grafp3 = 8'h00;
        grafp0 = 8'hFF; grafp1 = 8'hFF;

        // ...and one past it does not.
        new_line();
        clear_hits();
        hposp0 = 8'd222; hposp1 = 8'd222;
        seek_cc(222);
        step_cc(3'd2, 3'd2);
        if (p_pf !== 16'h0 || p_pl !== 16'h0) begin
            $display("FAIL T8h: collided at cc 222, past the right bound"); fail++;
        end

        new_line();
        clear_hits();
        grafp1 = 8'h00; hposp1 = 8'd200;
        seek_cc(0);

        // ================================================================
        // T11: GTIA modes — two bits a colour clock, two colour clocks a nibble
        // ================================================================
        // The nibble for an aligned PAIR of colour clocks is only complete once
        // the second has delivered its bits, so it goes on display for the NEXT
        // pair.  That is causal, not a choice, and real GR.9/10/11 displays sit
        // shifted for the same reason.
        new_line();
        hposp0 = 8'd200; grafp0 = 8'h00;        // no objects in the way
        prior = 8'h41;                          // GTIA mode 9 + priority $01
        pf_win = 1'b1;
        colbk = 8'h50;                          // hue 5, luma 0
        an_pair = 2'b10; step_cc(3'd0, 3'd0);   // cc 0
        an_pair = 2'b11; step_cc(3'd0, 3'd0);   // cc 1: nibble $B is complete
        an_pair = 2'b00; step_cc(3'd0, 3'd0);   // cc 2: it goes on display
        chk(got_a, 8'h5B, "T11 mode 9 nibble $B -> hue 5 luma B");
        chk(got_b, 8'h5B, "T11b both halves of the colour clock");
        an_pair = 2'b00; step_cc(3'd0, 3'd0);   // cc 3: still the same pixel
        chk(got_a, 8'h5B, "T11c a GTIA pixel spans two colour clocks");
        an_pair = 2'b00; step_cc(3'd0, 3'd0);   // cc 4: the next nibble, $0
        chk(got_a, 8'h50, "T11d the following GTIA pixel");

        // Mode 11 is the mirror: the nibble is the hue.
        new_line();
        prior = 8'hC1;
        an_pair = 2'b10; step_cc(3'd0, 3'd0);
        an_pair = 2'b11; step_cc(3'd0, 3'd0);
        an_pair = 2'b00; step_cc(3'd0, 3'd0);
        chk(got_a, 8'hB0, "T11e mode 11 nibble $B -> hue B luma 0");

        // Mode 10 indexes the colour registers.
        new_line();
        prior = 8'h81;
        an_pair = 2'b01; step_cc(3'd0, 3'd0);
        an_pair = 2'b01; step_cc(3'd0, 3'd0);   // nibble 0101 = 5 -> COLPF1
        an_pair = 2'b00; step_cc(3'd0, 3'd0);
        chk(got_a, colpf1, "T11f mode 10 nibble 5 -> COLPF1");

        // A player still wins and keeps its OWN colour: a GTIA mode recolours
        // the playfield, not the picture.
        new_line();
        prior = 8'h41; hposp0 = 8'd2; grafp0 = 8'hFF;
        an_pair = 2'b11; step_cc(3'd0, 3'd0);
        an_pair = 2'b11; step_cc(3'd0, 3'd0);
        an_pair = 2'b11; step_cc(3'd0, 3'd0);   // cc 2: the player is here
        chk(got_a, colpm0, "T11g a player over a GTIA-mode playfield");
        hposp0 = 8'd200; grafp0 = 8'h00;

        // Outside the playfield window the border is untouched.
        new_line();
        pf_win = 1'b0;
        an_pair = 2'b11; step_cc(3'd0, 3'd0);
        an_pair = 2'b11; step_cc(3'd0, 3'd0);
        an_pair = 2'b11; step_cc(3'd0, 3'd0);
        chk(got_a, colbk, "T11h the border is not recoloured by a GTIA mode");
        // Restore the WINDOW as well as prior/colbk.  Leaving it closed makes
        // every later case run on the border, where a playfield check fails and
        // a player check passes -- both for the wrong reason.
        prior = 8'h01; colbk = 8'h00; pf_win = 1'b1;

        // ----------------------------------------------------------------
        // T11i-k: GTIA modes under PRIOR SCHEME 2 (playfield ABOVE players).
        //
        // This is the BallBlazer case ($54) generalised.  gtia_stage feeds the
        // priority network a SUBSTITUTED playfield source in GTIA modes
        // (pri_pf_now): mode 9/11 class EVERY playfield pixel as SRC_BK, so a
        // player still wins even though the scheme ranks playfield first; mode
        // 10 instead classes nibbles with bit 2 SET as PF0-3, which under this
        // scheme DO outrank the player.  Mode 10 must therefore behave
        // DIFFERENTLY from 9 and 11 here -- that asymmetry is the whole claim,
        // and it was previously inherited from the collision rule untested.
        // ----------------------------------------------------------------
        // Drive a LIT playfield source (PF1), not source 0.  Source 0 is
        // already SRC_BK, so pre-fix and post-fix agree on it and the case
        // cannot discriminate; with a lit source the pre-fix code hands
        // priority a PF class, which under this scheme hides the player.
        new_line();
        hposp0 = 8'd2; grafp0 = 8'hFF;
        prior = 8'hD4;                          // mode 11 + scheme 2
        an_pair = 2'b11; step_cc(3'd2, 3'd2);
        an_pair = 2'b11; step_cc(3'd2, 3'd2);
        an_pair = 2'b11; step_cc(3'd2, 3'd2);
        chk(got_a, colpm0, "T11i mode 11 + scheme 2: the player still wins");

        // T11j/T11k are REFERENCE-VALIDATED, not just self-consistent: the same
        // two cases were built on Altirra over the AltirraBridge (mode 10,
        // PRIOR $94, quad player 0 at HPOSP0 $70, screen filled with one
        // repeated nibble) and its rendered frame agrees on both halves --
        // nibble 5 hides the player COMPLETELY, nibble 1 draws it in full
        // (a 64 px run at x=136..199, the border being COLPM0 in mode 10).
        // Do not relax either expectation.  See docs/NextSteps.md.
        new_line();
        prior = 8'h94;                          // mode 10 + scheme 2
        an_pair = 2'b01; step_cc(3'd0, 3'd0);   // nibble 0101 = 5 -> PF1 class
        an_pair = 2'b01; step_cc(3'd0, 3'd0);
        an_pair = 2'b01; step_cc(3'd0, 3'd0);
        chk(got_a, colpf1, "T11j mode 10 + scheme 2: a PF nibble hides the player");

        new_line();
        prior = 8'h94;                          // mode 10 + scheme 2
        an_pair = 2'b00; step_cc(3'd2, 3'd2);   // nibble 0001 = 1 -> SRC_BK class
        an_pair = 2'b01; step_cc(3'd2, 3'd2);
        an_pair = 2'b01; step_cc(3'd2, 3'd2);
        chk(got_a, colpm0, "T11k mode 10 + scheme 2: a background nibble does not");

        hposp0 = 8'd200; grafp0 = 8'h00; prior = 8'h01;

        // ================================================================
        // ================================================================
        // TG: THE FIRST COLOUR CLOCKS OF A LINE IN A GTIA MODE.
        //
        // This is the left-edge bar, reduced to its smallest form.  Measured on
        // hardware (graboverlay, BallBlazer intro): the whole screen is hue 1 at
        // every even luminance -- exactly GTIA mode 9, sixteen luminances of
        // COLBK's hue -- EXCEPT columns 0-3, four pixels, which carry $28, hue
        // 2.  In mode 9 gtia_special computes {colbk[7:4], nibble}, so every
        // playfield pixel must carry COLBK's hue; a hue-2 pixel never went
        // through the recolour.
        //
        // Suspected cause: line_start clears win_ready and gtia_win, and
        // repriming needs an ODD colour clock to load win_ready from pf_win and
        // the NEXT EVEN clock to move it into gtia_win -- so gtia_win is 0 for
        // the first two colour clocks and the resolve falls through to
        // sel_color.  Two colour clocks is four pixels, which is the measured
        // bar.  COLBK is hue 1 and the playfield registers are hue 2 here, so
        // the two are told apart by HUE ALONE, exactly as on hardware.
        // ================================================================
        begin : tg_line_start_gtia
            logic [7:0] first_a [0:3];
            logic [7:0] first_b [0:3];
            prior  = 8'h41;             // PRIOR[7:6]=01 -> GTIA mode 9
            colbk  = 8'h10;             // hue 1: every recoloured pixel is $1x
            colpf0 = 8'h20; colpf1 = 8'h22; colpf2 = 8'h24; colpf3 = 8'h26;
            grafp0 = 8'h00; grafp1 = 8'h00; grafp2 = 8'h00; grafp3 = 8'h00;
            grafm  = 8'h00;
            hposp0 = 8'd200; hposp1 = 8'd200; hposp2 = 8'd200; hposp3 = 8'd200;
            hposm0 = 8'd200; hposm1 = 8'd200; hposm2 = 8'd200; hposm3 = 8'd200;
            an_pair = 2'b11;            // a non-zero nibble either half
            pf_win  = 1'b1;             // the playfield IS displaying
            new_line();
            for (int i = 0; i < 4; i++) begin
                step_cc(3'd4, 3'd4);    // PF0 both halves
                first_a[i] = got_a; first_b[i] = got_b;
            end
            for (int i = 0; i < 4; i++)
                $display("NOTE TG: cc %0d after line_start -> a=$%02h b=$%02h (hue %0d/%0d)",
                         i, first_a[i], first_b[i], first_a[i][7:4], first_b[i][7:4]);
            // The claim under test: in a GTIA mode EVERY displayed playfield
            // pixel carries COLBK's hue.  Anything else is the bar.
            for (int i = 0; i < 4; i++) begin
                if (first_a[i][7:4] !== colbk[7:4]) begin
                    $display("FAIL TG: cc %0d half A is hue %0d ($%02h), expected COLBK's hue %0d -- this is the left-edge bar",
                             i, first_a[i][7:4], first_a[i], colbk[7:4]);
                    fail++;
                end
                if (first_b[i][7:4] !== colbk[7:4]) begin
                    $display("FAIL TG: cc %0d half B is hue %0d ($%02h), expected COLBK's hue %0d -- this is the left-edge bar",
                             i, first_b[i][7:4], first_b[i], colbk[7:4]);
                    fail++;
                end
            end
            // ---- the FAITHFUL case: the window OPENS mid-line ----------
            // On hardware the playfield window does not open at cc 0; it opens
            // at machine cycle 20, which is px_pos 80, which is plane column 0.
            // If the same two-clock lag applies to pf_win's RISING EDGE then the
            // artefact lands exactly at plane column 0 -- which is where it was
            // measured.  This is the case that decides it.
            begin : tg_window_open
                logic [7:0] w_a [0:5];
                new_line();
                pf_win = 1'b0;
                for (int i = 0; i < 8; i++) step_cc(3'd4, 3'd4);   // border
                pf_win = 1'b1;                                     // window OPENS
                for (int i = 0; i < 6; i++) begin
                    step_cc(3'd4, 3'd4);
                    w_a[i] = got_a;
                end
                for (int i = 0; i < 6; i++)
                    $display("NOTE TG2: %0d cc after the window opened -> $%02h (hue %0d)",
                             i, w_a[i], w_a[i][7:4]);
                for (int i = 0; i < 6; i++)
                    if (w_a[i][7:4] !== colbk[7:4]) begin
                        $display("FAIL TG2: %0d cc after the window opened the pixel is hue %0d ($%02h), expected COLBK's hue %0d",
                                 i, w_a[i][7:4], w_a[i], colbk[7:4]);
                        fail++;
                    end
            end
            pf_win = 1'b0; an_pair = 2'd0; prior = 8'h01;
        end

        // ================================================================
        // TM: THE MISSING MAN, as measured on Altirra at t~23 s.
        //
        // Altirra draws a 50x28 object at x=130..179 in COLPF3's $36 while our
        // board draws nothing there.  Peeking its registers at that instant:
        //     hposp = $84 $7c $74 $6c    prior = $54    gractl = $03
        //     grafm = $00, sizem = $00   (so it is NOT the missiles)
        // x_left = (HPOS-48)*2 maps those to x = 120/136/152/168 -- four
        // adjacent players forming one figure.  We write the SAME positions.
        // PRIOR $54 = GTIA mode 9 + fifth player + priority scheme 2
        // (playfield above all players).
        // ================================================================
        begin : tm_missing_man
            logic [7:0] got [0:3];
            prior  = 8'h54;                 // mode 9, fifth player, scheme 2
            colbk  = 8'h10;
            colpm0 = 8'h36; colpm1 = 8'h36; colpm2 = 8'h36; colpm3 = 8'h36;
            colpf0 = 8'h20; colpf1 = 8'h22; colpf2 = 8'h24; colpf3 = 8'h36;
            hposp0 = 8'h6c; hposp1 = 8'h74; hposp2 = 8'h7c; hposp3 = 8'h84;
            sizep0 = 2'b00; sizep1 = 2'b00; sizep2 = 2'b00; sizep3 = 2'b00;
            grafp0 = 8'hFF; grafp1 = 8'hFF; grafp2 = 8'hFF; grafp3 = 8'hFF;
            hposm0 = 8'd250; hposm1 = 8'd250; hposm2 = 8'd250; hposm3 = 8'd250;
            grafm  = 8'h00;                 // as Altirra: no missiles
            an_pair = 2'b11; pf_win = 1'b1; // playfield displaying, mode 9
            new_line();
            seek_cc(0);
            for (int i = 0; i < 4; i++) begin
                cc = 8'h6c + i*8;           // stand on each player's first clock
                step_cc(3'd4, 3'd4);        // over PF3
                got[i] = got_a;
            end
            for (int i = 0; i < 4; i++)
                $display("NOTE TM: player %0d at HPOS $%02h -> $%02h", i, 8'h6c+i*8, got[i]);
            for (int i = 0; i < 4; i++)
                if (got[i] !== 8'h36) begin
                    $display("FAIL TM: player %0d emitted $%02h, expected COLPM $36 -- THE MAN IS INVISIBLE",
                             i, got[i]);
                    fail++;
                end
            prior = 8'h01; pf_win = 1'b0; an_pair = 2'd0;
            colpm0 = 8'h30; colpm1 = 8'h44; colpm2 = 8'h68; colpm3 = 8'h7A;
            grafp0 = 0; grafp1 = 0; grafp2 = 0; grafp3 = 0;
        end

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
