`timescale 1ns/1ps
`default_nettype none
//
// tb_antic_reg_file — ANTIC's registers, $D400-$D40F.
//
// T5 and T6 are the two that were hard-won and are easy to undo:
//
//   T5  the WSYNC strobe must be an EDGE. Derived from the write level instead,
//       a stalled write holds it asserted and re-arms WSYNC the instant /RDY is
//       released, and the machine never restarts.
//   T6  a read-modify-write instruction writes $D40A twice and the delay arms
//       on the FIRST write. Arming on every write regresses VCOUNT.
//
module tb_antic_reg_file;

    localparam int CYC = 114;

    logic clk = 0, rst = 1;
    always #5 clk = ~clk;

    logic       tick;
    logic [6:0] hcount;
    logic [7:0] addr, wdata;
    logic       we;
    logic [7:0] vcount, nmist;

    wire [7:0] rdata;
    wire [7:0] dmactl, chactl, hscrol, vscrol, pmbase, chbase, nmien;
    wire       dlist_we_l, dlist_we_h, nmires, rdy_n;
    wire [7:0] dlist_wdata;

    antic_reg_file dut (
        .clk(clk), .rst(rst), .tick(tick), .hcount(hcount),
        .addr(addr), .we(we), .wdata(wdata), .rdata(rdata),
        .vcount(vcount), .nmist(nmist),
        .dmactl(dmactl), .chactl(chactl), .hscrol(hscrol), .vscrol(vscrol),
        .pmbase(pmbase), .chbase(chbase), .nmien(nmien),
        .dlist_we_l(dlist_we_l), .dlist_we_h(dlist_we_h),
        .dlist_wdata(dlist_wdata), .nmires(nmires), .rdy_n(rdy_n)
    );

    int fail = 0;
    int dl_l_count, dl_h_count;

    always @(posedge clk) if (!rst) begin
        if (dlist_we_l) dl_l_count++;
        if (dlist_we_h) dl_h_count++;
    end

    task automatic step;
        begin
            @(negedge clk); tick = 1'b1;
            @(negedge clk); tick = 1'b0;
                            hcount = (hcount == 7'(CYC-1)) ? 7'd0 : hcount + 7'd1;
        end
    endtask

    task automatic wr(input [7:0] a, input [7:0] d);
        begin
            @(negedge clk); addr = a; wdata = d; we = 1'b1;
            @(negedge clk); we = 1'b0;
        end
    endtask

    // A write held across several clocks, as a stalled bus cycle would be.
    task automatic wr_held(input [7:0] a, input [7:0] d, input int clocks);
        begin
            @(negedge clk); addr = a; wdata = d; we = 1'b1;
            repeat (clocks) @(negedge clk);
            we = 1'b0;
        end
    endtask

    task automatic rd(input [7:0] a, output [7:0] v);
        begin
            @(negedge clk); addr = a; #1; v = rdata;
        end
    endtask

    logic [7:0] v;

    initial begin
        tick = 0; hcount = 0; addr = 0; wdata = 0; we = 0;
        vcount = 8'h5A; nmist = 8'h9F;
        dl_l_count = 0; dl_h_count = 0;

        repeat (3) @(posedge clk);
        rst = 0;
        @(posedge clk);

        // ---- T1: the writable registers -----------------------------------
        wr(8'h00, 8'h22); wr(8'h01, 8'h02); wr(8'h04, 8'h07);
        wr(8'h05, 8'h03); wr(8'h07, 8'h70); wr(8'h09, 8'hE0);
        wr(8'h0E, 8'hC0);
        @(negedge clk);
        if (dmactl !== 8'h22) begin $display("FAIL T1 DMACTL $%02h", dmactl); fail++; end
        if (chactl !== 8'h02) begin $display("FAIL T1b CHACTL $%02h", chactl); fail++; end
        if (hscrol !== 8'h07) begin $display("FAIL T1c HSCROL $%02h", hscrol); fail++; end
        if (vscrol !== 8'h03) begin $display("FAIL T1d VSCROL $%02h", vscrol); fail++; end
        if (pmbase !== 8'h70) begin $display("FAIL T1e PMBASE $%02h", pmbase); fail++; end
        if (chbase !== 8'hE0) begin $display("FAIL T1f CHBASE $%02h", chbase); fail++; end
        if (nmien  !== 8'hC0) begin $display("FAIL T1g NMIEN $%02h", nmien); fail++; end

        // ---- T2: only VCOUNT and NMIST read anything ----------------------
        rd(8'h0B, v);
        if (v !== 8'h5A) begin $display("FAIL T2: VCOUNT read $%02h", v); fail++; end
        rd(8'h0F, v);
        if (v !== 8'h9F) begin $display("FAIL T2b: NMIST read $%02h", v); fail++; end
        for (int i = 0; i < 16; i++) begin
            if (i == 11 || i == 15) continue;
            rd(8'(i), v);
            if (v !== 8'hFF) begin
                $display("FAIL T2c: $D40%01h read $%02h, expected $FF (write-only)", i, v);
                fail++;
            end
        end

        // ---- T3: sixteen addresses, mirrored sixteen times ----------------
        // antic_addrmirror: ANTIC decodes four bits and nothing above them.
        wr(8'hF0, 8'h11);               // $D4F0 is DMACTL
        @(negedge clk);
        if (dmactl !== 8'h11) begin
            $display("FAIL T3: a write to $D4F0 did not reach DMACTL (got $%02h)", dmactl);
            fail++;
        end
        rd(8'h8B, v);                   // $D48B is VCOUNT
        if (v !== 8'h5A) begin
            $display("FAIL T3b: $D48B read $%02h, expected VCOUNT", v); fail++;
        end

        // ---- T4: the display list pointer is forwarded, not held -----------
        dl_l_count = 0; dl_h_count = 0;
        wr(8'h02, 8'h34);
        @(negedge clk);
        if (dl_l_count != 1 || dlist_wdata !== 8'h34) begin
            $display("FAIL T4: DLISTL write not forwarded (count %0d data $%02h)",
                     dl_l_count, dlist_wdata);
            fail++;
        end
        wr(8'h03, 8'h12);
        @(negedge clk);
        if (dl_h_count != 1) begin
            $display("FAIL T4b: DLISTH write not forwarded"); fail++;
        end
        rd(8'h02, v);
        if (v !== 8'hFF) begin
            $display("FAIL T4c: DLISTL read $%02h — ANTIC never drives it", v); fail++;
        end

        // ---- T5: the WSYNC strobe is an EDGE ------------------------------
        // A held write must arm ONCE.  Held as a level, WSYNC re-arms the
        // instant /RDY is released and the machine never restarts.
        hcount = 7'd0;
        wr_held(8'h0A, 8'h00, 12);      // a long, stalled write
        @(negedge clk);
        if (!rdy_n) begin
            $display("FAIL T5: WSYNC did not hold the CPU"); fail++;
        end
        // Run to the release cycle with the write still recently held.
        while (hcount != 7'd104) step();
        step();
        if (rdy_n) begin
            $display("FAIL T5b: /RDY never came back — the strobe re-armed itself");
            fail++;
        end

        // ---- T6: a read-modify-write arms on the FIRST write --------------
        // RMW writes $D40A twice.  Arming on both regresses VCOUNT.
        hcount = 7'd0;
        wr(8'h0A, 8'h00);               // first write
        step(); step();
        wr(8'h0A, 8'h00);               // the RMW's second write
        @(negedge clk);
        if (!rdy_n) begin
            $display("FAIL T6: not waiting after an RMW WSYNC"); fail++;
        end
        while (hcount != 7'd104) step();
        step();
        if (rdy_n) begin
            $display("FAIL T6b: the second write of an RMW re-armed WSYNC"); fail++;
        end

        // ---- T7: WSYNC releases at 104, not before ------------------------
        hcount = 7'd0;
        wr(8'h0A, 8'h00);
        @(negedge clk);
        while (hcount != 7'd103) step();
        if (!rdy_n) begin
            $display("FAIL T7: /RDY came back before cycle 104"); fail++;
        end
        step();                          // 103 -> 104
        step();                          // the release
        if (rdy_n) begin
            $display("FAIL T7b: /RDY did not come back at cycle 104"); fail++;
        end

        // ---- T8: NMIRES is a one-clock strobe ------------------------------
        begin
            int n;
            n = 0;
            @(negedge clk); addr = 8'h0F; wdata = 8'h00; we = 1'b1;
            for (int i = 0; i < 6; i++) begin
                @(posedge clk); if (nmires) n++;
            end
            @(negedge clk); we = 1'b0;
            if (n != 1) begin
                $display("FAIL T8: a held NMIRES write pulsed %0d times, expected 1", n);
                fail++;
            end
        end

        if (fail == 0) $display("tb_antic_reg_file: all checks PASS");
        else           $display("tb_antic_reg_file: %0d FAIL", fail);
        $finish;
    end

    initial begin
        #4000000;
        $display("FAIL: timeout");
        $finish;
    end

endmodule

`default_nettype wire
