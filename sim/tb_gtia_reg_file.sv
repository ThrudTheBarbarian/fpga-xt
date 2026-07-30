`timescale 1ns/1ps
`default_nettype none
//
// tb_gtia_reg_file — GTIA's registers, $D000-$D01F.
//
// T2 is the one that catches a register file written by assuming read-back:
// almost nothing in GTIA reads what it wrote. $D000-$D00F write positions and
// sizes but read the collision latches, and $D015-$D01E are write-only and
// return $0F — not open bus, not zero. That last value is what gtia_default
// measures.
//
// T5 pins the two-key gate that gtia_phantomdma tests on: DMACTL makes ANTIC
// FETCH a shape and GRACTL makes GTIA LATCH it, and both are needed.
//
module tb_gtia_reg_file;

    logic clk = 0, rst = 1;
    always #5 clk = ~clk;

    logic [7:0] addr, wdata;
    logic       we;
    wire  [7:0] rdata;

    logic       pm_we;
    logic [2:0] pm_obj;
    logic [7:0] pm_data, pm_mask;

    logic [15:0] m_pf, p_pf, m_pl, p_pl;
    logic [7:0]  trig0, trig1, trig2, trig3, pal_sense, consol_keys;

    wire [7:0] hposp0, hposp1, hposp2, hposp3;
    wire [7:0] hposm0, hposm1, hposm2, hposm3;
    wire [1:0] sizep0, sizep1, sizep2, sizep3;
    wire [7:0] sizem, grafp0, grafp1, grafp2, grafp3, grafm;
    wire [7:0] colpm0, colpm1, colpm2, colpm3;
    wire [7:0] colpf0, colpf1, colpf2, colpf3, colbk;
    wire [7:0] prior, vdelay, gractl;
    wire       hitclr;

    gtia_reg_file dut (
        .clk(clk), .rst(rst),
        .addr(addr), .we(we), .wdata(wdata), .rdata(rdata),
        .pm_we(pm_we), .pm_obj(pm_obj), .pm_data(pm_data), .pm_mask(pm_mask),
        .m_pf(m_pf), .p_pf(p_pf), .m_pl(m_pl), .p_pl(p_pl),
        .trig0(trig0), .trig1(trig1), .trig2(trig2), .trig3(trig3),
        .pal_sense(pal_sense), .consol_keys(consol_keys),
        .hposp0(hposp0), .hposp1(hposp1), .hposp2(hposp2), .hposp3(hposp3),
        .hposm0(hposm0), .hposm1(hposm1), .hposm2(hposm2), .hposm3(hposm3),
        .sizep0(sizep0), .sizep1(sizep1), .sizep2(sizep2), .sizep3(sizep3),
        .sizem(sizem),
        .grafp0(grafp0), .grafp1(grafp1), .grafp2(grafp2), .grafp3(grafp3),
        .grafm(grafm),
        .colpm0(colpm0), .colpm1(colpm1), .colpm2(colpm2), .colpm3(colpm3),
        .colpf0(colpf0), .colpf1(colpf1), .colpf2(colpf2), .colpf3(colpf3),
        .colbk(colbk), .prior(prior), .vdelay(vdelay), .gractl(gractl),
        .hitclr(hitclr)
    );

    int fail = 0;
    logic [7:0] v;

    task automatic wr(input [7:0] a, input [7:0] d);
        begin
            @(negedge clk); addr = a; wdata = d; we = 1'b1;
            @(negedge clk); we = 1'b0;
        end
    endtask

    task automatic rd(input [7:0] a, output [7:0] o);
        begin
            @(negedge clk); addr = a; #1; o = rdata;
        end
    endtask

    task automatic dma(input [2:0] o, input [7:0] d, input [7:0] m);
        begin
            @(negedge clk); pm_obj = o; pm_data = d; pm_mask = m; pm_we = 1'b1;
            @(negedge clk); pm_we = 1'b0;
        end
    endtask

    initial begin
        addr = 0; wdata = 0; we = 0;
        pm_we = 0; pm_obj = 0; pm_data = 0; pm_mask = 8'hFF;
        m_pf = 16'h4321; p_pf = 16'h8765; m_pl = 16'hCBA9; p_pl = 16'h0FED;
        trig0 = 8'h01; trig1 = 8'h00; trig2 = 8'h01; trig3 = 8'h00;
        pal_sense = 8'h0E; consol_keys = 8'hFF;

        repeat (3) @(posedge clk);
        rst = 0;
        @(posedge clk);

        // ---- T1: the write map --------------------------------------------
        wr(8'h00, 8'h30); wr(8'h03, 8'h33); wr(8'h04, 8'h40); wr(8'h07, 8'h47);
        wr(8'h08, 8'h03); wr(8'h0B, 8'h01); wr(8'h0C, 8'h5A);
        wr(8'h0D, 8'hD0); wr(8'h10, 8'hD3); wr(8'h11, 8'hAA);
        wr(8'h12, 8'h12); wr(8'h15, 8'h15); wr(8'h16, 8'h16); wr(8'h19, 8'h19);
        wr(8'h1A, 8'h1A); wr(8'h1B, 8'h1B); wr(8'h1C, 8'h1C); wr(8'h1D, 8'h03);
        @(negedge clk);
        if (hposp0 !== 8'h30 || hposp3 !== 8'h33) begin
            $display("FAIL T1: HPOSP0/3 $%02h/$%02h", hposp0, hposp3); fail++; end
        if (hposm0 !== 8'h40 || hposm3 !== 8'h47) begin
            $display("FAIL T1b: HPOSM0/3 $%02h/$%02h", hposm0, hposm3); fail++; end
        if (sizep0 !== 2'b11 || sizep3 !== 2'b01) begin
            $display("FAIL T1c: SIZEP0/3 %b/%b", sizep0, sizep3); fail++; end
        if (sizem !== 8'h5A) begin $display("FAIL T1d: SIZEM $%02h", sizem); fail++; end
        if (grafp0 !== 8'hD0 || grafp3 !== 8'hD3) begin
            $display("FAIL T1e: GRAFP0/3 $%02h/$%02h", grafp0, grafp3); fail++; end
        if (grafm !== 8'hAA) begin $display("FAIL T1f: GRAFM $%02h", grafm); fail++; end
        if (colpm0 !== 8'h12 || colpm3 !== 8'h15) begin
            $display("FAIL T1g: COLPM0/3 $%02h/$%02h", colpm0, colpm3); fail++; end
        if (colpf0 !== 8'h16 || colpf3 !== 8'h19) begin
            $display("FAIL T1h: COLPF0/3 $%02h/$%02h", colpf0, colpf3); fail++; end
        if (colbk !== 8'h1A || prior !== 8'h1B || vdelay !== 8'h1C) begin
            $display("FAIL T1i: COLBK/PRIOR/VDELAY $%02h/$%02h/$%02h",
                     colbk, prior, vdelay); fail++; end

        // ---- T2: the READ map is different registers -----------------------
        // $D000-$D00F wrote positions and sizes; they read collisions.
        rd(8'h00, v); if (v !== 8'h01) begin
            $display("FAIL T2: $D000 read $%02h, expected M0PF", v); fail++; end
        rd(8'h07, v); if (v !== 8'h08) begin
            $display("FAIL T2b: $D007 read $%02h, expected P3PF", v); fail++; end
        rd(8'h0C, v); if (v !== 8'h0D) begin
            $display("FAIL T2c: $D00C read $%02h, expected P0PL", v); fail++; end
        rd(8'h10, v); if (v !== trig0) begin
            $display("FAIL T2d: $D010 read $%02h, expected TRIG0", v); fail++; end
        rd(8'h14, v); if (v !== pal_sense) begin
            $display("FAIL T2e: $D014 read $%02h, expected PAL", v); fail++; end
        // $D015-$D01E are write-only: D4-D7 low, D0-D3 driven high.
        for (int i = 8'h15; i <= 8'h1E; i++) begin
            rd(8'(i), v);
            if (v !== 8'h0F) begin
                $display("FAIL T2f: $D0%02h read $%02h, expected $0F", i, v); fail++;
            end
        end

        // ---- T3: thirty-two addresses, mirrored eight times ---------------
        wr(8'hE0, 8'h77);               // $D0E0 is HPOSP0
        @(negedge clk);
        if (hposp0 !== 8'h77) begin
            $display("FAIL T3: a write to $D0E0 did not reach HPOSP0 ($%02h)", hposp0);
            fail++;
        end
        rd(8'hF4, v);                   // $D0F4 is PAL
        if (v !== pal_sense) begin
            $display("FAIL T3b: $D0F4 read $%02h, expected PAL", v); fail++; end

        // ---- T4: HITCLR is a strobe ---------------------------------------
        begin
            int n;
            n = 0;
            @(negedge clk); addr = 8'h1E; wdata = 8'h00; we = 1'b1;
            for (int i = 0; i < 4; i++) begin @(posedge clk); if (hitclr) n++; end
            @(negedge clk); we = 1'b0;
            if (n == 0) begin $display("FAIL T4: HITCLR never strobed"); fail++; end
        end

        // ---- T5: GRACTL gates the DMA store, DMACTL gates the fetch --------
        // gtia_phantomdma: ANTIC fetching a shape is not GTIA accepting it.
        wr(8'h1D, 8'h00);               // GRACTL off
        wr(8'h0D, 8'h11);               // CPU sets GRAFP0
        dma(3'd1, 8'hEE, 8'hFF);        // ...and P/M DMA offers a new one
        @(negedge clk);
        if (grafp0 !== 8'h11) begin
            $display("FAIL T5: GRAFP0 took a DMA store with GRACTL clear ($%02h)", grafp0);
            fail++;
        end
        wr(8'h1D, 8'h02);               // GRACTL: players only
        dma(3'd1, 8'hEE, 8'hFF);
        @(negedge clk);
        if (grafp0 !== 8'hEE) begin
            $display("FAIL T5b: GRAFP0 refused a DMA store with GRACTL[1] set ($%02h)",
                     grafp0);
            fail++;
        end
        // ...and the missile enable is separate.
        wr(8'h11, 8'h55);               // CPU sets GRAFM
        dma(3'd0, 8'hCC, 8'hFF);
        @(negedge clk);
        if (grafm !== 8'h55) begin
            $display("FAIL T5c: GRAFM took a DMA store with GRACTL[0] clear ($%02h)",
                     grafm);
            fail++;
        end
        wr(8'h1D, 8'h03);
        dma(3'd0, 8'hCC, 8'hFF);
        @(negedge clk);
        if (grafm !== 8'hCC) begin
            $display("FAIL T5d: GRAFM refused a DMA store with GRACTL[0] set ($%02h)",
                     grafm);
            fail++;
        end

        // ---- T6: the VDELAY mask merges rather than assigns -----------------
        wr(8'h11, 8'hFF);
        dma(3'd0, 8'h00, 8'hCC);        // only bits 7:6 and 3:2 may change
        @(negedge clk);
        if (grafm !== 8'h33) begin
            $display("FAIL T6: masked DMA store gave $%02h, expected $33", grafm);
            fail++;
        end
        dma(3'd0, 8'hFF, 8'h00);        // a zero mask changes nothing
        @(negedge clk);
        if (grafm !== 8'h33) begin
            $display("FAIL T6b: a zero mask still wrote ($%02h)", grafm); fail++;
        end

        // ---- T7: the console lines are open drain --------------------------
        consol_keys = 8'hFF;            // nothing pressed
        wr(8'h1F, 8'h00);               // release the lines
        rd(8'h1F, v);
        if (v[2:0] !== 3'b111) begin
            $display("FAIL T7: released lines with no key read %03b", v[2:0]); fail++;
        end
        wr(8'h1F, 8'h07);               // pull all three low
        rd(8'h1F, v);
        if (v[2:0] !== 3'b000) begin
            $display("FAIL T7b: driven lines read %03b, expected 000", v[2:0]); fail++;
        end
        wr(8'h1F, 8'h00);
        consol_keys = 8'hFB;            // OPTION held (bit 2 low)
        rd(8'h1F, v);
        if (v[2:0] !== 3'b011) begin
            $display("FAIL T7c: a held key read %03b, expected 011", v[2:0]); fail++;
        end

        if (fail == 0) $display("tb_gtia_reg_file: all checks PASS");
        else           $display("tb_gtia_reg_file: %0d FAIL", fail);
        $finish;
    end

    initial begin
        #4000000;
        $display("FAIL: timeout");
        $finish;
    end

endmodule

`default_nettype wire
