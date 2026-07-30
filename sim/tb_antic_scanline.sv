`timescale 1ns/1ps
`default_nettype none
//
// tb_antic_scanline — the whole raster path, beam to line buffer.
//
// A real display list in a behavioural memory, a real beam, and a check on
// WHERE in the line buffer each pixel lands. That last part is the point: every
// module below has been tested for what it produces, and this is the first test
// of where it goes.
//
// T3 and T4 are the ones the rewrite exists for. They write DMACTL and HSCROL
// partway along a scanline and require the playfield edge to move on that same
// scanline — antic_pfstoptiming and antic_hscrolbug in miniature. A renderer
// that decides the row at one instant cannot pass them at any price.
//
module tb_antic_scanline;

    localparam int CYC   = 114;
    localparam int LINES = 262;

    logic clk = 0, rst = 1, cold = 0;
    always #5 clk = ~clk;

    // 16 fabric clocks per machine cycle, 4 hi-res pixels per cycle.  The real
    // ratio is ~56; 16 keeps the simulation quick and still leaves the fetch
    // (~200 clocks worst case) finished long before the window opens.
    logic [3:0] phase = 4'd0;
    logic       tick, px_tick;
    always_ff @(posedge clk) begin
        phase   <= phase + 4'd1;
        tick    <= (phase == 4'd15);
        px_tick <= (phase[1:0] == 2'b11);
    end

    wire [6:0] hcount;
    wire [8:0] line;
    wire [7:0] vcount;
    wire       line_start, in_display, in_vblank;

    antic_beam #(.CYCLES_PER_LINE(CYC), .LINES_PER_FRAME(LINES),
                 .DISPLAY_TOP(8), .DISPLAY_LINES(192))
    u_beam (
        .clk(clk), .rst(rst), .tick(tick),
        .hcount(hcount), .line(line), .vcount(vcount),
        .line_start(line_start), .in_display(in_display), .in_vblank(in_vblank)
    );

    logic [7:0] dmactl, chbase;
    logic [2:0] chactl;
    logic [3:0] hscrol, vscrol;
    logic       dlist_we_l, dlist_we_h;
    logic [7:0] dlist_wdata;
    logic [7:0] colbk, colpf0, colpf1, colpf2, colpf3;

    wire [15:0] mem_addr;
    logic [7:0] mem_data;
    wire        lb_wr, dli;
    wire [7:0]  lb_color;
    wire [15:0] dlpc;

    antic_scanline u_sl (
        .clk(clk), .rst(rst), .cold(cold),
        .line_start(line_start), .px_tick(px_tick), .hcount(hcount),
        .in_vblank(in_vblank),
        .dmactl(dmactl), .chactl(chactl),
        .dlist_we_l(dlist_we_l), .dlist_we_h(dlist_we_h),
        .dlist_wdata(dlist_wdata),
        .hscrol(hscrol), .vscrol(vscrol), .chbase(chbase),
        .colbk(colbk), .colpf0(colpf0), .colpf1(colpf1),
        .colpf2(colpf2), .colpf3(colpf3),
        .mem_addr(mem_addr), .mem_data(mem_data),
        .lb_wr(lb_wr), .lb_color(lb_color),
        .dli(dli), .dlpc(dlpc)
    );

    logic [9:0] rd_addr;
    wire [7:0]  rd_color;

    antic_line_buf u_lb (
        .clk(clk), .rst(rst),
        .line_start(line_start), .wr_stb(lb_wr), .wr_color(lb_color),
        .wr_index(), .rd_addr(rd_addr), .rd_color(rd_color), .swap(1'b0)
    );

    // Behavioural memory, 1-clock read latency.
    logic [7:0] mem [0:65535];
    always_ff @(posedge clk) mem_data <= mem[mem_addr];

    // Shadow the line buffer's writes so a completed line can be inspected
    // without disturbing the ping-pong.
    logic [7:0] shadow [0:511];
    int         wp, last_line_px;
    // Mirror the line buffer's own ordering: the write uses the current
    // pointer and the rewind happens on the same edge, so the last pixel of a
    // line still lands before the pointer goes back to zero.
    always_ff @(posedge clk) begin
        if (lb_wr && wp < 512) shadow[wp] <= lb_color;
        if (line_start) begin
            last_line_px <= wp + (lb_wr ? 1 : 0);
            wp           <= 0;
        end else if (lb_wr) begin
            wp <= wp + 1;
        end
    end

    int fail = 0;
    int pixels_this_line;

    task automatic next_line;
        begin
            @(posedge line_start);
            @(negedge clk);
        end
    endtask

    // Wait until the beam is at a given machine cycle of the current line.
    task automatic at_cycle(input int c);
        int guard;
        begin
            guard = 0;
            while (hcount != 7'(c) && guard < 4 * CYC * 16) begin
                @(negedge clk); guard++;
            end
        end
    endtask

    task automatic chk_px(input int i, input [7:0] want, input string tag);
        begin
            if (shadow[i] !== want) begin
                $display("FAIL %s: line buffer[%0d] = $%02h, expected $%02h",
                         tag, i, shadow[i], want);
                fail++;
            end
        end
    endtask

    // How many pixels of a finished line are playfield rather than background.
    function automatic int count_pf;
        int n;
        begin
            n = 0;
            for (int i = 0; i < 456; i++) if (shadow[i] !== colbk) n++;
            count_pf = n;
        end
    endfunction

    function automatic int first_pf;
        begin
            first_pf = -1;
            for (int i = 455; i >= 0; i--) if (shadow[i] !== colbk) first_pf = i;
        end
    endfunction

    function automatic int last_pf;
        begin
            last_pf = -1;
            for (int i = 0; i < 456; i++) if (shadow[i] !== colbk) last_pf = i;
        end
    endfunction

    initial begin
        dmactl = 8'h22;                 // normal width + display list DMA
        chactl = 3'b000; chbase = 8'hE0;
        hscrol = 4'd0; vscrol = 4'd0;
        dlist_we_l = 0; dlist_we_h = 0; dlist_wdata = 0;
        colbk = 8'h00; colpf0 = 8'h28; colpf1 = 8'h3A; colpf2 = 8'h94;
        colpf3 = 8'h56;
        wp = 0; last_line_px = 0;
        for (int i = 0; i < 65536; i++) mem[i] = 8'h00;
        for (int i = 0; i < 512; i++)   shadow[i] = 8'h00;

        // A display list at $3000: one blank, then mode E lines forever.
        mem[16'h3000] = 8'h00;                      // 1 blank scanline
        mem[16'h3001] = 8'h4E;                      // mode E + LMS
        mem[16'h3002] = 8'h00;
        mem[16'h3003] = 8'h80;                      // -> $8000
        for (int i = 4; i < 200; i++) mem[16'h3000 + i] = 8'h0E;   // mode E

        // Playfield data: every byte $FF, so every playfield pixel is COLPF2
        // and any background pixel stands out.
        for (int i = 0; i < 4096; i++) mem[16'h8000 + i] = 8'hFF;

        repeat (4) @(posedge clk);
        rst = 0;
        repeat (4) @(posedge clk);

        // Point ANTIC at the display list.
        @(negedge clk); dlist_wdata = 8'h00; dlist_we_l = 1'b1;
        @(negedge clk); dlist_we_l = 1'b0;
                        dlist_wdata = 8'h30; dlist_we_h = 1'b1;
        @(negedge clk); dlist_we_h = 1'b0;

        // Let it settle onto a mode E line.
        repeat (4) next_line();

        // ================================================================
        // T1: a normal-width line fills exactly the normal window
        // ================================================================
        next_line();
        next_line();
        if (count_pf() != 320) begin
            $display("FAIL T1: %0d playfield pixels on a normal line, expected 320",
                     count_pf());
            fail++;
        end
        if (first_pf() != 80) begin
            $display("FAIL T1b: playfield starts at pixel %0d, expected 80 (cycle 20)",
                     first_pf());
            fail++;
        end
        if (last_pf() != 399) begin
            $display("FAIL T1c: playfield ends at pixel %0d, expected 399 (cycle 100)",
                     last_pf());
            fail++;
        end
        chk_px(79,  colbk, "T1d");      // one before: border
        chk_px(80,  colpf2, "T1e");
        chk_px(399, colpf2, "T1f");
        chk_px(400, colbk, "T1g");      // one after: border

        // ================================================================
        // T2: narrow is inset by 8 machine cycles at BOTH ends
        // ================================================================
        @(negedge clk); dmactl = 8'h21;             // narrow
        next_line();
        next_line();
        if (count_pf() != 256) begin
            $display("FAIL T2: %0d playfield pixels on a narrow line, expected 256",
                     count_pf());
            fail++;
        end
        if (first_pf() != 112 || last_pf() != 367) begin
            $display("FAIL T2b: narrow playfield spans %0d..%0d, expected 112..367",
                     first_pf(), last_pf());
            fail++;
        end
        @(negedge clk); dmactl = 8'h23;             // wide
        next_line();
        next_line();
        if (first_pf() != 48 || last_pf() != 431) begin
            $display("FAIL T2c: wide playfield spans %0d..%0d, expected 48..431",
                     first_pf(), last_pf());
            fail++;
        end
        @(negedge clk); dmactl = 8'h22;             // back to normal

        // ================================================================
        // T3: DMACTL written MID-LINE moves the edge on THAT line
        // ================================================================
        // This is antic_pfstoptiming.  Start the line normal, then narrow it
        // partway: the playfield must stop early on this very scanline.
        next_line();
        at_cycle(60);                               // well inside the playfield
        @(negedge clk); dmactl = 8'h21;             // narrow, mid-line
        next_line();                                // let the line finish
        if (last_pf() != 367) begin
            $display("FAIL T3: a mid-line DMACTL narrow left the playfield ending at %0d, expected 367",
                     last_pf());
            fail++;
        end
        // ...and the START was still normal, because the change came later.
        if (first_pf() != 80) begin
            $display("FAIL T3b: the mid-line change moved the START to %0d, expected 80",
                     first_pf());
            fail++;
        end
        @(negedge clk); dmactl = 8'h22;
        next_line();

        // ================================================================
        // T4: HSCROL moves the playfield start
        // ================================================================
        // Give the mode line a scroll bit and watch the start move with HSCROL.
        // Scrolled normal fetches wide, so the window opens at the wide start
        // (cycle 12 = pixel 48) plus HSCROL.
        for (int i = 4; i < 200; i++) mem[16'h3000 + i] = 8'h1E;   // mode E + HSCROL
        @(negedge clk); hscrol = 4'd0;
        repeat (3) next_line();
        next_line();
        if (first_pf() != 48) begin
            $display("FAIL T4: HSCROL=0 scrolled line starts at %0d, expected 48",
                     first_pf());
            fail++;
        end
        if (count_pf() != 320) begin
            $display("FAIL T4b: a scrolled normal line shows %0d px, expected 320",
                     count_pf());
            fail++;
        end
        @(negedge clk); hscrol = 4'd4;              // 4 colour clocks = 8 px
        repeat (2) next_line();
        if (first_pf() != 56) begin
            $display("FAIL T4c: HSCROL=4 starts at %0d, expected 56 (48 + 8)",
                     first_pf());
            fail++;
        end
        @(negedge clk); hscrol = 4'd15;             // 15 cc = 30 px
        repeat (2) next_line();
        if (first_pf() != 78) begin
            $display("FAIL T4d: HSCROL=15 starts at %0d, expected 78 (48 + 30)",
                     first_pf());
            fail++;
        end
        @(negedge clk); hscrol = 4'd0;
        for (int i = 4; i < 200; i++) mem[16'h3000 + i] = 8'h0E;   // unscroll
        repeat (3) next_line();

        // ================================================================
        // T5: DMACTL width 0 blanks the playfield entirely
        // ================================================================
        @(negedge clk); dmactl = 8'h20;             // DL DMA on, width off
        repeat (2) next_line();
        if (count_pf() != 0) begin
            $display("FAIL T5: width 0 still drew %0d playfield pixels", count_pf());
            fail++;
        end
        @(negedge clk); dmactl = 8'h22;
        repeat (2) next_line();

        // ================================================================
        // T6: the whole line is written, every line
        // ================================================================
        // 456 pixels, no more and no less: the border comes from writing
        // background outside the window, not from leaving the buffer stale.
        next_line();
        next_line();
        pixels_this_line = last_line_px;
        if (pixels_this_line != 456) begin
            $display("FAIL T6: %0d pixels written on a scanline, expected 456",
                     pixels_this_line);
            fail++;
        end

        // ================================================================
        // T7: a blank display list instruction draws background only
        // ================================================================
        // The list starts with one blank scanline; force a restart and catch it.
        @(negedge clk); cold = 1'b1;
        @(negedge clk); cold = 1'b0;
        @(negedge clk); dlist_wdata = 8'h00; dlist_we_l = 1'b1;
        @(negedge clk); dlist_we_l = 1'b0;
                        dlist_wdata = 8'h30; dlist_we_h = 1'b1;
        @(negedge clk); dlist_we_h = 1'b0;
        next_line();                                // the blank instruction
        next_line();
        if (count_pf() != 0) begin
            $display("FAIL T7: the blank instruction drew %0d playfield pixels",
                     count_pf());
            fail++;
        end
        // ...and the line after it is a real mode E line again.
        next_line();
        if (count_pf() != 320) begin
            $display("FAIL T7b: the line after the blank drew %0d px, expected 320",
                     count_pf());
            fail++;
        end

        if (fail == 0) $display("tb_antic_scanline: all checks PASS");
        else           $display("tb_antic_scanline: %0d FAIL", fail);
        $finish;
    end

    initial begin
        #40000000;
        $display("FAIL: timeout");
        $finish;
    end

endmodule

`default_nettype wire
