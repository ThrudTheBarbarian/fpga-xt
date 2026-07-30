`timescale 1ns/1ps
`default_nettype none
//
// tb_antic_nmi — NMIEN, NMIST and the /NMI line.
//
// T1 is the one antic_dlitiming was really about. The status bit and the /NMI
// are ONE CYCLE APART — status at 7, /NMI at 8 — and modelling them as a single
// event is what made the two delivery sleds move together no matter what was
// tried on the CPU side. This checks the gap directly, by reading NMIST on the
// cycle between them.
//
// T3 pins the flags as a 2-bit latch rather than a pair of independent set-reset
// flip-flops: a DLI clears the VBI bit and vice versa, so a program that misses
// an interrupt cannot ever see both at once.
//
module tb_antic_nmi;

    localparam int CYC = 114;

    logic clk = 0, rst = 1;
    always #5 clk = ~clk;

    logic       tick, line_start, dli, vbi_line, nmires;
    logic [6:0] hcount;
    logic [7:0] nmien;

    wire [7:0] nmist;
    wire       nmi_n;

    antic_nmi dut (
        .clk(clk), .rst(rst),
        .tick(tick), .hcount(hcount), .line_start(line_start),
        .dli(dli), .vbi_line(vbi_line),
        .nmien(nmien), .nmires(nmires),
        .nmist(nmist), .nmi_n(nmi_n)
    );

    int fail = 0;

    // A machine cycle: pulse tick, then advance hcount.
    task automatic step;
        begin
            @(negedge clk); tick = 1'b1;
            @(negedge clk); tick = 1'b0;
                            hcount = (hcount == 7'(CYC - 1)) ? 7'd0 : hcount + 7'd1;
        end
    endtask

    // Run a scanline, optionally flagging it for a DLI.  The display list
    // reports its DLI early in the line, as antic_dl does.
    task automatic run_line(input logic want_dli, input logic want_vbi);
        begin
            @(negedge clk); line_start = 1'b1;
            @(negedge clk); line_start = 1'b0;
            vbi_line = want_vbi;
            hcount = 7'd0;
            if (want_dli) begin
                @(negedge clk); dli = 1'b1;
                @(negedge clk); dli = 1'b0;
            end
            for (int c = 0; c < CYC; c++) step();
        end
    endtask

    // Run a line but stop at a given cycle, so the state can be inspected
    // partway through.
    task automatic run_to_cycle(input logic want_dli, input logic want_vbi,
                                input int upto);
        begin
            @(negedge clk); line_start = 1'b1;
            @(negedge clk); line_start = 1'b0;
            vbi_line = want_vbi;
            hcount = 7'd0;
            if (want_dli) begin
                @(negedge clk); dli = 1'b1;
                @(negedge clk); dli = 1'b0;
            end
            for (int c = 0; c < upto; c++) step();
        end
    endtask

    task automatic do_nmires;
        begin
            @(negedge clk); nmires = 1'b1;
            @(negedge clk); nmires = 1'b0;
        end
    endtask

    initial begin
        tick = 0; hcount = 0; line_start = 0; dli = 0; vbi_line = 0;
        nmires = 0; nmien = 8'hC0;      // both interrupts enabled

        repeat (3) @(posedge clk);
        rst = 0;
        @(posedge clk);

        // ================================================================
        // T1: the status leads the /NMI by exactly one cycle
        // ================================================================
        do_nmires();
        // Stop after cycle 7 has been stepped: the status is set, /NMI is not
        // yet asserted.
        run_to_cycle(1'b1, 1'b0, 8);
        if (nmist[7] !== 1'b1) begin
            $display("FAIL T1: NMIST[7] not set after cycle 7 (nmist $%02h)", nmist);
            fail++;
        end
        if (nmi_n !== 1'b1) begin
            $display("FAIL T1b: /NMI already low after cycle 7 — it belongs at cycle 8");
            fail++;
        end
        step();                         // now cycle 8 goes by
        if (nmi_n !== 1'b0) begin
            $display("FAIL T1c: /NMI not asserted after cycle 8"); fail++;
        end
        // Finish the line.
        for (int c = 9; c < CYC; c++) step();

        // ================================================================
        // T2: a line without a DLI does nothing
        // ================================================================
        do_nmires();
        run_line(1'b0, 1'b0);
        if (nmist[7] !== 1'b0) begin
            $display("FAIL T2: a plain line set NMIST[7] (nmist $%02h)", nmist); fail++;
        end
        if (nmi_n !== 1'b1) begin
            $display("FAIL T2b: a plain line pulled /NMI low"); fail++;
        end

        // ================================================================
        // T3: the flags are a latch, not two independent bits
        // ================================================================
        do_nmires();
        run_line(1'b1, 1'b0);
        if ((nmist & 8'hC0) !== 8'h80) begin
            $display("FAIL T3: after a DLI, NMIST is $%02h, expected bit 7 only", nmist);
            fail++;
        end
        run_line(1'b0, 1'b1);           // a VBI, with the DLI flag still set
        if ((nmist & 8'hC0) !== 8'h40) begin
            $display("FAIL T3b: after a VBI, NMIST is $%02h — the DLI bit should have gone",
                     nmist);
            fail++;
        end
        run_line(1'b1, 1'b0);           // ...and back the other way
        if ((nmist & 8'hC0) !== 8'h80) begin
            $display("FAIL T3c: after a DLI, NMIST is $%02h — the VBI bit should have gone",
                     nmist);
            fail++;
        end
        // A coincidence goes to the VBI.
        do_nmires();
        run_line(1'b1, 1'b1);
        if ((nmist & 8'hC0) !== 8'h40) begin
            $display("FAIL T3d: a coincident DLI and VBI gave $%02h, expected the VBI",
                     nmist);
            fail++;
        end

        // ================================================================
        // T4: the low five bits are not driven
        // ================================================================
        do_nmires();
        if ((nmist & 8'h1F) !== 8'h1F) begin
            $display("FAIL T4: NMIST low bits read $%02h, expected all ones", nmist & 8'h1F);
            fail++;
        end
        if (nmist !== 8'h1F) begin
            $display("FAIL T4b: a cleared NMIST reads $%02h, expected $1F", nmist);
            fail++;
        end

        // ================================================================
        // T5: NMIEN gates the interrupt, not the status
        // ================================================================
        do_nmires();
        nmien = 8'h00;
        run_line(1'b1, 1'b0);
        if (nmist[7] !== 1'b1) begin
            $display("FAIL T5: with NMIEN clear the DLI status did not latch — a polling program would miss it");
            fail++;
        end
        if (nmi_n !== 1'b1) begin
            $display("FAIL T5b: /NMI fired with NMIEN clear"); fail++;
        end
        // The two enables are independent.  /NMI is only low for a few cycles
        // after cycle 8, so both of these are sampled inside the pulse rather
        // than at the end of the line.
        do_nmires();
        nmien = 8'h40;                  // VBI only
        run_to_cycle(1'b1, 1'b0, 10);
        if (nmi_n !== 1'b1) begin
            $display("FAIL T5c: a DLI fired with only the VBI enabled"); fail++;
        end
        for (int c = 10; c < CYC; c++) step();
        run_to_cycle(1'b0, 1'b1, 10);
        if (nmi_n !== 1'b0) begin
            $display("FAIL T5d: the VBI did not fire with its own enable set"); fail++;
        end
        for (int c = 10; c < CYC; c++) step();
        nmien = 8'hC0;

        // ================================================================
        // T6: NMIRES clears, but a coincident set wins
        // ================================================================
        do_nmires();
        run_line(1'b1, 1'b0);
        do_nmires();
        if ((nmist & 8'hC0) !== 8'h00) begin
            $display("FAIL T6: NMIRES left $%02h", nmist); fail++;
        end
        // Acknowledge exactly as the status is being set: the event is
        // happening now and the clear refers to something already past, so the
        // new flag must stand or the interrupt is lost silently.
        run_to_cycle(1'b1, 1'b0, 7);    // stop just before cycle 7 is stepped
        @(negedge clk); nmires = 1'b1; tick = 1'b1;
        @(negedge clk); nmires = 1'b0; tick = 1'b0;
                        hcount = hcount + 7'd1;
        if (nmist[7] !== 1'b1) begin
            $display("FAIL T6b: an NMIRES coincident with the set swallowed the DLI");
            fail++;
        end
        for (int c = 8; c < CYC; c++) step();

        // ================================================================
        // T7: /NMI comes back up on its own
        // ================================================================
        do_nmires();
        run_line(1'b1, 1'b0);
        if (nmi_n !== 1'b1) begin
            $display("FAIL T7: /NMI still low at the end of the line — ANTIC releases it, the acknowledge does not");
            fail++;
        end

        if (fail == 0) $display("tb_antic_nmi: all checks PASS");
        else           $display("tb_antic_nmi: %0d FAIL", fail);
        $finish;
    end

    initial begin
        #4000000;
        $display("FAIL: timeout");
        $finish;
    end

endmodule

`default_nettype wire
