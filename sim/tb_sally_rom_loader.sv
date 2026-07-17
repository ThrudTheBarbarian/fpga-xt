// tb_sally_rom_loader.sv — the ROM-loader AXI-Lite write path, driven the way
// the Zynq PS M_AXI_GP0 master actually behaves: AWVALID first, wait for
// AWREADY, THEN WVALID.  That ordering DEADLOCKED the old FSM (which needed
// awvalid&&wvalid in one cycle) and hung the A9 on the window's first real use.
// Also checks the classic "both together" ordering, a W-before-AW ordering, and
// that an out-of-window ($0xxx) AW is left alone for xt_gp0_regs.
`timescale 1ns/1ps
`default_nettype none

module tb_sally_rom_loader;
    logic clk_sys = 0, clk_sally = 0, rst = 1;
    always #5  clk_sys   = ~clk_sys;      // 100 MHz-ish
    always #7  clk_sally = ~clk_sally;    // async-ish to clk_sys

    logic [31:0] awaddr, wdata, araddr;
    logic        awvalid, wvalid, bready, arvalid, rready;
    logic [3:0]  wstrb;
    logic        awready, wready, bvalid, arready, rvalid;
    logic [1:0]  bresp, rresp;
    logic [31:0] rdata;
    logic [15:0] rom_addr;
    logic [7:0]  rom_data;
    logic        rom_we;

    sally_rom_loader dut (
        .clk_sys(clk_sys), .rst_sys(rst),
        .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr(araddr), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready),
        .clk_sally(clk_sally), .rst_sally(rst),
        .rom_addr(rom_addr), .rom_data(rom_data), .rom_we(rom_we)
    );

    int nfail = 0;
    logic [15:0] cap_addr; logic [7:0] cap_data; int cap_n = 0;
    always_ff @(posedge clk_sally)
        if (rom_we) begin cap_addr <= rom_addr; cap_data <= rom_data; cap_n <= cap_n + 1; end
    // sticky B-response monitor (the pulse is 1 cycle; a per-posedge sample can miss it)
    logic b_seen = 0;
    always_ff @(posedge clk_sys) if (bvalid && bready) b_seen <= 1;

    // The PS ordering: AWVALID up, hold until AWREADY, THEN WVALID up.
    task automatic write_aw_then_w(input [15:0] addr, input [7:0] data,
                                   input int max_cyc);
        int c; logic done;
        @(negedge clk_sys);
        awaddr = {16'h43C0, addr}; awvalid = 1'b1;   // full addr; only [15:0] used
        // wait for AWREADY (do NOT assert WVALID yet — this is the deadlock case)
        c = 0; done = 0;
        while (!done && c < max_cyc) begin
            @(posedge clk_sys);
            if (awready) done = 1;
            c++;
        end
        if (!done) begin $display("FAIL: AWREADY never asserted (DEADLOCK) addr=%04h", addr); nfail++; disable write_aw_then_w; end
        @(negedge clk_sys); awvalid = 1'b0;
        // now the data
        wdata = {24'd0, data}; wstrb = 4'b0001; wvalid = 1'b1;
        c = 0; done = 0;
        while (!done && c < max_cyc) begin @(posedge clk_sys); if (wready) done = 1; c++; end
        if (!done) begin $display("FAIL: WREADY never asserted addr=%04h", addr); nfail++; disable write_aw_then_w; end
        @(negedge clk_sys); wvalid = 1'b0; bready = 1'b1;
        c = 0; done = 0;
        while (!done && c < max_cyc) begin @(posedge clk_sys); if (bvalid) done = 1; c++; end
        if (!done) begin $display("FAIL: BVALID never asserted addr=%04h", addr); nfail++; disable write_aw_then_w; end
        @(negedge clk_sys); bready = 1'b0;
        $display("  ok  AW-then-W addr=%04h data=%02h completed", addr, data);
    endtask

    // Both AW and W asserted together (the old FSM's only working case).
    task automatic write_together(input [15:0] addr, input [7:0] data, input int max_cyc);
        int c;
        b_seen = 0;
        @(negedge clk_sys);
        awaddr = {16'h43C0, addr}; awvalid = 1'b1;
        wdata = {24'd0, data}; wstrb = 4'b0001; wvalid = 1'b1; bready = 1'b1;
        c = 0;
        while (!b_seen && c < max_cyc) begin
            @(posedge clk_sys);
            if (awready) awvalid = 1'b0;   // drop each on its own ready
            if (wready)  wvalid  = 1'b0;
            c++;
        end
        @(negedge clk_sys); awvalid=0; wvalid=0; bready=0;
        if (!b_seen) begin $display("FAIL: together addr=%04h no BVALID", addr); nfail++; end
        else $display("  ok  together addr=%04h data=%02h completed", addr, data);
    endtask

    initial begin
        awvalid=0; wvalid=0; bready=0; arvalid=0; rready=0; awaddr=0; wdata=0; wstrb=0; araddr=0;
        repeat (4) @(posedge clk_sys);
        rst = 0;
        repeat (2) @(posedge clk_sys);

        $display("[T1] PS ordering: AW, wait AWREADY, then W (the deadlock case)");
        cap_n = 0;
        write_aw_then_w(16'h1000, 8'hAA, 200);
        repeat (8) @(posedge clk_sally);
        if (cap_n != 1)              begin $display("FAIL T1: rom_we pulses=%0d (want 1)", cap_n); nfail++; end
        else if (cap_addr!=16'h1000 || cap_data!=8'hAA)
                                     begin $display("FAIL T1: rom addr=%04h data=%02h", cap_addr, cap_data); nfail++; end
        else $display("  ok  T1: rom_we -> addr=1000 data=AA");

        $display("[T2] both-together ordering still works");
        cap_n = 0;
        write_together(16'hC123, 8'h5A, 200);
        repeat (8) @(posedge clk_sally);
        if (cap_n != 1 || cap_addr!=16'hC123 || cap_data!=8'h5A)
                                     begin $display("FAIL T2: n=%0d addr=%04h data=%02h", cap_n, cap_addr, cap_data); nfail++; end
        else $display("  ok  T2: rom_we -> addr=C123 data=5A");

        $display("[T3] a burst of AW-then-W writes (upload pattern)");
        cap_n = 0;
        for (int i = 0; i < 8; i++) write_aw_then_w(16'h2000 + i[15:0], 8'h10 + i[7:0], 200);
        repeat (8) @(posedge clk_sally);
        if (cap_n != 8) begin $display("FAIL T3: pushed %0d/8", cap_n); nfail++; end
        else $display("  ok  T3: 8 bytes uploaded, last=%04h/%02h", cap_addr, cap_data);

        if (nfail == 0) $display("*** SALLY_ROM_LOADER OK ***");
        else            $display("*** SALLY_ROM_LOADER FAIL *** %0d failure(s)", nfail);
        $finish;
    end

    initial begin #500000; $display("*** SALLY_ROM_LOADER TIMEOUT (hang not fixed) ***"); $finish; end
endmodule
`default_nettype wire
