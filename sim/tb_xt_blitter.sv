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
    wire         cq_full;
    wire         pat_blocked;
    wire [15:0]  seq_counter;

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
        .cq_full       (cq_full),
        .pat_blocked   (pat_blocked),
        .seq_counter   (seq_counter),
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
                // Apply strobed bytes to backing store.  word_idx must be a
                // plain (per-execution) assignment, NOT `int x = expr` — the
                // latter is a STATIC initializer evaluated once at time 0, so
                // every write would land on a constant garbage index.
                int word_idx;
                word_idx = mem_idx(aw_addr_q + w_beat_count * 8);
                for (int b = 0; b < 8; b++) begin
                    if (m_axi_wstrb[b])
                        mem[word_idx][b*8 +: 8] <= m_axi_wdata[b*8 +: 8];
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
    // RECT_FILL to an ARBITRARY DDR surface (DST_DDR=1): the any-DDR fill
    // path for GEM window backing stores.  4x2 solid fill, ROW0=0x30080000,
    // stride 64 -> row 1 must land at ROW0+64.  Proves the dst_row_base seed
    // (descriptor ROW0, not FB_BASE) + per-row accumulate (no fabric multiply).
    // ----------------------------------------------------------------
    task test_rect_fill_ddr();
        $display("=== Test: RECT_FILL -> DDR surface (DST_DDR), 4x2, stride 64 ===");
        clear_logs();
        write_reg(16'hD4BA, 8'h00);
        load_1x1_pattern(8'hFF, 8'h00, 8'h00, 8'hFF);
        write_reg(16'hD4BE, 8'h00);
        // DST surface descriptor: ROW0 = 0x30080000, stride 64
        write_reg(16'hD4E6,8'h00); write_reg(16'hD4E7,8'h00); write_reg(16'hD4E8,8'h08); write_reg(16'hD4E9,8'h30);
        write_reg(16'hD4EA,8'd64); write_reg(16'hD4EB,8'd0);
        // DST_X=0 (8-byte half parity), DST_Y=0; 4 wide x 2 tall
        write_reg(16'hD4B0,8'h00); write_reg(16'hD4B1,8'h00); write_reg(16'hD4B2,8'h00); write_reg(16'hD4B3,8'h00);
        write_reg(16'hD4B4,8'h04); write_reg(16'hD4B5,8'h00); write_reg(16'hD4B6,8'h02); write_reg(16'hD4B7,8'h00);
        write_reg(16'hD4BF,8'h03);   // RASTER_OP = S (copy)
        write_reg(16'hD4C8,8'h20);   // FLAGS: DST_DDR (bit 5)
        write_reg(16'hD4BC,8'h01);   // CMD = RECT_FILL
        wait_idle();
        expect_write_count(4);
        expect_write(0, 32'h3008_0000, 64'hFF0000FF_FF0000FF, 8'hFF);
        expect_write(1, 32'h3008_0008, 64'hFF0000FF_FF0000FF, 8'hFF);
        expect_write(2, 32'h3008_0040, 64'hFF0000FF_FF0000FF, 8'hFF);  // row 1 = ROW0 + stride
        expect_write(3, 32'h3008_0048, 64'hFF0000FF_FF0000FF, 8'hFF);
        $display("PASS: test_rect_fill_ddr");
    endtask

    // ----------------------------------------------------------------
    // BLOCK_BLIT DDR->DDR (SRC_DDR|DST_DDR): src + dst both off-plane,
    // 4x2 (TWO rows) so the src_row_base AND dst_row_base accumulators must
    // both advance +stride at S_ADV.  Straight copy (RASTER_OP=S).
    // ----------------------------------------------------------------
    task test_block_blit_ddr();
        logic [31:0] sa, da, got, exp;
        int errs;
        $display("=== Test: BLOCK_BLIT DDR->DDR (SRC_DDR|DST_DDR), 4x2, stride 64 ===");
        clear_logs(); errs = 0;
        for (int yy = 0; yy < 2; yy++)
          for (int xx = 0; xx < 4; xx++) begin
            sa = 32'h3004_0000 + yy*64 + xx*4;
            mem[mem_idx(sa)][(sa[2] ? 32 : 0) +: 32] = 32'hA0B0C000 + yy*32'h100 + xx;
          end
        // SRC descriptor 0x30040000/64, DST descriptor 0x30080000/64
        write_reg(16'hD4E0,8'h00); write_reg(16'hD4E1,8'h00); write_reg(16'hD4E2,8'h04); write_reg(16'hD4E3,8'h30);
        write_reg(16'hD4E4,8'd64); write_reg(16'hD4E5,8'd0);
        write_reg(16'hD4E6,8'h00); write_reg(16'hD4E7,8'h00); write_reg(16'hD4E8,8'h08); write_reg(16'hD4E9,8'h30);
        write_reg(16'hD4EA,8'd64); write_reg(16'hD4EB,8'd0);
        // SRC_X/Y=0, SRC_W/H=4x2 ; DST_X/Y=0, DST_W/H=4x2 (origins folded into ROW0)
        write_reg(16'hD4C0,8'd0); write_reg(16'hD4C1,8'd0); write_reg(16'hD4C2,8'd0); write_reg(16'hD4C3,8'd0);
        write_reg(16'hD4C4,8'd4); write_reg(16'hD4C5,8'd0); write_reg(16'hD4C6,8'd2); write_reg(16'hD4C7,8'd0);
        write_reg(16'hD4B0,8'd0); write_reg(16'hD4B1,8'd0); write_reg(16'hD4B2,8'd0); write_reg(16'hD4B3,8'd0);
        write_reg(16'hD4B4,8'd4); write_reg(16'hD4B5,8'd0); write_reg(16'hD4B6,8'd2); write_reg(16'hD4B7,8'd0);
        write_reg(16'hD4BF,8'h03);   // RASTER_OP = S (copy)
        write_reg(16'hD4C8,8'h24);   // FLAGS: SRC_DDR(2) | DST_DDR(5)
        write_reg(16'hD4BC,8'h03);   // CMD = BLOCK_BLIT
        wait_idle();
        for (int yy = 0; yy < 2; yy++)
          for (int xx = 0; xx < 4; xx++) begin
            da  = 32'h3008_0000 + yy*64 + xx*4;
            got = mem[mem_idx(da)][(da[2] ? 32 : 0) +: 32];
            exp = 32'hA0B0C000 + yy*32'h100 + xx;
            if (got !== exp) begin errs++; $display("  MISMATCH (%0d,%0d): got %08x exp %08x", xx, yy, got, exp); end
          end
        if (errs == 0) $display("PASS: test_block_blit_ddr");
        else begin $display("FAIL: test_block_blit_ddr (%0d mismatches)", errs); $fatal(1); end
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
    // Diagonal line, DX=5 DY=3 -> 6 pixels (x-dominant).  Exercises the
    // Bresenham step for DY != 0 (the horizontal test has DY=0).
    // ----------------------------------------------------------------
    task test_line_draw_diagonal();
        $display("=== Test: Line draw, diagonal, DX=5 DY=3 -> 6 pixels ===");
        clear_logs();
        write_reg(16'hD4BA, 8'h00);
        load_1x1_pattern(8'h00, 8'hFF, 8'h00, 8'hFF);
        write_reg(16'hD4BE, 8'h00);
        write_reg(16'hD4B0, 8'h00); write_reg(16'hD4B1, 8'h00);   // DST_X = 0
        write_reg(16'hD4B2, 8'h00); write_reg(16'hD4B3, 8'h00);   // DST_Y = 0
        write_reg(16'hD4B4, 8'd5);  write_reg(16'hD4B5, 8'h00);   // DST_W = DX = 5
        write_reg(16'hD4B6, 8'd3);  write_reg(16'hD4B7, 8'h00);   // DST_H = DY = 3
        write_reg(16'hD4BC, 8'h02);                               // CMD = line draw
        wait_idle();
        $display("  diagonal wrote %0d beats (expect 6)", w_addr_q.size());
        expect_write_count(6);
        $display("PASS: test_line_draw_diagonal");
    endtask

    // ----------------------------------------------------------------
    // Reverse diagonal: (5,3)->(0,0), DX=-5 DY=-3 -> 6 pixels.  Exercises
    // negative deltas (line_sx/sy = step -1) with the signed Bresenham.
    // ----------------------------------------------------------------
    task test_line_draw_diagonal_rev();
        $display("=== Test: Line draw, reverse diagonal, DX=-5 DY=-3 -> 6 pixels ===");
        clear_logs();
        write_reg(16'hD4BA, 8'h00);
        load_1x1_pattern(8'h00, 8'hFF, 8'h00, 8'hFF);
        write_reg(16'hD4BE, 8'h00);
        write_reg(16'hD4B0, 8'd5);  write_reg(16'hD4B1, 8'h00);   // DST_X = 5
        write_reg(16'hD4B2, 8'd3);  write_reg(16'hD4B3, 8'h00);   // DST_Y = 3
        write_reg(16'hD4B4, 8'hFB); write_reg(16'hD4B5, 8'hFF);   // DST_W = DX = -5
        write_reg(16'hD4B6, 8'hFD); write_reg(16'hD4B7, 8'hFF);   // DST_H = DY = -3
        write_reg(16'hD4BC, 8'h02);                               // CMD = line draw
        wait_idle();
        $display("  reverse diagonal wrote %0d beats (expect 6)", w_addr_q.size());
        expect_write_count(6);
        $display("PASS: test_line_draw_diagonal_rev");
    endtask

    // ----------------------------------------------------------------
    // SRC_BLIT (CMD 0x08) — straight RGBA copy, DDR source -> DDR dest.
    // Source surface @0x30040000 (stride 64B), dest @0x30080000 (stride 64B).
    // ----------------------------------------------------------------
    task test_src_blit_copy();
        logic [31:0] sa, da, got, exp;
        int errs;
        $display("=== Test: SRC_BLIT RGBA copy, 4x2, DDR src -> DDR dst ===");
        clear_logs(); errs = 0;
        for (int yy = 0; yy < 2; yy++)
          for (int xx = 0; xx < 4; xx++) begin
            sa = 32'h3004_0000 + yy*64 + xx*4;
            mem[mem_idx(sa)][(sa[2] ? 32 : 0) +: 32] = 32'h1122_3300 + yy*32'h1000 + xx;
          end
        // SRC descriptor 0x30040000/64, DST descriptor 0x30080000/64
        write_reg(16'hD4E0,8'h00); write_reg(16'hD4E1,8'h00); write_reg(16'hD4E2,8'h04); write_reg(16'hD4E3,8'h30);
        write_reg(16'hD4E4,8'd64); write_reg(16'hD4E5,8'd0);
        write_reg(16'hD4E6,8'h00); write_reg(16'hD4E7,8'h00); write_reg(16'hD4E8,8'h08); write_reg(16'hD4E9,8'h30);
        write_reg(16'hD4EA,8'd64); write_reg(16'hD4EB,8'd0);
        write_reg(16'hD4C0,8'd0); write_reg(16'hD4C1,8'd0); write_reg(16'hD4C2,8'd0); write_reg(16'hD4C3,8'd0);
        write_reg(16'hD4B0,8'd0); write_reg(16'hD4B1,8'd0); write_reg(16'hD4B2,8'd0); write_reg(16'hD4B3,8'd0);
        write_reg(16'hD4B4,8'd4); write_reg(16'hD4B5,8'd0); write_reg(16'hD4B6,8'd2); write_reg(16'hD4B7,8'd0);
        write_reg(16'hD4C8,8'h24);   // FLAGS: SRC_DDR(bit2) | DST_DDR(bit5)
        write_reg(16'hD4BC,8'h08);   // CMD = SRC_BLIT
        wait_idle();
        for (int yy = 0; yy < 2; yy++)
          for (int xx = 0; xx < 4; xx++) begin
            da  = 32'h3008_0000 + yy*64 + xx*4;
            got = mem[mem_idx(da)][(da[2] ? 32 : 0) +: 32];
            exp = 32'h1122_3300 + yy*32'h1000 + xx;
            if (got !== exp) begin errs++; $display("  MISMATCH (%0d,%0d): got %08x exp %08x", xx, yy, got, exp); end
          end
        if (errs == 0) $display("PASS: test_src_blit_copy");
        else begin $display("FAIL: test_src_blit_copy (%0d mismatches)", errs); $fatal(1); end
    endtask

    // ----------------------------------------------------------------
    // SRC_BLIT coverage->colour blend: 8-bit coverage atlas + pattern colour,
    // blended over a known background.  cov: 255(opaque) 128 0(skip) 64.
    // ----------------------------------------------------------------
    task test_src_blit_coverage();
        logic [31:0] da, got;
        int errs;
        $display("=== Test: SRC_BLIT coverage blend, 4x1, red over black ===");
        clear_logs(); errs = 0;
        // Coverage atlas @0x30040000: bytes [255,128,0,64] in the first beat.
        mem[mem_idx(32'h3004_0000)] = 64'h0000_0000_4000_80FF;
        // Dest @0x30080000 prefilled black (alpha 0).
        mem[mem_idx(32'h3008_0000)] = 64'h0;
        mem[mem_idx(32'h3008_0008)] = 64'h0;
        // 1x1 red pattern = text colour (R,G,B,A = FF,00,00,FF)
        write_reg(16'hD4BA, 8'h00); load_1x1_pattern(8'hFF, 8'h00, 8'h00, 8'hFF); write_reg(16'hD4BE, 8'h00);
        // SRC descriptor 0x30040000/8 (1 B/px), DST 0x30080000/64
        write_reg(16'hD4E0,8'h00); write_reg(16'hD4E1,8'h00); write_reg(16'hD4E2,8'h04); write_reg(16'hD4E3,8'h30);
        write_reg(16'hD4E4,8'd8);  write_reg(16'hD4E5,8'd0);
        write_reg(16'hD4E6,8'h00); write_reg(16'hD4E7,8'h00); write_reg(16'hD4E8,8'h08); write_reg(16'hD4E9,8'h30);
        write_reg(16'hD4EA,8'd64); write_reg(16'hD4EB,8'd0);
        write_reg(16'hD4C0,8'd0); write_reg(16'hD4C1,8'd0); write_reg(16'hD4C2,8'd0); write_reg(16'hD4C3,8'd0);
        write_reg(16'hD4B0,8'd0); write_reg(16'hD4B1,8'd0); write_reg(16'hD4B2,8'd0); write_reg(16'hD4B3,8'd0);
        write_reg(16'hD4B4,8'd4); write_reg(16'hD4B5,8'd0); write_reg(16'hD4B6,8'd1); write_reg(16'hD4B7,8'd0);
        write_reg(16'hD4C8,8'h2C);   // FLAGS: SRC_DDR(2) | SRC_COV(3) | DST_DDR(5)
        write_reg(16'hD4BC,8'h08);   // CMD = SRC_BLIT
        wait_idle();
        // Expected: x0=255 fast-path FF0000FF; x1=128 -> 800000FF; x2=0 unchanged 0; x3=64 -> 400000FF
        for (int xx = 0; xx < 4; xx++) begin
            logic [31:0] e;
            da  = 32'h3008_0000 + xx*4;
            got = mem[mem_idx(da)][(da[2] ? 32 : 0) +: 32];
            case (xx)
                0: e = 32'hFF0000FF;
                1: e = 32'h800000FF;
                2: e = 32'h00000000;
                3: e = 32'h400000FF;
            endcase
            $display("  cov pixel %0d = %08x (expect %08x)", xx, got, e);
            if (got !== e) errs++;
        end
        if (errs == 0) $display("PASS: test_src_blit_coverage");
        else begin $display("FAIL: test_src_blit_coverage (%0d mismatches)", errs); $fatal(1); end
    endtask

    // ----------------------------------------------------------------
    // SRC_BLIT RGBA alpha-over: src {red@α128, green@α255, transparent@α0}
    // composited over a blue background.
    // ----------------------------------------------------------------
    task test_src_blit_aover();
        logic [31:0] da, got, e;
        int errs;
        $display("=== Test: SRC_BLIT RGBA alpha-over, 3x1, over blue ===");
        clear_logs(); errs = 0;
        // Source @0x30040000: px0=FF000080 (red α128), px1=00FF00FF (green opaque), px2=00000000 (clear)
        mem[mem_idx(32'h3004_0000)] = 64'h00FF00FF_FF000080;
        mem[mem_idx(32'h3004_0008)] = 64'h00000000_00000000;
        // Dest @0x30080000 prefilled blue (0000FFFF)
        mem[mem_idx(32'h3008_0000)] = 64'h0000FFFF_0000FFFF;
        mem[mem_idx(32'h3008_0008)] = 64'h0000FFFF_0000FFFF;
        write_reg(16'hD4E0,8'h00); write_reg(16'hD4E1,8'h00); write_reg(16'hD4E2,8'h04); write_reg(16'hD4E3,8'h30);
        write_reg(16'hD4E4,8'd64); write_reg(16'hD4E5,8'd0);
        write_reg(16'hD4E6,8'h00); write_reg(16'hD4E7,8'h00); write_reg(16'hD4E8,8'h08); write_reg(16'hD4E9,8'h30);
        write_reg(16'hD4EA,8'd64); write_reg(16'hD4EB,8'd0);
        write_reg(16'hD4C0,8'd0); write_reg(16'hD4C1,8'd0); write_reg(16'hD4C2,8'd0); write_reg(16'hD4C3,8'd0);
        write_reg(16'hD4B0,8'd0); write_reg(16'hD4B1,8'd0); write_reg(16'hD4B2,8'd0); write_reg(16'hD4B3,8'd0);
        write_reg(16'hD4B4,8'd3); write_reg(16'hD4B5,8'd0); write_reg(16'hD4B6,8'd1); write_reg(16'hD4B7,8'd0);
        write_reg(16'hD4C8,8'h34);   // FLAGS: SRC_DDR(2) | SRC_AOVER(4) | DST_DDR(5)
        write_reg(16'hD4BC,8'h08);   // CMD = SRC_BLIT
        wait_idle();
        for (int xx = 0; xx < 3; xx++) begin
            da  = 32'h3008_0000 + xx*4;
            got = mem[mem_idx(da)][(da[2] ? 32 : 0) +: 32];
            case (xx)
                0: e = 32'h80007FFF;   // red α128 over blue
                1: e = 32'h00FF00FF;   // green opaque (fast path)
                2: e = 32'h0000FFFF;   // α0 → unchanged blue
            endcase
            $display("  aover pixel %0d = %08x (expect %08x)", xx, got, e);
            if (got !== e) errs++;
        end
        if (errs == 0) $display("PASS: test_src_blit_aover");
        else begin $display("FAIL: test_src_blit_aover (%0d mismatches)", errs); $fatal(1); end
    endtask

    // ----------------------------------------------------------------
    // SRC_BLIT coverage -> the PLANE: exactly the path that vdi.srctest /
    // hardware text rendering uses.  The plane is now an explicit surface
    // descriptor (ROW0=FB_BASE, stride FB_STRIDE_B) like any other — there is
    // no implicit DST_DDR=0 plane default.  Coverage atlas in DDR, dest = plane.
    // ----------------------------------------------------------------
    task test_src_blit_cov_plane();
        logic [31:0] da, got, e;
        int errs;
        $display("=== Test: SRC_BLIT coverage -> plane (DST_DDR=0), 4x1 ===");
        clear_logs(); errs = 0;
        mem[mem_idx(32'h3004_0000)] = 64'h0000_0000_4000_80FF;   // cov 255,128,0,64
        mem[mem_idx(32'h3000_0000)] = 64'h0;                     // plane (0,0)/(1,0) black
        mem[mem_idx(32'h3000_0008)] = 64'h0;                     // plane (2,0)/(3,0) black
        write_reg(16'hD4BA, 8'h00); load_1x1_pattern(8'h00, 8'hFF, 8'h00, 8'hFF); write_reg(16'hD4BE, 8'h00); // green
        write_reg(16'hD4E0,8'h00); write_reg(16'hD4E1,8'h00); write_reg(16'hD4E2,8'h04); write_reg(16'hD4E3,8'h30);
        write_reg(16'hD4E4,8'd8);  write_reg(16'hD4E5,8'd0);     // SRC stride 8 (1 B/px)
        // DST = the plane as an explicit surface: ROW0 = FB_BASE 0x30000000,
        // stride FB_STRIDE_B = 8192 = 0x2000.
        write_reg(16'hD4E6,8'h00); write_reg(16'hD4E7,8'h00); write_reg(16'hD4E8,8'h00); write_reg(16'hD4E9,8'h30);
        write_reg(16'hD4EA,8'h00); write_reg(16'hD4EB,8'h20);
        write_reg(16'hD4C0,8'd0); write_reg(16'hD4C1,8'd0); write_reg(16'hD4C2,8'd0); write_reg(16'hD4C3,8'd0);
        write_reg(16'hD4B0,8'd0); write_reg(16'hD4B1,8'd0); write_reg(16'hD4B2,8'd0); write_reg(16'hD4B3,8'd0);
        write_reg(16'hD4B4,8'd4); write_reg(16'hD4B5,8'd0); write_reg(16'hD4B6,8'd1); write_reg(16'hD4B7,8'd0);
        write_reg(16'hD4C8,8'h08);   // FLAGS: SRC_COV(3) (SRC_DDR/DST_DDR now implied)
        write_reg(16'hD4BC,8'h08);   // CMD = SRC_BLIT
        wait_idle();
        for (int xx = 0; xx < 4; xx++) begin
            da  = 32'h3000_0000 + xx*4;
            got = mem[mem_idx(da)][(da[2] ? 32 : 0) +: 32];
            case (xx)
                0: e = 32'h00FF00FF;   // cov 255 -> green
                1: e = 32'h008000FF;   // cov 128 -> half green over black
                2: e = 32'h00000000;   // cov 0   -> unchanged
                3: e = 32'h004000FF;   // cov 64
            endcase
            $display("  plane pixel %0d = %08x (expect %08x)", xx, got, e);
            if (got !== e) errs++;
        end
        if (errs == 0) $display("PASS: test_src_blit_cov_plane");
        else begin $display("FAIL: test_src_blit_cov_plane (%0d mismatches)", errs); $fatal(1); end
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

    // ----------------------------------------------------------------
    // Test 8: Command queue -- push 3 rect fills back-to-back
    //
    // Pushes three CMD=0x01 operations without polling busy between
    // them: a 2x1 red rect at (0,0), a 2x1 green rect at (4,0), and
    // a 2x1 blue rect at (8,0).  All share the same pattern memory
    // (caveat: only the LAST loaded pattern actually applies — the
    // queue snapshots register state, not pattern BRAM contents).
    //
    // The point of this test is to verify FIFO ordering and that
    // each queued operation runs to completion without the PS poking
    // busy in between.  We use the SAME colour pattern for all three
    // rects to avoid the pattern-memory-shared caveat, then verify
    // by destination address.
    //
    // Per rect (2 pixels at known X): 1 AXI write beat per rect since
    // both pixels fit in one 64-bit beat (even-X start, even count).
    // Total: 3 write beats, no reads.
    // ----------------------------------------------------------------
    task test_command_queue();
        $display("=== Test 8: Command queue, 3 batched rect fills ===");

        clear_logs();

        // Load 1x1 solid red pattern (shared by all queued rects).
        write_reg(16'hD4BA, 8'h00);
        load_1x1_pattern(8'hFF, 8'h00, 8'h00, 8'hFF);
        write_reg(16'hD4BE, 8'h00);

        // Rect 1: (0,0) 2x1
        write_reg(16'hD4B0, 8'd0);
        write_reg(16'hD4B1, 8'd0);
        write_reg(16'hD4B2, 8'd0);
        write_reg(16'hD4B3, 8'd0);
        write_reg(16'hD4B4, 8'd2);
        write_reg(16'hD4B5, 8'd0);
        write_reg(16'hD4B6, 8'd1);
        write_reg(16'hD4B7, 8'd0);
        write_reg(16'hD4BF, 8'd3);            // RASTER_OP = COPY
        write_reg(16'hD4BC, 8'h01);           // push CMD #1

        // Don't poll busy — just update regs for rect 2 and push.
        // Rect 2: (4,0) 2x1
        write_reg(16'hD4B0, 8'd4);
        write_reg(16'hD4B1, 8'd0);
        write_reg(16'hD4B4, 8'd2);
        write_reg(16'hD4B6, 8'd1);
        write_reg(16'hD4BC, 8'h01);           // push CMD #2

        // Rect 3: (8,0) 2x1
        write_reg(16'hD4B0, 8'd8);
        write_reg(16'hD4B1, 8'd0);
        write_reg(16'hD4B4, 8'd2);
        write_reg(16'hD4B6, 8'd1);
        write_reg(16'hD4BC, 8'h01);           // push CMD #3

        // Now wait for the whole batch to drain.
        wait_idle();

        // Expect 3 write beats — one per rect, in pushed order.
        // pixel addr (x*4 + y*8192), 8-byte-aligned beat addr.
        //   rect1: x=0,1 → beat at 0x3000_0000, both halves = red
        //   rect2: x=4,5 → beat at 0x3000_0010
        //   rect3: x=8,9 → beat at 0x3000_0020
        expect_write_count(3);
        expect_write(0, 32'h3000_0000, {32'hFF_00_00_FF, 32'hFF_00_00_FF}, 8'hFF);
        expect_write(1, 32'h3000_0010, {32'hFF_00_00_FF, 32'hFF_00_00_FF}, 8'hFF);
        expect_write(2, 32'h3000_0020, {32'hFF_00_00_FF, 32'hFF_00_00_FF}, 8'hFF);

        expect_read_count(0);

        $display("PASS: test_command_queue");
    endtask

    // ----------------------------------------------------------------
    // Test 9: Pattern-while-busy block
    //
    // 1. Load red pattern, push CMD #1 (2x1 rect at (0,0)).
    // 2. While the blitter is busy executing #1, attempt to load a
    //    green pattern.  Hardware should drop the write and set
    //    pat_blocked.
    // 3. Push CMD #2 (2x1 rect at (4,0)).  Since the pattern load
    //    was dropped, this rect should ALSO come out red.
    // 4. wait_idle, verify pat_blocked is set, verify both rects
    //    are red.
    // 5. Now drained — load green pattern (allowed), push CMD #3
    //    (2x1 rect at (8,0)), wait_idle.  Verify rect 3 is green
    //    and pat_blocked auto-cleared on drain.
    // ----------------------------------------------------------------
    task test_pat_while_busy();
        $display("=== Test 9: Pattern-while-busy block ===");

        clear_logs();

        // Step 1: load red pattern, push rect 1
        write_reg(16'hD4BA, 8'h00);
        load_1x1_pattern(8'hFF, 8'h00, 8'h00, 8'hFF);
        write_reg(16'hD4BE, 8'h00);

        write_reg(16'hD4B0, 8'd0);   write_reg(16'hD4B1, 8'd0);
        write_reg(16'hD4B2, 8'd0);   write_reg(16'hD4B3, 8'd0);
        write_reg(16'hD4B4, 8'd2);   write_reg(16'hD4B5, 8'd0);
        write_reg(16'hD4B6, 8'd1);   write_reg(16'hD4B7, 8'd0);
        write_reg(16'hD4BF, 8'd3);
        write_reg(16'hD4BC, 8'h01);   // push CMD #1 (red)

        // Step 2: immediately try to load green — should be dropped.
        // Skip past the CMD push cycle so busy is asserted.
        @(posedge clk);
        @(posedge clk);
        if (!busy) begin
            $display("FAIL: blitter should be busy after CMD push");
            $fatal(1);
        end
        // Attempt a pattern load while busy.  The single $D4BA write below
        // would normally reset pat_load_ptr — gated on !busy, it doesn't —
        // and raises pat_blocked.  Read after @(negedge clk) so NBAs settle.
        write_reg(16'hD4BA, 8'h00);
        @(negedge clk);
        if (!pat_blocked) begin
            $display("FAIL: pat_blocked should be set after dropped $D4BA write");
            $fatal(1);
        end

        // Continue the load — should also be dropped, pat_blocked stays set.
        load_1x1_pattern(8'h00, 8'hFF, 8'h00, 8'hFF);

        // Step 3: while still busy, push rect 2.  Should reuse RED pattern.
        write_reg(16'hD4B0, 8'd4);
        write_reg(16'hD4BC, 8'h01);

        // Step 4: drain.  pat_blocked auto-clears when busy goes 0.
        wait_idle();

        // Both rects should be red — the green load was dropped.
        expect_write_count(2);
        expect_write(0, 32'h3000_0000, {32'hFF_00_00_FF, 32'hFF_00_00_FF}, 8'hFF);
        expect_write(1, 32'h3000_0010, {32'hFF_00_00_FF, 32'hFF_00_00_FF}, 8'hFF);

        // Wait a couple of cycles for the cdc/sticky logic to settle, then
        // pat_blocked should be 0 (auto-clear once busy=0).
        @(posedge clk);
        @(posedge clk);
        if (pat_blocked) begin
            $display("FAIL: pat_blocked should clear once busy=0");
            $fatal(1);
        end

        // Step 5: now allowed — load green, push rect 3.
        clear_logs();
        write_reg(16'hD4BA, 8'h00);
        load_1x1_pattern(8'h00, 8'hFF, 8'h00, 8'hFF);
        write_reg(16'hD4B0, 8'd8);
        write_reg(16'hD4BC, 8'h01);
        wait_idle();

        expect_write_count(1);
        expect_write(0, 32'h3000_0020, {32'h00_FF_00_FF, 32'h00_FF_00_FF}, 8'hFF);

        $display("PASS: test_pat_while_busy");
    endtask

    // ----------------------------------------------------------------
    // Test 10: SYNC barrier (CMD=0x07) + seq counter
    //
    // Two scenarios:
    //   (a) Direct shortcut: with queue empty + FSM idle, writing
    //       CMD=0x07 bumps seq_counter immediately (same cycle).
    //   (b) Through-the-queue: push a slow rect, push SYNC behind it,
    //       verify seq_counter only advances after the rect's AXI
    //       write completes.
    // ----------------------------------------------------------------
    task test_sync_barrier();
        logic [15:0] seq_before;
        logic [15:0] seq_after_direct;
        $display("=== Test 10: SYNC barrier + seq counter ===");

        clear_logs();

        // Previous test left us drained (busy=0); confirm and proceed.
        @(negedge clk);
        if (busy) begin
            $display("FAIL: test entered with busy=1 (previous test didn't drain)");
            $fatal(1);
        end

        // ---- (a) Direct shortcut ----------------------------------------
        seq_before = seq_counter;
        write_reg(16'hD4BC, 8'h07);     // CMD = SYNC
        @(negedge clk);
        seq_after_direct = seq_counter;
        if (seq_after_direct != (seq_before + 16'd1)) begin
            $display("FAIL: SYNC direct shortcut: seq %h -> %h, expected +1",
                     seq_before, seq_after_direct);
            $fatal(1);
        end

        // The shortcut shouldn't have generated any AXI traffic.
        expect_write_count(0);
        expect_read_count(0);

        // ---- (b) SYNC behind a real op ---------------------------------
        // Load 1x1 red pattern.
        write_reg(16'hD4BA, 8'h00);
        load_1x1_pattern(8'hFF, 8'h00, 8'h00, 8'hFF);
        write_reg(16'hD4BE, 8'h00);

        // 2x1 rect at (0,0) — generates one AXI write beat.
        write_reg(16'hD4B0, 8'd0);  write_reg(16'hD4B1, 8'd0);
        write_reg(16'hD4B2, 8'd0);  write_reg(16'hD4B3, 8'd0);
        write_reg(16'hD4B4, 8'd2);  write_reg(16'hD4B5, 8'd0);
        write_reg(16'hD4B6, 8'd1);  write_reg(16'hD4B7, 8'd0);
        write_reg(16'hD4BF, 8'd3);

        seq_before = seq_counter;
        write_reg(16'hD4BC, 8'h01);     // push the rect — queue is non-empty now
        write_reg(16'hD4BC, 8'h07);     // push SYNC behind it

        // SYNC should NOT have shortcut this time — queue was non-empty.
        // seq should still be at seq_before until the rect drains.
        @(negedge clk);
        if (seq_counter != seq_before) begin
            $display("FAIL: SYNC behind rect: seq advanced too early (%h -> %h)",
                     seq_before, seq_counter);
            $fatal(1);
        end

        // Drain.  At end of drain, the rect's AXI write has happened AND
        // SYNC has popped, bumping seq.
        wait_idle();
        if (seq_counter != (seq_before + 16'd1)) begin
            $display("FAIL: SYNC behind rect: seq %h -> %h after drain, expected +1",
                     seq_before, seq_counter);
            $fatal(1);
        end

        // Exactly one AXI write beat from the rect.
        expect_write_count(1);
        expect_write(0, 32'h3000_0000, {32'hFF_00_00_FF, 32'hFF_00_00_FF}, 8'hFF);

        $display("PASS: test_sync_barrier");
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
        test_rect_fill_ddr();
        test_block_blit_ddr();
        test_pattern_fill_transparent();
        test_line_draw_horizontal();
        test_line_draw_diagonal();
        test_line_draw_diagonal_rev();
        test_src_blit_copy();
        test_src_blit_coverage();
        test_src_blit_aover();
        test_src_blit_cov_plane();
        test_block_blit_copy();
        test_block_blit_xor();
        test_block_blit_notsrc();
        test_line_draw_blend();
        test_command_queue();
        test_pat_while_busy();
        test_sync_barrier();

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
