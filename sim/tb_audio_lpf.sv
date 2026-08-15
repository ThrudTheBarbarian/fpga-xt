`timescale 1ns/1ps
`default_nettype none
//
// tb_audio_lpf — does the anti-alias filter actually stop the aliasing?
//
// Simon's report on the first working HDMI audio was that the melody is clearly
// there but the sound is "harsh", "rough", and possibly saturating.  That is the
// signature of decimating a megahertz-rate square-wave source straight down to
// 48 kHz: the fundamentals are under Nyquist and survive, everything above folds
// back as inharmonic hash.  So the filter has one job, and this bench measures
// whether it does it — in dB, not by assertion.
//
// Three measurements, each of which is a way the filter could be wrong while
// looking plausible in a waveform viewer:
//
//   1. DC GAIN — a constant input must come out unchanged (after centring and
//      the headroom shift).  A leaky integrator with the wrong shift has a gain
//      that is close to, but not exactly, one; that error would show up as a
//      level and offset error rather than as anything audible, and so would
//      survive listening tests.
//   2. PASSBAND — a 1 kHz square must come through with most of its amplitude.
//      A filter that fixes harshness by removing the music is not a fix.
//   3. STOPBAND — a 40 kHz square (which decimation would fold to 8 kHz, right
//      in the ear's most sensitive region) must come back substantially
//      attenuated.  This is the number that matters.
//
module tb_audio_lpf;

    localparam int unsigned CLK_HZ  = 150_000_000;
    localparam real         HALF_NS = 500.0e6 / real'(CLK_HZ);

    logic clk = 0, rst = 1;
    always #(HALF_NS) clk = ~clk;

    logic [23:0] in_l = 24'h000000, in_r = 24'h000000;
    wire signed [23:0] out_l, out_r;

    audio_lpf dut (.clk(clk), .rst(rst), .in_l(in_l), .in_r(in_r),
                   .out_l(out_l), .out_r(out_r));

    // POKEY's full scale, as pokey_i2s_tx presents it: 60 << 18.
    localparam logic [23:0] FULL = 24'hF00000;
    localparam logic [23:0] MID  = 24'h780000;

    int errors = 0;

    // Peak tracking has to run on the CLOCK, not once per stimulus cycle: the
    // filter output moves continuously, so sampling it at one phase per period
    // finds the same value every time and reports a peak-to-peak of zero.
    logic meas_en = 0;
    int   pk_lo, pk_hi;
    always @(posedge clk) if (meas_en) begin
        if (out_l < pk_lo) pk_lo <= out_l;
        if (out_l > pk_hi) pk_hi <= out_l;
    end

    // Drive a square wave of `hz` for `cycles` periods and return peak-to-peak
    // of the output, measured over the last third (once the filter has settled).
    task automatic measure_square(input real hz, input int cycles,
                                  output int pp);
        realtime half_ns;
        int      i;
        begin
            half_ns = 1.0e9 / (hz * 2.0);
            meas_en = 0;
            pk_lo   = 32'sh7FFFFFFF;
            pk_hi   = -32'sh7FFFFFFF;
            for (i = 0; i < cycles; i++) begin
                if (i == (cycles * 2) / 3) meas_en = 1;
                in_l = FULL; #(half_ns);
                in_l = 24'h0; #(half_ns);
            end
            meas_en = 0;
            pp = pk_hi - pk_lo;
        end
    endtask

    real db_pass, db_stop;
    int  pp_dc, pp_1k, pp_40k;

    initial begin
        repeat (10) @(posedge clk);
        rst = 0;

        $display("");
        $display("=== tb_audio_lpf ===");

        // ---- 1. DC gain -----------------------------------------------------
        // Hold full scale long enough for two poles at ~11.6 kHz to settle.
        in_l = FULL; in_r = 24'h000000;
        #2_000_000;                                  // 2 ms
        begin
            // Signed arithmetic in `int`, NOT 24-bit: the right channel is held
            // at zero, so its centred value is negative and a 24-bit expression
            // would wrap into a huge positive.
            int want_l, want_r, tol;
            want_l = (int'(FULL) - int'(MID)) >>> 1;   // centred, then -6 dB
            want_r = (0          - int'(MID)) >>> 1;
            tol    = (want_l > 0 ? want_l : -want_l) / 100;   // 1 %
            if (out_l < want_l - tol || out_l > want_l + tol) begin
                $display("  FAIL dc gain L: got %0d want ~%0d", out_l, want_l);
                errors++;
            end else
                $display("  ok   dc gain L        %0d (want ~%0d)", out_l, want_l);
            if (out_r < want_r - tol || out_r > want_r + tol) begin
                $display("  FAIL dc gain R: got %0d want ~%0d", out_r, want_r);
                errors++;
            end else
                $display("  ok   dc gain R        %0d (want ~%0d)", out_r, want_r);
        end

        // ---- 2. passband: 1 kHz ---------------------------------------------
        measure_square(1000.0, 24, pp_1k);
        $display("  1 kHz  peak-to-peak = %0d", pp_1k);

        // ---- 3. stopband: 40 kHz (folds to 8 kHz when decimated) -------------
        measure_square(40000.0, 1200, pp_40k);
        $display("  40 kHz peak-to-peak = %0d", pp_40k);

        if (pp_1k <= 0 || pp_40k < 0) begin
            $display("  FAIL degenerate measurement");
            errors++;
        end else begin
            db_stop = 20.0 * $log10(real'(pp_40k <= 0 ? 1 : pp_40k) / real'(pp_1k));
            $display("  40 kHz relative to 1 kHz = %.1f dB", db_stop);
            // A square at 40 kHz is 1.6 octaves above an 11.6 kHz corner; two
            // poles should put it at least 15 dB down.  Without the filter this
            // number is ~0 dB and every bit of it aliases into the audio band.
            if (db_stop > -15.0) begin
                $display("  FAIL stopband: 40 kHz only %.1f dB down (want <= -15)", db_stop);
                errors++;
            end else
                $display("  ok   stopband rejection");
            // and the passband must survive
            if (pp_1k < (FULL >> 2)) begin
                $display("  FAIL passband: 1 kHz lost too much (%0d)", pp_1k);
                errors++;
            end else
                $display("  ok   passband preserved");
        end

        $display("");
        if (errors == 0) $display("tb_audio_lpf: PASS");
        else             $display("tb_audio_lpf: FAIL (%0d)", errors);
        $finish;
    end

    initial begin
        #500_000_000;
        $display("tb_audio_lpf: FAIL (timeout)");
        $finish;
    end

endmodule

`default_nettype wire
