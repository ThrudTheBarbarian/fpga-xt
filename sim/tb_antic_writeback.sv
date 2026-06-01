// tb_antic_writeback.sv — unit test for the ANTIC->DDR3 writeback orchestrator.
//
// Feeds a synthetic pixel-pair stream + palette, flushes a row, and peeks the
// DDR3 surface back. Then exercises the triple-buffer write target: changing
// write_idx (driven by xl_buffer_ctrl in the real design) lands the next row in
// a different buffer slot.

`default_nettype none
`timescale 1ns / 1ps

module tb_antic_writeback;

    localparam [31:0] BASE0  = 32'h0000_1000;
    localparam [31:0] BASE1  = 32'h0000_2000;
    localparam [31:0] BASE2  = 32'h0000_3000;
    localparam [15:0] STRIDE = 16'd64;
    localparam int    W      = 8;

    logic clk = 1'b0; always #3 clk = ~clk;
    logic rst = 1'b1;

    logic        pix_valid = 0;
    logic [7:0]  pix_pair = 0, color_lo = 0, color_hi = 0, atari_row = 0;
    logic        row_flush = 0;
    logic [1:0]  write_idx = 2'd0;
    logic        pal_we = 0;
    logic [7:0]  pal_idx = 0;
    logic [23:0] pal_rgb = 0;

    wire [31:0] awaddr; wire [7:0] awlen; wire [2:0] awsize; wire [1:0] awburst;
    wire        awvalid, awready, wvalid, wready, wlast, bvalid, bready;
    wire [63:0] wdata; wire [7:0] wstrb;

    antic_writeback u_dut (
        .clk_sys (clk), .rst_sys (rst),
        .pix_valid (pix_valid), .pix_pair (pix_pair),
        .color_lo (color_lo), .color_hi (color_hi), .atari_row (atari_row),
        .row_flush (row_flush),
        .pal_we (pal_we), .pal_idx (pal_idx), .pal_rgb (pal_rgb),
        .base0 (BASE0), .base1 (BASE1), .base2 (BASE2), .write_idx (write_idx),
        .stride_bytes (STRIDE), .src_w (W[11:0]),
        .m_axi_awaddr (awaddr), .m_axi_awlen (awlen), .m_axi_awsize (awsize),
        .m_axi_awburst (awburst), .m_axi_awvalid (awvalid), .m_axi_awready (awready),
        .m_axi_wdata (wdata), .m_axi_wstrb (wstrb), .m_axi_wlast (wlast),
        .m_axi_wvalid (wvalid), .m_axi_wready (wready),
        .m_axi_bvalid (bvalid), .m_axi_bready (bready)
    );

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
    // color code for column c, and the RGBA we expect after palette resolve.
    function automatic [7:0]  code(input int c);  code = 8'(c + 16);          endfunction
    function automatic [23:0] rgb (input int c);  rgb  = {8'(c+1), 8'(c+2), 8'(c+3)}; endfunction
    function automatic [31:0] rgba(input int c);  rgba = {rgb(c), 8'hFF};      endfunction

    task automatic pal_write(input [7:0] idx, input [23:0] v);
        @(negedge clk); pal_we = 1; pal_idx = idx; pal_rgb = v;
        @(negedge clk); pal_we = 0;
    endtask

    task automatic send_pair(input int p, input int row);
        @(negedge clk);
        pix_valid = 1; pix_pair = p[7:0];
        color_lo = code(2*p); color_hi = code(2*p+1); atari_row = row[7:0];
        @(negedge clk); pix_valid = 0;
        repeat (7) @(posedge clk);     // let the resolve FSM finish both pixels
    endtask

    task automatic flush_row;
        @(negedge clk); row_flush = 1;
        @(negedge clk); row_flush = 0;
        while (!u_dut.lw_busy) @(posedge clk);   // wait for the DMA to START
        while ( u_dut.lw_busy) @(posedge clk);   // ...then for it to finish
        repeat (4) @(posedge clk);
    endtask

    task automatic check_surface(input string label, input [31:0] base, input int row);
        logic [31:0] got;
        for (int c = 0; c < W; c++) begin
            got = {u_mem.peek_byte(base + row*STRIDE + c*4 + 3),
                   u_mem.peek_byte(base + row*STRIDE + c*4 + 2),
                   u_mem.peek_byte(base + row*STRIDE + c*4 + 1),
                   u_mem.peek_byte(base + row*STRIDE + c*4 + 0)};
            if (got !== rgba(c)) begin
                $display("FAIL %s col %0d: got=%08h expected=%08h", label, c, got, rgba(c));
                fail_count++;
            end
        end
    endtask

    initial begin
        $display("=== ANTIC_WRITEBACK TEST ===");
        repeat (4) @(posedge clk);
        rst = 1'b0;
        repeat (2) @(posedge clk);

        for (int c = 0; c < W; c++) pal_write(code(c), rgb(c));

        // write_idx=0 -> writeback targets BASE0. Render row 5.
        write_idx = 2'd0;
        for (int p = 0; p < W/2; p++) send_pair(p, 5);
        flush_row;
        check_surface("slot0", BASE0, 5);

        // xl_buffer_ctrl advances write_idx between frames; here drive it to slot 2
        // and confirm the next row lands in BASE2 (and slots are disjoint).
        @(negedge clk); write_idx = 2'd2;
        repeat (2) @(posedge clk);

        for (int p = 0; p < W/2; p++) send_pair(p, 6);
        flush_row;
        check_surface("slot2", BASE2, 6);

        if (fail_count == 0) begin
            $display("*** ANTIC_WRITEBACK OK *** palette resolve + row DMA + double-buffer");
            $finish;
        end else begin
            $display("*** ANTIC_WRITEBACK FAIL *** %0d failures", fail_count);
            $fatal(1);
        end
    end

    initial begin
        #3_000_000;
        $display("FAIL: tb_antic_writeback watchdog");
        $fatal(1);
    end

endmodule

`default_nettype wire
