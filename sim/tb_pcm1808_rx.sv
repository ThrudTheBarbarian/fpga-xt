// tb_pcm1808_rx.sv — exercise pcm1808_rx by driving a synthetic
// PCM1808-style I²S slave in the testbench. Two known L/R samples are
// emitted via SDATA in response to the DUT's BCK + LRCK; checks that
// adc_l / adc_r latch the expected values and adc_strobe pulses once
// per stereo frame.

`default_nettype none
`timescale 1ns / 1ps

module tb_pcm1808_rx;

    // 161 MHz clk_bus (matches the production default).
    logic clk = 1'b0;
    always #3.103 clk = ~clk;       // 161.08 MHz: half = 3.103 ns

    logic rst = 1'b1;

    wire adc_bclk;
    wire adc_lrck;
    logic adc_sdata = 1'b0;

    wire signed [23:0] adc_l;
    wire signed [23:0] adc_r;
    wire adc_strobe;

    pcm1808_rx #(
        .CLK_BUS_HZ (161_079_525),
        .SAMPLE_HZ  (48_000),
        .PHASE_BITS (24)
    ) u_dut (
        .clk        (clk),
        .rst        (rst),
        .adc_bclk_o (adc_bclk),
        .adc_lrck_o (adc_lrck),
        .adc_sdata_i(adc_sdata),
        .adc_l      (adc_l),
        .adc_r      (adc_r),
        .adc_strobe (adc_strobe)
    );

    // ---- Synthetic PCM1808 slave ------------------------------------
    // Drives SDATA combinationally based on the DUT's bit_cnt + lrck
    // state, sampled via hierarchical reference. Much simpler than
    // tracking BCK/LRCK edges in clk_bus — the DUT already knows where
    // it is in the LRCK frame, so we just emit the corresponding bit
    // of the appropriate sample.
    //
    // I²S left-justified: bit_cnt 0..23 = MSB..LSB of the current
    // channel, bit_cnt 24..31 = padding (drive 0).
    logic signed [23:0] tx_l_sample = 24'h00_0000;
    logic signed [23:0] tx_r_sample = 24'h00_0000;
    wire [4:0] dut_bit_cnt = u_dut.bit_cnt_q;
    wire       dut_lrck    = u_dut.lrck_q;

    always @(*) begin
        if (dut_bit_cnt <= 5'd23) begin
            // 23 - bit_cnt = which MSB-down position to drive
            if (dut_lrck == 1'b0)
                adc_sdata = tx_l_sample[23 - dut_bit_cnt];
            else
                adc_sdata = tx_r_sample[23 - dut_bit_cnt];
        end else begin
            adc_sdata = 1'b0;
        end
    end

    // ---- Test harness ------------------------------------------------
    int errors = 0;
    task automatic expect_signed(input string label,
                                 input signed [23:0] got,
                                 input signed [23:0] expect_);
        if (got !== expect_) begin
            $display("FAIL %s: got=%06h expected=%06h", label, got, expect_);
            errors++;
        end
    endtask

    int strobe_count;
    always @(posedge clk) if (adc_strobe) strobe_count++;

    initial begin
        $display("=== M-aux-audio tb_pcm1808_rx ===");
        strobe_count = 0;

        // ===== Phase A — initial sample =================================
        // Set tx values BEFORE rst deasserts so the FIRST channels capture
        // them. Wait for ENOUGH strobes that both L and R have been
        // captured at least once with the new values (each strobe latches
        // R; L was latched in the prior half-frame, so 2 strobes ensures
        // a full L+R round-trip after the values were set).
        tx_l_sample = 24'h12_3456;
        tx_r_sample = 24'h78_9ABC;

        repeat (20) @(posedge clk);
        rst = 1'b0;

        // After rst deasserts, the first 32 BCK rises run in the initial
        // R channel (lrck=1, no preceding LRCK transition → MSB is missed
        // by 1 BCK fall). Wait through one full LRCK period to skip the
        // initial-channel quirk; then the next L+R cycle captures cleanly.
        @(posedge adc_strobe);   // first strobe (R, partial)
        @(posedge clk);
        @(posedge adc_strobe);   // second strobe (R, fully captured)
        @(posedge clk);

        $display("[A] adc_l=%06h adc_r=%06h", adc_l, adc_r);
        expect_signed("adc_l = $123456", adc_l, 24'h12_3456);
        expect_signed("adc_r = $789ABC", adc_r, 24'h78_9ABC);

        // ===== Phase B — different L, same R =========================
        $display("[B] update L only");
        tx_l_sample = 24'hA5_5A5A;
        // tx_r_sample unchanged ($789ABC)

        @(posedge adc_strobe);
        @(posedge clk);
        @(posedge adc_strobe);   // 2nd strobe for clean capture
        @(posedge clk);

        $display("[B] adc_l=%06h adc_r=%06h", adc_l, adc_r);
        expect_signed("adc_l = $A55A5A", adc_l, 24'hA5_5A5A);
        expect_signed("adc_r = $789ABC",  adc_r, 24'h78_9ABC);

        // ===== Phase C — negative-looking signed value ===============
        $display("[C] full-negative L (MSB = 1)");
        tx_l_sample = 24'h80_0000;     // most-negative signed 24
        tx_r_sample = 24'h7F_FFFF;     // most-positive signed 24

        @(posedge adc_strobe);
        @(posedge clk);
        @(posedge adc_strobe);
        @(posedge clk);

        $display("[C] adc_l=%06h adc_r=%06h", adc_l, adc_r);
        expect_signed("adc_l = $800000",  adc_l, 24'h80_0000);
        expect_signed("adc_r = $7FFFFF",  adc_r, 24'h7F_FFFF);

        // ===== Phase D — strobe count plausible ======================
        // strobe_count should have ticked at least once per frame above.
        // We hit `wait (adc_strobe)` four times → strobe_count ≥ 4.
        $display("[D] strobe_count = %0d (expect >= 4)", strobe_count);
        if (strobe_count < 4) begin
            $display("FAIL: strobe never pulsed enough times");
            errors++;
        end

        // ===== Summary ===============================================
        if (errors == 0) begin
            $display("*** PCM1808_RX OK ***");
            $finish;
        end else begin
            $display("*** PCM1808_RX FAIL *** %0d failures", errors);
            $fatal(1);
        end
    end

    initial begin
        #50_000_000;
        $display("FAIL: tb_pcm1808_rx watchdog");
        $fatal(1);
    end

endmodule

`default_nettype wire
