// tb_rp_bus.sv — M3 paired sim. Stitches rp_tx + rp_rx + rp_bus_mock
// together, fires a randomized sequence of FETCH/SET/NOP commands,
// and verifies that the RP-side mock services them correctly.
//
// Ship criterion: 1024 random ops with zero mismatches; counters
// (FPGA-side TX trap, RX drops; mock-side bad-tag, set-misalign,
// draw count) all stay at 0 except where intentionally exercised.

`default_nettype none
`timescale 1ns / 1ps

`include "bus_opcodes.vh"

module tb_rp_bus;

    // Single 360 MHz simulation clock for all bus traffic.
    logic clk = 1'b0;
    always #1.389 clk = ~clk;            // 360 MHz: half-period 1.389 ns

    logic rst = 1'b1;

    // ---- TX side --------------------------------------------------------
    logic [1:0]  cmd_tag    = `BUS_TAG_NOP;
    logic [23:0] cmd_addr   = 24'h0;
    logic [23:0] cmd_data   = 24'h0;     // M10c: widened 16→24 (legacy 16-bit data zero-pads top)
    logic        cmd_valid  = 1'b0;
    wire         cmd_ready;

    wire [1:0]  bus_tag;
    wire [23:0] bus_payload;
    wire [31:0] tx_set_misalign_count;

    rp_tx u_tx (
        .clk                   (clk),
        .rst                   (rst),
        .cmd_tag               (cmd_tag),
        .cmd_addr              (cmd_addr),
        .cmd_data              (cmd_data),
        .cmd_valid             (cmd_valid),
        .cmd_ready             (cmd_ready),
        .bus_tag               (bus_tag),
        .bus_payload           (bus_payload),
        .tx_set_misalign_count (tx_set_misalign_count)
    );

    // ---- RP-side mock ---------------------------------------------------
    wire [15:0] rsp_payload;
    wire        rsp_valid;
    wire [31:0] mock_fetch_count, mock_set_count, mock_draw_count;
    wire [31:0] mock_bad_tag_count, mock_set_misalign_count;

    rp_bus_mock #(
        .FB_BYTES      (4096),     // small for sim — only addresses 0..4095 used
        .FETCH_LATENCY (4)
    ) u_mock (
        .clk                     (clk),
        .rst                     (rst),
        .bus_tag                 (bus_tag),
        .bus_payload             (bus_payload),
        .rsp_payload             (rsp_payload),
        .rsp_valid               (rsp_valid),
        .mock_fetch_count        (mock_fetch_count),
        .mock_set_count          (mock_set_count),
        .mock_draw_count         (mock_draw_count),
        .mock_bad_tag_count      (mock_bad_tag_count),
        .mock_set_misalign_count (mock_set_misalign_count)
    );

    // ---- RX side --------------------------------------------------------
    wire [15:0] rsp_data;
    wire        rsp_data_valid;
    wire [31:0] rx_drop_count;
    // Combinational pop: drain the FIFO every cycle a response is available.
    // The verification block compares once per cycle of valid output, then
    // the FIFO advances at end-of-cycle. One push → one verify → one pop.
    wire        rsp_pop = rsp_data_valid;

    rp_rx #(
        .FIFO_DEPTH (16)
    ) u_rx (
        .clk           (clk),
        .rst           (rst),
        .bus_payload   (rsp_payload),
        .bus_valid     (rsp_valid),
        .rsp_data      (rsp_data),
        .rsp_valid     (rsp_data_valid),
        .rsp_pop       (rsp_pop),
        .rx_drop_count (rx_drop_count)
    );

    // ---- Test scoreboard -------------------------------------------------
    int fail_count = 0;
    int fetch_issued = 0;
    int fetch_verified = 0;

    // Expected-response queue (one entry per FETCH issued, in issue order).
    logic [15:0] exp_queue [$];

    // Software model of the framebuffer (matches the mock so we can
    // predict FETCH responses).
    logic [7:0]  sw_fb [0:4095];
    initial begin
        for (int i = 0; i < 4096; i++) sw_fb[i] = 8'h00;
    end

    // ---- Helper tasks ---------------------------------------------------
    task automatic do_set(input logic [23:0] addr, input logic [15:0] data);
        @(posedge clk);
        while (!cmd_ready) @(posedge clk);
        cmd_tag   = `BUS_TAG_SET;
        cmd_addr  = addr;
        cmd_data  = {8'h0, data};        // legacy 16-bit data → top 8 zero (M-only nibbles)
        cmd_valid = 1'b1;
        @(posedge clk);
        cmd_valid = 1'b0;
        cmd_tag   = `BUS_TAG_NOP;
        // Update software model.
        if (addr < 4095) begin
            sw_fb[addr]     = data[7:0];
            sw_fb[addr + 1] = data[15:8];
        end
    endtask

    task automatic do_fetch(input logic [23:0] addr);
        logic [15:0] expected;
        @(posedge clk);
        while (!cmd_ready) @(posedge clk);
        cmd_tag   = `BUS_TAG_FETCH;
        cmd_addr  = addr & 24'hFFFFFE;       // force aligned
        cmd_valid = 1'b1;
        @(posedge clk);
        cmd_valid = 1'b0;
        cmd_tag   = `BUS_TAG_NOP;
        // Predict response based on software model.
        if (addr < 4095) expected = {sw_fb[addr + 1], sw_fb[addr]};
        else             expected = 16'h0000;
        exp_queue.push_back(expected);
        fetch_issued++;
    endtask

    // Verify each response against the expected queue. Pop happens
    // combinationally via rsp_pop = rsp_data_valid, so each FIFO entry
    // produces exactly one cycle of rsp_data_valid at the testbench
    // and exactly one verification.
    logic [15:0] verify_expected;
    always @(posedge clk) begin
        if (!rst && rsp_data_valid) begin
            if (exp_queue.size() == 0) begin
                $display("FAIL fetch[%0d]: response $%04h with empty exp_queue",
                         fetch_verified, rsp_data);
                fail_count++;
            end else begin
                verify_expected = exp_queue.pop_front();
                if (rsp_data !== verify_expected) begin
                    $display("FAIL fetch[%0d]: got $%04h, expected $%04h",
                             fetch_verified, rsp_data, verify_expected);
                    fail_count++;
                end
            end
            fetch_verified++;
        end
    end

    // ---- Main test sequence ---------------------------------------------
    int          seed;
    int          n_ops;
    logic [23:0] addr;
    logic [15:0] data;
    int          op;
    int          dice;

    initial begin : main
        seed  = 32'hCAFEBABE;
        n_ops = 1024;

        $display("[rp_bus] start");
        repeat (4) @(posedge clk);
        rst = 1'b0;
        repeat (4) @(posedge clk);

        // Phase 1 — populate the framebuffer with a known pattern via SET
        // ops so subsequent FETCHes have something to read back.
        for (int i = 0; i < 256; i++) begin
            addr = (i * 2) & 24'hFFFFFE;
            data = ($random(seed) & 16'hFFFF);
            do_set(addr, data);
        end

        // Phase 2 — randomized op stream with mixed FETCH/SET/NOP.
        for (op = 0; op < n_ops; op++) begin
            dice = $random(seed) & 32'h3;
            addr = ($random(seed) & 24'hFFE);    // 0..4094, even
            data = ($random(seed) & 16'hFFFF);
            case (dice)
                2'd0, 2'd1: do_fetch(addr);
                2'd2:       do_set(addr, data);
                2'd3: begin
                    // NOP gap — drive cmd_valid low for a few cycles.
                    repeat (3) @(posedge clk);
                end
            endcase
        end

        // Drain remaining responses.
        repeat (200) @(posedge clk);

        if (fetch_verified != fetch_issued) begin
            $display("FAIL: issued %0d FETCHes, verified %0d", fetch_issued, fetch_verified);
            fail_count++;
        end
        if (mock_bad_tag_count != 32'h0) begin
            $display("FAIL: mock_bad_tag_count=%0d", mock_bad_tag_count); fail_count++;
        end
        if (mock_set_misalign_count != 32'h0) begin
            $display("FAIL: mock_set_misalign_count=%0d", mock_set_misalign_count);
            fail_count++;
        end
        if (mock_draw_count != 32'h0) begin
            $display("FAIL: mock_draw_count=%0d (no DRAW issued)", mock_draw_count);
            fail_count++;
        end
        if (rx_drop_count != 32'h0) begin
            $display("FAIL: rx_drop_count=%0d", rx_drop_count); fail_count++;
        end
        if (tx_set_misalign_count != 32'h0) begin
            $display("FAIL: tx_set_misalign_count=%0d", tx_set_misalign_count);
            fail_count++;
        end

        if (fail_count == 0) begin
            $display("*** RP_BUS OK *** ops=%0d fetches=%0d sets=%0d",
                     n_ops, fetch_verified, mock_set_count);
            $finish;
        end else begin
            $display("*** RP_BUS FAIL *** %0d failures", fail_count);
            $fatal(1);
        end
    end

    // Watchdog.
    initial begin
        #10_000_000;
        $display("FAIL: tb_rp_bus watchdog expired"); $fatal(1);
    end

endmodule

`default_nettype wire
