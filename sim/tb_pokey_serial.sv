`timescale 1ns/1ps
`default_nettype none
//
// tb_pokey_serial — POKEY's serial shift timing.
//
// The behaviour that matters for ACID800 pokey_sertiming is the DOUBLE BUFFER:
// a write to SEROUT lands in a holding register, and the transfer into the
// shifter happens on a shift tick only when the shifter is idle. The test
// asserts on exactly that instant ("output register was loaded too early /
// too late"), so these checks pin the transfer, not the bit rate.
//
module tb_pokey_serial;

    logic clk = 0, rst = 1;
    always #5 clk = ~clk;

    logic [7:0] skctl;
    logic       timer2_pulse, timer4_pulse, ext_clk_tick;
    logic [7:0] serout_byte;
    logic       serout_strobe;

    wire        ser_out_ready_pulse, ser_out_complete, ser_out_bit;
    wire [3:0]  dbg_bitcnt;
    wire        dbg_holding_valid;

    pokey_serial dut (
        .clk(clk), .rst(rst),
        .skctl(skctl),
        .timer2_pulse(timer2_pulse), .timer4_pulse(timer4_pulse),
        .ext_clk_tick(ext_clk_tick),
        .serout_byte(serout_byte), .serout_strobe(serout_strobe),
        .ser_out_ready_pulse(ser_out_ready_pulse),
        .ser_out_complete(ser_out_complete),
        .ser_out_bit(ser_out_bit),
        .dbg_bitcnt(dbg_bitcnt), .dbg_holding_valid(dbg_holding_valid)
    );

    int fail = 0;
    int ready_count = 0;
    int before_cnt = 0;
    always @(posedge clk) if (!rst && ser_out_ready_pulse) ready_count++;

    // Stimulus on the negedge: driving at the posedge races the always_ff.
    // The DUT raises ser_out_ready_pulse on the cycle AFTER the transfer, so
    // settle one more edge before returning or the counter has not seen it.
    task automatic t2_tick;
        begin
            @(negedge clk); timer2_pulse = 1'b1;
            @(negedge clk); timer2_pulse = 1'b0;
            @(negedge clk);
        end
    endtask

    task automatic wr_serout(input [7:0] b);
        begin
            @(negedge clk); serout_byte = b; serout_strobe = 1'b1;
            @(negedge clk); serout_strobe = 1'b0;
        end
    endtask

    initial begin
        skctl = 8'h63;            // mode 11 -> timer 2, poly running
        timer2_pulse = 0; timer4_pulse = 0; ext_clk_tick = 0;
        serout_byte = 8'h00; serout_strobe = 0;
        repeat (3) @(posedge clk);
        rst = 0;
        @(posedge clk);

        // ---- T1: idle at reset -------------------------------------------
        if (!ser_out_complete) begin
            $display("FAIL T1: shifter not idle at reset"); fail++;
        end

        // ---- T2: a SEROUT write alone does NOT start a transfer ----------
        // The transfer only happens on a shift tick.  If this fired on the
        // write, the "loaded too early" assertion would trip.
        wr_serout(8'h55);
        if (ready_count != 0) begin
            $display("FAIL T2: transfer happened on the WRITE, not a shift tick");
            fail++;
        end
        if (!dbg_holding_valid) begin
            $display("FAIL T2b: byte did not land in the holding register"); fail++;
        end

        // ---- T3: the first shift tick performs the transfer --------------
        t2_tick();
        if (ready_count != 1) begin
            $display("FAIL T3: no transfer on the first shift tick (count=%0d)", ready_count);
            fail++;
        end
        if (ser_out_complete) begin
            $display("FAIL T3b: still reporting idle while shifting"); fail++;
        end
        if (ser_out_bit !== 1'b0) begin
            $display("FAIL T3c: start bit not low (got %b)", ser_out_bit); fail++;
        end

        // ---- T4: a full frame is 10 shift ticks --------------------------
        // One tick already consumed by the transfer above, so 9 more complete it.
        for (int i = 0; i < 9; i++) t2_tick();
        if (!ser_out_complete) begin
            $display("FAIL T4: frame not finished after 10 ticks (bitcnt=%0d)", dbg_bitcnt);
            fail++;
        end
        if (ready_count != 1) begin
            $display("FAIL T4b: spurious extra transfer (count=%0d)", ready_count);
            fail++;
        end

        // ---- T5: writing mid-frame does not disturb the shifter ----------
        wr_serout(8'hAA);
        t2_tick();                       // transfer #2 starts
        if (ready_count != 2) begin
            $display("FAIL T5: second byte did not transfer (count=%0d)", ready_count);
            fail++;
        end
        wr_serout(8'hF0);                // queued while shifting
        for (int i = 0; i < 5; i++) t2_tick();
        if (ready_count != 2) begin
            $display("FAIL T5b: queued byte transferred mid-frame (count=%0d)", ready_count);
            fail++;
        end

        // ---- T6: init mode halts the shift clock -------------------------
        skctl = 8'h60;                   // SKCTL[1:0] = 00 -> init
        for (int i = 0; i < 20; i++) t2_tick();
        if (ready_count != 2) begin
            $display("FAIL T6: shifting continued in init mode (count=%0d)", ready_count);
            fail++;
        end
        skctl = 8'h63;

        // ---- T7: timer 4 does not drive mode 11 --------------------------
        // Wrong-source ticks must be ignored, or the bit rate is wrong
        // whenever both timers are running.
        before_cnt = ready_count;
        for (int i = 0; i < 12; i++) begin
            @(negedge clk); timer4_pulse = 1'b1;
            @(negedge clk); timer4_pulse = 1'b0;
        end
        if (ready_count != before_cnt) begin
            $display("FAIL T7: timer 4 drove the shifter in timer-2 mode"); fail++;
        end

        if (fail == 0) $display("tb_pokey_serial: all checks PASS");
        else           $display("tb_pokey_serial: %0d FAIL", fail);
        $finish;
    end

endmodule

`default_nettype wire
