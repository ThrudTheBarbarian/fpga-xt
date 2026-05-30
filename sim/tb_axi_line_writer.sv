// tb_axi_line_writer.sv — unit test for the ANTIC->DDR3 row writeback DMA.
//
// Fill the writer's row buffer with RGBA pixels, flush to a DDR3 byte address
// in axi_slave_mem, wait for busy to clear, then peek the bytes back.  Covers
// a single partial burst (8 px -> 4 beats) and a multi-burst (34 px -> 16+1).

`default_nettype none
`timescale 1ns / 1ps

module tb_axi_line_writer;

    logic clk = 1'b0; always #3 clk = ~clk;
    logic rst = 1'b1;

    logic        wr_en = 0;
    logic [11:0] wr_col = 0;
    logic [31:0] wr_pixel = 0;
    logic        flush = 0;
    logic [31:0] flush_base = 0;
    logic [11:0] flush_w = 0;
    wire         busy;

    wire [31:0] awaddr; wire [7:0] awlen; wire [2:0] awsize; wire [1:0] awburst;
    wire        awvalid, awready, wvalid, wready, wlast, bvalid, bready;
    wire [63:0] wdata; wire [7:0] wstrb;

    axi_line_writer u_dut (
        .clk_sys (clk), .rst_sys (rst),
        .wr_en (wr_en), .wr_col (wr_col), .wr_pixel (wr_pixel),
        .flush (flush), .flush_base (flush_base), .flush_w (flush_w), .busy (busy),
        .m_axi_awaddr (awaddr), .m_axi_awlen (awlen), .m_axi_awsize (awsize),
        .m_axi_awburst (awburst), .m_axi_awvalid (awvalid), .m_axi_awready (awready),
        .m_axi_wdata (wdata), .m_axi_wstrb (wstrb), .m_axi_wlast (wlast),
        .m_axi_wvalid (wvalid), .m_axi_wready (wready),
        .m_axi_bvalid (bvalid), .m_axi_bready (bready)
    );

    // AXI slave — read channel tied off (write-only test).
    axi_slave_mem u_mem (
        .clk (clk), .rst (rst),
        .s_axi_awaddr (awaddr), .s_axi_awlen (awlen), .s_axi_awsize (awsize),
        .s_axi_awburst (awburst), .s_axi_awvalid (awvalid), .s_axi_awready (awready),
        .s_axi_wdata (wdata), .s_axi_wstrb (wstrb), .s_axi_wlast (wlast),
        .s_axi_wvalid (wvalid), .s_axi_wready (wready),
        .s_axi_bvalid (bvalid), .s_axi_bready (bready),
        .s_axi_araddr (32'd0), .s_axi_arlen (8'd0), .s_axi_arsize (3'd0),
        .s_axi_arburst (2'd0), .s_axi_arvalid (1'b0), .s_axi_arready (),
        .s_axi_rdata (), .s_axi_rvalid (), .s_axi_rlast (), .s_axi_rready (1'b1)
    );

    int fail_count = 0;
    function automatic [31:0] pat(input int c);
        pat = {8'(c), 8'hA5, 8'h5A, 8'(c + 16)};   // distinct per column
    endfunction

    task automatic fill_row(input int n);
        for (int c = 0; c < n; c++) begin
            @(negedge clk);
            wr_en = 1; wr_col = c[11:0]; wr_pixel = pat(c);
        end
        @(negedge clk); wr_en = 0;
    endtask

    task automatic do_flush(input [31:0] base, input int n);
        @(negedge clk);
        flush = 1; flush_base = base; flush_w = n[11:0];
        @(negedge clk); flush = 0;
        @(posedge clk);
        while (busy) @(posedge clk);
        repeat (4) @(posedge clk);
    endtask

    task automatic check_row(input string label, input [31:0] base, input int n);
        logic [31:0] got;
        for (int c = 0; c < n; c++) begin
            got = {u_mem.peek_byte(base + c*4 + 3), u_mem.peek_byte(base + c*4 + 2),
                   u_mem.peek_byte(base + c*4 + 1), u_mem.peek_byte(base + c*4 + 0)};
            if (got !== pat(c)) begin
                $display("FAIL %s col %0d: got=%08h expected=%08h", label, c, got, pat(c));
                fail_count++;
            end
        end
    endtask

    initial begin
        $display("=== AXI_LINE_WRITER TEST ===");
        repeat (4) @(posedge clk);
        rst = 1'b0;
        repeat (2) @(posedge clk);

        // Single partial burst: 8 px -> 4 beats (awlen=3).
        fill_row(8);
        do_flush(32'h0000_2000, 8);
        check_row("8px", 32'h0000_2000, 8);

        // Multi-burst: 34 px -> 17 beats -> 16-beat burst + 1-beat burst.
        fill_row(34);
        do_flush(32'h0000_3000, 34);
        check_row("34px", 32'h0000_3000, 34);

        if (fail_count == 0) begin
            $display("*** AXI_LINE_WRITER OK *** row DMA + single/multi burst");
            $finish;
        end else begin
            $display("*** AXI_LINE_WRITER FAIL *** %0d failures", fail_count);
            $fatal(1);
        end
    end

    initial begin
        #2_000_000;
        $display("FAIL: tb_axi_line_writer watchdog");
        $fatal(1);
    end

endmodule

`default_nettype wire
