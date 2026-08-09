`timescale 1ns/1ps
`default_nettype none
//
// tb_antic_gtia — the whole pair, driven only through the CPU bus.
//
// Every other testbench in this set reaches into the design and drives module
// ports directly. This one does not: it writes $D400/$D401/... and $D000/... the
// way a 6502 would, and reads back on the same bus. If a register is unreachable
// or wired to the wrong place, nothing here works — which is exactly the class
// of mistake that survives unit tests and then wastes a day on hardware.
//
// It runs at the real 56 fabric clocks per machine cycle, because the GTIA stage
// needs 26 of the 28 in a colour clock and a compressed ratio would not exercise
// it.
//
module tb_antic_gtia;

    localparam int CYC = 114;

    logic clk = 0, rst = 1, cold = 0;
    always #5 clk = ~clk;

    // 56 clocks per machine cycle, 4 hi-res pixels to each.
    logic [5:0] phase = 6'd0;
    logic       tick, px_tick;
    always_ff @(posedge clk) begin
        phase   <= (phase == 6'd55) ? 6'd0 : phase + 6'd1;
        tick    <= (phase == 6'd55);
        px_tick <= (phase == 6'd13) || (phase == 6'd27) ||
                   (phase == 6'd41) || (phase == 6'd55);
    end

    logic       cs_antic, cs_gtia, we;
    logic [7:0] addr, wdata;
    wire  [7:0] rdata;

    wire        rdy_n, nmi_n, dma_steal;
    wire [15:0] mem_addr;
    logic [7:0] mem_data;
    wire        lb_wr, lb_line_start;
    wire [7:0]  lb_color;
    wire [6:0]  hcount;
    wire [8:0]  line;
    wire [7:0]  vcount;
    wire        line_start;
    wire [15:0] dlpc;

    antic_gtia dut (
        .tune(16'd0),
        .clk(clk), .rst(rst), .cold(cold),
        .tick(tick), .px_tick(px_tick),
        .cs_antic(cs_antic), .cs_gtia(cs_gtia),
        .addr(addr), .we(we), .wdata(wdata), .rdata(rdata),
        .rdy_n(rdy_n), .nmi_n(nmi_n), .dma_steal(dma_steal),
        .mem_addr(mem_addr), .mem_data(mem_data),
        .trig0(8'h01), .trig1(8'h01), .trig2(8'h01), .trig3(8'h01),
        .pal_sense(8'h0E), .consol_keys(8'hFF),
        .lb_wr(lb_wr), .lb_color(lb_color), .lb_line_start(lb_line_start),
        .hcount(hcount), .line(line), .vcount(vcount),
        .line_start(line_start), .dlpc(dlpc)
    );

    logic [7:0] mem [0:65535];
    always_ff @(posedge clk) mem_data <= mem[mem_addr];

    // Shadow the scanline, mirroring the line buffer's own ordering.
    logic [7:0] shadow [0:511];
    int wp;
    always_ff @(posedge clk) begin
        if (lb_wr && wp < 512) shadow[wp] <= lb_color;
        if (lb_line_start) wp <= 0;
        else if (lb_wr)    wp <= wp + 1;
    end

    int fail = 0;
    logic [7:0] v;

    // A CPU write: one machine cycle wide, like a real store.
    task automatic poke(input logic antic, input [7:0] a, input [7:0] d);
        begin
            @(negedge clk);
            addr = a; wdata = d; we = 1'b1;
            cs_antic = antic; cs_gtia = !antic;
            @(negedge clk);
            we = 1'b0; cs_antic = 1'b0; cs_gtia = 1'b0;
        end
    endtask

    task automatic peek(input logic antic, input [7:0] a, output [7:0] o);
        begin
            @(negedge clk);
            addr = a; cs_antic = antic; cs_gtia = !antic; #1;
            o = rdata;
            @(negedge clk); cs_antic = 1'b0; cs_gtia = 1'b0;
        end
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

    function automatic int first_pf(input [7:0] bg);
        begin
            first_pf = -1;
            for (int i = 455; i >= 0; i--) if (shadow[i] !== bg) first_pf = i;
        end
    endfunction

    initial begin
        cs_antic = 0; cs_gtia = 0; we = 0; addr = 0; wdata = 0; wp = 0;
        for (int i = 0; i < 65536; i++) mem[i] = 8'h00;
        for (int i = 0; i < 512; i++)   shadow[i] = 8'h00;

        // A display list at $3000: a blank line, then mode E from $8000.
        mem[16'h3000] = 8'h00;
        mem[16'h3001] = 8'h4E;
        mem[16'h3002] = 8'h00;
        mem[16'h3003] = 8'h80;
        for (int i = 4; i < 220; i++) mem[16'h3000 + i] = 8'h0E;
        for (int i = 0; i < 4096; i++) mem[16'h8000 + i] = 8'hFF;

        repeat (4) @(posedge clk);
        rst = 0;
        repeat (4) @(posedge clk);

        // ================================================================
        // T1: bring the display up entirely through the bus
        // ================================================================
        poke(1, 8'h02, 8'h00);          // DLISTL
        poke(1, 8'h03, 8'h30);          // DLISTH
        poke(0, 8'h1A, 8'h00);          // COLBK  = $00
        poke(0, 8'h18, 8'h94);          // COLPF2 = $94
        poke(0, 8'h1B, 8'h01);          // PRIOR  = $01
        poke(1, 8'h00, 8'h22);          // DMACTL = normal + DL DMA

        repeat (6) next_line();
        next_line();
        if (count_pf(8'h00) != 320) begin
            $display("FAIL T1: %0d playfield pixels, expected 320 — the display did not come up through the bus",
                     count_pf(8'h00));
            fail++;
        end
        if (first_pf(8'h00) != 80) begin
            $display("FAIL T1b: playfield starts at %0d, expected 80", first_pf(8'h00));
            fail++;
        end

        // ================================================================
        // T2: a colour register write is visible on the next line
        // ================================================================
        poke(0, 8'h18, 8'h3A);          // COLPF2 = $3A
        repeat (3) next_line();
        if (shadow[100] !== 8'h3A) begin
            $display("FAIL T2: pixel 100 is $%02h after a COLPF2 write, expected $3A",
                     shadow[100]);
            fail++;
        end
        poke(0, 8'h18, 8'h94);

        // ================================================================
        // T3: the read map answers on the bus
        // ================================================================
        peek(1, 8'h0B, v);              // VCOUNT
        if (v !== vcount) begin
            $display("FAIL T3: VCOUNT read $%02h, beam says $%02h", v, vcount); fail++;
        end
        peek(1, 8'h00, v);              // DMACTL is write-only
        if (v !== 8'hFF) begin
            $display("FAIL T3b: DMACTL read $%02h, expected $FF", v); fail++;
        end
        peek(0, 8'h1B, v);              // PRIOR is write-only
        if (v !== 8'h0F) begin
            $display("FAIL T3c: a write-only GTIA read gave $%02h, expected $0F", v);
            fail++;
        end
        peek(0, 8'h10, v);              // TRIG0
        if (v !== 8'h01) begin
            $display("FAIL T3d: TRIG0 read $%02h, expected $01", v); fail++;
        end

        // ================================================================
        // T4: a player, positioned and coloured through the bus
        // ================================================================
        poke(0, 8'h12, 8'h30);          // COLPM0 = $30
        poke(0, 8'h00, 8'd60);          // HPOSP0 = 60
        poke(0, 8'h08, 8'h00);          // SIZEP0 = normal
        poke(0, 8'h0D, 8'hFF);          // GRAFP0 = solid
        repeat (3) next_line();
        for (int i = 120; i <= 135; i++)
            if (shadow[i] !== 8'h30) begin
                $display("FAIL T4: pixel %0d is $%02h, expected the player $30",
                         i, shadow[i]);
                fail++;
            end
        if (shadow[119] !== 8'h94 || shadow[136] !== 8'h94) begin
            $display("FAIL T4b: the playfield around the player is $%02h/$%02h",
                     shadow[119], shadow[136]);
            fail++;
        end

        // ================================================================
        // T5: collisions read back on the bus, and HITCLR clears them
        // ================================================================
        poke(0, 8'h1E, 8'h00);          // HITCLR
        repeat (2) next_line();
        peek(0, 8'h04, v);              // P0PF
        if (v[2] !== 1'b1) begin
            $display("FAIL T5: P0PF read $%02h — the player is over COLPF2", v);
            fail++;
        end
        poke(0, 8'h1E, 8'h00);
        peek(0, 8'h04, v);
        if (v !== 8'h00) begin
            $display("FAIL T5b: HITCLR left P0PF at $%02h", v); fail++;
        end
        poke(0, 8'h0D, 8'h00);          // put the player away

        // ================================================================
        // T6: WSYNC holds the CPU, after its delay slot
        // ================================================================
        // /RDY trails the latch by a MACHINE cycle -- 56 fabric clocks here --
        // so it is deliberately still high immediately after the write.  That
        // gap is the delay slot an RMW needs; see antic_reg_file.
        poke(1, 8'h0A, 8'h00);
        @(negedge clk);
        if (rdy_n) begin
            $display("FAIL T6: /RDY fell in the same fabric clock as the write — the delay slot is gone");
            fail++;
        end
        begin
            int guard; logic held;
            held = 1'b0; guard = 0;
            while (!held && guard < 200) begin
                @(posedge clk); if (rdy_n) held = 1'b1;
                guard++;
            end
            if (!held) begin
                $display("FAIL T6b: WSYNC never held the CPU"); fail++;
            end
        end
        // Wait for the release and check where it happened.
        begin
            int guard;
            guard = 0;
            while (rdy_n && guard < 200000) begin @(posedge clk); guard++; end
            if (rdy_n) begin
                $display("FAIL T6c: /RDY never came back"); fail++;
            end
        end

        // ================================================================
        // T7: a DLI fires the NMI, through the bus
        // ================================================================
        @(negedge clk);
        mem[16'h3004] = 8'h8E;          // mode E + DLI
        poke(1, 8'h0E, 8'h80);          // NMIEN = DLI
        poke(1, 8'h0F, 8'h00);          // NMIRES
        poke(1, 8'h02, 8'h00);          // re-aim the list: it has no JVB
        poke(1, 8'h03, 8'h30);
        begin
            int guard; logic seen;
            seen = 1'b0; guard = 0;
            while (!seen && guard < 400000) begin
                @(posedge clk);
                if (!nmi_n) seen = 1'b1;
                guard++;
            end
            if (!seen) begin
                $display("FAIL T7: no NMI from a display list DLI"); fail++;
            end
        end
        peek(1, 8'h0F, v);              // NMIST
        if (v[7] !== 1'b1) begin
            $display("FAIL T7b: NMIST read $%02h, expected the DLI bit", v); fail++;
        end
        poke(1, 8'h0E, 8'h00);

        // ================================================================
        // T8: ANTIC steals cycles from the CPU
        // ================================================================
        // Not how many or which — tb_antic_dma_sched checks that against ACID's
        // own maps.  This is that the signal reaches the top at all, and that
        // turning the playfield off stops it.
        begin
            int steals_on, steals_off;
            steals_on = 0; steals_off = 0;
            @(posedge line_start);
            for (int c = 0; c < CYC * 56; c++) begin
                @(posedge clk); if (dma_steal) steals_on++;
            end
            poke(1, 8'h00, 8'h20);      // DL DMA on, playfield width 0
            repeat (3) next_line();
            @(posedge line_start);
            for (int c = 0; c < CYC * 56; c++) begin
                @(posedge clk); if (dma_steal) steals_off++;
            end
            if (steals_on <= steals_off) begin
                $display("FAIL T8: %0d steals with a playfield, %0d without — it should be far more",
                         steals_on, steals_off);
                fail++;
            end
            if (steals_off == 0) begin
                $display("FAIL T8b: no steals at all with the playfield off — refresh still happens");
                fail++;
            end
        end

        if (fail == 0) $display("tb_antic_gtia: all checks PASS");
        else           $display("tb_antic_gtia: %0d FAIL", fail);
        $finish;
    end

    initial begin
        #200000000;
        $display("FAIL: timeout");
        $finish;
    end

endmodule

`default_nettype wire
