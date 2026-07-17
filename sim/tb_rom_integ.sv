// tb_rom_integ.sv — sally_rom_loader + sally_mem WIRED TOGETHER, end to end.
// The board bring-up (2026-07-17) found the ROM-window OS upload never reaches
// the CPU's executed ROM, even though the loader (tb_sally_rom_loader) and
// sally_mem (tb_sally_mem A.12) each pass in isolation. This TB closes the gap:
// drive AXI writes into the loader the way the PS does (AW, wait AWREADY, then
// W, held BREADY), let its rom_we drive sally_mem, then read the bytes back on
// sally_mem's CPU port with OS ROM enabled. Includes a BURST (the real 52 KB
// upload is thousands of back-to-back writes — a FIFO drain bug could hide until
// sustained load).
`timescale 1ns/1ps
`default_nettype none

module tb_rom_integ;
    logic clk_sys = 0, clk_sally = 0, rst = 1;
    always #5  clk_sys   = ~clk_sys;    // ~100 MHz
    always #7  clk_sally = ~clk_sally;  // async to clk_sys (like the real 133/100)

    // ---- GP0 AXI-Lite (driven by this TB, into the loader) ----
    logic [31:0] awaddr, wdata; logic awvalid, wvalid, bready; logic [3:0] wstrb;
    wire awready, wready, bvalid; wire [1:0] bresp;
    logic [31:0] araddr = 0; logic arvalid = 0, rready = 0;
    wire arready, rvalid; wire [31:0] rdata; wire [1:0] rresp;

    // ---- loader -> sally_mem ROM-init bus ----
    wire [15:0] rom_addr; wire [7:0] rom_data; wire rom_we;

    sally_rom_loader u_loader (
        .clk_sys(clk_sys), .rst_sys(rst),
        .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr(araddr), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready),
        .clk_sally(clk_sally), .rst_sally(rst),
        .rom_addr(rom_addr), .rom_data(rom_data), .rom_we(rom_we)
    );

    // ---- sally_mem CPU-side probe ----
    logic [15:0] addr = 0; logic [7:0] data_in = 0; logic rw = 1; wire [7:0] data_out;
    logic [7:0] portb = 8'h03;   // OS ROM ON (bit0=1), BASIC off (bit1=1)
    logic tb_rdy = 1;
    wire [15:0] hwreg_addr; wire hwreg_we; wire [7:0] hwreg_din; logic [7:0] hwreg_dout = 8'hFF;
    wire mem_busy;
    // banking AXI (unused here; tie the slave off with a memory model)
    wire [31:0] ax_araddr, ax_awaddr; wire [7:0] ax_arlen, ax_awlen; wire [2:0] ax_arsize, ax_awsize;
    wire [1:0] ax_arburst, ax_awburst; wire ax_arvalid, ax_arready, ax_rvalid, ax_rlast, ax_rready;
    wire [63:0] ax_rdata, ax_wdata; wire ax_awvalid, ax_awready, ax_wvalid, ax_wready, ax_wlast;
    wire [7:0] ax_wstrb; wire ax_bvalid, ax_bready;

    sally_mem #(.DDR3_BANKED_BASE(32'h0), .DDR3_DATA_BASE(32'h0008_0000), .BANKED_CACHE("LINE"))
    u_mem (
        .clk(clk_sally), .rst(rst), .addr(addr), .data_in(data_in), .rw(rw), .data_out(data_out),
        .rdy(tb_rdy), .busy(mem_busy),
        .hwreg_addr(hwreg_addr), .hwreg_we(hwreg_we), .hwreg_din(hwreg_din), .hwreg_dout(hwreg_dout),
        .cpu_code_bank_q(), .cpu_data_bank_q(),
        .scrn_cpu_bank_q(), .scrn_antic_bank_q(), .scrn_cpu_bank_we(), .scrn_antic_bank_we(),
        .scrn_bank_wval(), .scrn_ready(1'b1), .scrn_cpu_addr(), .scrn_cpu_we(), .scrn_cpu_wdata(),
        .scrn_cpu_rdata(8'h00), .unlock_bank(1'b1), .portb(portb),
        .bus_mpd_n_in(1'b1), .bus_pbi_rdata(8'hFF), .bus_rd4_n_in(1'b1), .bus_rd5_n_in(1'b1),
        .m_axi_araddr(ax_araddr), .m_axi_arlen(ax_arlen), .m_axi_arsize(ax_arsize),
        .m_axi_arburst(ax_arburst), .m_axi_arvalid(ax_arvalid), .m_axi_arready(ax_arready),
        .m_axi_rdata(ax_rdata), .m_axi_rvalid(ax_rvalid), .m_axi_rlast(ax_rlast), .m_axi_rready(ax_rready),
        .m_axi_awaddr(ax_awaddr), .m_axi_awlen(ax_awlen), .m_axi_awsize(ax_awsize),
        .m_axi_awburst(ax_awburst), .m_axi_awvalid(ax_awvalid), .m_axi_awready(ax_awready),
        .m_axi_wdata(ax_wdata), .m_axi_wstrb(ax_wstrb), .m_axi_wlast(ax_wlast), .m_axi_wvalid(ax_wvalid),
        .m_axi_wready(ax_wready), .m_axi_bvalid(ax_bvalid), .m_axi_bready(ax_bready),
        .rom_addr(rom_addr), .rom_data(rom_data), .rom_we(rom_we),   // <== the wired link
        .stack_op(1'b0), .s_high(4'd0), .dma_clk(clk_sally), .dma_addr(16'd0), .dma_rdata()
    );
    axi_slave_mem u_axi (
        .clk(clk_sally), .rst(rst),
        .s_axi_awaddr(ax_awaddr), .s_axi_awlen(ax_awlen), .s_axi_awsize(ax_awsize),
        .s_axi_awburst(ax_awburst), .s_axi_awvalid(ax_awvalid), .s_axi_awready(ax_awready),
        .s_axi_wdata(ax_wdata), .s_axi_wstrb(ax_wstrb), .s_axi_wlast(ax_wlast), .s_axi_wvalid(ax_wvalid),
        .s_axi_wready(ax_wready), .s_axi_bvalid(ax_bvalid), .s_axi_bready(ax_bready),
        .s_axi_araddr(ax_araddr), .s_axi_arlen(ax_arlen), .s_axi_arsize(ax_arsize),
        .s_axi_arburst(ax_arburst), .s_axi_arvalid(ax_arvalid), .s_axi_arready(ax_arready),
        .s_axi_rdata(ax_rdata), .s_axi_rvalid(ax_rvalid), .s_axi_rlast(ax_rlast), .s_axi_rready(ax_rready)
    );

    int nfail = 0;

    // PS-ordering AXI write to the loader (AW, wait AWREADY, then W, held BREADY)
    task automatic axi_wr(input [15:0] a, input [7:0] d);
        int c; logic b;
        @(negedge clk_sys); awaddr = {16'h43C0, a}; awvalid = 1;
        c=0; while (!awready && c<300) begin @(posedge clk_sys); c++; end
        if (!awready) begin $display("FAIL: AWREADY hang @%04h", a); nfail++; disable axi_wr; end
        @(negedge clk_sys); awvalid = 0;
        wdata = {24'd0, d}; wstrb = 4'b0001; wvalid = 1; bready = 1; b = 0;
        c=0; while (c<300) begin @(posedge clk_sys); if (wready) wvalid = 0; if (bvalid) begin b=1; break; end c++; end
        @(negedge clk_sys); wvalid = 0; bready = 0;
        if (!b) begin $display("FAIL: no BVALID @%04h", a); nfail++; end
    endtask

    // CPU read via sally_mem (registered read one cycle later)
    task automatic cpu_rd(input [15:0] a, output [7:0] v);
        @(negedge clk_sally); addr = a; rw = 1;
        @(posedge clk_sally); @(negedge clk_sally); #1 v = data_out;
    endtask
    task automatic chk(input string s, input [7:0] got, input [7:0] want);
        if (got !== want) begin $display("FAIL %s: got=$%02h want=$%02h", s, got, want); nfail++; end
        else $display("  ok  %s = $%02h", s, got);
    endtask

    initial begin
        awvalid=0; wvalid=0; bready=0; wstrb=0;
        repeat (6) @(posedge clk_sys); rst = 0; repeat (4) @(posedge clk_sys);

        // T1: the real SIOV patch — write $E45A=$65, $E45B=$CB (SIOV -> $CB65)
        $display("[T1] upload SIOV vector patch via the loader, read on CPU port");
        axi_wr(16'hE45A, 8'h65);
        axi_wr(16'hE45B, 8'hCB);
        repeat (8) @(posedge clk_sally);
        begin logic [7:0] v;
            cpu_rd(16'hE45A, v); chk("E45A (SIOV target lo)", v, 8'h65);
            cpu_rd(16'hE45B, v); chk("E45B (SIOV target hi)", v, 8'hCB);
        end

        // T2: BURST — 512 back-to-back writes $D800.. ascending data (upload stress)
        $display("[T2] burst 512 writes $D800.. (sustained FIFO drain)");
        for (int i = 0; i < 512; i++) axi_wr(16'hD800 + i[15:0], 8'(i & 8'hFF));
        repeat (16) @(posedge clk_sally);
        begin logic [7:0] v; int bad = 0;
            for (int i = 0; i < 512; i++) begin
                cpu_rd(16'hD800 + i[15:0], v);
                if (v !== 8'(i & 8'hFF)) begin bad++; if (bad<=4) $display("  burst mismatch @%04h got $%02h want $%02h", 16'hD800+i, v, i&8'hFF); end
            end
            if (bad) begin $display("FAIL T2: %0d/512 burst bytes wrong", bad); nfail++; end
            else $display("  ok  T2: all 512 burst bytes read back correct");
        end

        if (nfail == 0) $display("*** ROM_INTEG OK ***");
        else            $display("*** ROM_INTEG FAIL *** %0d failure(s)", nfail);
        $finish;
    end
    initial begin #5000000; $display("*** ROM_INTEG TIMEOUT ***"); $finish; end
endmodule
`default_nettype wire
