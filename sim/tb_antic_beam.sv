`timescale 1ns/1ps
`default_nettype none
//
// tb_antic_beam — the counter chain.
//
// T3 is the one that matters and the only reason this module is not trivial:
// the scanline advances entering cycle 111, so VCOUNT read during cycles
// 111-113 already reports the NEXT line. That is exactly what ACID's
// antic_vcount measures, and advancing at the line boundary instead puts every
// VCOUNT read three cycles late.
//
module tb_antic_beam;

    localparam int CYC   = 114;
    localparam int LINES = 262;
    localparam int ADV   = 111;

    logic clk = 0, rst = 1;
    always #5 clk = ~clk;

    logic tick;
    wire [6:0] hcount;
    wire [8:0] line;
    wire [7:0] vcount;
    wire       line_start, in_display, in_vblank;

    antic_beam #(.CYCLES_PER_LINE(CYC), .LINES_PER_FRAME(LINES),
                 .DISPLAY_TOP(8), .DISPLAY_LINES(192), .VCOUNT_ADVANCE(ADV))
    dut (
        .clk(clk), .rst(rst), .tick(tick),
        .hcount(hcount), .line(line), .vcount(vcount),
        .line_start(line_start), .in_display(in_display), .in_vblank(in_vblank)
    );

    int fail = 0;
    int line_starts;

    always @(posedge clk) if (!rst && line_start) line_starts++;

    task automatic step;
        begin
            @(negedge clk); tick = 1'b1;
            @(negedge clk); tick = 1'b0;
        end
    endtask

    // Advance until hcount reaches a value, guarding against never getting there.
    task automatic goto_cycle(input int c);
        int guard;
        begin
            guard = 0;
            while (hcount != 7'(c) && guard < 2*CYC) begin step(); guard++; end
            if (guard >= 2*CYC) begin
                $display("FAIL: never reached cycle %0d", c); fail++;
            end
        end
    endtask

    int seen_line_at_110, seen_line_at_111;

    initial begin
        tick = 0; line_starts = 0;
        repeat (3) @(posedge clk);
        rst = 0;
        @(posedge clk);

        // ---- T1: hcount wraps at CYCLES_PER_LINE -------------------------
        goto_cycle(CYC - 1);
        step();
        if (hcount !== 7'd0) begin
            $display("FAIL T1: hcount=%0d after the last cycle, expected 0", hcount);
            fail++;
        end

        // ---- T2: exactly one line_start per line -------------------------
        line_starts = 0;
        for (int i = 0; i < CYC; i++) step();
        if (line_starts != 1) begin
            $display("FAIL T2: %0d line_starts in one line, expected 1", line_starts);
            fail++;
        end

        // ---- T3: the scanline advances ENTERING cycle 111 ----------------
        // The increment happens on the edge that takes hcount 110 -> 111, so
        // sit AT 110 and step once: the sample after is the first cycle of the
        // new line's VCOUNT.
        goto_cycle(ADV - 1);            // sit at 110
        seen_line_at_110 = int'(line);
        step();                          // -> 111, line has advanced
        seen_line_at_111 = int'(line);
        if (seen_line_at_111 != seen_line_at_110 + 1) begin
            $display("FAIL T3: line went %0d -> %0d entering cycle %0d, expected +1",
                     seen_line_at_110, seen_line_at_111, hcount);
            fail++;
        end
        // ...and it must NOT advance again at the line wrap.
        goto_cycle(0);
        if (int'(line) != seen_line_at_111) begin
            $display("FAIL T3b: line advanced again at the wrap (%0d -> %0d)",
                     seen_line_at_111, line);
            fail++;
        end

        // ---- T4: VCOUNT is the scanline halved ---------------------------
        for (int i = 0; i < 8; i++) begin
            if (vcount !== line[8:1]) begin
                $display("FAIL T4: vcount=%0d but line=%0d", vcount, line); fail++;
            end
            for (int j = 0; j < CYC; j++) step();
        end

        // ---- T5: the display band ----------------------------------------
        // Lines 8..199 draw playfield; everything else is vblank.
        while (line != 9'd7) begin step(); end
        goto_cycle(0);
        if (in_display) begin
            $display("FAIL T5: line 7 reported as display"); fail++;
        end
        while (line != 9'd8) begin step(); end
        goto_cycle(0);
        if (!in_display) begin
            $display("FAIL T5b: line 8 not reported as display"); fail++;
        end
        while (line != 9'd200) begin step(); end
        goto_cycle(0);
        if (in_display) begin
            $display("FAIL T5c: line 200 reported as display"); fail++;
        end
        if (!in_vblank) begin
            $display("FAIL T5d: line 200 not reported as vblank"); fail++;
        end

        // ---- T6: the frame wraps -----------------------------------------
        while (line != 9'(LINES - 1)) begin step(); end
        while (line == 9'(LINES - 1)) begin step(); end
        if (line !== 9'd0) begin
            $display("FAIL T6: frame wrapped to line %0d, expected 0", line); fail++;
        end

        if (fail == 0) $display("tb_antic_beam: all checks PASS");
        else           $display("tb_antic_beam: %0d FAIL", fail);
        $finish;
    end

    initial begin
        #20000000;
        $display("FAIL: timeout");
        $finish;
    end

endmodule

`default_nettype wire
