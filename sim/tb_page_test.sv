`timescale 1ns / 1ps
module tb_page_test;
    // Instantiate sally_mem with PAGE cache for testing
    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst = 1'b1;

    logic [15:0] addr = 16'h0000;
    logic [7:0]  data_in = 8'h00;
    logic        rw = 1'b1;
    wire  [7:0]  data_out;
    wire         busy;

    wire [15:0] hwreg_addr;
    wire        hwreg_we;
    wire [7:0]  hwreg_din;
    logic [7:0] hwreg_dout = 8'hFF;

    wire [31:0] axi_araddr, axi_awaddr;
    wire [7:0]  axi_arlen, axi_awlen;
    wire [2:0]  axi_arsize, axi_awsize;
    wire [1:0]  axi_arburst, axi_awburst;
    wire        axi_arvalid, axi_awvalid, axi_wvalid, axi_rready, axi_bready;
    wire        axi_arready, axi_awready, axi_wready, axi_rvalid, axi_rlast, axi_bvalid;
    wire [63:0] axi_rdata, axi_wdata;
    wire [7:0]  axi_wstrb;
    wire        axi_wlast;

    sally_mem #(
        .DDR3_BANKED_BASE (32'h0000_0000),
        .DDR3_DATA_BASE   (32'h0008_0000),
        .BANKED_CACHE     ("PAGE")
    ) u_mem (
        .clk        (clk),
        .rst        (rst),
        .addr       (addr),
        .data_in    (data_in),
        .rw         (rw),
        .data_out   (data_out),
        .rdy        (1'b1),
        .busy       (busy),
        .hwreg_addr (hwreg_addr),
        .hwreg_we   (hwreg_we),
        .hwreg_din  (hwreg_din),
        .hwreg_dout (hwreg_dout),
        .portb      (8'hFF),
        .bus_mpd_n_in      (1'b1),
        .bus_pbi_rdata     (8'hFF),
        .bus_rd4_n_in      (1'b1),
        .bus_rd5_n_in      (1'b1),
        .m_axi_araddr  (axi_araddr),
        .m_axi_arlen   (axi_arlen),
        .m_axi_arsize  (axi_arsize),
        .m_axi_arburst (axi_arburst),
        .m_axi_arvalid (axi_arvalid),
        .m_axi_arready (axi_arready),
        .m_axi_rdata   (axi_rdata),
        .m_axi_rvalid  (axi_rvalid),
        .m_axi_rlast   (axi_rlast),
        .m_axi_rready  (axi_rready),
        .m_axi_awaddr  (axi_awaddr),
        .m_axi_awlen   (axi_awlen),
        .m_axi_awsize  (axi_awsize),
        .m_axi_awburst (axi_awburst),
        .m_axi_awvalid (axi_awvalid),
        .m_axi_awready (axi_awready),
        .m_axi_wdata   (axi_wdata),
        .m_axi_wstrb   (axi_wstrb),
        .m_axi_wlast   (axi_wlast),
        .m_axi_wvalid  (axi_wvalid),
        .m_axi_wready  (axi_wready),
        .m_axi_bvalid  (axi_bvalid),
        .m_axi_bready  (axi_bready),
        .rom_addr    (16'h0000),
        .rom_data    (8'h00),
        .rom_we      (1'b0),
        .stack_op    (1'b0),
        .s_high      (4'd0),
        .dma_clk     (clk),
        .dma_addr    (16'd0),
        .dma_rdata   ()
    );

    axi_slave_mem u_axi_mem (
        .clk           (clk),
        .rst           (rst),
        .s_axi_awaddr  (axi_awaddr),
        .s_axi_awlen   (axi_awlen),
        .s_axi_awsize  (axi_awsize),
        .s_axi_awburst (axi_awburst),
        .s_axi_awvalid (axi_awvalid),
        .s_axi_awready (axi_awready),
        .s_axi_wdata   (axi_wdata),
        .s_axi_wstrb   (axi_wstrb),
        .s_axi_wlast   (axi_wlast),
        .s_axi_wvalid  (axi_wvalid),
        .s_axi_wready  (axi_wready),
        .s_axi_bvalid  (axi_bvalid),
        .s_axi_bready  (axi_bready),
        .s_axi_araddr  (axi_araddr),
        .s_axi_arlen   (axi_arlen),
        .s_axi_arsize  (axi_arsize),
        .s_axi_arburst (axi_arburst),
        .s_axi_arvalid (axi_arvalid),
        .s_axi_arready (axi_arready),
        .s_axi_rdata   (axi_rdata),
        .s_axi_rvalid  (axi_rvalid),
        .s_axi_rlast   (axi_rlast),
        .s_axi_rready  (axi_rready)
    );

    int fail_count = 0;

    task automatic expect_eq(string label, input [31:0] got, input [31:0] want);
        if (got !== want) begin
            $display("FAIL %s: got=$%0h expected=$%0h", label, got, want);
            fail_count++;
        end
    endtask

    task automatic do_write(input [15:0] a, input [7:0] v);
        while (busy) @(posedge clk);
        @(negedge clk);
        addr    = a;
        data_in = v;
        rw      = 1'b0;
        @(posedge clk);
        @(negedge clk);
        rw      = 1'b1;
        data_in = 8'h00;
        while (busy) @(posedge clk);
    endtask

    task automatic do_read(input [15:0] a, output [7:0] v);
        while (busy) @(posedge clk);
        @(negedge clk);
        addr = a;
        rw   = 1'b1;
        @(posedge clk);
        while (busy) @(posedge clk);
        @(negedge clk);
        v = data_out;
        $display("  do_read($%04h) → %02h", a, v);
    endtask

    // peek AXI slave contents for debugging
    task peek_axi(input [31:0] addr);
        $display("  peek_axi(%08h) = %02h %02h %02h %02h %02h %02h %02h %02h",
            addr,
            u_axi_mem.peek_byte(addr+0),
            u_axi_mem.peek_byte(addr+1),
            u_axi_mem.peek_byte(addr+2),
            u_axi_mem.peek_byte(addr+3),
            u_axi_mem.peek_byte(addr+4),
            u_axi_mem.peek_byte(addr+5),
            u_axi_mem.peek_byte(addr+6),
            u_axi_mem.peek_byte(addr+7));
    endtask

    initial begin
        $display("=== PAGE CACHE TEST ===");
        repeat (4) @(posedge clk);
        rst = 1'b0;
        @(posedge clk);

        // Bank 0 = BRAM now (gap-1, prompts/task-0001). This test
        // exercises the DDR3 page cache, so it runs on NON-ZERO banks:
        // code bank 1, data bank 1.
        do_write(16'h0082, 8'h01);   // $0082 code bank = 1
        do_write(16'h0083, 8'h01);   // $0083 data bank = 1

        // ---- Test 1: Data window write + read-back (write allocate) ----
        $display("[T1] data write allocate + read-back");
        begin
            logic [7:0] v;
            do_write(16'hA000, 8'h55);
            do_read (16'hA000, v);
            expect_eq("T1 data[$A000]", v, 8'h55);
        end

        // ---- Test 2: Read within same page — should be cache hit (no AXI) ----
        $display("[T2] read-back without AXI (cache hit)");
        begin
            logic [7:0] v;
            do_read(16'hA001, v);
            // $A001 was not written, should be 0 from the read-allocate fill
            expect_eq("T2 data[$A001]", v, 8'h00);
        end

        // ---- Test 3: Multiple writes within same page ----
        $display("[T3] multiple writes within same page");
        begin
            logic [7:0] v;
            do_write(16'hA010, 8'hAA);
            do_read (16'hA010, v);
            expect_eq("T3 data[$A010]", v, 8'hAA);
            do_write(16'hA0FF, 8'hBB);
            do_read (16'hA0FF, v);
            expect_eq("T3 data[$A0FF]", v, 8'hBB);
        end

        // ---- Test 4: Code window ----
        $display("[T4] code window read");
        begin
            logic [7:0] v;
            // Seed code page 1 via AXI directly (code bank 1, offset 0):
            //   axi = DDR3_BANKED_BASE + (1<<14) + 0 = 0x0000_4000.
            u_axi_mem.seed_byte(32'h0000_4000, 8'hC0);
            do_read(16'h6000, v);
            expect_eq("T4 code[$6000]", v, 8'hC0);
        end

        // ---- Test 5: Page swap (data), bank 1 <-> bank 2 ----
        // Bank 0 is BRAM, so the swap test uses two DDR3 pages (1 and 2)
        // to exercise dirty-line write-back + re-fill on swap-back.
        $display("[T5] data page swap (write-back + re-fill)");
        begin
            logic [7:0] v;
            // Currently on data page 1 (from T1/T3). Dirty it.
            do_write(16'hA000, 8'h11);
            do_write(16'hA001, 8'h22);
            // Switch to data page 2 ($0083=2) and write there.
            do_write(16'h0083, 8'h02);
            do_write(16'hA000, 8'h33);
            do_read (16'hA000, v);
            expect_eq("T5 page2[$A000]", v, 8'h33);
            // Switch back to page 1: the dirty bytes must have been
            // flushed to DDR3 and re-fill on swap-back.
            do_write(16'h0083, 8'h01);
            // Debug: page 1 base = DDR3_DATA_BASE + (1<<14) = 0x0008_4000.
            peek_axi(32'h0008_4000);
            do_read (16'hA000, v);
            expect_eq("T5 page1[$A000] after swap", v, 8'h11);
            do_read (16'hA001, v);
            expect_eq("T5 page1[$A001] after swap", v, 8'h22);
        end

        // ---- Final report ----------------------------------------------
        if (fail_count == 0) begin
            $display("*** PAGE CACHE OK *** all tests passed");
            $finish;
        end else begin
            $display("*** PAGE CACHE FAIL *** %0d failures", fail_count);
            $fatal(1);
        end
    end

    initial begin
        #2_000_000;
        $display("FAIL: tb_page_test watchdog");
        $fatal(1);
    end
endmodule
