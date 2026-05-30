// tb_joy_bridge.sv — M25-2c-rev joy_bridge end-to-end against a
// PCAL9722 slave mock.
//
// joy_bridge ↔ joy_link ↔ PCAL9722-mock (24-bit /CS-framed register
// file). Slave mock is the same shape as tb_joy_link's so the wire
// format is consistent.
//
// Coverage:
//
//   A — write-through PORTA_OUT / PORTA_OE: setting joy_porta_out
//       and joy_porta_oe drives the PCAL9722's Output port 0 and
//       Configuration port 0 (with OE inverted to PCAL9722's
//       1 = INPUT convention).
//   B — polled shadow: pre-load slave mem at $00/$01/$02
//       (Input port 0/1/2), wait one poll cycle, verify
//       joy_porta_in / joy_portb_in / joy_fire mirror those.
//   C — live tracking: change joy_porta_out / joy_portb_oe at
//       runtime, verify slave mem updates without an explicit kick.
//   D — TRIG nibble truncation: high nibble of Input port 2 must
//       not leak into joy_fire.

`default_nettype none
`timescale 1ns / 1ps

module tb_joy_bridge;

    logic clk = 1'b0;
    always #5 clk = ~clk;          // 100 MHz sim clock
    logic rst = 1'b1;

    // Write-through inputs.
    logic [7:0] joy_porta_out = 8'hFF;
    logic [7:0] joy_porta_oe  = 8'h00;
    logic [7:0] joy_portb_out = 8'hFF;
    logic [7:0] joy_portb_oe  = 8'h00;

    // Polled outputs.
    wire  [7:0] joy_porta_in;
    wire  [7:0] joy_portb_in;
    wire  [3:0] joy_fire;

    // SPI pads.
    wire        spi_clk;
    wire        spi_mosi;
    wire        spi_miso;
    wire        spi_cs_n;
    logic       spi_int_n = 1'b1;

    joy_bridge #(
        .POLL_DIV         (256),
        .LINK_CLK_DIV     (4),
        .LINK_IDLE_CYCLES (8),
        .LINK_SLAVE_ADDR  (7'h40)
    ) u_dut (
        .clk           (clk),
        .rst           (rst),
        .joy_porta_out (joy_porta_out),
        .joy_porta_oe  (joy_porta_oe),
        .joy_portb_out (joy_portb_out),
        .joy_portb_oe  (joy_portb_oe),
        .joy_porta_in  (joy_porta_in),
        .joy_portb_in  (joy_portb_in),
        .joy_fire      (joy_fire),
        .spi_clk       (spi_clk),
        .spi_mosi      (spi_mosi),
        .spi_miso      (spi_miso),
        .spi_cs_n      (spi_cs_n),
        .spi_int_n     (spi_int_n)
    );

    // ---- PCAL9722-mock slave ---------------------------------------
    // Same /CS-framed 24-bit shifter as tb_joy_link.
    logic [7:0]  slave_mem [0:127];
    logic [4:0]  bit_cnt_q;
    logic [23:0] rx_shift_q;
    logic [7:0]  tx_shift_q;
    logic        spi_clk_q;
    logic        cs_n_q;

    assign spi_miso = tx_shift_q[7];

    initial begin
        for (int i = 0; i < 128; i++) slave_mem[i] = 8'h00;
    end

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            bit_cnt_q  <= 5'd0;
            rx_shift_q <= 24'h0;
            tx_shift_q <= 8'h00;
            spi_clk_q  <= 1'b0;
            cs_n_q     <= 1'b1;
        end else begin
            spi_clk_q <= spi_clk;
            cs_n_q    <= spi_cs_n;

            if (!spi_cs_n && cs_n_q) begin
                bit_cnt_q  <= 5'd0;
                rx_shift_q <= 24'h0;
                tx_shift_q <= 8'h00;
            end

            if (spi_cs_n && !cs_n_q) begin
                if (rx_shift_q[16] == 1'b0) begin
                    slave_mem[rx_shift_q[14:8] & 7'h7F] <= rx_shift_q[7:0];
                end
            end

            if (!spi_cs_n) begin
                if (spi_clk && !spi_clk_q) begin
                    rx_shift_q <= {rx_shift_q[22:0], spi_mosi};
                    bit_cnt_q  <= bit_cnt_q + 5'd1;
                end
                if (!spi_clk && spi_clk_q) begin
                    if (bit_cnt_q == 5'd16) begin
                        tx_shift_q <= slave_mem[rx_shift_q[7:0] & 7'h7F];
                    end else begin
                        tx_shift_q <= {tx_shift_q[6:0], 1'b0};
                    end
                end
            end
        end
    end

    // ---- Test driver -----------------------------------------------
    int fail_count = 0;
    task automatic expect_eq(input string label,
                             input [31:0] got, input [31:0] want);
        if (got !== want) begin
            $display("FAIL %s: got=$%0h expected=$%0h", label, got, want);
            fail_count++;
        end
    endtask

    // Wait until last_*_q matches the live joy_* inputs (writes
    // committed) AND no poll is in flight.
    task automatic wait_idle();
        int cycles_left;
        cycles_left = 16000;
        while (cycles_left > 0) begin
            @(posedge clk);
            cycles_left--;
            if (u_dut.state_q == 1'b0
                && u_dut.poll_q == 2'd0
                && u_dut.last_porta_out_q == joy_porta_out
                && u_dut.last_porta_oe_q  == joy_porta_oe
                && u_dut.last_portb_out_q == joy_portb_out
                && u_dut.last_portb_oe_q  == joy_portb_oe) begin
                return;
            end
        end
        $display("FAIL wait_idle timeout: state=%0d poll=%0d last_pa_o=$%0h pa_o=$%0h last_pa_e=$%0h pa_e=$%0h last_pb_o=$%0h pb_o=$%0h last_pb_e=$%0h pb_e=$%0h",
                 u_dut.state_q, u_dut.poll_q,
                 u_dut.last_porta_out_q, joy_porta_out,
                 u_dut.last_porta_oe_q,  joy_porta_oe,
                 u_dut.last_portb_out_q, joy_portb_out,
                 u_dut.last_portb_oe_q,  joy_portb_oe);
        fail_count++;
    endtask

    task automatic wait_one_poll_cycle();
        repeat (4000) @(posedge clk);
    endtask

    initial begin
        $display("=== M25-2c-rev joy_bridge ===");
        repeat (4) @(posedge clk);
        rst = 1'b0;
        @(posedge clk);

        // ===== A — write-through ===================================
        // (Phase E below confirms the boot-time INT_MASK init writes
        // also fire — they happen during the wait_idle below.)
        $display("[A] write-through PORTA_OUT / PORTA_OE");
        joy_porta_out = 8'h5A;
        joy_porta_oe  = 8'h0F;
        wait_idle();
        // Output port 0 should get the raw joy_porta_out value.
        expect_eq("A.PCAL[OUT0]=PORTA_OUT", slave_mem[7'h04], 8'h5A);
        // Configuration port 0 should get ~joy_porta_oe (PCAL9722
        // convention: 1 = INPUT).
        expect_eq("A.PCAL[CFG0]=~PORTA_OE", slave_mem[7'h0C], 8'hF0);

        // ===== E — boot-time INT_MASK writes =======================
        // Three writes fire on first leaving reset: INT_MASK_0/1/2
        // landing at slave_mem $4A / $4B / $4C respectively.
        $display("[E] PCAL9722 INT_MASK init sequence");
        expect_eq("E.INT_MASK_0", slave_mem[7'h4A], 8'h00);   // PORTA all enabled
        expect_eq("E.INT_MASK_1", slave_mem[7'h4B], 8'h00);   // PORTB all enabled
        expect_eq("E.INT_MASK_2", slave_mem[7'h4C], 8'hF0);   // fire enabled, spares masked

        // ===== B — polled shadow ===================================
        $display("[B] polled shadow Input 0 / Input 1 / Input 2");
        slave_mem[7'h00] = 8'h7E;     // Input port 0 (= PORTA_IN)
        slave_mem[7'h01] = 8'hA5;     // Input port 1 (= PORTB_IN)
        slave_mem[7'h02] = 8'h09;     // Input port 2 (low nibble = TRIG)
        wait_one_poll_cycle();
        wait_one_poll_cycle();
        expect_eq("B.joy_porta_in", joy_porta_in, 8'h7E);
        expect_eq("B.joy_portb_in", joy_portb_in, 8'hA5);
        expect_eq("B.joy_fire",     {4'h0, joy_fire}, 8'h09);

        // ===== C — live tracking ===================================
        $display("[C] live write tracking");
        joy_porta_out = 8'hC3;
        joy_portb_oe  = 8'h33;
        wait_idle();
        expect_eq("C.PCAL[OUT0]=$C3",  slave_mem[7'h04], 8'hC3);
        expect_eq("C.PCAL[CFG1]=~$33", slave_mem[7'h0D], 8'hCC);

        // ===== D — TRIG nibble truncation ==========================
        $display("[D] TRIG nibble truncation");
        slave_mem[7'h02] = 8'hF6;     // upper nibble must NOT leak
        wait_one_poll_cycle();
        wait_one_poll_cycle();
        expect_eq("D.joy_fire", {4'h0, joy_fire}, 8'h06);

        if (fail_count == 0) begin
            $display("*** JOY_BRIDGE OK *** all checks passed");
            $finish;
        end else begin
            $display("*** JOY_BRIDGE FAIL *** %0d failures", fail_count);
            $fatal(1);
        end
    end

    initial begin
        #20_000_000;
        $display("FAIL: tb_joy_bridge watchdog");
        $fatal(1);
    end

endmodule
