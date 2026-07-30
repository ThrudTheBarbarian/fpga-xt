`timescale 1ns/1ps
`default_nettype none
//
// tb_antic_pm_fetch — player/missile DMA addressing.
//
// T1/T2 check the documented memory layout in both resolutions, which is the
// whole substance of the module: missiles at PMBASE+$300 and players at
// +$400/$500/$600/$700 one-line, +$180 and +$200/$280/$300/$380 two-line. They
// come out of one adder and a shift, so getting the shift wrong moves every
// object at once and is easy to miss on a single spot check.
//
// T4 is the one antic_pmdma and gtia_phantomdma care about: missiles and
// players are enabled separately, and a disabled object is not fetched at all
// so its register keeps whatever the CPU last wrote.
//
module tb_antic_pm_fetch;

    logic clk = 0, rst = 1;
    always #5 clk = ~clk;

    logic        start;
    logic [8:0]  line;
    logic [7:0]  pmbase;
    logic        player_dma_en, missile_dma_en, res_1line;
    logic [7:0]  vdelay;

    wire [15:0] mem_addr;
    logic [7:0] mem_data;
    wire        pm_we, busy, done;
    wire [2:0]  pm_obj;
    wire [7:0]  pm_data, pm_mask;

    antic_pm_fetch dut (
        .clk(clk), .rst(rst),
        .start(start), .line(line),
        .pmbase(pmbase), .player_dma_en(player_dma_en),
        .missile_dma_en(missile_dma_en), .res_1line(res_1line),
        .vdelay(vdelay),
        .mem_addr(mem_addr), .mem_data(mem_data),
        .pm_we(pm_we), .pm_obj(pm_obj), .pm_data(pm_data), .pm_mask(pm_mask),
        .busy(busy), .done(done)
    );

    // Behavioural memory, 1-clock read latency.
    logic [7:0] mem [0:65535];
    always_ff @(posedge clk) mem_data <= mem[mem_addr];

    int fail = 0;

    // Capture what each object was stored with, and the address it came from.
    logic [7:0] got  [0:4];
    logic       seen [0:4];
    logic [15:0] addr_of [0:4];
    logic [7:0]  mask_of [0:4];
    logic [15:0] addr_d;

    always_ff @(posedge clk) addr_d <= mem_addr;
    always_ff @(posedge clk) if (!rst && pm_we) begin
        got[pm_obj]     <= pm_data;
        seen[pm_obj]    <= 1'b1;
        addr_of[pm_obj] <= addr_d;
        mask_of[pm_obj] <= pm_mask;
    end

    task automatic do_line(input int ln);
        int guard;
        begin
            for (int i = 0; i < 5; i++) begin seen[i] = 1'b0; got[i] = 8'h00; end
            line = 9'(ln);
            @(negedge clk); start = 1'b1;
            @(negedge clk); start = 1'b0;
            guard = 0;
            while (!done && guard < 200) begin @(negedge clk); guard++; end
            if (guard >= 200) begin
                $display("FAIL: P/M fetch never completed"); fail++;
            end
            @(negedge clk);
        end
    endtask

    task automatic chk(input int o, input [7:0] want, input string tag);
        begin
            if (!seen[o]) begin
                $display("FAIL %s: object %0d was never fetched", tag, o);
                fail++;
            end else if (got[o] !== want) begin
                $display("FAIL %s: object %0d = $%02h from $%04h, expected $%02h",
                         tag, o, got[o], addr_of[o], want);
                fail++;
            end
        end
    endtask

    initial begin
        start = 0; line = 0; pmbase = 8'h30;
        player_dma_en = 1; missile_dma_en = 1; res_1line = 1; vdelay = 8'h00;
        for (int i = 0; i < 65536; i++) mem[i] = 8'h00;
        for (int i = 0; i < 5; i++) begin
            seen[i] = 0; got[i] = 0; addr_of[i] = 0; mask_of[i] = 0;
        end

        // ---- ONE-LINE layout: base $3000, 2K aligned --------------------
        // missiles +$300, players +$400/$500/$600/$700, indexed by scanline.
        mem[16'h3300 + 16'd50] = 8'hE5;
        mem[16'h3400 + 16'd50] = 8'hA0;
        mem[16'h3500 + 16'd50] = 8'hA1;
        mem[16'h3600 + 16'd50] = 8'hA2;
        mem[16'h3700 + 16'd50] = 8'hA3;

        // ---- TWO-LINE layout: base $3000, 1K aligned --------------------
        // missiles +$180, players +$200/$280/$300/$380, indexed by scanline/2.
        mem[16'h3180 + 16'd25] = 8'hB5;
        mem[16'h3200 + 16'd25] = 8'hB0;
        mem[16'h3280 + 16'd25] = 8'hB1;
        mem[16'h3300 + 16'd25] = 8'hB2;
        mem[16'h3380 + 16'd25] = 8'hB3;

        repeat (3) @(posedge clk);
        rst = 0;
        @(posedge clk);

        // ================================================================
        // T1: one-line resolution
        // ================================================================
        res_1line = 1'b1;
        do_line(50);
        chk(0, 8'hE5, "T1 missiles");
        chk(1, 8'hA0, "T1 P0");
        chk(2, 8'hA1, "T1 P1");
        chk(3, 8'hA2, "T1 P2");
        chk(4, 8'hA3, "T1 P3");

        // ================================================================
        // T2: two-line resolution — index halves, regions halve
        // ================================================================
        res_1line = 1'b0;
        do_line(50);                    // scanline 50 -> index 25
        chk(0, 8'hB5, "T2 missiles");
        chk(1, 8'hB0, "T2 P0");
        chk(2, 8'hB1, "T2 P1");
        chk(3, 8'hB2, "T2 P2");
        chk(4, 8'hB3, "T2 P3");
        // Both scanlines of a pair read the SAME byte — that is what two-line
        // resolution means.
        do_line(51);
        chk(1, 8'hB0, "T2b P0 on the odd line of the pair");

        // ================================================================
        // T3: exactly five fetches, in order, missiles first
        // ================================================================
        res_1line = 1'b1;
        do_line(50);
        for (int i = 0; i < 5; i++)
            if (!seen[i]) begin
                $display("FAIL T3: object %0d not fetched", i); fail++;
            end
        // Missiles come from the lowest region, players ascending above it.
        if (!(addr_of[0] < addr_of[1] && addr_of[1] < addr_of[2] &&
              addr_of[2] < addr_of[3] && addr_of[3] < addr_of[4])) begin
            $display("FAIL T3b: fetch addresses not ascending: %04h %04h %04h %04h %04h",
                     addr_of[0], addr_of[1], addr_of[2], addr_of[3], addr_of[4]);
            fail++;
        end
        if (addr_of[2] - addr_of[1] != 16'h0100) begin
            $display("FAIL T3c: one-line player stride is $%04h, expected $0100",
                     addr_of[2] - addr_of[1]);
            fail++;
        end
        res_1line = 1'b0;
        do_line(50);
        if (addr_of[2] - addr_of[1] != 16'h0080) begin
            $display("FAIL T3d: two-line player stride is $%04h, expected $0080",
                     addr_of[2] - addr_of[1]);
            fail++;
        end

        // ================================================================
        // T4: missiles and players are enabled independently
        // ================================================================
        res_1line = 1'b1;
        player_dma_en = 1'b1; missile_dma_en = 1'b0;
        do_line(50);
        if (seen[0]) begin
            $display("FAIL T4: missiles fetched with missile DMA off"); fail++;
        end
        chk(1, 8'hA0, "T4b players still fetched");

        player_dma_en = 1'b0; missile_dma_en = 1'b1;
        do_line(50);
        chk(0, 8'hE5, "T4c missiles still fetched");
        for (int i = 1; i < 5; i++)
            if (seen[i]) begin
                $display("FAIL T4d: player %0d fetched with player DMA off", i - 1);
                fail++;
            end

        // With both off nothing is stored at all, so the registers keep
        // whatever the CPU last wrote — which is what gtia_phantomdma probes.
        player_dma_en = 1'b0; missile_dma_en = 1'b0;
        do_line(50);
        for (int i = 0; i < 5; i++)
            if (seen[i]) begin
                $display("FAIL T4e: object %0d fetched with all P/M DMA off", i);
                fail++;
            end
        player_dma_en = 1'b1; missile_dma_en = 1'b1;

        // ================================================================
        // T5: PMBASE alignment differs by resolution
        // ================================================================
        // One-line needs 2K alignment, so PMBASE bits 2:0 are ignored; two-line
        // needs 1K, so only bits 1:0 are.
        pmbase = 8'h34;                 // $3400: 1K aligned, not 2K
        res_1line = 1'b1;
        do_line(0);
        if (addr_of[0] !== 16'h3300) begin
            $display("FAIL T5: one-line with PMBASE $34 used base $%04h, expected the 2K-aligned $3000 (missiles $3300)",
                     addr_of[0]);
            fail++;
        end
        res_1line = 1'b0;
        do_line(0);
        if (addr_of[0] !== 16'h3580) begin
            $display("FAIL T5b: two-line with PMBASE $34 gave missiles at $%04h, expected $3580",
                     addr_of[0]);
            fail++;
        end

        // ================================================================
        // T6: VDELAY masks the store on EVEN scanlines
        // ================================================================
        // In two-line resolution both scanlines of a pair fetch the same byte,
        // so inhibiting the even one makes the object change on the odd one --
        // which is the object one scanline lower.
        pmbase = 8'h30; res_1line = 1'b0; vdelay = 8'h00;
        do_line(50);
        if (mask_of[1] !== 8'hFF) begin
            $display("FAIL T6: no VDELAY gave player mask $%02h, expected $FF",
                     mask_of[1]);
            fail++;
        end
        vdelay = 8'h10;                 // player 0 delayed
        do_line(50);                    // even scanline: inhibited
        if (mask_of[1] !== 8'h00) begin
            $display("FAIL T6b: delayed player on an even line gave mask $%02h, expected $00",
                     mask_of[1]);
            fail++;
        end
        do_line(51);                    // odd scanline: it goes through
        if (mask_of[1] !== 8'hFF) begin
            $display("FAIL T6c: delayed player on an odd line gave mask $%02h, expected $FF",
                     mask_of[1]);
            fail++;
        end
        // ...and only the player that was named.
        do_line(50);
        for (int o = 2; o <= 4; o++)
            if (mask_of[o] !== 8'hFF) begin
                $display("FAIL T6d: player %0d masked by another player's VDELAY", o - 1);
                fail++;
            end
        vdelay = 8'h80;                 // player 3 delayed instead
        do_line(50);
        if (mask_of[4] !== 8'h00 || mask_of[1] !== 8'hFF) begin
            $display("FAIL T6e: VDELAY bit 7 should delay player 3, not player 0 (masks $%02h / $%02h)",
                     mask_of[4], mask_of[1]);
            fail++;
        end

        // ================================================================
        // T7: the missile byte is masked TWO BITS AT A TIME
        // ================================================================
        // Four missiles with four independent delay bits share one register, so
        // an all-or-nothing store enable cannot express this.
        vdelay = 8'h00;
        do_line(50);
        if (mask_of[0] !== 8'hFF) begin
            $display("FAIL T7: no VDELAY gave missile mask $%02h, expected $FF",
                     mask_of[0]);
            fail++;
        end
        vdelay = 8'h01;                 // missile 0 only
        do_line(50);
        if (mask_of[0] !== 8'hFC) begin
            $display("FAIL T7b: missile 0 delayed gave mask $%02h, expected $FC",
                     mask_of[0]);
            fail++;
        end
        vdelay = 8'h08;                 // missile 3 only
        do_line(50);
        if (mask_of[0] !== 8'h3F) begin
            $display("FAIL T7c: missile 3 delayed gave mask $%02h, expected $3F",
                     mask_of[0]);
            fail++;
        end
        vdelay = 8'h05;                 // missiles 0 and 2
        do_line(50);
        if (mask_of[0] !== 8'hCC) begin
            $display("FAIL T7d: missiles 0 and 2 delayed gave mask $%02h, expected $CC",
                     mask_of[0]);
            fail++;
        end
        // On the odd line everything goes through regardless.
        do_line(51);
        if (mask_of[0] !== 8'hFF) begin
            $display("FAIL T7e: odd line gave missile mask $%02h, expected $FF",
                     mask_of[0]);
            fail++;
        end
        // Missile delays must not touch the players, or the other way round.
        vdelay = 8'h0F;
        do_line(50);
        for (int o = 1; o <= 4; o++)
            if (mask_of[o] !== 8'hFF) begin
                $display("FAIL T7f: a missile VDELAY masked player %0d", o - 1); fail++;
            end
        vdelay = 8'hF0;
        do_line(50);
        if (mask_of[0] !== 8'hFF) begin
            $display("FAIL T7g: a player VDELAY masked the missiles"); fail++;
        end
        vdelay = 8'h00; res_1line = 1'b1;

        if (fail == 0) $display("tb_antic_pm_fetch: all checks PASS");
        else           $display("tb_antic_pm_fetch: %0d FAIL", fail);
        $finish;
    end

    initial begin
        #2000000;
        $display("FAIL: timeout");
        $finish;
    end

endmodule

`default_nettype wire
