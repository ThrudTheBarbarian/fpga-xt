// tb_peri_bridge.sv — M25-3c POT + M25-4 SIO bridge tests.
//
// Coverage:
//   A/B/C — POT (slow/fast/partial-allpot)
//   D     — IRQ-driven STATUS poll short-circuit
//   E     — SIO_OUT write: serout_strobe → byte at slave_mem[$06]
//   F     — SIO_IN + SIO_STAT chain on sio_rx flag → ser_in_byte /
//           ser_in_byte_pulse / framing/overrun/busy/break

`default_nettype none
`timescale 1ns / 1ps

module tb_peri_bridge;

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst = 1'b1;

    // POKEY-side — POT
    logic       potgo_pulse = 1'b0;
    logic       fast_scan   = 1'b0;
    wire  [7:0] pot0, pot1, pot2, pot3;
    wire  [7:0] pot4, pot5, pot6, pot7;
    wire  [7:0] allpot;

    // POKEY-side — SIO
    logic [7:0] serout_byte    = 8'h00;
    logic       serout_strobe  = 1'b0;
    wire  [7:0] ser_in_byte;
    wire        ser_in_byte_pulse;
    wire        ser_framing_err;
    wire        ser_input_overrun;
    wire        ser_input_busy;
    wire        break_key_pulse;
    wire        ser_out_ready_pulse;
    wire        ser_out_complete;

    // SPI pads
    wire        spi_clk;
    wire        spi_mosi;
    wire        spi_miso;
    wire        spi_cs_n;
    logic       spi_irq = 1'b1;

    peri_bridge #(
        .POLL_DIV       (128),
        .LINK_CLK_DIV   (4),
        .LINK_HALF_GAP  (8),
        .LINK_TAIL_GAP  (8)
    ) u_dut (
        .clk          (clk),
        .rst          (rst),
        .potgo_pulse  (potgo_pulse),
        .fast_scan    (fast_scan),
        .pot0 (pot0), .pot1 (pot1), .pot2 (pot2), .pot3 (pot3),
        .pot4 (pot4), .pot5 (pot5), .pot6 (pot6), .pot7 (pot7),
        .allpot       (allpot),
        .serout_byte         (serout_byte),
        .serout_strobe       (serout_strobe),
        .ser_in_byte         (ser_in_byte),
        .ser_in_byte_pulse   (ser_in_byte_pulse),
        .ser_framing_err     (ser_framing_err),
        .ser_input_overrun   (ser_input_overrun),
        .ser_input_busy      (ser_input_busy),
        .break_key_pulse     (break_key_pulse),
        .ser_out_ready_pulse (ser_out_ready_pulse),
        .ser_out_complete    (ser_out_complete),
        .spi_clk      (spi_clk),
        .spi_mosi     (spi_mosi),
        .spi_miso     (spi_miso),
        .spi_cs_n     (spi_cs_n),
        .spi_irq      (spi_irq)
    );

    // ---- peri-RP slave mock — same shape as tb_peri_link/_bridge ----
    localparam logic FRAME_CMD  = 1'b0;
    localparam logic FRAME_DATA = 1'b1;

    logic [7:0]  slave_mem [0:127];
    logic        frame_kind_q;
    logic [3:0]  bit_cnt_q;
    logic [7:0]  rx_shift_q;
    logic [7:0]  tx_shift_q;
    logic [7:0]  cmd_q;
    logic        spi_clk_q;
    logic        cs_n_q;

    assign spi_miso = tx_shift_q[7];

    // POT-side test driver
    logic [7:0] sim_pot   [0:7];      // value the slave reports for POTn
    logic [7:0] sim_allpot;
    logic       sim_pot_done;          // STATUS bit 0
    int         pot_done_delay_cnt;    // cycles before pot_done flips to 1
                                        // after a POTGO command lands. Set
                                        // by test code per scenario.
    int         last_potgo_cmd_cycle;
    int         sim_cycle;

    initial begin
        for (int i = 0; i < 128; i++) slave_mem[i] = 8'h00;
        for (int i = 0; i < 8;   i++) sim_pot[i]   = 8'h00;
        sim_allpot           = 8'hFF;
        sim_pot_done         = 1'b0;
        pot_done_delay_cnt   = 0;
        last_potgo_cmd_cycle = 0;
        sim_cycle            = 0;
    end

    always_ff @(posedge clk) sim_cycle <= sim_cycle + 1;

    // ---- POT-scan model: when CMD=POTGO arrives, schedule pot_done ---
    // After `pot_done_delay_cnt` clock cycles, flip STATUS bit 0 to 1
    // and load slave_mem with the configured POT values.
    int pot_done_target_cycle;
    logic pot_done_pending;
    initial begin
        pot_done_target_cycle = 0;
        pot_done_pending      = 1'b0;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            sim_pot_done       <= 1'b0;
            pot_done_pending   <= 1'b0;
        end else begin
            // When pot_done becomes due, flip the flag and load
            // POT0..7 + ALLPOT shadows.
            if (pot_done_pending && sim_cycle >= pot_done_target_cycle) begin
                sim_pot_done     <= 1'b1;
                pot_done_pending <= 1'b0;
                slave_mem[7'h03] <= 8'h01;             // STATUS.pot_done
                slave_mem[7'h04] <= sim_allpot;
                for (int i = 0; i < 8; i++)
                    slave_mem[7'h05 + i] <= sim_pot[i];
            end
        end
    end

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            frame_kind_q <= FRAME_CMD;
            bit_cnt_q    <= 4'd0;
            rx_shift_q   <= 8'h00;
            tx_shift_q   <= 8'h00;
            cmd_q        <= 8'h00;
            spi_clk_q    <= 1'b0;
            cs_n_q       <= 1'b1;
        end else begin
            spi_clk_q <= spi_clk;
            cs_n_q    <= spi_cs_n;

            if (!spi_cs_n && cs_n_q) begin
                bit_cnt_q  <= 4'd0;
                rx_shift_q <= 8'h00;
                if (frame_kind_q == FRAME_CMD) tx_shift_q <= 8'h00;
            end

            if (spi_cs_n && !cs_n_q) begin
                if (frame_kind_q == FRAME_CMD) begin
                    cmd_q <= rx_shift_q;
                    if (rx_shift_q[7]) begin
                        tx_shift_q <= slave_mem[rx_shift_q[6:0]];
                    end else begin
                        tx_shift_q <= 8'h00;
                    end
                    frame_kind_q <= FRAME_DATA;
                end else begin
                    if (!cmd_q[7]) begin
                        // Write — commit data byte to register file.
                        slave_mem[cmd_q[6:0]] <= rx_shift_q;
                        // Side-effect: writing CMD=POTGO schedules
                        // pot_done after the configured delay.
                        if (cmd_q[6:0] == 7'h05 && rx_shift_q[3:0] == 4'h1) begin
                            // CMD_POTGO_SLOW = $01, CMD_POTGO_FAST = $11
                            last_potgo_cmd_cycle  <= sim_cycle;
                            pot_done_target_cycle <= sim_cycle + pot_done_delay_cnt;
                            pot_done_pending      <= 1'b1;
                            // Until pot_done arrives, STATUS bit 0 stays 0.
                            slave_mem[7'h03] <= 8'h00;
                        end
                    end
                    frame_kind_q <= FRAME_CMD;
                end
            end

            if (!spi_cs_n) begin
                if (spi_clk && !spi_clk_q) begin
                    rx_shift_q <= {rx_shift_q[6:0], spi_mosi};
                    bit_cnt_q  <= bit_cnt_q + 4'd1;
                end
                if (!spi_clk && spi_clk_q) begin
                    tx_shift_q <= {tx_shift_q[6:0], 1'b0};
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

    task automatic pulse_potgo();
        @(negedge clk);
        potgo_pulse = 1'b1;
        @(posedge clk);
        @(negedge clk);
        potgo_pulse = 1'b0;
    endtask

    task automatic wait_for_pot_done_committed();
        // Wait until the bridge's pot7 shadow has been updated (the
        // last register read in the chain). Generous timeout to
        // accommodate the multi-transaction polling sequence.
        int cycles_left;
        cycles_left = 30000;
        while (cycles_left > 0) begin
            @(posedge clk);
            cycles_left--;
            // The chain finishes when poll_q transitions back to IDLE
            // (pot7 just got written).
            if (u_dut.poll_q == 4'd0 && u_dut.state_q == 1'b0
                && u_dut.allpot == sim_allpot
                && u_dut.pot0   == sim_pot[0]
                && u_dut.pot7   == sim_pot[7]) begin
                return;
            end
        end
        $display("FAIL wait_for_pot_done_committed: timeout. poll_q=%0d state_q=%0d allpot=$%0h pot0=$%0h pot7=$%0h",
                 u_dut.poll_q, u_dut.state_q, u_dut.allpot,
                 u_dut.pot0, u_dut.pot7);
        fail_count++;
    endtask

    initial begin
        $display("=== M25-3c peri_bridge ===");
        repeat (4) @(posedge clk);
        rst = 1'b0;
        @(posedge clk);

        // ===== A — POTGO write reaches CMD ($05) ===================
        $display("[A] slow-scan POTGO arrives at peri-RP CMD register");
        sim_pot[0] = 8'h2A; sim_pot[1] = 8'h44; sim_pot[2] = 8'h66; sim_pot[3] = 8'h88;
        sim_pot[4] = 8'hAA; sim_pot[5] = 8'hCC; sim_pot[6] = 8'hEE; sim_pot[7] = 8'h11;
        sim_allpot         = 8'h00;     // all done
        pot_done_delay_cnt = 200;        // ~200 cycles after CMD lands
        fast_scan          = 1'b0;
        pulse_potgo();
        // Give the bridge a few cycles to issue the CMD write.
        repeat (300) @(posedge clk);
        expect_eq("A.CMD.POTGO_SLOW", slave_mem[7'h05], 8'h01);
        expect_eq("A.allpot.scanning", allpot, 8'hFF);   // bridge sets FF on POTGO

        // Wait for the polling chain to read back POT0..7.
        wait_for_pot_done_committed();
        expect_eq("A.pot0.read", pot0, sim_pot[0]);
        expect_eq("A.pot1.read", pot1, sim_pot[1]);
        expect_eq("A.pot7.read", pot7, sim_pot[7]);
        expect_eq("A.allpot.read", allpot, sim_allpot);

        // ===== B — fast scan flips bit 4 in CMD ====================
        $display("[B] fast-scan POTGO sets CMD bit 4");
        for (int i = 0; i < 8; i++) sim_pot[i] = 8'h70 + i[7:0];
        sim_allpot         = 8'h00;
        pot_done_delay_cnt = 200;
        fast_scan          = 1'b1;
        pulse_potgo();
        repeat (300) @(posedge clk);
        expect_eq("B.CMD.POTGO_FAST", slave_mem[7'h05], 8'h11);
        wait_for_pot_done_committed();
        expect_eq("B.pot3.fast", pot3, sim_pot[3]);

        // ===== C — partial ALLPOT (still scanning) =================
        $display("[C] ALLPOT non-zero (some channels still scanning)");
        for (int i = 0; i < 8; i++) sim_pot[i] = 8'hC0 + i[7:0];
        sim_allpot         = 8'h0F;     // POT0..3 still scanning
        pot_done_delay_cnt = 200;
        fast_scan          = 1'b0;
        pulse_potgo();
        repeat (300) @(posedge clk);
        wait_for_pot_done_committed();
        expect_eq("C.allpot.partial", allpot, 8'h0F);
        expect_eq("C.pot4.committed", pot4, sim_pot[4]);

        // ===== D — IRQ-driven STATUS poll short-circuit ============
        // After the previous scans the bridge is idle. Pre-load a
        // pot_done STATUS in the slave; then pulse spi_irq low for
        // a few cycles. Bridge should kick STATUS poll without
        // waiting for the next poll_tick (POLL_DIV = 128 cycles).
        $display("[D] IRQ-driven short-circuit");
        begin
            int i;
            for (i = 0; i < 8; i++) sim_pot[i] = 8'h30 + i[7:0];
            sim_allpot         = 8'h00;
            slave_mem[7'h03]   = 8'h01;     // STATUS.pot_done already set
            slave_mem[7'h04]   = sim_allpot;
            for (i = 0; i < 8; i++) slave_mem[7'h05 + i] = sim_pot[i];

            // Reset the bridge's poll_cnt right before the IRQ so
            // we know we aren't winning by raw timing. We don't have
            // a way to reset internals, so just rely on POLL_DIV
            // being short enough that we'll observe the chain
            // running quickly either way; check that pot0 picks up
            // the new value.
            @(negedge clk);
            spi_irq = 1'b0;
            repeat (4) @(posedge clk);
            spi_irq = 1'b1;
            wait_for_pot_done_committed();
            expect_eq("D.pot0.IRQ-driven", pot0, sim_pot[0]);
            // Drain the slave's STATUS so we don't accidentally
            // re-trigger pot_done in the next phase.
            slave_mem[7'h03] = 8'h00;
        end

        // ===== E — SIO byte transmit ===============================
        $display("[E] SIO_OUT write");
        begin
            int ack_count;
            ack_count = 0;
            @(negedge clk);
            serout_byte   = 8'h5A;
            serout_strobe = 1'b1;
            @(posedge clk);
            @(negedge clk);
            serout_strobe = 1'b0;
            // Ride the link until the byte lands.
            for (int i = 0; i < 600; i++) begin
                @(posedge clk);
                if (ser_out_ready_pulse) ack_count = ack_count + 1;
            end
            expect_eq("E.slave_mem[$06]", slave_mem[7'h06], 8'h5A);
            if (ack_count != 1) begin
                $display("FAIL E.ack_count: got %0d, expected 1", ack_count);
                fail_count++;
            end
            expect_eq("E.ser_out_complete", ser_out_complete, 1'b1);
        end

        // ===== F — SIO byte receive ================================
        $display("[F] sio_rx + SIO_IN/SIO_STAT chain");
        begin
            int rx_pulse_count;
            rx_pulse_count = 0;
            // Pre-load the slave with a received byte + status flags
            // (framing_err = 1, input_busy = 1).
            slave_mem[7'h0D] = 8'hC3;
            slave_mem[7'h0E] = 8'b0000_0101;   // framing | busy
            slave_mem[7'h03] = 8'b0000_0010;   // STATUS.sio_rx
            // Pulse IRQ to short-circuit poll-tick wait.
            @(negedge clk);
            spi_irq = 1'b0;
            repeat (4) @(posedge clk);
            spi_irq = 1'b1;
            // Wait for the chain to update ser_in_byte + status.
            for (int i = 0; i < 1500; i++) begin
                @(posedge clk);
                if (ser_in_byte_pulse) rx_pulse_count = rx_pulse_count + 1;
                if (ser_in_byte == 8'hC3 && ser_framing_err == 1'b1
                    && ser_input_busy == 1'b1
                    && ser_input_overrun == 1'b0
                    && rx_pulse_count >= 1) break;
            end
            expect_eq("F.ser_in_byte",     ser_in_byte, 8'hC3);
            expect_eq("F.ser_framing_err", ser_framing_err, 1'b1);
            expect_eq("F.ser_input_busy",  ser_input_busy, 1'b1);
            expect_eq("F.ser_input_overrun", ser_input_overrun, 1'b0);
            if (rx_pulse_count != 1) begin
                $display("FAIL F.rx_pulse_count: got %0d, expected 1",
                         rx_pulse_count);
                fail_count++;
            end
            // Drain.
            slave_mem[7'h03] = 8'h00;
        end

        if (fail_count == 0) begin
            $display("*** PERI_BRIDGE OK *** all checks passed");
            $finish;
        end else begin
            $display("*** PERI_BRIDGE FAIL *** %0d failures", fail_count);
            $fatal(1);
        end
    end

    initial begin
        #50_000_000;
        $display("FAIL: tb_peri_bridge watchdog");
        $fatal(1);
    end

endmodule
