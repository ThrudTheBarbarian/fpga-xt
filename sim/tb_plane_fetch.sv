// tb_plane_fetch.sv — unit test for the per-plane DDR3 line fetch unit.
//
// plane_fetch's AXI read master drives axi_slave_mem (seeded surface).  The
// raster side issues line_start + fetch_row; we verify the ping-pong line
// buffer then serves the correct source pixels at rd_col.
//
// Pipeline: the row latched at line N's line_start displays on line N+1, so
// after fetch_line(R_next) the front buffer holds the PREVIOUS fetch's row.

`default_nettype none
`timescale 1ns / 1ps

module tb_plane_fetch;

    localparam int    SRC_W  = 8;
    localparam [31:0] BASE   = 32'h0000_1000;
    localparam [15:0] STRIDE = 16'd64;        // bytes per source row

    logic clk_sys = 1'b0, clk_pix = 1'b0;
    always #3 clk_sys = ~clk_sys;
    always #5 clk_pix = ~clk_pix;
    logic rst_sys = 1'b1, rst_pix = 1'b1;

    // AXI wires (plane_fetch master -> axi_slave_mem slave)
    wire [31:0] araddr;  wire [7:0] arlen;  wire [2:0] arsize;  wire [1:0] arburst;
    wire        arvalid, arready, rvalid, rlast, rready;
    wire [63:0] rdata;

    logic [11:0] fetch_row = 12'd0, rd_col = 12'd0;
    logic        line_start = 1'b0;
    wire  [31:0] rd_pixel;

    plane_fetch u_dut (
        .clk_sys (clk_sys), .rst_sys (rst_sys), .enable (1'b1),
        .surface_base (BASE), .stride_bytes (STRIDE), .src_w (SRC_W[11:0]),
        .m_axi_araddr (araddr), .m_axi_arlen (arlen), .m_axi_arsize (arsize),
        .m_axi_arburst (arburst), .m_axi_arvalid (arvalid), .m_axi_arready (arready),
        .m_axi_rdata (rdata), .m_axi_rvalid (rvalid), .m_axi_rlast (rlast),
        .m_axi_rready (rready),
        .clk_pix (clk_pix), .rst_pix (rst_pix),
        .line_start (line_start), .fetch_row (fetch_row),
        .rd_col (rd_col), .rd_pixel (rd_pixel)
    );

    // AXI slave write channel — unused (we seed via seed_byte), tie off.
    axi_slave_mem u_mem (
        .clk (clk_sys), .rst (rst_sys),
        .s_axi_awaddr (32'd0), .s_axi_awlen (8'd0), .s_axi_awsize (3'd0),
        .s_axi_awburst (2'd0), .s_axi_awvalid (1'b0), .s_axi_awready (),
        .s_axi_wdata (64'd0), .s_axi_wstrb (8'd0), .s_axi_wlast (1'b0),
        .s_axi_wvalid (1'b0), .s_axi_wready (),
        .s_axi_bvalid (), .s_axi_bready (1'b1),
        .s_axi_araddr (araddr), .s_axi_arlen (arlen), .s_axi_arsize (arsize),
        .s_axi_arburst (arburst), .s_axi_arvalid (arvalid), .s_axi_arready (arready),
        .s_axi_rdata (rdata), .s_axi_rvalid (rvalid), .s_axi_rlast (rlast),
        .s_axi_rready (rready)
    );

    int fail_count = 0;
    function automatic [31:0] pat(input int row, input int col);
        pat = {8'(row), 8'(col), 8'hA5, 8'h00};   // [31:24]=row [23:16]=col
    endfunction

    // Seed one RGBA pixel (little-endian bytes) into the slave.
    task automatic seed_pixel(input int row, input int col);
        logic [31:0] a; logic [31:0] p;
        a = BASE + row*STRIDE + col*4;
        p = pat(row, col);
        u_mem.seed_byte(a + 0, p[7:0]);
        u_mem.seed_byte(a + 1, p[15:8]);
        u_mem.seed_byte(a + 2, p[23:16]);
        u_mem.seed_byte(a + 3, p[31:24]);
    endtask

    // Latch a row to fetch, pulse line_start, wait for the fetch to drain.
    task automatic fetch_line(input int row);
        @(negedge clk_pix);
        fetch_row  = row[11:0];
        line_start = 1'b1;
        @(negedge clk_pix);
        line_start = 1'b0;
        repeat (120) @(posedge clk_pix);   // ample for a 1-burst clk_sys fetch
    endtask

    // Read+check all SRC_W columns of the currently-front row.
    task automatic check_row(input string label, input int row);
        logic [31:0] got;
        for (int c = 0; c < SRC_W; c++) begin
            @(negedge clk_pix);
            rd_col = c[11:0];
            @(posedge clk_pix); @(posedge clk_pix); #1;
            got = rd_pixel;
            if (got !== pat(row, c)) begin
                $display("FAIL %s col %0d: got=%08h expected=%08h", label, c, got, pat(row,c));
                fail_count++;
            end
        end
    endtask

    initial begin
        $display("=== PLANE_FETCH TEST ===");
        // Seed rows 2, 3, 5 (cols 0..7).
        for (int c = 0; c < SRC_W; c++) begin
            seed_pixel(2, c); seed_pixel(3, c); seed_pixel(5, c);
        end

        repeat (4) @(posedge clk_pix);
        rst_sys = 1'b0; rst_pix = 1'b0;
        repeat (4) @(posedge clk_pix);

        fetch_line(2);                 // prime: row 2 -> write buffer
        fetch_line(3); check_row("row2", 2);   // front now = row 2
        fetch_line(5); check_row("row3", 3);
        fetch_line(0); check_row("row5", 5);

        if (fail_count == 0) begin
            $display("*** PLANE_FETCH OK *** DDR3 line fetch + ping-pong + col read");
            $finish;
        end else begin
            $display("*** PLANE_FETCH FAIL *** %0d failures", fail_count);
            $fatal(1);
        end
    end

    initial begin
        #2_000_000;
        $display("FAIL: tb_plane_fetch watchdog");
        $fatal(1);
    end

endmodule

`default_nettype wire
