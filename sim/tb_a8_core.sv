`timescale 1ns/1ps
`default_nettype none
//
// tb_a8_core — a real 6502 program bringing the display up.
//
// The last testbench that pokes registers from the outside is tb_antic_gtia.
// This one does not poke anything: a hand-assembled program sits in memory, the
// core fetches it through the reset vector, and the display appears because the
// CPU executed stores to $D4xx and $D0xx. If the register decode, the bus mux or
// the clock enable is wrong, nothing happens at all.
//
// T2 is the one that matters for the cycle stealing being real rather than
// decorative: it counts how many instructions the CPU retires in a scanline with
// the playfield on and off, and the difference is ANTIC taking the bus.
//
// T3 checks the two halt paths are composed differently — WSYNC cannot stall a
// write, ANTIC's HALT can. Getting those the same way round is a
// silent-corruption bug rather than a visible one.
//
module tb_a8_core;

    localparam int CYC = 114;

    logic clk = 0, rst = 1, cold = 0;
    always #5 clk = ~clk;

    // The real ratio: 56 fabric clocks per machine cycle.
    logic [5:0] phase = 6'd0;
    logic       tick, px_tick;
    always_ff @(posedge clk) begin
        phase   <= (phase == 6'd55) ? 6'd0 : phase + 6'd1;
        tick    <= (phase == 6'd55);
        px_tick <= (phase == 6'd13) || (phase == 6'd27) ||
                   (phase == 6'd41) || (phase == 6'd55);
    end

    wire [15:0] cpu_addr, antic_addr;
    wire [7:0]  cpu_wdata;
    wire        cpu_we;
    logic [7:0] cpu_rdata, antic_rdata;

    wire        lb_wr, lb_line_start, dma_steal, rdy_n, nmi_n, sync;
    wire [7:0]  lb_color;
    wire [15:0] dbg_pc;
    wire [7:0]  dbg_a, dbg_x, dbg_y, dbg_s, dbg_p;
    wire [6:0]  hcount;
    wire [8:0]  line;

    a8_core dut (
        .clk(clk), .rst(rst), .cold(cold),
        .tick(tick), .px_tick(px_tick), .tune(16'd0),
        .cpu_addr(cpu_addr), .cpu_wdata(cpu_wdata), .cpu_we(cpu_we),
        .cpu_rdata(cpu_rdata),
        .antic_addr(antic_addr), .antic_rdata(antic_rdata),
        .irq_n(1'b1),
        .trig0(8'h01), .trig1(8'h01), .trig2(8'h01), .trig3(8'h01),
        .pal_sense(8'h0F), .consol_keys(8'hFF),
        .lb_wr(lb_wr), .lb_color(lb_color), .lb_line_start(lb_line_start),
        .dma_steal(dma_steal), .rdy_n(rdy_n), .nmi_n(nmi_n), .sync(sync),
        .dbg_pc(dbg_pc), .dbg_a(dbg_a), .dbg_x(dbg_x), .dbg_y(dbg_y),
        .dbg_s(dbg_s), .dbg_p(dbg_p),
        .hcount(hcount), .line(line)
    );

    // Dual-ported memory: the CPU writes and reads one port, ANTIC reads the
    // other.  On the FPGA this is what a BRAM gives for free.
    logic [7:0] mem [0:65535];
    always_ff @(posedge clk) begin
        if (cpu_we) mem[cpu_addr] <= cpu_wdata;
        cpu_rdata   <= mem[cpu_addr];
        antic_rdata <= mem[antic_addr];
    end

    logic [7:0] shadow [0:511];
    int wp;
    always_ff @(posedge clk) begin
        if (lb_wr && wp < 512) shadow[wp] <= lb_color;
        if (lb_line_start) wp <= 0;
        else if (lb_wr)    wp <= wp + 1;
    end

    int fail = 0;
    int p;

    task automatic emit(input [7:0] b);
        begin mem[p] = b; p = p + 1; end
    endtask

    task automatic next_line;
        begin @(posedge lb_line_start); @(negedge clk); end
    endtask

    function automatic int count_pf(input [7:0] bg);
        int n; begin
            n = 0;
            for (int i = 0; i < 456; i++) if (shadow[i] !== bg) n++;
            count_pf = n;
        end
    endfunction

    initial begin
        wp = 0;
        for (int i = 0; i < 65536; i++) mem[i] = 8'h00;
        for (int i = 0; i < 512; i++)   shadow[i] = 8'h00;

        // ---- the display list, at $3000 ----------------------------------
        mem[16'h3000] = 8'h00;                  // one blank scanline
        mem[16'h3001] = 8'h4E;                  // mode E + LMS
        mem[16'h3002] = 8'h00;
        mem[16'h3003] = 8'h80;                  // ...from $8000
        for (int i = 4; i < 220; i++) mem[16'h3000 + i] = 8'h0E;
        for (int i = 0; i < 4096; i++) mem[16'h8000 + i] = 8'hFF;

        // ---- the program, at $2000 ---------------------------------------
        p = 16'h2000;
        emit(8'hA9); emit(8'h00);               // LDA #$00
        emit(8'h8D); emit(8'h02); emit(8'hD4);  // STA DLISTL
        emit(8'hA9); emit(8'h30);               // LDA #$30
        emit(8'h8D); emit(8'h03); emit(8'hD4);  // STA DLISTH
        emit(8'hA9); emit(8'h00);               // LDA #$00
        emit(8'h8D); emit(8'h1A); emit(8'hD0);  // STA COLBK
        emit(8'hA9); emit(8'h94);               // LDA #$94
        emit(8'h8D); emit(8'h18); emit(8'hD0);  // STA COLPF2
        emit(8'hA9); emit(8'h01);               // LDA #$01
        emit(8'h8D); emit(8'h1B); emit(8'hD0);  // STA PRIOR
        emit(8'hA9); emit(8'h22);               // LDA #$22
        emit(8'h8D); emit(8'h00); emit(8'hD4);  // STA DMACTL
        // spin
        mem[16'h2020] = 8'h4C; mem[16'h2021] = 8'h20; mem[16'h2022] = 8'h20;
        if (p > 16'h2020) begin
            $display("FAIL: the setup program overran the spin loop"); fail++;
        end
        for (int i = p; i < 16'h2020; i++) mem[i] = 8'hEA;   // NOP fill

        mem[16'hFFFC] = 8'h00;                  // reset vector -> $2000
        mem[16'hFFFD] = 8'h20;

        repeat (4) @(posedge clk);
        rst = 0;

        // ================================================================
        // T1: the program brings the display up on its own
        // ================================================================
        repeat (10) next_line();
        if (dbg_pc < 16'h2020 || dbg_pc > 16'h2022) begin
            $display("FAIL T1: the CPU is at $%04h, expected the spin loop at $2020",
                     dbg_pc);
            fail++;
        end
        next_line();
        next_line();
        if (count_pf(8'h00) != 320) begin
            $display("FAIL T1b: %0d playfield pixels, expected 320 — the program's stores did not reach the chips",
                     count_pf(8'h00));
            fail++;
        end
        if (shadow[200] !== 8'h94) begin
            $display("FAIL T1c: pixel 200 is $%02h, expected COLPF2 $94", shadow[200]);
            fail++;
        end

        // ================================================================
        // T2: ANTIC really takes cycles away from the CPU
        // ================================================================
        // Count the machine cycles the CPU is HELD in a scanline, with the
        // playfield on and then with DMACTL width 0.
        //
        // Counting instruction fetches instead does not work and is worth
        // recording: `sync` stays asserted while a fetch is halted, so
        // `sync && tick` counts machine cycles spent in the fetch state and
        // goes UP as stealing increases -- exactly backwards.
        begin
            int held_on, held_off;
            held_on = 0; held_off = 0;

            @(posedge lb_line_start);
            for (int c = 0; c < CYC * 56; c++) begin
                @(posedge clk); if (tick && !dut.c_rdy) held_on++;
            end

            // Poke DMACTL down to width 0 by rewriting the program's constant
            // and letting it run again is slow; drive the register directly
            // through the CPU's own bus instead, by restarting at $2000 with a
            // different DMACTL value.
            // The DMACTL constant is the operand of the last LDA, at $201A.
            // ($201C is the low byte of the STA address, and patching THAT
            // just aims the store at $D420 -- which mirrors back to $D400 and
            // changes nothing, because ANTIC decodes four bits.)
            mem[16'h201A] = 8'h20;              // LDA #$20 (DL DMA, width 0)
            mem[16'hFFFC] = 8'h00; mem[16'hFFFD] = 8'h20;
            rst = 1'b1; @(posedge clk); @(posedge clk); rst = 1'b0;
            repeat (12) next_line();

            @(posedge lb_line_start);
            for (int c = 0; c < CYC * 56; c++) begin
                @(posedge clk); if (tick && !dut.c_rdy) held_off++;
            end

            if (held_on <= held_off) begin
                $display("FAIL T2: the CPU was held %0d cycles with a playfield and %0d without — ANTIC is not stealing",
                         held_on, held_off);
                fail++;
            end
            // With the playfield off there is still refresh and the display
            // list, so the CPU never gets a whole line to itself.
            if (held_off == 0) begin
                $display("FAIL T2b: no cycles held with the playfield off — refresh and the display list still cost");
                fail++;
            end
            $display("  cycle stealing: CPU held %0d cycles per line with the playfield, %0d without",
                     held_on, held_off);
        end

        // ================================================================
        // T3: HALT and RDY are composed differently
        // ================================================================
        // WSYNC cannot stall a write; ANTIC's HALT can.  Checked at the point
        // the two are combined, because from outside they look the same.
        begin
            int seen_wsync_write, seen_halt_write;
            seen_wsync_write = 0; seen_halt_write = 0;
            for (int c = 0; c < CYC * 56 * 4; c++) begin
                @(posedge clk);
                if (tick && !dut.c_rw) begin
                    // a CPU write cycle
                    if (rdy_n     && dut.c_rdy) seen_wsync_write++;
                    if (dma_steal && dut.c_rdy) seen_halt_write++;
                end
            end
            if (seen_halt_write != 0) begin
                $display("FAIL T3: a write ran during %0d stolen cycles — HALT is unconditional",
                         seen_halt_write);
                fail++;
            end
        end
        // ...and the composition itself, directly.
        if (dut.wsync_ok !== (!rdy_n || !dut.c_rw)) begin
            $display("FAIL T3b: WSYNC is not write-immune"); fail++;
        end
        if (dut.halt_n !== !dma_steal) begin
            $display("FAIL T3c: HALT is not unconditional"); fail++;
        end

        if (fail == 0) $display("tb_a8_core: all checks PASS");
        else           $display("tb_a8_core: %0d FAIL", fail);
        $finish;
    end

    initial begin
        #400000000;
        $display("FAIL: timeout");
        $finish;
    end

endmodule

`default_nettype wire
