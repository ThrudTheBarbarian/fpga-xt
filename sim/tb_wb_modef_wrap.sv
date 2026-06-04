// tb_wb_modef_wrap.sv — reproduce the GR.8 (mode F) right-edge horizontal-wrap
// ghost in the WRITEBACK path only.
//
// Models the antic_top render-tap stream into antic_writeback for a mode-F
// (320 px = 160 pair) line with a right-edge bar (columns 250..319 lit), then
// reads the DDR XL surface back and checks:
//   (a) row Y is correct (bar at the right edge)
//   (b) row Y+1 (the NEXT row, written by a SECOND flush of a blank line) has
//       NO pixels in its left columns 0..70.
//
// This isolates: does the writeback itself create the wrap (row Y's right edge
// landing in row Y+1's left), or is the writeback clean (=> the wrap is in the
// display path)?

`default_nettype none
`timescale 1ns / 1ps

module tb_wb_modef_wrap;

    // Real config: 320-wide RGBA8888, stride 1280.
    localparam [31:0] BASE0  = 32'h0000_1000;
    localparam [31:0] BASE1  = 32'h0000_2000;
    localparam [31:0] BASE2  = 32'h0000_3000;
    localparam [15:0] STRIDE = 16'd1280;
    localparam int    SRC_W  = 320;
    localparam int    NPAIR  = SRC_W/2;          // 160

    // Atari colour codes used by mode F in the compositor: set bit -> $04
    // (COLPF2 owner), clear -> $00 (COLBK).
    localparam [7:0]  CODE_LIT = 8'h04;
    localparam [7:0]  CODE_BG  = 8'h00;
    // RGBA we program for those two codes.
    localparam [23:0] RGB_LIT = 24'hC0_C0_C0;    // light grey
    localparam [23:0] RGB_BG  = 24'h00_00_00;    // black

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
        .stride_bytes (STRIDE), .src_w (12'(SRC_W)),
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

    task automatic pal_write(input [7:0] idx, input [23:0] v);
        @(negedge clk); pal_we = 1; pal_idx = idx; pal_rgb = v;
        @(negedge clk); pal_we = 0;
    endtask

    // Send one pair (index p) with the given two column colour codes.
    task automatic send_pair(input int p, input [7:0] clo, input [7:0] chi,
                             input int row);
        @(negedge clk);
        pix_valid = 1; pix_pair = p[7:0];
        color_lo = clo; color_hi = chi; atari_row = row[7:0];
        @(negedge clk); pix_valid = 0;
        // resolve FSM takes 4 cyc/pair; FIFO buffers but give it room to drain.
        repeat (7) @(posedge clk);
    endtask

    task automatic flush_row;
        @(negedge clk); row_flush = 1;
        @(negedge clk); row_flush = 0;
        while (!u_dut.lw_busy) @(posedge clk);
        while ( u_dut.lw_busy) @(posedge clk);
        repeat (4) @(posedge clk);
    endtask

    // Read RGBA at (base,row,col).
    function automatic [31:0] surf(input [31:0] base, input int row, input int col);
        surf = {u_mem.peek_byte(base + row*STRIDE + col*4 + 3),
                u_mem.peek_byte(base + row*STRIDE + col*4 + 2),
                u_mem.peek_byte(base + row*STRIDE + col*4 + 1),
                u_mem.peek_byte(base + row*STRIDE + col*4 + 0)};
    endfunction

    localparam [31:0] RGBA_LIT = {RGB_LIT, 8'hFF};
    localparam [31:0] RGBA_BG  = {RGB_BG,  8'hFF};

    int fail = 0;
    integer c;
    integer left_lit_row6;

    initial begin
        $display("=== MODE-F RIGHT-EDGE WRAP (writeback path) ===");
        repeat (4) @(posedge clk); rst = 1'b0; repeat (2) @(posedge clk);

        // Programme the two palette entries used.
        pal_write(CODE_LIT, RGB_LIT);
        pal_write(CODE_BG,  RGB_BG);

        // ---- ROW 5: mode-F line, bar lit at columns 250..319 ----
        // pair p covers columns 2p (lo) and 2p+1 (hi).  Lit when col >= 250.
        write_idx = 2'd0;
        for (int p = 0; p < NPAIR; p++) begin
            logic [7:0] clo, chi;
            clo = (2*p   >= 250) ? CODE_LIT : CODE_BG;
            chi = (2*p+1 >= 250) ? CODE_LIT : CODE_BG;
            send_pair(p, clo, chi, 5);
        end
        // antic_raster advances atari_row to 6 before row_flush (= next line_start).
        @(negedge clk); atari_row = 8'd6;
        flush_row;

        // ---- ROW 6: a fully BLANK mode-F line (all columns background) ----
        for (int p = 0; p < NPAIR; p++)
            send_pair(p, CODE_BG, CODE_BG, 6);
        @(negedge clk); atari_row = 8'd7;
        flush_row;

        // ---- CHECK row 5: lit at 250..319, bg below 250 ----
        for (c = 0; c < SRC_W; c++) begin
            logic [31:0] exp;
            exp = (c >= 250) ? RGBA_LIT : RGBA_BG;
            if (surf(BASE0, 5, c) !== exp) begin
                if (fail < 12)
                  $display("ROW5 col %0d: got=%08h exp=%08h", c, surf(BASE0,5,c), exp);
                fail++;
            end
        end

        // ---- CHECK row 6: must be ALL background.  Count any lit pixel in
        // the left region 0..70 (where the HW ghost appears). ----
        left_lit_row6 = 0;
        for (c = 0; c < SRC_W; c++) begin
            if (surf(BASE0, 6, c) === RGBA_LIT) begin
                if (c <= 70) left_lit_row6++;
                if (fail < 24)
                  $display("ROW6 col %0d UNEXPECTEDLY LIT: got=%08h", c, surf(BASE0,6,c));
                fail++;
            end
        end

        $display("---- summary ----");
        $display("row6 left-region(0..70) lit pixels = %0d", left_lit_row6);
        if (fail == 0)
            $display("WRITEBACK CLEAN: no wrap in writeback path (DDR surface correct)");
        else
            $display("WRITEBACK WRAP REPRODUCED: %0d anomalous pixels", fail);
        $display("*** WB_MODEF_WRAP DONE ***");
        $finish;
    end

    initial begin
        #20_000_000;
        $display("FAIL: watchdog"); $fatal(1);
    end

endmodule

`default_nettype wire
