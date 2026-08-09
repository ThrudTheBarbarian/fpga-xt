`timescale 1ns/1ps
`default_nettype none
//
// tb_antic_dl — the display list machine.
//
// Every check here corresponds to something an ACID800 test measures:
//   T1  antic_dlistwrap  — the DL pointer advances within a 1K page
//   T4  (LMS liveness)   — the memory scan pointer survives across scanlines,
//                          which is what the old design got wrong by treating
//                          the LMS operand as "the renderer's concern"
//   T6  antic_dlistwrap  — JVB parks, and its DLI keeps firing while parked
//   T7  acid800_dli_cluster — the DLI fires on the LAST scanline of a mode
//                          line, and a blank-line instruction is NOT special
//   T8  antic_vscroll / antic_vscroldli — VSCROL shortens the top of a scroll
//                          region and the bottom of the block that follows it
//
module tb_antic_dl;

    logic clk = 0, rst = 1, cold = 0;
    always #5 clk = ~clk;

    logic        line_start, in_vblank;
    logic        dlist_we_l, dlist_we_h;
    logic [7:0]  dlist_wdata;
    logic        dl_dma_en;
    logic [3:0]  vscrol;

    wire [15:0] dl_addr;
    logic [7:0] dl_data;
    wire        dl_rd;

    logic [15:0] scan_ret;
    logic        scan_we;

    wire        line_ready, hscrol_en, line_valid, dli;
    wire [3:0]  mode, row;
    wire [15:0] scan_addr, dlpc;

    antic_dl dut (
        .clk(clk), .rst(rst), .cold(cold),
        .line_start(line_start), .in_vblank(in_vblank),
        .dlist_we_l(dlist_we_l), .dlist_we_h(dlist_we_h),
        .dlist_wdata(dlist_wdata),
        .dl_dma_en(dl_dma_en), .vscrol(vscrol),
        .dl_addr(dl_addr), .dl_data(dl_data), .dl_rd(dl_rd),
        .scan_ret(scan_ret), .scan_we(scan_we),
        .line_ready(line_ready), .mode(mode), .scan_addr(scan_addr),
        .row(row), .hscrol_en(hscrol_en), .line_valid(line_valid), .dli(dli),
        .dlpc(dlpc)
    );

    // Behavioural memory, 1-clock read latency.
    logic [7:0] mem [0:65535];
    always_ff @(posedge clk) dl_data <= mem[dl_addr];

    int fail = 0;

    // What the last scanline reported.
    logic [3:0]  g_mode, g_row;
    logic        g_valid, g_dli;
    logic [15:0] g_scan;

    // Emulate the renderer: hand back a scan pointer advanced by one line's
    // worth of bytes, so the DL machine's memscan has to stay live.
    task automatic do_line;
        int guard;
        begin
            @(negedge clk); line_start = 1'b1;
            @(negedge clk); line_start = 1'b0;
            guard = 0;
            while (!line_ready && guard < 64) begin @(negedge clk); guard++; end
            if (guard >= 64) begin
                $display("FAIL: no line_ready (state stuck)"); fail++;
            end
            g_mode = mode; g_row = row; g_valid = line_valid;
            g_scan = scan_addr; g_dli = dli;
            if (line_valid) begin
                scan_ret = scan_addr + 16'd40;
                scan_we  = 1'b1;
                @(negedge clk);
                scan_we  = 1'b0;
            end
            @(negedge clk);
        end
    endtask

    task automatic set_dl(input [15:0] a);
        begin
            @(negedge clk); dlist_wdata = a[7:0];  dlist_we_l = 1'b1;
            @(negedge clk); dlist_we_l  = 1'b0;
                            dlist_wdata = a[15:8]; dlist_we_h = 1'b1;
            @(negedge clk); dlist_we_h  = 1'b0;
            @(negedge clk);
        end
    endtask

    task automatic do_cold;
        begin
            @(negedge clk); cold = 1'b1;
            @(negedge clk); cold = 1'b0;
            @(negedge clk);
        end
    endtask

    int blanks;

    initial begin
        line_start = 0; in_vblank = 0; dl_dma_en = 1; vscrol = 4'd0;
        dlist_we_l = 0; dlist_we_h = 0; dlist_wdata = 0;
        scan_ret = 0; scan_we = 0;
        for (int i = 0; i < 65536; i++) mem[i] = 8'h00;

        // ---- the display list programs ------------------------------------
        // T1: sits at the very top of a 1K page.
        mem[16'h37FF] = 8'h00;              // 1 blank line

        // T2/T3/T7: blanks, then a plain mode 2, then a mode 2 with DLI.
        mem[16'h3000] = 8'h70;              // 8 blank lines, no DLI
        mem[16'h3001] = 8'h02;              // mode 2, 8 rows
        mem[16'h3002] = 8'h82;              // mode 2 + DLI
        mem[16'h3003] = 8'hF0;              // 8 blank lines + DLI

        // T4: LMS.
        mem[16'h3500] = 8'h42;              // mode 2 + LMS
        mem[16'h3501] = 8'h34;
        mem[16'h3502] = 8'h12;              // -> $1234

        // T5: a plain jump.
        mem[16'h3100] = 8'h01;
        mem[16'h3101] = 8'h10;
        mem[16'h3102] = 8'h31;              // -> $3110
        mem[16'h3110] = 8'h70;              // 8 blank lines

        // T6: JVB with DLI.
        mem[16'h3200] = 8'hC1;              // jump + wait-for-vblank + DLI
        mem[16'h3201] = 8'h10;
        mem[16'h3202] = 8'h32;              // -> $3210
        mem[16'h3210] = 8'h00;              // 1 blank line

        // T8: a vertical scroll region and the block that closes it.
        mem[16'h3300] = 8'h22;              // mode 2 WITH vscrol
        mem[16'h3301] = 8'h02;              // mode 2 WITHOUT vscrol

        repeat (3) @(posedge clk);
        rst = 0;
        @(posedge clk);

        // ================================================================
        // T1: the DL pointer wraps within 1K (antic_dlistwrap)
        // ================================================================
        set_dl(16'h37FF);
        do_line();
        if (dlpc !== 16'h3400) begin
            $display("FAIL T1: pc after fetching $37FF is $%04h, expected $3400 (1K wrap)",
                     dlpc);
            fail++;
        end

        // ================================================================
        // T2: a blank instruction draws (count+1) blank scanlines
        // ================================================================
        do_cold();
        set_dl(16'h3000);
        blanks = 0;
        for (int i = 0; i < 8; i++) begin
            do_line();
            if (g_valid) begin
                $display("FAIL T2: blank line %0d reported line_valid", i); fail++;
            end
            if (g_dli) begin
                $display("FAIL T2b: blank line %0d fired a DLI it does not own", i);
                fail++;
            end
            blanks++;
        end
        // The NEXT line must have moved on to the mode 2 instruction.
        do_line();
        if (!g_valid || g_mode !== 4'h2 || g_row !== 4'd0) begin
            $display("FAIL T2c: after 8 blanks got valid=%0b mode=%0h row=%0d, expected a mode 2 row 0",
                     g_valid, g_mode, g_row);
            fail++;
        end

        // ================================================================
        // T3: a mode 2 block is 8 scanlines, rows 0..7
        // ================================================================
        // We are already on row 0 of the first mode 2 from T2c.
        for (int i = 1; i < 8; i++) begin
            do_line();
            if (g_mode !== 4'h2 || g_row !== 4'(i)) begin
                $display("FAIL T3: expected mode 2 row %0d, got mode %0h row %0d",
                         i, g_mode, g_row);
                fail++;
            end
        end

        // ================================================================
        // T7: the DLI fires on the LAST scanline of the mode line, and a
        //     blank-line instruction obeys the same single rule
        // ================================================================
        // Next up is $3002 = mode 2 + DLI: rows 0..7, DLI only on row 7.
        for (int i = 0; i < 8; i++) begin
            do_line();
            if (g_dli !== (i == 7)) begin
                $display("FAIL T7: mode 2+DLI row %0d gave dli=%0b, expected %0b",
                         i, g_dli, (i == 7));
                fail++;
            end
        end
        // Then $3003 = 8 blank lines + DLI: the DLI belongs to the LAST of
        // the eight, not the first.
        for (int i = 0; i < 8; i++) begin
            do_line();
            if (g_valid) begin
                $display("FAIL T7b: blank+DLI line %0d reported line_valid", i); fail++;
            end
            if (g_dli !== (i == 7)) begin
                $display("FAIL T7c: blank+DLI line %0d gave dli=%0b, expected %0b",
                         i, g_dli, (i == 7));
                fail++;
            end
        end

        // ================================================================
        // T4: LMS loads the scan pointer, and it stays LIVE across lines
        // ================================================================
        do_cold();
        set_dl(16'h3500);
        do_line();
        if (g_scan !== 16'h1234) begin
            $display("FAIL T4: LMS gave scan $%04h, expected $1234", g_scan); fail++;
        end
        if (dlpc !== 16'h3503) begin
            $display("FAIL T4b: pc after LMS is $%04h, expected $3503", dlpc); fail++;
        end
        do_line();
        if (g_scan !== 16'h125C) begin
            $display("FAIL T4c: line 2 scan $%04h, expected $125C — the memscan pointer did not stay live",
                     g_scan);
            fail++;
        end
        do_line();
        if (g_scan !== 16'h1284) begin
            $display("FAIL T4d: line 3 scan $%04h, expected $1284", g_scan); fail++;
        end

        // ================================================================
        // T5: a plain jump consumes no scanline
        // ================================================================
        do_cold();
        set_dl(16'h3100);
        do_line();
        // The very first scanline must already be the blank instruction at
        // the jump target, not a wasted line.
        if (g_valid || dlpc !== 16'h3111) begin
            $display("FAIL T5: after a jump, valid=%0b pc=$%04h, expected a blank line and pc $3111",
                     g_valid, dlpc);
            fail++;
        end

        // ================================================================
        // T6: JVB parks until vblank, and keeps firing its DLI (dlistwrap)
        // ================================================================
        do_cold();
        set_dl(16'h3200);
        in_vblank = 0;
        do_line();
        if (g_valid || !g_dli) begin
            $display("FAIL T6: the JVB line gave valid=%0b dli=%0b, expected a blank line with a DLI",
                     g_valid, g_dli);
            fail++;
        end
        if (dlpc !== 16'h3210) begin
            $display("FAIL T6b: JVB left pc at $%04h, expected the target $3210", dlpc);
            fail++;
        end
        // Parked: still blank, still firing, and the pointer must not move.
        for (int i = 0; i < 3; i++) begin
            do_line();
            if (g_valid) begin
                $display("FAIL T6c: parked line %0d drew playfield", i); fail++;
            end
            if (!g_dli) begin
                $display("FAIL T6d: parked line %0d stopped firing its DLI", i); fail++;
            end
            if (dlpc !== 16'h3210) begin
                $display("FAIL T6e: parked pc moved to $%04h", dlpc); fail++;
            end
        end
        // Vertical blank does NOT release it — the END of vertical blank does.
        //
        // Releasing at the START of vblank restarts the display list on line
        // 248 instead of line 8, which displaces the ENTIRE frame by the length
        // of the vertical blank.  Measured on hardware against the timing
        // machine, with a DLI on a known scanline and 0/1/3 blank-line openers:
        // the correct VCOUNTs are $07/$0B/$13, and releasing at the start of
        // vblank gives $7F/$00/$08 — every DLI 23 scanlines early, wrapped
        // through the top of the frame.  ACID antic_nmist waits for a specific
        // VCOUNT and then counts WSYNCs, so this desynchronises it completely.
        in_vblank = 1;
        for (int i = 0; i < 3; i++) begin
            do_line();
            if (g_valid) begin
                $display("FAIL T6f: parked vblank line %0d drew playfield", i); fail++;
            end
            if (!g_dli) begin
                $display("FAIL T6g: parked vblank line %0d stopped firing its DLI", i);
                fail++;
            end
            if (dlpc !== 16'h3210) begin
                $display("FAIL T6h: park released DURING vblank (pc $%04h)", dlpc); fail++;
            end
        end
        // Now vertical blank ends: the list resumes at the top of the display.
        in_vblank = 0;
        do_line();
        if (dlpc !== 16'h3211) begin
            $display("FAIL T6i: the end of vblank did not release the park (pc $%04h, expected $3211)",
                     dlpc);
            fail++;
        end
        if (g_dli) begin
            $display("FAIL T6j: the resumed line fired a DLI it does not own"); fail++;
        end

        // ================================================================
        // T8: VSCROL shortens the top of the region and the bottom of the
        //     block that follows it (antic_vscroll)
        // ================================================================
        do_cold();
        vscrol = 4'd3;
        set_dl(16'h3300);
        // Block 1 has the vscroll bit and the previous block did not, so it
        // starts at DCTR = VSCROL and still ends at 7: rows 3,4,5,6,7.
        for (int i = 0; i < 5; i++) begin
            do_line();
            if (g_row !== 4'(3 + i)) begin
                $display("FAIL T8: scrolled block line %0d gave row %0d, expected %0d",
                         i, g_row, 3 + i);
                fail++;
            end
        end
        // Block 2 has no vscroll bit but the previous one did, so it starts at
        // 0 and ENDS at DCTR = VSCROL: rows 0,1,2,3.
        for (int i = 0; i < 4; i++) begin
            do_line();
            if (g_row !== 4'(i)) begin
                $display("FAIL T8b: closing block line %0d gave row %0d, expected %0d",
                         i, g_row, i);
                fail++;
            end
        end
        // ...and the block really did end there, so we are back at row 0 of a
        // fresh instruction rather than row 4 of the same one.
        do_line();
        if (g_row !== 4'd0) begin
            $display("FAIL T8c: the closing block ran past VSCROL (row %0d)", g_row);
            fail++;
        end
        vscrol = 4'd0;

        // ================================================================
        // T9: with DL DMA off nothing is fetched
        // ================================================================
        do_cold();
        set_dl(16'h3000);
        dl_dma_en = 0;
        do_line();
        if (g_valid) begin
            $display("FAIL T9: DL DMA off still drew playfield"); fail++;
        end
        if (dlpc !== 16'h3000) begin
            $display("FAIL T9b: DL DMA off still moved the pointer to $%04h", dlpc);
            fail++;
        end
        dl_dma_en = 1;

        // ================================================================
        // T10: cold clears the WHOLE machine, not just the visible registers
        // ================================================================
        set_dl(16'h3000);
        do_line();                          // get part-way into a blank block
        do_line();
        do_cold();
        if (dlpc !== 16'h0000) begin
            $display("FAIL T10: cold left pc at $%04h", dlpc); fail++;
        end
        // A cleared machine must fetch a fresh instruction, not resume the
        // block it was half-way through.
        set_dl(16'h3001);                   // straight at the mode 2
        do_line();
        if (!g_valid || g_mode !== 4'h2 || g_row !== 4'd0) begin
            $display("FAIL T10b: after cold got valid=%0b mode=%0h row=%0d, expected mode 2 row 0",
                     g_valid, g_mode, g_row);
            fail++;
        end

        if (fail == 0) $display("tb_antic_dl: all checks PASS");
        else           $display("tb_antic_dl: %0d FAIL", fail);
        $finish;
    end

    initial begin
        #2000000;
        $display("FAIL: timeout");
        $finish;
    end

endmodule

`default_nettype wire
