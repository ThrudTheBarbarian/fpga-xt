// tb_pokey_i2s.sv — M23-7 verification of pokey_i2s_tx (stereo).
//
// Drives the 8 channel-output wires (4 left from POKEY1 at $D20x,
// 4 right from POKEY2 at $D21x) and verifies:
//   A. sample_strobe rate matches SAMPLE_HZ (within rounding error
//      of the fractional divider).
//   B. last_sample_{l,r} mirrors the per-side channel sum, scaled
//      to 24-bit LPCM.
//   C. frame_ready pulses every 4 sample strobes.
//   D. audio_present = $F when frame_ready fires.
//   E. audio_l[i] / audio_r[i] reflect L/R independently (stereo
//      separation).
//   F. audio_flat[i] = 1 when both L and R for slot i were zero.
//   G. audio_block_start cycles every 192 sample strobes.

`timescale 1ns / 1ps

module tb_pokey_i2s;

    logic clk = 1'b0;
    always #5 clk = ~clk;            // 100 MHz fabric for sim
    logic rst = 1'b1;

    // Stereo channel outputs — testbench drives both POKEYs.
    logic [3:0] ch1l = 4'h0, ch2l = 4'h0, ch3l = 4'h0, ch4l = 4'h0;
    logic [3:0] ch1r = 4'h0, ch2r = 4'h0, ch3r = 4'h0, ch4r = 4'h0;

    wire [23:0] audio_l0, audio_l1, audio_l2, audio_l3;
    wire [23:0] audio_r0, audio_r1, audio_r2, audio_r3;
    wire [3:0]  audio_present, audio_flat, audio_block_start;
    wire        frame_ready;
    wire        sample_strobe;
    wire [23:0] last_sample_l, last_sample_r;

    // CLK_BUS_HZ = 1024, SAMPLE_HZ = 64 → divider = 16 (clean).
    // Fractional inc = 64 × 2^24 / 1024 = 1048576 → strobe every 16 clks.
    pokey_i2s_tx #(.CLK_BUS_HZ(1024),
                   .SAMPLE_HZ(64),
                   .PHASE_BITS(24)) u_dut (
        .clk               (clk),
        .rst               (rst),
        .ch1_l             (ch1l), .ch2_l (ch2l), .ch3_l (ch3l), .ch4_l (ch4l),
        .ch1_r             (ch1r), .ch2_r (ch2r), .ch3_r (ch3r), .ch4_r (ch4r),
        .adc_l_in          (24'sh0),       // M-aux-audio: no ADC in unit-level sim
        .adc_r_in          (24'sh0),
        .audio_l0          (audio_l0),  .audio_r0 (audio_r0),
        .audio_l1          (audio_l1),  .audio_r1 (audio_r1),
        .audio_l2          (audio_l2),  .audio_r2 (audio_r2),
        .audio_l3          (audio_l3),  .audio_r3 (audio_r3),
        .audio_present     (audio_present),
        .audio_flat        (audio_flat),
        .audio_block_start (audio_block_start),
        .frame_ready       (frame_ready),
        .sample_strobe     (sample_strobe),
        .last_sample_l     (last_sample_l),
        .last_sample_r     (last_sample_r)
    );

    int fail_count = 0;

    task automatic expect_eq(input string label,
                             input [31:0] got, input [31:0] want);
        if (got !== want) begin
            $display("FAIL %s: got=$%0h expected=$%0h", label, got, want);
            fail_count++;
        end
    endtask

    initial begin
        $display("=== M23-7 pokey_i2s_tx ===");

        // Hold reset for a few cycles, then release.
        repeat (4) @(posedge clk);
        rst = 1'b0;
        @(posedge clk);

        // ===== Phase A — sample_strobe rate ============================
        // With CLK_BUS_HZ=1024 and SAMPLE_HZ=64, expect 1 strobe every
        // 16 clks. Over 1024 clks we should see 64 strobes.
        $display("[A] sample_strobe rate");
        begin
            int strobes;
            strobes = 0;
            repeat (1024) begin
                @(posedge clk);
                if (sample_strobe) strobes = strobes + 1;
            end
            // Allow ±1 for boundary effects (the divider may be one
            // strobe ahead/behind depending on exact phase at start).
            if (strobes < 63 || strobes > 65) begin
                $display("FAIL A: %0d strobes in 1024 clks (expected 64)", strobes);
                fail_count++;
            end else begin
                $display("[A] %0d strobes / 1024 clks (expected ~64) OK", strobes);
            end
        end

        // ===== Phase B — channel sum → LPCM mapping ====================
        // Drive ch1..ch4 on the left side; right side stays silent.
        // Verify last_sample_l reflects the L sum and last_sample_r
        // stays at 0.
        $display("[B] LPCM mapping (left-only)");
        begin
            // sum = 1+2+3+4 = 10. lpcm = 10 << 18 = 2621440 = 24'h280000.
            ch1l = 4'd1;
            ch2l = 4'd2;
            ch3l = 4'd3;
            ch4l = 4'd4;
            // Wait for the next sample strobe.
            do @(posedge clk); while (!sample_strobe);
            expect_eq("B.10L", last_sample_l, 24'h280000);
            expect_eq("B.0R",  last_sample_r, 24'h000000);

            // Max sum on L: 15+15+15+15 = 60 → 24'hF00000.
            ch1l = 4'd15; ch2l = 4'd15; ch3l = 4'd15; ch4l = 4'd15;
            do @(posedge clk); while (!sample_strobe);
            expect_eq("B.60L", last_sample_l, 24'hF00000);

            // Silence: all zero.
            ch1l = 4'd0; ch2l = 4'd0; ch3l = 4'd0; ch4l = 4'd0;
            do @(posedge clk); while (!sample_strobe);
            expect_eq("B.0L", last_sample_l, 24'h000000);
        end

        // ===== Phase C — frame_ready every 4 strobes ===================
        $display("[C] frame_ready cadence");
        begin
            int strobes_between;
            int frames;
            strobes_between = 0;
            frames = 0;
            // Reset slot alignment by waiting until frame_ready fires.
            ch1l = 4'd5;       // make samples non-zero so flat is observable
            ch2l = 4'd0; ch3l = 4'd0; ch4l = 4'd0;
            do @(posedge clk); while (!frame_ready);
            // Now measure: the next 16 sample strobes should produce
            // exactly 4 frame_ready pulses.
            repeat (4) begin
                strobes_between = 0;
                do begin
                    @(posedge clk);
                    if (sample_strobe) strobes_between = strobes_between + 1;
                end while (!frame_ready);
                if (strobes_between != 4) begin
                    $display("FAIL C.frames: %0d strobes between frame_ready (expected 4)",
                             strobes_between);
                    fail_count++;
                end
                frames++;
            end
            $display("[C] observed %0d frame_ready pulses, 4 strobes apart each", frames);
        end

        // ===== Phase D — audio_present = $F on frame_ready =============
        $display("[D] audio_present");
        begin
            // Wait for next frame_ready and sample audio_present.
            do @(posedge clk); while (!frame_ready);
            // Sample on the next negedge so the NBA settles.
            @(negedge clk);
            expect_eq("D.present", audio_present, 4'hF);
        end

        // ===== Phase E — stereo independence (L != R) ==================
        // Drive different L and R levels; verify audio_l[i] reflects
        // L's sum and audio_r[i] reflects R's sum independently.
        $display("[E] stereo separation (L != R)");
        begin
            ch1l = 4'd7; ch2l = 4'd0; ch3l = 4'd0; ch4l = 4'd0;   // L sum = 7
            ch1r = 4'd2; ch2r = 4'd0; ch3r = 4'd0; ch4r = 4'd0;   // R sum = 2
            do @(posedge clk); while (!frame_ready);
            @(negedge clk);
            // 4 slots all see (L=7, R=2). audio_l[i] = 7<<18 = 24'h1C0000;
            // audio_r[i] = 2<<18 = 24'h080000.
            if (audio_l0 !== 24'h1C0000) begin
                $display("FAIL E.L0: $%06x expected $1C0000", audio_l0); fail_count++;
            end
            if (audio_r0 !== 24'h080000) begin
                $display("FAIL E.R0: $%06x expected $080000", audio_r0); fail_count++;
            end
            if (audio_l3 !== 24'h1C0000) begin
                $display("FAIL E.L3: $%06x expected $1C0000", audio_l3); fail_count++;
            end
            if (audio_r3 !== 24'h080000) begin
                $display("FAIL E.R3: $%06x expected $080000", audio_r3); fail_count++;
            end
            // Reset right back to zero before subsequent phases.
            ch1r = 4'd0; ch2r = 4'd0; ch3r = 4'd0; ch4r = 4'd0;
        end

        // ===== Phase F — audio_flat per-subpacket silence detect =======
        $display("[F] audio_flat detect");
        begin
            // Drive a sequence: silence, tone, silence, tone within a
            // single 4-sample frame. Walk the ring buffer through.
            // Easiest: align to a frame boundary first.
            ch1l = 4'd0; ch2l = 4'd0; ch3l = 4'd0; ch4l = 4'd0;
            do @(posedge clk); while (!frame_ready);
            // Now we're at the start of a fresh slot 0.
            // Slot 0 = silence (ch1l=0), slot 1 = tone, slot 2 = silence,
            // slot 3 = tone. Need to switch ch1l between strobes.
            // Strobe cadence is 16 clks; switch a couple cycles before
            // each strobe to make the change land cleanly.
            // Slot 0: silence (already set).
            do @(posedge clk); while (!sample_strobe);
            // After strobe 0 — set slot 1 to tone.
            ch1l = 4'd5;
            do @(posedge clk); while (!sample_strobe);
            // After strobe 1 — set slot 2 to silence.
            ch1l = 4'd0;
            do @(posedge clk); while (!sample_strobe);
            // After strobe 2 — set slot 3 to tone.
            ch1l = 4'd5;
            do @(posedge clk); while (!sample_strobe);
            // After strobe 3 — frame_ready should fire imminently.
            // (Frame_ready fires the same cycle as the slot-3 strobe.)
            @(negedge clk);
            // Expect flat = 4'b0101 (slots 0 and 2 are zero).
            expect_eq("F.flat", audio_flat, 4'b0101);
        end

        // ===== Phase G — audio_block_start cycles every 192 strobes ====
        // Catching the transition: one of every 48 frames (192/4) has
        // a non-zero block_start mask. Run 200 frame-readys and verify
        // we see at least 4 non-zero block_start pulses (200/48 ≈ 4.17).
        $display("[G] audio_block_start cycles");
        begin
            int frames_with_block;
            frames_with_block = 0;
            ch1l = 4'd1; ch2l = 4'd0; ch3l = 4'd0; ch4l = 4'd0;
            repeat (200) begin
                do @(posedge clk); while (!frame_ready);
                if (audio_block_start != 4'h0) frames_with_block++;
            end
            if (frames_with_block < 3 || frames_with_block > 6) begin
                $display("FAIL G: %0d frames with block_start (expected ~4)",
                         frames_with_block);
                fail_count++;
            end else begin
                $display("[G] %0d / 200 frames carried block_start (expected ~4)",
                         frames_with_block);
            end
        end

        if (fail_count == 0) begin
            $display("*** POKEY_I2S OK *** strobe + LPCM map + ring buffer + flat + block_start");
            $finish;
        end else begin
            $display("*** POKEY_I2S FAIL *** %0d failures", fail_count);
            $fatal(1);
        end
    end

    initial begin
        #20_000_000;
        $display("FAIL: tb_pokey_i2s watchdog");
        $fatal(1);
    end

endmodule
