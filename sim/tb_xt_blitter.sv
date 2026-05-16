// tb_xt_blitter.sv — Verilator/iverilog testbench for xt_blitter.
//
// Exercises:
//   1. Pattern fill (CMD=0x01) — solid 1×1 pattern, small rectangle
//   2. Pattern fill with zero-alpha — entire burst should be skipped
//   3. Line draw (CMD=0x02) — horizontal
//   4. Block blit (CMD=0x03) — straight copy + GEM raster ops
//
// A mock AXI slave accepts all transactions, logs them for verification,
// and provides a backing-store memory for reads.  The testbench compares
// logged AXI writes against expected address/data/strb patterns.

`default_nettype none
`timescale 1ns / 1ps

module tb_xt_blitter;

    // ====================================================================
    // Parameters
    // ====================================================================
    parameter logic [31:0] FB_BASE     = 32'h3000_0000;
    parameter int          FB_STRIDE_B = 8192;

    // ====================================================================
    // Clock — 150 MHz matching clk_sys (6.667 ns period)
    // ====================================================================
    logic clk = 1'b0;
    always #3.333 clk = ~clk;

    // ====================================================================
    // Reset
    // ====================================================================
    logic rst = 1'b1;
    int rst_cycles = 0;
    always_ff @(posedge clk) begin
        if (rst_cycles < 5) rst_cycles <= rst_cycles + 1;
        else                rst <= 1'b0;
    end

    // ====================================================================
    // DUT signal declarations
    // ====================================================================
    logic [15:0] bus_addr;
    logic [7:0]  bus_data;
    logic        bus_we;
    wire         busy;

    // AXI4 write master
    wire [31:0] m_axi_awaddr;
    wire [7:0]  m_axi_awlen;
    wire [2:0]  m_axi_awsize;
    wire [1:0]  m_axi_awburst;
    wire        m_axi_awvalid;
    logic       m_axi_awready;
    wire [63:0] m_axi_wdata;
    wire [7:0]  m_axi_wstrb;
    wire        m_axi_wlast;
    wire        m_axi_wvalid;
    logic       m_axi_wready;
    logic       m_axi_bvalid;
    wire        m_axi_bready;

    // AXI4 read master
    wire [31:0] m_axi_araddr;
    wire [7:0]  m_axi_arlen;
    wire [2:0]  m_axi_arsize;
    wire [1:0]  m_axi_arburst;
    wire        m_axi_arvalid;
    logic       m_axi_arready;
    logic [63:0] m_axi_rdata;
    logic        m_axi_rvalid;
    logic        m_axi_rlast;
    wire         m_axi_rready;

    // ====================================================================
    // DUT instance
    // ====================================================================
    xt_blitter #(
        .FB_BASE    (FB_BASE),
        .FB_STRIDE_B(FB_STRIDE_B)
    ) u_dut (
        .clk           (clk),
        .rst           (rst),
        .bus_addr      (bus_addr),
        .bus_data      (bus_data),
        .bus_we        (bus_we),
        .busy          (busy),
        .m_axi_awaddr  (m_axi_awaddr),
        .m_axi_awlen   (m_axi_awlen),
        .m_axi_awsize  (m_axi_awsize),
        .m_axi_awburst (m_axi_awburst),
        .m_axi_awvalid (m_axi_awvalid),
        .m_axi_awready (m_axi_awready),
        .m_axi_wdata   (m_axi_wdata),
        .m_axi_wstrb   (m_axi_wstrb),
        .m_axi_wlast   (m_axi_wlast),
        .m_axi_wvalid  (m_axi_wvalid),
        .m_axi_wready  (m_axi_wready),
        .m_axi_bvalid  (m_axi_bvalid),
        .m_axi_bready  (m_axi_bready),
        .m_axi_araddr  (m_axi_araddr),
        .m_axi_arlen   (m_axi_arlen),
        .m_axi_arsize  (m_axi_arsize),
        .m_axi_arburst (m_axi_arburst),
        .m_axi_arvalid (m_axi_arvalid),
        .m_axi_arready (m_axi_arready),
        .m_axi_rdata   (m_axi_rdata),
        .m_axi_rvalid  (m_axi_rvalid),
        .m_axi_rlast   (m_axi_rlast),
        .m_axi_rready  (m_axi_rready)
    );

    // ====================================================================
    // Mock AXI slave
    // ====================================================================

    // ---- Backing store (64-bit words, relative to FB_BASE)
    localparam int MEM_WORDS = 2 * 1024 * 1024;  // 16 MB / 8 bytes
    logic [63:0] mem [0:MEM_WORDS-1];

    // Helper to convert absolute byte address to word index.
    function automatic int mem_idx(input [31:0] addr);
        return (addr - FB_BASE) >> 3;
    endfunction

    // Initialise backing store with deterministic pattern.
    initial begin
        for (int i = 0; i < MEM_WORDS; i++)
            mem[i] = 64'hDEAD_BEEF_CAFE_BABE;
    end

    // ---- Transaction log (parallel queues; iverilog does not support
    //      queues of struct types) -------------------------------------------
    logic [31:0] w_addr_q [$];
    logic [63:0] w_data_q [$];
    logic [7:0]  w_strb_q [$];
    logic        w_last_q [$];
    longint      w_cycle_q [$];

    logic [31:0] r_addr_q [$];
    logic [7:0]  r_len_q [$];
    longint      r_cycle_q [$];

    // ---- Write state ------------------------------------------------------
    logic        aw_pending;
    logic [31:0] aw_addr_q;
    logic [7:0]  aw_len_q;
    logic [7:0]  w_beat_count;
    logic        w_need_bvalid;

    // ---- Read state -------------------------------------------------------
    logic        ar_pending;
    logic [31:0] ar_addr_q;
    logic [7:0]  ar_len_q;
    logic [7:0]  r_beat_count;
    logic        r_active;
    logic [63:0] r_data_q;

    // ====================================================================
    // AXI mock behaviour — clocked on posedge
    // ====================================================================
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            m_axi_awready  <= 1'b0;
            m_axi_wready   <= 1'b0;
            m_axi_bvalid   <= 1'b0;
            m_axi_arready  <= 1'b0;
            m_axi_rvalid   <= 1'b0;
            m_axi_rlast    <= 1'b0;
            m_axi_rdata    <= 64'd0;
            aw_pending     <= 1'b0;
            aw_addr_q      <= 32'd0;
            aw_len_q       <= 8'd0;
            w_beat_count   <= 8'd0;
            w_need_bvalid  <= 1'b0;
            ar_pending     <= 1'b0;
            ar_addr_q      <= 32'd0;
            ar_len_q       <= 8'd0;
            r_beat_count   <= 8'd0;
            r_active       <= 1'b0;
            r_data_q       <= 64'd0;
            w_addr_q.delete();
            w_data_q.delete();
            w_strb_q.delete();
            w_last_q.delete();
            w_cycle_q.delete();
            r_addr_q.delete();
            r_len_q.delete();
            r_cycle_q.delete();
        end else begin
            // Default: de-assert one-shot strobes
            m_axi_awready  <= 1'b0;
            m_axi_wready   <= 1'b0;
            m_axi_arready  <= 1'b0;

            // ---- Write address (AW) ready -- always accept --------------
            m_axi_awready <= 1'b1;
            if (m_axi_awvalid && m_axi_awready) begin
                aw_pending   <= 1'b1;
                aw_addr_q    <= m_axi_awaddr;
                aw_len_q     <= m_axi_awlen;
                w_beat_count <= 8'd0;
            end

            // ---- Write data (W) ready -- always accept -----------------
            m_axi_wready <= 1'b1;
            if (aw_pending && m_axi_wvalid && m_axi_wready) begin
                // Apply strobed bytes to backing store
                for (int b = 0; b < 8; b++) begin
                    if (m_axi_wstrb[b]) begin
                        int word_idx = mem_idx(aw_addr_q + w_beat_count * 8);
                        mem[word_idx][b*8 +: 8] <= m_axi_wdata[b*8 +: 8];
                    end
                end

                // Log the write beat
                w_addr_q.push_back(aw_addr_q + w_beat_count * 8);
                w_data_q.push_back(m_axi_wdata);
                w_strb_q.push_back(m_axi_wstrb);
                w_last_q.push_back(m_axi_wlast);
                w_cycle_q.push_back($time);

                if (m_axi_wlast) begin
                    aw_pending   <= 1'b0;
                    w_need_bvalid <= 1'b1;
                end else begin
                    w_beat_count <= w_beat_count + 8'd1;
                end
            end

            // ---- Write response (B) ------------------------------------
            if (w_need_bvalid) begin
                m_axi_bvalid <= 1'b1;
                w_need_bvalid <= 1'b0;
            end else if (m_axi_bvalid && m_axi_bready) begin
                m_axi_bvalid <= 1'b0;
            end

            // ---- Read address (AR) ready -- always accept ---------------
            m_axi_arready <= 1'b1;
            if (m_axi_arvalid && m_axi_arready) begin
                ar_pending <= 1'b1;
                ar_addr_q  <= m_axi_araddr;
                ar_len_q   <= m_axi_arlen;
                r_beat_count <= 8'd0;

                r_addr_q.push_back(m_axi_araddr);
                r_len_q.push_back(m_axi_arlen);
                r_cycle_q.push_back($time);
            end

            // ---- Read data (R) ------------------------------------------
            if (ar_pending && !r_active) begin
                // Start read burst on the cycle after AR accepted
                r_active    <= 1'b1;
                r_beat_count <= 8'd0;
                r_data_q    <= mem[mem_idx(ar_addr_q)];
                m_axi_rvalid <= 1'b1;
                m_axi_rlast  <= (ar_len_q == 8'd0);
                m_axi_rdata  <= mem[mem_idx(ar_addr_q)];
            end else if (r_active && m_axi_rvalid && m_axi_rready) begin
                if (m_axi_rlast) begin
                    // Last beat of read burst
                    r_active    <= 1'b0;
                    ar_pending  <= 1'b0;
                    m_axi_rvalid <= 1'b0;
                    m_axi_rlast  <= 1'b0;
                end else begin
                    // Advance to next beat
                    r_beat_count <= r_beat_count + 8'd1;
                    r_data_q     <= mem[mem_idx(ar_addr_q) + r_beat_count + 8'd1];
                    m_axi_rdata  <= mem[mem_idx(ar_addr_q) + r_beat_count + 8'd1];
                    m_axi_rlast  <= (r_beat_count + 8'd1 == ar_len_q);
                end
            end
        end
    end

    // ====================================================================
    // Helper tasks
    // ====================================================================

    // Write one byte to a blitter register.
    task write_reg(input [15:0] addr, input [7:0] data);
        @(posedge clk);
        bus_addr <= addr;
        bus_data <= data;
        bus_we   <= 1'b1;
        @(posedge clk);
        bus_we   <= 1'b0;
        bus_addr <= 16'h0000;
        bus_data <= 8'h00;
    endtask

    // Load a 1x1 pattern entry (4 bytes: R, G, B, A).
    // Assumes PAT_LOG_W was already written (resets load pointer).
    task load_1x1_pattern(input [7:0] r, g, b, a);
        write_reg(16'hD4BB, r);
        write_reg(16'hD4BB, g);
        write_reg(16'hD4BB, b);
        write_reg(16'hD4BB, a);
    endtask

    // Wait until the blitter is idle (busy == 0) or timeout.
    // First waits for busy to go high (start of operation), then for it to go low.
    task wait_idle();
        int timeout = 10000;
        // Wait for busy to assert (operation starts 1 cycle after CMD write)
        while (!busy) begin
            @(posedge clk);
            timeout = timeout - 1;
            if (timeout == 0) begin
                $display("FATAL: timeout waiting for blitter to start");
                $fatal(1);
            end
        end
        // Now wait for busy to deassert (operation complete)
        timeout = 100000;
        while (busy) begin
            @(posedge clk);
            timeout = timeout - 1;
            if (timeout == 0) begin
                $display("FATAL: timeout waiting for blitter idle");
                $fatal(1);
            end
        end
    endtask

    // Clear the AXI transaction logs.
    task clear_logs();
        w_addr_q.delete();
        w_data_q.delete();
        w_strb_q.delete();
        w_last_q.delete();
        w_cycle_q.delete();
        r_addr_q.delete();
        r_len_q.delete();
        r_cycle_q.delete();
    endtask

    // ====================================================================
    // Test verification helpers
    // ====================================================================

    // Verify a write beat against expected values.
    task expect_write(input int idx,
                      input [31:0] exp_addr,
                      input [63:0] exp_data,
                      input [7:0] exp_strb);
        if (idx >= w_addr_q.size()) begin
            $display("FAIL: expected write beat %0d but only %0d logged",
                     idx, w_addr_q.size());
            $fatal(1);
        end
        if (w_addr_q[idx] !== exp_addr) begin
            $display("FAIL: write[%0d] addr mismatch: got %08h, expected %08h",
                     idx, w_addr_q[idx], exp_addr);
            $fatal(1);
        end
        if (w_data_q[idx] !== exp_data) begin
            $display("FAIL: write[%0d] data mismatch: got %016h, expected %016h",
                     idx, w_data_q[idx], exp_data);
            $fatal(1);
        end
        if (w_strb_q[idx] !== exp_strb) begin
            $display("FAIL: write[%0d] strb mismatch: got %02h, expected %02h",
                     idx, w_strb_q[idx], exp_strb);
            $fatal(1);
        end
    endtask

    // Verify total write count.
    task expect_write_count(input int exp_count);
        if (w_addr_q.size() != exp_count) begin
            $display("FAIL: expected %0d write beats, got %0d",
                     exp_count, w_addr_q.size());
            $fatal(1);
        end
    endtask

    // Verify total read count.
    task expect_read_count(input int exp_count);
        if (r_addr_q.size() != exp_count) begin
            $display("FAIL: expected %0d read bursts, got %0d",
                     exp_count, r_addr_q.size());
            $fatal(1);
        end
    endtask

    // ====================================================================
    // Test cases
    // ====================================================================

    // ----------------------------------------------------------------
    // Test 1: Pattern fill -- 1x1 solid red, 4x1 rectangle at (0,0)
    //
    // Should generate 2 write beats (4 pixels, 2 per beat) with
    // full byte strobes and pattern value 0xFF0000FF per pixel.
    // No AXI reads.
    // ----------------------------------------------------------------
    task test_pattern_fill();
        $display("=== Test 1: Pattern fill, 1x1 solid red, 4x1 rect ===");

        clear_logs();

        // Load 1x1 red pattern
        write_reg(16'hD4BA, 8'h00);    // PAT_LOG_W = 0 (1 wide, resets ptr)
        load_1x1_pattern(8'hFF, 8'h00, 8'h00, 8'hFF);
        write_reg(16'hD4BE, 8'h00);    // PAT_LOG_H = 0 (1 tall)

        // Set destination: 4x1 at (0,0)
        write_reg(16'hD4B0, 8'h00);    // DST_X_LO
        write_reg(16'hD4B1, 8'h00);    // DST_X_HI
        write_reg(16'hD4B2, 8'h00);    // DST_Y_LO
        write_reg(16'hD4B3, 8'h00);    // DST_Y_HI
        write_reg(16'hD4B4, 8'h04);    // DST_W_LO
        write_reg(16'hD4B5, 8'h00);    // DST_W_HI
        write_reg(16'hD4B6, 8'h01);    // DST_H_LO
        write_reg(16'hD4B7, 8'h00);    // DST_H_HI

        // Start rect fill
        write_reg(16'hD4BC, 8'h01);    // CMD = 0x01
        wait_idle();

        // Verify: 2 write beats at 8-byte-aligned address 0x30000000
        // Pixel layout: beat[0] = {pixel1(odd), pixel0(even)}
        //               beat[1] = {pixel3(odd), pixel2(even)}
        // Each pixel: 0xFF0000FF = R=255 G=0 B=0 A=255
        expect_write_count(2);
        expect_write(0, 32'h3000_0000, 64'hFF0000FF_FF0000FF, 8'hFF);
        expect_write(1, 32'h3000_0008, 64'hFF0000FF_FF0000FF, 8'hFF);

        // Verify no reads happened
        expect_read_count(0);

        $display("PASS: test_pattern_fill");
    endtask

    // ----------------------------------------------------------------
    // Test 2: Pattern fill with zero alpha -- should skip all writes
    //
    // 1x1 transparent pattern (A=0), 4x1 rectangle.  The burst buffer
    // should remain empty and no AXI transactions should be issued.
    // ----------------------------------------------------------------
    task test_pattern_fill_transparent();
        $display("=== Test 2: Pattern fill, transparent alpha, skip ===");

        clear_logs();

        // Load 1x1 transparent pattern
        write_reg(16'hD4BA, 8'h00);    // PAT_LOG_W = 0
        load_1x1_pattern(8'hFF, 8'h00, 8'h00, 8'h00);  // A=0
        write_reg(16'hD4BE, 8'h00);    // PAT_LOG_H = 0

        write_reg(16'hD4B0, 8'h00);    // DST_X_LO
        write_reg(16'hD4B1, 8'h00);    // DST_X_HI
        write_reg(16'hD4B2, 8'h00);    // DST_Y_LO
        write_reg(16'hD4B3, 8'h00);    // DST_Y_HI
        write_reg(16'hD4B4, 8'h04);    // DST_W_LO
        write_reg(16'hD4B5, 8'h00);    // DST_W_HI
        write_reg(16'hD4B6, 8'h01);    // DST_H_LO
        write_reg(16'hD4B7, 8'h00);    // DST_H_HI

        write_reg(16'hD4BC, 8'h01);    // CMD = 0x01
        wait_idle();

        // Verify: no AXI writes (burst skipped -- all pixels transparent)
        expect_write_count(0);
        expect_read_count(0);

        $display("PASS: test_pattern_fill_transparent");
    endtask

    // ----------------------------------------------------------------
    // Test 3: Line draw -- horizontal, 4 pixels at y=0
    //
    // DST_X=0, DST_Y=0, DST_W=+4 (DX=4), DST_H=0 (DY=0).
    // Pattern: 1x1 solid green.
    // Should generate 5 single-beat AXI writes (Bresenham draws
    // DX+1 pixels includes both endpoints).
    // ----------------------------------------------------------------
    task test_line_draw_horizontal();
        $display("=== Test 3: Line draw, horizontal, DX=4 -> 5 pixels ===");

        clear_logs();

        // Load 1x1 green pattern
        write_reg(16'hD4BA, 8'h00);
        load_1x1_pattern(8'h00, 8'hFF, 8'h00, 8'hFF);
        write_reg(16'hD4BE, 8'h00);

        // Line: start (0,0), DX=+4, DY=0
        write_reg(16'hD4B0, 8'h00);    // DST_X_LO
        write_reg(16'hD4B1, 8'h00);    // DST_X_HI
        write_reg(16'hD4B2, 8'h00);    // DST_Y_LO
        write_reg(16'hD4B3, 8'h00);    // DST_Y_HI
        write_reg(16'hD4B4, 8'h04);    // DST_W_LO = DX = 4
        write_reg(16'hD4B5, 8'h00);    // DST_W_HI
        write_reg(16'hD4B6, 8'h00);    // DST_H_LO = DY = 0
        write_reg(16'hD4B7, 8'h00);    // DST_H_HI

        write_reg(16'hD4BC, 8'h02);    // CMD = 0x02 (line draw)
        wait_idle();

        // Verify: 5 single-beat writes (DX=4 → 5 pixels inclusive).
        // Each write is 8-byte aligned. Adjacent even/odd pixels share
        // the same aligned address, distinguished by wstrb.
        //   x=0 (even, beat0 low):  addr 0x3000_0000, strb=0x0F
        //   x=1 (odd,  beat0 high): addr 0x3000_0000, strb=0xF0
        //   x=2 (even, beat1 low):  addr 0x3000_0008, strb=0x0F
        //   x=3 (odd,  beat1 high): addr 0x3000_0008, strb=0xF0
        //   x=4 (even, beat2 low):  addr 0x3000_0010, strb=0x0F
        // Green pixel = {R=0, G=255, B=0, A=255} = 32'h00FF00FF
        expect_write_count(5);
        expect_write(0, 32'h3000_0000, {32'h0, 32'h00FF00FF}, 8'h0F);  // x=0
        expect_write(1, 32'h3000_0000, {32'h00FF00FF, 32'h0}, 8'hF0);  // x=1
        expect_write(2, 32'h3000_0008, {32'h0, 32'h00FF00FF}, 8'h0F);  // x=2
        expect_write(3, 32'h3000_0008, {32'h00FF00FF, 32'h0}, 8'hF0);  // x=3
        expect_write(4, 32'h3000_0010, {32'h0, 32'h00FF00FF}, 8'h0F);  // x=4

        expect_read_count(0);

        $display("PASS: test_line_draw_horizontal");
    endtask

    // ----------------------------------------------------------------
    // Test 4: Block blit -- straight copy (RASTER_OP=3)
    //
    // Copies 4x1 pixels from (16,16) to (0,0).  Source data
    // pre-loaded into the backing memory.
    // ----------------------------------------------------------------
    task test_block_blit_copy();
        $display("=== Test 4: Block blit, straight copy, 4x1 ===");

        clear_logs();

        // Pre-fill source region at (16,16) with known data
        // Pixel (16+0, 16) -> FB_BASE + (16 << 13) + (16 << 2)
        //                    = 0x3000_0000 + 0x20000 + 0x40
        // Beat 0 at aligned address 0x3002_0040:
        //   {pixel17, pixel16} = {0x112233FF, 0xAABBCC00}
        // Beat 1 at 0x3002_0048:
        //   {pixel19, pixel18} = {0x778899FF, 0x445566FF}
        mem[mem_idx(32'h3002_0040)] = {32'h11_22_33_FF, 32'hAA_BB_CC_00};
        mem[mem_idx(32'h3002_0048)] = {32'h77_88_99_FF, 32'h44_55_66_FF};

        // Source at (16,16)
        write_reg(16'hD4C0, 8'd16);    // SRC_X_LO
        write_reg(16'hD4C1, 8'd0);     // SRC_X_HI
        write_reg(16'hD4C2, 8'd16);    // SRC_Y_LO
        write_reg(16'hD4C3, 8'd0);     // SRC_Y_HI

        // Destination at (0,0), 4x1
        write_reg(16'hD4B0, 8'd0);     // DST_X_LO
        write_reg(16'hD4B1, 8'd0);     // DST_X_HI
        write_reg(16'hD4B2, 8'd0);     // DST_Y_LO
        write_reg(16'hD4B3, 8'd0);     // DST_Y_HI
        write_reg(16'hD4B4, 8'd4);     // DST_W_LO = 4
        write_reg(16'hD4B5, 8'd0);     // DST_W_HI
        write_reg(16'hD4B6, 8'd1);     // DST_H_LO = 1
        write_reg(16'hD4B7, 8'd0);     // DST_H_HI

        // RASTER_OP = 3 (SRC copy, default)
        write_reg(16'hD4BF, 8'd3);

        write_reg(16'hD4BC, 8'h03);    // CMD = 0x03 (block blit)
        wait_idle();

        // Verify: 1 read burst + 2 write beats
        expect_read_count(1);
        expect_write_count(2);

        expect_write(0, 32'h3000_0000, {32'h11_22_33_FF, 32'hAA_BB_CC_00}, 8'hFF);
        expect_write(1, 32'h3000_0008, {32'h77_88_99_FF, 32'h44_55_66_FF}, 8'hFF);

        $display("PASS: test_block_blit_copy");
    endtask

    // ----------------------------------------------------------------
    // Test 5: Block blit with RASTER_OP=6 (SRC ^ DST)
    //
    // Verifies the byte-wise XOR combine with destination read.
    // ----------------------------------------------------------------
    task test_block_blit_xor();
        $display("=== Test 5: Block blit, RASTER_OP=6 (SRC^DST), 4x1 ===");

        clear_logs();

        // Pre-fill source at (16,16)
        mem[mem_idx(32'h3002_0040)] = {32'h11_22_33_FF, 32'hAA_BB_CC_00};
        mem[mem_idx(32'h3002_0048)] = {32'h77_88_99_FF, 32'h44_55_66_FF};

        // Pre-fill destination at (0,0) with all-ones per pixel
        mem[mem_idx(32'h3000_0000)] = {32'hFFFF_FFFF, 32'hFFFF_FFFF};
        mem[mem_idx(32'h3000_0008)] = {32'hFFFF_FFFF, 32'hFFFF_FFFF};

        // Source at (16,16)
        write_reg(16'hD4C0, 8'd16);
        write_reg(16'hD4C1, 8'd0);
        write_reg(16'hD4C2, 8'd16);
        write_reg(16'hD4C3, 8'd0);

        // Destination at (0,0), 4x1
        write_reg(16'hD4B0, 8'd0);
        write_reg(16'hD4B1, 8'd0);
        write_reg(16'hD4B2, 8'd0);
        write_reg(16'hD4B3, 8'd0);
        write_reg(16'hD4B4, 8'd4);
        write_reg(16'hD4B5, 8'd0);
        write_reg(16'hD4B6, 8'd1);
        write_reg(16'hD4B7, 8'd0);

        // RASTER_OP = 6 (SRC ^ DST)
        write_reg(16'hD4BF, 8'd6);

        write_reg(16'hD4BC, 8'h03);
        wait_idle();

        // Verify: 2 read bursts (source + dest) + 2 write beats
        expect_read_count(2);
        expect_write_count(2);

        // Source: {11_22_33_FF, AA_BB_CC_00}  Dest: {FF_FF_FF_FF, FF_FF_FF_FF}
        // XOR:    {EE_DD_CC_00, 55_44_33_FF}
        expect_write(0, 32'h3000_0000, {32'hEE_DD_CC_00, 32'h55_44_33_FF}, 8'hFF);
        expect_write(1, 32'h3000_0008, {32'h88_77_66_00, 32'hBB_AA_99_00}, 8'hFF);

        $display("PASS: test_block_blit_xor");
    endtask

    // ----------------------------------------------------------------
    // Test 6: Block blit with RASTER_OP=12 (~SRC)
    //
    // Source-only transform: invert all bytes.  No dest read needed.
    // ----------------------------------------------------------------
    task test_block_blit_notsrc();
        $display("=== Test 6: Block blit, RASTER_OP=12 (~SRC), 4x1 ===");

        clear_logs();

        // Pre-fill source at (16,16)
        mem[mem_idx(32'h3002_0040)] = {32'h11_22_33_FF, 32'hAA_BB_CC_00};
        mem[mem_idx(32'h3002_0048)] = {32'h77_88_99_FF, 32'h44_55_66_FF};

        // Source at (16,16)
        write_reg(16'hD4C0, 8'd16);
        write_reg(16'hD4C1, 8'd0);
        write_reg(16'hD4C2, 8'd16);
        write_reg(16'hD4C3, 8'd0);

        // Destination at (0,0), 4x1
        write_reg(16'hD4B0, 8'd0);
        write_reg(16'hD4B1, 8'd0);
        write_reg(16'hD4B2, 8'd0);
        write_reg(16'hD4B3, 8'd0);
        write_reg(16'hD4B4, 8'd4);
        write_reg(16'hD4B5, 8'd0);
        write_reg(16'hD4B6, 8'd1);
        write_reg(16'hD4B7, 8'd0);

        // RASTER_OP = 12 (~SRC)
        write_reg(16'hD4BF, 8'd12);

        write_reg(16'hD4BC, 8'h03);
        wait_idle();

        // Verify: 1 read burst (source only) + 2 write beats
        expect_read_count(1);
        expect_write_count(2);

        // Source inverted: {~11_22_33_FF, ~AA_BB_CC_00} = {EE_DD_CC_00, 55_44_33_FF}
        expect_write(0, 32'h3000_0000, {32'hEE_DD_CC_00, 32'h55_44_33_FF}, 8'hFF);
        expect_write(1, 32'h3000_0008, {32'h88_77_66_00, 32'hBB_AA_99_00}, 8'hFF);

        $display("PASS: test_block_blit_notsrc");
    endtask

    // ----------------------------------------------------------------
    // Test 7: Line draw + FLAGS.BLEND -- horizontal blended line
    //
    // 5-pixel horizontal line (DX=+4, DY=0) at (0,0).
    // Pattern pixel: R=255 G=0 B=0 A=128 (half-alpha red).
    // Destination pre-seeded with grey: R=64 G=64 B=64 A=255.
    // FLAGS.BLEND=1 should cause each pixel to read dest, blend, write.
    //
    // Expected blend (per channel):
    //   out = (src*sa + dst*inv_a + 128) >> 8
    //   sa=128, inv_a=127
    //   R = (255*128 + 64*127 + 128) >> 8 = 40896 >> 8 = 159 (0x9F)
    //   G = (  0*128 + 64*127 + 128) >> 8 =  8256 >> 8 =  32 (0x20)
    //   B = (  0*128 + 64*127 + 128) >> 8 =                  32 (0x20)
    //   A = 128 (source alpha preserved)
    //   Result pixel = 0x9F_20_20_80
    //
    // Expects 5 AXI reads + 5 AXI writes (one each per pixel).
    // ----------------------------------------------------------------
    task test_line_draw_blend();
        $display("=== Test 7: Line draw + FLAGS.BLEND, DX=4 -> 5 blended pixels ===");

        clear_logs();

        // Pre-seed destination: 3 beats covering x=0..4 at y=0.
        // Both halves of each beat hold the grey dest, so the read works
        // regardless of which half the blitter extracts.
        mem[mem_idx(32'h3000_0000)] = {32'h40_40_40_FF, 32'h40_40_40_FF};
        mem[mem_idx(32'h3000_0008)] = {32'h40_40_40_FF, 32'h40_40_40_FF};
        mem[mem_idx(32'h3000_0010)] = {32'h40_40_40_FF, 32'h40_40_40_FF};

        // Pattern: 1x1 half-alpha red
        write_reg(16'hD4BA, 8'h00);
        load_1x1_pattern(8'hFF, 8'h00, 8'h00, 8'h80);
        write_reg(16'hD4BE, 8'h00);

        // Line: (0,0) → DX=+4, DY=0
        write_reg(16'hD4B0, 8'h00);
        write_reg(16'hD4B1, 8'h00);
        write_reg(16'hD4B2, 8'h00);
        write_reg(16'hD4B3, 8'h00);
        write_reg(16'hD4B4, 8'h04);
        write_reg(16'hD4B5, 8'h00);
        write_reg(16'hD4B6, 8'h00);
        write_reg(16'hD4B7, 8'h00);

        // FLAGS.BLEND=1
        write_reg(16'hD4C8, 8'h01);

        write_reg(16'hD4BC, 8'h02);    // CMD = 0x02 (line draw)
        wait_idle();

        // Verify: 5 single-beat reads + 5 single-beat writes
        expect_read_count(5);
        expect_write_count(5);

        // Blended pixel = 0x9F_20_20_80
        expect_write(0, 32'h3000_0000, {32'h0, 32'h9F_20_20_80}, 8'h0F);
        expect_write(1, 32'h3000_0000, {32'h9F_20_20_80, 32'h0}, 8'hF0);
        expect_write(2, 32'h3000_0008, {32'h0, 32'h9F_20_20_80}, 8'h0F);
        expect_write(3, 32'h3000_0008, {32'h9F_20_20_80, 32'h0}, 8'hF0);
        expect_write(4, 32'h3000_0010, {32'h0, 32'h9F_20_20_80}, 8'h0F);

        // Clear FLAGS for subsequent tests
        write_reg(16'hD4C8, 8'h00);

        $display("PASS: test_line_draw_blend");
    endtask

    // ====================================================================
    // Main test scheduler
    // ====================================================================
    initial begin
        $display("=== xt_blitter testbench starting ===");

        // Wait for reset release
        @(negedge rst);
        @(posedge clk);
        @(posedge clk);

        // Drain any initial spurious AXI activity
        clear_logs();

        // Run tests
        test_pattern_fill();
        test_pattern_fill_transparent();
        test_line_draw_horizontal();
        test_block_blit_copy();
        test_block_blit_xor();
        test_block_blit_notsrc();
        test_line_draw_blend();

        // Done
        $display("=== ALL TESTS PASSED ===");
        $finish;
    end

    // Watchdog -- 200k cycles (~1.3 ms at 150 MHz) should be plenty
    initial begin
        #1_333_333;   // 1.33 ms
        $display("FATAL: watchdog expired");
        $fatal(1);
    end

    // VCD dump for debugging (enable with +vcd).
    initial begin
        if ($test$plusargs("vcd")) begin
            $dumpfile("tb_xt_blitter.vcd");
            $dumpvars(0, tb_xt_blitter);
        end
    end

endmodule

`default_nettype wire
