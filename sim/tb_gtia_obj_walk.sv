`timescale 1ns/1ps
`default_nettype none
//
// tb_gtia_obj_walk — the serial player/missile object walk.
//
// T4 and T5 are the two that a positional formula cannot pass, and they are the
// reason the model is a shift register:
//
//   T4 (gtia_pmretrigger)  a second HPOS match mid-line RELOADS the register and
//                          draws the object again. A formula draws once.
//   T5 (gtia_pmresize)     changing SIZE mid-draw changes the advance RATE only.
//                          Pixels already emitted stand and the register carries
//                          on. A formula re-indexes the whole shape, which is
//                          how 4x->1x produced $E0 where hardware gives $80.
//
// Geometry, from tb_pm_collide: x_left = (HPOS - 48) * 2 hi-res pixels, so HPOS
// counts colour clocks and a normal player is 8 colour clocks wide.
//
module tb_gtia_obj_walk;

    logic clk = 0, rst = 1;
    always #5 clk = ~clk;

    logic       line_start, cc_tick;
    logic [7:0] cc_pos;
    logic [7:0] hposp0, hposp1, hposp2, hposp3;
    logic [7:0] hposm0, hposm1, hposm2, hposm3;
    logic [1:0] sizep0, sizep1, sizep2, sizep3;
    logic [7:0] sizem, grafm;
    logic [7:0] grafp0, grafp1, grafp2, grafp3;

    wire [7:0] pres;
    wire       pres_valid;

    gtia_obj_walk dut (
        .clk(clk), .rst(rst),
        .line_start(line_start), .cc_tick(cc_tick), .cc_pos(cc_pos),
        .hposp0(hposp0), .hposp1(hposp1), .hposp2(hposp2), .hposp3(hposp3),
        .hposm0(hposm0), .hposm1(hposm1), .hposm2(hposm2), .hposm3(hposm3),
        .sizep0(sizep0), .sizep1(sizep1), .sizep2(sizep2), .sizep3(sizep3),
        .sizem(sizem),
        .grafp0(grafp0), .grafp1(grafp1), .grafp2(grafp2), .grafp3(grafp3),
        .grafm(grafm),
        .pres(pres), .pres_valid(pres_valid)
    );

    int fail = 0;

    // Presence of each object at every colour clock of the line.
    logic [7:0] trace [0:255];
    int         cc;

    // Run one colour clock and record the settled presence.
    task automatic step_cc;
        int guard;
        begin
            @(negedge clk); cc_tick = 1'b1; cc_pos = 8'(cc);
            @(negedge clk); cc_tick = 1'b0;
            guard = 0;
            while (!pres_valid && guard < 32) begin @(negedge clk); guard++; end
            if (guard >= 32) begin
                $display("FAIL: the object walk never settled at cc %0d", cc);
                fail++;
            end
            trace[cc] = pres;
            cc++;
        end
    endtask

    task automatic new_line;
        begin
            @(negedge clk); line_start = 1'b1;
            @(negedge clk); line_start = 1'b0;
            cc = 0;
            for (int i = 0; i < 256; i++) trace[i] = 8'h00;
        end
    endtask

    task automatic run_to(input int upto);
        begin
            while (cc < upto) step_cc();
        end
    endtask

    // Which colour clocks was object `o` present at?
    function automatic int span_first(input int o);
        begin
            span_first = -1;
            for (int i = 255; i >= 0; i--) if (trace[i][o]) span_first = i;
        end
    endfunction

    function automatic int span_last(input int o);
        begin
            span_last = -1;
            for (int i = 0; i < 256; i++) if (trace[i][o]) span_last = i;
        end
    endfunction

    function automatic int span_count(input int o);
        int n;
        begin
            n = 0;
            for (int i = 0; i < 256; i++) if (trace[i][o]) n++;
            span_count = n;
        end
    endfunction

    initial begin
        line_start = 0; cc_tick = 0; cc_pos = 0; cc = 0;
        hposp0 = 8'd60; hposp1 = 8'd0; hposp2 = 8'd0; hposp3 = 8'd0;
        hposm0 = 8'd0;  hposm1 = 8'd0; hposm2 = 8'd0; hposm3 = 8'd0;
        sizep0 = 2'b00; sizep1 = 2'b00; sizep2 = 2'b00; sizep3 = 2'b00;
        sizem  = 8'h00;
        grafp0 = 8'h00; grafp1 = 8'h00; grafp2 = 8'h00; grafp3 = 8'h00;
        grafm  = 8'h00;
        for (int i = 0; i < 256; i++) trace[i] = 8'h00;

        repeat (3) @(posedge clk);
        rst = 0;
        @(posedge clk);

        // ================================================================
        // T1: a solid player is 8 colour clocks wide, starting at HPOS
        // ================================================================
        new_line();
        hposp0 = 8'd60; grafp0 = 8'hFF; sizep0 = 2'b00;
        run_to(120);
        if (span_first(0) != 60 || span_last(0) != 67) begin
            $display("FAIL T1: solid player spans cc %0d..%0d, expected 60..67",
                     span_first(0), span_last(0));
            fail++;
        end
        if (span_count(0) != 8) begin
            $display("FAIL T1b: solid player present for %0d cc, expected 8",
                     span_count(0));
            fail++;
        end

        // ---- T1c: the shape's BITS land in order, MSB first ---------------
        new_line();
        grafp0 = 8'h81;                 // 1000_0001
        run_to(120);
        if (!trace[60][0] || !trace[67][0]) begin
            $display("FAIL T1c: $81 should be lit at cc 60 and 67 (got %0b %0b)",
                     trace[60][0], trace[67][0]);
            fail++;
        end
        for (int i = 61; i <= 66; i++)
            if (trace[i][0]) begin
                $display("FAIL T1d: $81 lit at cc %0d, expected clear", i); fail++;
            end

        // ================================================================
        // T2: SIZE stretches the object without changing its start
        // ================================================================
        new_line();
        grafp0 = 8'hFF; sizep0 = 2'b01;             // double
        run_to(120);
        if (span_first(0) != 60 || span_count(0) != 16) begin
            $display("FAIL T2: double-size player starts %0d for %0d cc, expected 60 for 16",
                     span_first(0), span_count(0));
            fail++;
        end
        new_line();
        sizep0 = 2'b11;                             // quad
        run_to(140);
        if (span_first(0) != 60 || span_count(0) != 32) begin
            $display("FAIL T2b: quad player starts %0d for %0d cc, expected 60 for 32",
                     span_first(0), span_count(0));
            fail++;
        end
        new_line();
        sizep0 = 2'b10;                             // 10 is NORMAL, not a third rate
        run_to(120);
        if (span_count(0) != 8) begin
            $display("FAIL T2c: SIZE 10 gave %0d cc, expected 8 (it is normal size)",
                     span_count(0));
            fail++;
        end
        sizep0 = 2'b00;

        // ================================================================
        // T3: missiles are two bits, taken from GRAFM most significant first
        // ================================================================
        new_line();
        grafp0 = 8'h00;
        hposm0 = 8'd30; hposm1 = 8'd40; hposm2 = 8'd50; hposm3 = 8'd70;
        grafm  = 8'b11_00_10_01;        // m3=11 m2=00 m1=10 m0=01
        run_to(120);
        // m0 = 01: second bit only.
        if (trace[30][4] || !trace[31][4]) begin
            $display("FAIL T3: missile 0 ($01) lit %0b,%0b at cc 30,31, expected 0,1",
                     trace[30][4], trace[31][4]);
            fail++;
        end
        // m1 = 10: first bit only.
        if (!trace[40][5] || trace[41][5]) begin
            $display("FAIL T3b: missile 1 ($10) lit %0b,%0b at cc 40,41, expected 1,0",
                     trace[40][5], trace[41][5]);
            fail++;
        end
        // m2 = 00: never.
        if (span_count(6) != 0) begin
            $display("FAIL T3c: missile 2 ($00) was present %0d times",
                     span_count(6));
            fail++;
        end
        // m3 = 11: both bits, and only two colour clocks wide.
        if (span_first(7) != 70 || span_count(7) != 2) begin
            $display("FAIL T3d: missile 3 spans %0d for %0d cc, expected 70 for 2",
                     span_first(7), span_count(7));
            fail++;
        end
        grafm = 8'h00;
        hposm0 = 0; hposm1 = 0; hposm2 = 0; hposm3 = 0;

        // ================================================================
        // T4: RETRIGGER — a second HPOS match draws the object again
        // ================================================================
        // This is gtia_pmretrigger.  Start player 0 at 60, then move HPOSP0 to
        // 100 after the beam has passed 60.  Both draws must appear.
        new_line();
        grafp0 = 8'hFF; hposp0 = 8'd60; sizep0 = 2'b00;
        run_to(80);                                 // past the first draw
        hposp0 = 8'd100;
        run_to(140);
        if (span_count(0) != 16) begin
            $display("FAIL T4: retriggered player present for %0d cc, expected 16 (two 8-wide draws)",
                     span_count(0));
            fail++;
        end
        if (span_first(0) != 60 || span_last(0) != 107) begin
            $display("FAIL T4b: retriggered player spans %0d..%0d, expected 60..107",
                     span_first(0), span_last(0));
            fail++;
        end
        for (int i = 68; i < 100; i++)
            if (trace[i][0]) begin
                $display("FAIL T4c: player present at cc %0d, between the two draws", i);
                fail++;
            end

        // A match landing WHILE the object is still drawing reloads it, so the
        // shape restarts rather than continuing.
        new_line();
        grafp0 = 8'hF0; hposp0 = 8'd60;
        run_to(62);
        hposp0 = 8'd62;                             // reload two cc in
        run_to(120);
        if (span_last(0) != 65) begin
            $display("FAIL T4d: a mid-draw reload ended at cc %0d, expected 65 (restarted at 62)",
                     span_last(0));
            fail++;
        end
        hposp0 = 8'd60;

        // ================================================================
        // T5: RESIZE — SIZE mid-draw changes the RATE, not the shape
        // ================================================================
        // gtia_pmresize.  Start quad, drop to normal partway: the bits already
        // emitted stand and the register continues from where it got to.  A
        // formula would re-index the shape from the new size and emit a
        // different pattern.
        // A shape with only its top two bits set, so a restart is visible as
        // light where there should be none.
        new_line();
        grafp0 = 8'hC0; hposp0 = 8'd60; sizep0 = 2'b11;      // quad: 4cc per bit
        run_to(68);                                          // into the 2nd bit
        sizep0 = 2'b00;                                      // ...now normal
        run_to(120);
        // bit 0 lit over cc 60-63 (quad), bit 1 over 64-67, then bits 2-7 clear.
        //
        // This USED to expect 60..68 — bit 1 stretched by one — and the comment
        // here said why: "the size counter compares for equality and was
        // already past the new limit, so it wraps before matching".  That is a
        // description of an implementation artefact, not of hardware: a
        // mid-draw SHRINK left cnt above the new size_max, so the equality
        // never hit and the object stalled until the 2-bit counter wrapped all
        // the way round.  The advance compare is now >=, so the rate changes on
        // the very next colour clock, which is what "the SIZE change changes the
        // advance RATE" means.  Hardware arbitrates: ACID gtia_pmresize reports
        // $40 where $80 is required, a one-bit-position shift.
        if (span_first(0) != 60 || span_last(0) != 67) begin
            $display("FAIL T5: resized player spans %0d..%0d, expected 60..67",
                     span_first(0), span_last(0));
            fail++;
        end
        if (span_count(0) != 8) begin
            $display("FAIL T5b: resized player present %0d cc, expected 8",
                     span_count(0));
            fail++;
        end
        // The shape must not RESTART.  A formula that re-derives the bit index
        // from dx and the new size emits bit 0 again here; the register model
        // carries on into bits 2-7, which are clear.
        for (int i = 69; i < 90; i++)
            if (trace[i][0]) begin
                $display("FAIL T5c: the shape re-indexed on resize (lit again at cc %0d)", i);
                fail++;
            end
        sizep0 = 2'b00;

        // ================================================================
        // T6: nothing carries across a line boundary
        // ================================================================
        new_line();
        grafp0 = 8'hFF; hposp0 = 8'd220;            // starts near the end
        run_to(228);
        new_line();                                 // ...and the line ends
        hposp0 = 8'd200;                            // no match in the range below
        run_to(40);
        if (span_count(0) != 0) begin
            $display("FAIL T6: %0d colour clocks of the previous line's player leaked across line_start",
                     span_count(0));
            fail++;
        end

        // ================================================================
        // T7: all eight objects walk independently in one pass
        // ================================================================
        new_line();
        hposp0 = 8'd20; hposp1 = 8'd40; hposp2 = 8'd60; hposp3 = 8'd80;
        hposm0 = 8'd100; hposm1 = 8'd110; hposm2 = 8'd120; hposm3 = 8'd130;
        grafp0 = 8'hFF; grafp1 = 8'hFF; grafp2 = 8'hFF; grafp3 = 8'hFF;
        grafm  = 8'hFF;
        sizep0 = 2'b00; sizep1 = 2'b00; sizep2 = 2'b00; sizep3 = 2'b00;
        sizem  = 8'h00;
        run_to(160);
        for (int o = 0; o < 4; o++)
            if (span_first(o) != 20 + 20 * o || span_count(o) != 8) begin
                $display("FAIL T7: player %0d spans %0d for %0d cc, expected %0d for 8",
                         o, span_first(o), span_count(o), 20 + 20 * o);
                fail++;
            end
        for (int o = 0; o < 4; o++)
            if (span_first(4 + o) != 100 + 10 * o || span_count(4 + o) != 2) begin
                $display("FAIL T7b: missile %0d spans %0d for %0d cc, expected %0d for 2",
                         o, span_first(4 + o), span_count(4 + o), 100 + 10 * o);
                fail++;
            end
        // Overlapping objects are all present at once — the walk is per object,
        // not first-hit-wins.  That resolution is the priority module's job.
        new_line();
        hposp0 = 8'd50; hposp1 = 8'd50; hposp2 = 8'd50; hposp3 = 8'd50;
        run_to(80);
        if (trace[52][3:0] !== 4'b1111) begin
            $display("FAIL T7c: four stacked players gave presence %04b at cc 52, expected 1111",
                     trace[52][3:0]);
            fail++;
        end

        if (fail == 0) $display("tb_gtia_obj_walk: all checks PASS");
        else           $display("tb_gtia_obj_walk: %0d FAIL", fail);
        $finish;
    end

    initial begin
        #4000000;
        $display("FAIL: timeout");
        $finish;
    end

endmodule

`default_nettype wire
