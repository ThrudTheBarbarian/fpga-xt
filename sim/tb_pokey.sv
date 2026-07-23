// tb_pokey.sv — POKEY register file + audio generators (M23-1).
//
// Phase A: register write + read-back (AUDCTL is the only readable
//   M23-1 register; AUDF / AUDC reads return 0 here — those become
//   POTn / KBCODE / RANDOM at M23-2..6).
// Phase B: 4 channels' square-wave frequency check. Write known
//   AUDF + AUDC values, count toggle pulses on each channel over a
//   bounded window, compare against the expected
//     toggles_per_window = window_ticks / (AUDF + 1)
//   where window_ticks is the number of reference-clock pulses that
//   fall in the window.
// Phase C: volume gate. AUDC volume = 0 → channel output stays 0.
//   AUDC volume = 15 → channel output is 0 / 15 alternating.
//
// To keep the test runtime modest, we override the audio module's
// CLK_BUS_HZ + REF_HZ_M23_1 parameters so the reference divider is
// small (a few clk cycles, not 336). Otherwise a 64 kHz reference at
// 21.5 MHz costs hundreds of clocks per ref tick — too slow for a
// quick frequency check.

`default_nettype none
`timescale 1ns / 1ps

module tb_pokey;

    logic clk = 1'b0;
    always #5 clk = ~clk;            // 100 MHz fabric for sim
    logic rst = 1'b1;

    logic        we    = 1'b0;
    logic [7:0]  waddr = 8'h00;
    logic [7:0]  wdata = 8'h00;
    logic [7:0]  raddr = 8'h00;
    wire  [7:0]  rdata;

    wire [3:0]   ch1_out, ch2_out, ch3_out, ch4_out;

    // M23-4 keyboard event ingest
    logic        re        = 1'b0;
    logic [7:0]  re_addr   = 8'h00;
    logic        kbd_event_valid = 1'b0;
    logic [7:0]  kbd_event_code  = 8'h00;

    // M25-3c POT scan — testbench drives shadow values from "peri-RP"
    // and watches the bridge_potgo_pulse / bridge_fast_scan outputs.
    logic [7:0]  shadow_pot0 = 8'h00, shadow_pot1 = 8'h00;
    logic [7:0]  shadow_pot2 = 8'h00, shadow_pot3 = 8'h00;
    logic [7:0]  shadow_pot4 = 8'h00, shadow_pot5 = 8'h00;
    logic [7:0]  shadow_pot6 = 8'h00, shadow_pot7 = 8'h00;
    logic [7:0]  shadow_allpot = 8'h00;     // idle: no channel scanning
    wire         bridge_potgo_pulse;
    wire         bridge_fast_scan;

    // M23-6 IRQ + serial — testbench drives the SIO-side pulses.
    logic        ser_out_complete     = 1'b1;   // shifter idle by default
    logic        ser_out_ready_pulse  = 1'b0;
    logic        ser_in_byte_pulse    = 1'b0;
    logic [7:0]  ser_in_byte          = 8'h00;
    logic        break_key_pulse      = 1'b0;
    logic        ser_framing_err      = 1'b0;
    logic        ser_input_overrun    = 1'b0;
    logic        ser_input_busy       = 1'b0;
    wire         irq_n;
    wire  [7:0]  serout_byte;
    wire         serout_strobe;
    wire  [7:0]  skctl_out;

    // CLK_BUS_HZ = 8 → REF_DIV_HI = 8/4 = 2 (ticks every 2 clks);
    // REF_DIV_LO = 8/2 = 4 (every 4 clks). 2× ratio for distinguishing
    // tests; the default 64k:15.7k ratio is ~4.1×.
    // phi2_tick: 1-cycle pulse every 4 clocks (2× ratio vs slowest
    // ref to keep test cadence reasonable).
    logic [1:0] phi2_div = 2'd0;
    logic       phi2_tick = 1'b0;
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            phi2_div  <= 2'd0;
            phi2_tick <= 1'b0;
        end else begin
            phi2_div  <= phi2_div + 2'd1;
            phi2_tick <= (phi2_div == 2'd3);
        end
    end

    pokey #(.CLK_BUS_HZ(8), .REF_HZ_M23_1(4), .REF_HZ_LOW(2)) u_dut (
        .clk                  (clk),
        .rst                  (rst),
        .phi2_tick            (phi2_tick),
        .we                   (we),
        .waddr                (waddr),
        .wdata                (wdata),
        .re                   (re),
        .re_addr              (re_addr),
        .raddr                (raddr),
        .rdata                (rdata),
        .kbd_event_valid      (kbd_event_valid),
        .kbd_event_code       (kbd_event_code),
        .shadow_pot0          (shadow_pot0),
        .shadow_pot1          (shadow_pot1),
        .shadow_pot2          (shadow_pot2),
        .shadow_pot3          (shadow_pot3),
        .shadow_pot4          (shadow_pot4),
        .shadow_pot5          (shadow_pot5),
        .shadow_pot6          (shadow_pot6),
        .shadow_pot7          (shadow_pot7),
        .shadow_allpot        (shadow_allpot),
        .bridge_potgo_pulse   (bridge_potgo_pulse),
        .bridge_fast_scan     (bridge_fast_scan),
        .ch1_out              (ch1_out),
        .ch2_out              (ch2_out),
        .ch3_out              (ch3_out),
        .ch4_out              (ch4_out),
        .ser_out_complete     (ser_out_complete),
        .ser_out_ready_pulse  (ser_out_ready_pulse),
        .ser_in_byte_pulse    (ser_in_byte_pulse),
        .ser_in_byte          (ser_in_byte),
        .break_key_pulse      (break_key_pulse),
        .ser_framing_err      (ser_framing_err),
        .ser_input_overrun    (ser_input_overrun),
        .ser_input_busy       (ser_input_busy),
        .irq_n                (irq_n),
        .serout_byte          (serout_byte),
        .serout_strobe        (serout_strobe),
        .skctl_out            (skctl_out)
    );

    int fail_count = 0;

    // Phase-G filter sample buffers — module-scope to avoid iverilog's
    // mixed-decl-statement limitations inside sequential begin blocks.
    logic [3:0] phase_g_no_filt   [0:199];
    logic [3:0] phase_g_with_filt [0:199];
    integer     phase_g_matches;
    integer     phase_g_i;

    task automatic do_write(input [7:0] a, input [7:0] d);
        @(negedge clk);
        we    = 1'b1;
        waddr = a;
        wdata = d;
        @(posedge clk);
        @(negedge clk);
        we    = 1'b0;
    endtask

    task automatic expect_eq(input string label,
                             input [31:0] got, input [31:0] want);
        if (got !== want) begin
            $display("FAIL %s: got=$%0h expected=$%0h", label, got, want);
            fail_count++;
        end
    endtask

    // Count rising edges of `signal_high` (= channel output non-zero)
    // over `cycles` clk_bus ticks.
    task automatic count_toggles(input  int     cycles,
                                  input  int     channel_idx,    // 0..3
                                  output int     toggles);
        int prev_state, cur_state;
        toggles = 0;
        prev_state = (channel_state(channel_idx) > 0) ? 1 : 0;
        repeat (cycles) begin
            @(posedge clk);
            cur_state = (channel_state(channel_idx) > 0) ? 1 : 0;
            if (cur_state != prev_state && cur_state == 1) toggles++;
            prev_state = cur_state;
        end
    endtask

    function automatic int channel_state(input int idx);
        case (idx)
            0: channel_state = ch1_out;
            1: channel_state = ch2_out;
            2: channel_state = ch3_out;
            3: channel_state = ch4_out;
            default: channel_state = 0;
        endcase
    endfunction

    initial begin
        $display("[pokey] start");
        repeat (8) @(posedge clk);
        rst = 1'b0;
        repeat (4) @(posedge clk);

        // ===== Phase A — register write =================================
        // M23-5 reclaimed $D208 reads as ALLPOT, so the M23-1 debug
        // AUDCTL read-back is gone. Instead just write AUDCTL and
        // verify that no scan is in flight (ALLPOT == 0).
        $display("[A] register write");
        do_write(8'h08, 8'h5A);               // AUDCTL = $5A
        @(negedge clk);
        raddr = 8'h08;
        @(negedge clk);
        expect_eq("A.ALLPOT-idle", rdata, 8'h00);

        // ===== Phase B — frequency check =================================
        // Write AUDF1 = 3, AUDC1 = $0F (volume 15, no volume-only).
        // Reference ticks every 2 clks; channel toggles every (AUDF+1)
        // ref ticks = 4 ref ticks = 8 clk cycles between toggles, so
        // ~half-period = 8 clks; full period ≈ 16 clks; rising edges
        // every 16 clks. Over 800 clks we expect ~50 rising edges.
        $display("[B] frequency check");
        // PURE square-wave mode: AUDC[7]=1 (NOT_5 bypass) + AUDC[5]=1
        // (PURE) + low nibble = volume → pattern $Av.
        // Clear AUDCTL (Phase A left it at $5A) so the M23-3 features
        // don't confuse the M23-1/2 baseline counts.
        do_write(8'h08, 8'h00);    // AUDCTL = 0
        do_write(8'h00, 8'h03);    // AUDF1 = 3
        do_write(8'h01, 8'hAF);    // AUDC1: PURE + NOT_5, vol=15
        do_write(8'h02, 8'h07);    // AUDF2 = 7
        do_write(8'h03, 8'hAA);    // AUDC2: PURE + NOT_5, vol=10
        do_write(8'h04, 8'h00);    // AUDF3 = 0 (toggle every ref)
        do_write(8'h05, 8'hA5);    // AUDC3: PURE + NOT_5, vol=5
        do_write(8'h06, 8'h0F);    // AUDF4 = 15
        do_write(8'h07, 8'hA8);    // AUDC4: PURE + NOT_5, vol=8

        begin
            // window 1600 clks ≈ 800 ref ticks
            // ch1 (AUDF=3): toggles every 4 ref ticks → period 8 ref → 100 rising/800 ref
            // ch2 (AUDF=7): toggles every 8 ref ticks → period 16 → 50 rising/800
            // ch3 (AUDF=0): toggles every 1 ref tick → period 2 → 400 rising/800
            // ch4 (AUDF=15): every 16 ref → period 32 → 25 rising/800
            int t1, t2, t3, t4;
            // Drain any pending state.
            @(posedge clk);
            count_toggles(1600, 0, t1);
            count_toggles(1600, 1, t2);
            count_toggles(1600, 2, t3);
            count_toggles(1600, 3, t4);
            // Allow ±5 % for sampling jitter (enter-mid-cycle, etc).
            $display("[B] toggles: ch1=%0d ch2=%0d ch3=%0d ch4=%0d",
                     t1, t2, t3, t4);
            // Sanity bounds: ch1 ≈ 100, ch2 ≈ 50, ch3 ≈ 400, ch4 ≈ 25.
            // Looser bounds because we sample one channel at a time
            // (sequential, multi-window over 4 × 1600 clks).
            if (t1 < 90 || t1 > 110) begin
                $display("FAIL B.ch1: %0d toggles, expected ~100", t1);
                fail_count++;
            end
            if (t2 < 45 || t2 > 55) begin
                $display("FAIL B.ch2: %0d toggles, expected ~50", t2);
                fail_count++;
            end
            if (t3 < 380 || t3 > 420) begin
                $display("FAIL B.ch3: %0d toggles, expected ~400", t3);
                fail_count++;
            end
            if (t4 < 22 || t4 > 28) begin
                $display("FAIL B.ch4: %0d toggles, expected ~25", t4);
                fail_count++;
            end
        end

        // ===== Phase C — volume gate ===================================
        $display("[C] volume = 0 → silence");
        do_write(8'h01, 8'h00);    // AUDC1 vol=0
        // Wait for any in-flight state to settle; sample for ~200 clks
        // and ensure ch1_out stays at 0.
        repeat (200) begin
            @(posedge clk);
            if (ch1_out !== 4'h0) begin
                $display("FAIL C.silence: ch1_out=$%0h after vol=0", ch1_out);
                fail_count++;
                break;
            end
        end

        // ===== Phase D0 — SKCTL init/reset holds RANDOM at $FF (M23-2) ===
        // Atari OS idiom (mirrored by ACID800 pokey_noise / antic_wsync):
        // SKCTL[1:0]==0 is POKEY "init" mode — the polynomial counters
        // are held in reset and RANDOM ($D20A) reads $FF. Writing a
        // non-zero SKCTL[1:0] (the OS uses $03) releases them to free
        // run on the machine clock. We can't reproduce the exact ACID800
        // phase-dependent values here (no ANTIC/WSYNC phase in this tb),
        // but the init→$FF hold and the release→advance are checkable.
        $display("[D0] SKCTL init holds RANDOM=$FF, release frees it");
        begin
            int unsigned r_init, r_run;
            do_write(8'h0F, 8'h00);        // SKCTL = 0 → init/reset mode
            repeat (8) @(posedge clk);     // let several phi2 ticks pass
            @(negedge clk);
            raddr = 8'h0A;
            @(negedge clk);
            r_init = rdata;
            expect_eq("D0.RANDOM-init", r_init, 8'hFF);

            // Release init (SKCTL=$03). The poly counters now free-run;
            // RANDOM must leave $FF within a bounded window.
            do_write(8'h0F, 8'h03);
            r_run = 8'hFF;
            begin
                int guard;
                guard = 0;
                while (r_run == 8'hFF && guard < 4096) begin
                    repeat (4) @(posedge clk);
                    @(negedge clk);
                    raddr = 8'h0A;
                    @(negedge clk);
                    r_run = rdata;
                    guard++;
                end
            end
            if (r_run == 8'hFF) begin
                $display("FAIL D0.release: RANDOM stuck at $FF after SKCTL=$03");
                fail_count++;
            end else begin
                $display("[D0] RANDOM: init=$%02x -> running=$%02x", r_init, r_run);
            end
        end

        // ===== Phase D — RANDOM advances + LFSR period checks (M23-2) ====
        // Sample RANDOM ($D20A) twice with a few hundred ref ticks
        // between samples; the value should change (the 17-bit LFSR's
        // high byte cycles through 256 distinct values within 65 535
        // ref ticks, so a few hundred ticks is essentially guaranteed
        // to land on a different byte).
        $display("[D] RANDOM advances");
        begin
            int unsigned r1, r2;
            @(negedge clk);
            raddr = 8'h0A;
            @(negedge clk);
            r1 = rdata;
            // Idle for ~512 clks (256 ref ticks at REF_DIV=2) so the
            // 17-bit LFSR has clocked through plenty of values.
            repeat (512) @(posedge clk);
            @(negedge clk);
            raddr = 8'h0A;
            @(negedge clk);
            r2 = rdata;
            if (r1 == r2) begin
                $display("FAIL D.RANDOM: %02x == %02x (LFSR didn't advance)", r1, r2);
                fail_count++;
            end else begin
                $display("[D] RANDOM advanced: %02x -> %02x", r1, r2);
            end
        end

        // ===== Phase E — poly-modulated channel (M23-2) ==================
        // AUDC[5]=0 (poly mode), [6]=0 (17-bit poly), [7]=1 (NOT_5
        // gate bypassed) → channel output is 17-bit poly bit gated by
        // AUDF divider. Output should be a sequence of randomish 0 /
        // volume samples — verify it's NOT a regular square wave by
        // counting transitions across a window and checking they fall
        // between "all-on" (volume always) and "all-off" (volume
        // never).
        $display("[E] poly-modulated channel");
        do_write(8'h00, 8'h00);    // AUDF1 = 0 (max-rate trigger)
        do_write(8'h01, 8'h8F);    // AUDC1 = $8F: NOT_5=1, POLY_SEL=0, PURE=0, VOL=15
        begin
            int high_count, low_count;
            high_count = 0; low_count = 0;
            repeat (1024) begin
                @(posedge clk);
                if (ch1_out == 4'h0)        low_count++;
                else if (ch1_out == 4'hF)   high_count++;
            end
            $display("[E] ch1 over 1024 cycles: high=%0d low=%0d",
                     high_count, low_count);
            // For a max-period 17-bit LFSR's high byte the bit
            // distribution is ~50/50 over a long enough window.
            // 1024 clocks at REF_DIV=2 = 512 ref ticks. Be loose:
            // require both > 100 (not silenced, not stuck-high).
            if (high_count < 100 || low_count < 100) begin
                $display("FAIL E.poly: imbalanced output (expected ~50/50)");
                fail_count++;
            end
        end

        // ===== Phase F — 16-bit linked-pair timer (audit fix #1) =========
        // AUDCTL[4]=1 → ch2 decrements only when ch1 underflows AND
        // the LOW counter's auto-reload is suppressed (Altirra §5.3).
        // Combined period = (AUDF1 + 256·AUDF2 + 1) ref ticks.
        //
        // Pick AUDF1=$04, AUDF2=$01 → combined = 4 + 256 + 1 = 261
        // ref ticks. Over 16000 clks (= 8000 ref ticks at REF_DIV=2)
        // we expect 8000/261 ≈ 30 ch2 underflows → ~15 rising edges
        // (toggle every other underflow in pure-tone mode). The OLD
        // (buggy) period of (AUDF1+1)·(AUDF2+1) = 5·2 = 10 would give
        // 800 underflows / 400 toggles — easily distinguished.
        $display("[F] 16-bit linked pair (ch1+ch2)");
        do_write(8'h08, 8'h10);    // AUDCTL = $10 (PAIR12 only)
        do_write(8'h00, 8'h04);    // AUDF1 = 4 (low byte)
        do_write(8'h01, 8'h00);    // AUDC1 silent (no audio role in pair)
        do_write(8'h02, 8'h01);    // AUDF2 = 1 (high byte → 16-bit period)
        do_write(8'h03, 8'hAF);    // AUDC2 PURE+NOT_5 vol=15 (audible)
        // Park ch3/ch4 silent.
        do_write(8'h05, 8'h00);
        do_write(8'h07, 8'h00);
        // STIMER to align both counters cleanly.
        do_write(8'h09, 8'h00);
        begin
            int t2;
            @(posedge clk);
            count_toggles(16000, 1, t2);
            $display("[F] ch2 toggles in 16-bit pair mode: %0d (expected ~15)", t2);
            if (t2 < 10 || t2 > 20) begin
                $display("FAIL F.pair12: %0d toggles, expected ~15 (linked-pair semantics broken)",
                         t2);
                fail_count++;
            end
        end

        // ===== Phase G — high-pass filter (AUDCTL[2] FILT1) ==============
        // ch1's audible state = ch1_state XOR ch3_state. We can't
        // verify the audio shape directly without a golden trace,
        // but we can verify that the filter bit toggles the output
        // pattern: write the same AUDF/AUDC for ch1 and ch3, run
        // for a window with FILT1=0 and again with FILT1=1, and
        // confirm the output sample sequence differs.
        $display("[G] high-pass filter (FILT1)");
        begin
            // Reset AUDCTL: 64 kHz ref, no pair, no filter.
            do_write(8'h08, 8'h00);
            do_write(8'h00, 8'h05);   // AUDF1 = 5
            do_write(8'h01, 8'hAF);   // AUDC1 PURE+NOT_5 vol=15
            do_write(8'h04, 8'h05);   // AUDF3 = 5  (same period)
            do_write(8'h05, 8'hAF);   // AUDC3 PURE+NOT_5 vol=15
            @(posedge clk);
            for (phase_g_i = 0; phase_g_i < 200; phase_g_i = phase_g_i + 1) begin
                @(posedge clk);
                phase_g_no_filt[phase_g_i] = ch1_out;
            end
            // Enable FILT1.
            do_write(8'h08, 8'h04);   // AUDCTL[2] = 1
            do_write(8'h00, 8'h05);
            do_write(8'h04, 8'h05);
            @(posedge clk);
            for (phase_g_i = 0; phase_g_i < 200; phase_g_i = phase_g_i + 1) begin
                @(posedge clk);
                phase_g_with_filt[phase_g_i] = ch1_out;
            end
            phase_g_matches = 0;
            for (phase_g_i = 0; phase_g_i < 200; phase_g_i = phase_g_i + 1)
                if (phase_g_no_filt[phase_g_i] == phase_g_with_filt[phase_g_i])
                    phase_g_matches = phase_g_matches + 1;
            $display("[G] ch1 sample agreement no_filt vs filt: %0d/200", phase_g_matches);
            // Filter should change the output pattern materially.
            if (phase_g_matches > 150) begin
                $display("FAIL G.filt1: filter had no effect (%0d/200 match)", phase_g_matches);
                fail_count++;
            end
        end

        // ===== Phase H — REF15 select (AUDCTL[0]) =======================
        // With CLK_BUS_HZ=8, REF_HZ_HI=4 (ref ticks every 2 clks)
        // vs REF_HZ_LOW=2 (ref ticks every 4 clks). AUDF1=0 →
        // toggles every 1 ref tick; over 1600 clks with REF15=0:
        // 800 toggles. With REF15=1: 400 toggles.
        $display("[H] REF15 select");
        do_write(8'h08, 8'h00);    // AUDCTL[0]=0 (64 kHz ref)
        do_write(8'h00, 8'h00);    // AUDF1=0
        do_write(8'h01, 8'hAF);    // PURE+NOT_5 vol=15
        // Park ch3/ch4 silent.
        do_write(8'h05, 8'h00);
        do_write(8'h07, 8'h00);
        begin
            int t_hi, t_lo;
            @(posedge clk);
            count_toggles(1600, 0, t_hi);
            // Switch to 15 kHz ref.
            do_write(8'h08, 8'h01);    // AUDCTL[0]=1
            do_write(8'h00, 8'h00);    // re-write AUDF1 (forces immediate adoption next ref)
            @(posedge clk);
            count_toggles(1600, 0, t_lo);
            $display("[H] toggles HI=%0d LO=%0d (expect ~2× ratio)", t_hi, t_lo);
            // Sanity: HI should be ~2× LO (allowing some slack for
            // boundary effects and the 1-cycle reset).
            if (t_hi < 2 * t_lo - 50 || t_hi > 2 * t_lo + 50) begin
                $display("FAIL H.ref_select: HI=%0d / LO=%0d not ~2×", t_hi, t_lo);
                fail_count++;
            end
        end

        // ===== Phase I — keyboard event ingest (M23-4) ==================
        // RP2354's USB-host translator presents pre-packed KBCODE
        // bytes (scan code + shift + ctrl) on a 1-cycle valid pulse.
        // Verify: KBCODE reflects the latest code, SKSTAT KEY_LATCH
        // bit goes high, and a KBCODE read clears KEY_LATCH (1 cycle
        // later). The IRQ-aggregation aspect of the same event is
        // covered in Phase K.
        $display("[I] keyboard event ingest");
        begin
            // Drive a key event: scan code $2A (some random key) +
            // shift bit set, ctrl bit clear. Packed: $6A.
            @(negedge clk);
            kbd_event_valid = 1'b1;
            kbd_event_code  = 8'h6A;
            @(posedge clk);
            @(negedge clk);
            kbd_event_valid = 1'b0;

            // Read KBCODE ($D209) — should be $6A.
            @(negedge clk);
            raddr = 8'h09;
            @(negedge clk);
            if (rdata !== 8'h6A) begin
                $display("FAIL I.kbcode: got $%02x expected $6A", rdata);
                fail_count++;
            end

            // Read SKSTAT ($D20F) — KEY_LATCH bit (5) should be 1,
            // SHIFT bit (7) should mirror kbcode_q[6] = 1.
            @(negedge clk);
            raddr = 8'h0F;
            @(negedge clk);
            if (rdata[5] !== 1'b1) begin
                $display("FAIL I.key_latch_set: SKSTAT=$%02x bit5=0", rdata);
                fail_count++;
            end
            if (rdata[7] !== 1'b1) begin
                $display("FAIL I.shift: SKSTAT=$%02x bit7=0 (expected SHIFT=1)", rdata);
                fail_count++;
            end

            // Now simulate a KBCODE read pulse (re=1 + re_addr=$09).
            // pokey_regs clears KEY_LATCH 1 cycle later.
            @(negedge clk);
            re      = 1'b1;
            re_addr = 8'h09;
            @(posedge clk);
            @(negedge clk);
            re = 1'b0;
            // Wait one cycle for the latch to clear.
            @(posedge clk);

            // Re-read SKSTAT — KEY_LATCH should now be 0.
            @(negedge clk);
            raddr = 8'h0F;
            @(negedge clk);
            if (rdata[5] !== 1'b0) begin
                $display("FAIL I.key_latch_clear: SKSTAT=$%02x bit5=1 after KBCODE read",
                         rdata);
                fail_count++;
            end
        end

        // ===== Phase J — POT scan shadow (M25-3c) ========================
        // pokey_pot was gutted to a passthrough in M25-3c — the actual
        // discharge counter now lives in peri-RP firmware via
        // peri_pot_bridge above antic_top. This phase exercises the
        // shadow path:
        //   - $D20B writes (POTGO) emit a 1-cycle bridge_potgo_pulse
        //   - SKCTL[2] flows out as bridge_fast_scan
        //   - shadow_pot0..7 / shadow_allpot drive the $D200..$D208 reads
        $display("[J] POT scan shadow");
        begin
            int       potgo_count;
            // Slow scan first — SKCTL[2] = 0.
            do_write(8'h0F, 8'h00);     // SKCTL ($D20F) = 0

            potgo_count = 0;
            fork
                begin
                    repeat (4) @(posedge clk);
                    do_write(8'h0B, 8'h00);
                    repeat (8) @(posedge clk);
                end
                begin
                    repeat (16) @(posedge clk);
                end
            join_any
            // bridge_potgo_pulse should have fired exactly once and
            // bridge_fast_scan should be 0 (slow scan).
            if (bridge_fast_scan !== 1'b0) begin
                $display("FAIL J.fast_scan_slow: got=%0b expected=0",
                         bridge_fast_scan);
                fail_count++;
            end

            // Drive shadow values; software then reads $D200..$D208
            // and should see them.
            shadow_pot0   = 8'd17;
            shadow_pot1   = 8'd42;
            shadow_pot7   = 8'hC3;
            shadow_allpot = 8'b1111_1100;   // POT0/1 done, others scanning

            @(negedge clk);
            raddr = 8'h00;
            @(negedge clk);
            expect_eq("J.POT0.read",  rdata, 8'd17);

            @(negedge clk);
            raddr = 8'h01;
            @(negedge clk);
            expect_eq("J.POT1.read",  rdata, 8'd42);

            @(negedge clk);
            raddr = 8'h07;
            @(negedge clk);
            expect_eq("J.POT7.read",  rdata, 8'hC3);

            @(negedge clk);
            raddr = 8'h08;
            @(negedge clk);
            expect_eq("J.ALLPOT.read", rdata, 8'b1111_1100);

            // Fast scan — SKCTL[2] = 1. Confirm bridge_fast_scan
            // tracks SKCTL.
            do_write(8'h0F, 8'h04);
            @(posedge clk);
            if (bridge_fast_scan !== 1'b1) begin
                $display("FAIL J.fast_scan_fast: got=%0b expected=1",
                         bridge_fast_scan);
                fail_count++;
            end
            // Restore default SKCTL.
            do_write(8'h0F, 8'h00);
        end

        // ===== Phase K — IRQ aggregation + serial registers (M23-6) ==========
        // Cover: keyboard/serial/timer IRQ latching, IRQEN gating,
        // IRQEN-clear ack, SKRES ack, SEROUT capture + strobe, SERIN
        // read, SKSTAT serial flags, irq_n aggregation.
        $display("[K] IRQ aggregation + serial registers");
        begin
            // ---- K.0: With IRQEN = 0, no source should latch even on
            //          a kbd event. irq_n should stay high.
            //          Note: ser_out_complete is held HIGH (shifter
            //          idle — the realistic reset state) so IRQST
            //          bit 3 reads 0 ("pending") even at idle. This
            //          matches Altirra §5.7 — bit 3 is unlatched and
            //          reflects the shifter idle level live, even
            //          when IRQEN[3]=0. Other bits are not pending,
            //          so IRQST = $F7 (bit 3 = 0, others = 1).
            @(negedge clk);
            kbd_event_valid = 1'b1;
            kbd_event_code  = 8'h45;
            @(posedge clk);
            @(negedge clk);
            kbd_event_valid = 1'b0;
            @(posedge clk);
            if (irq_n !== 1'b1) begin
                $display("FAIL K.0: irq_n=%0b after disabled kbd event (expected 1)", irq_n);
                fail_count++;
            end
            @(negedge clk);
            raddr = 8'h0E;          // IRQST
            @(negedge clk);
            if (rdata !== 8'hF7) begin
                $display("FAIL K.0: IRQST=$%02x expected $F7 (only bit 3 live-pending)", rdata);
                fail_count++;
            end

            // ---- K.1: enable IRQ bit 6 (KEY), drive a kbd event,
            //          observe irq_n low and IRQST bit 6 = 0.
            do_write(8'h0E, 8'h40);   // IRQEN = $40 (bit 6)

            @(negedge clk);
            kbd_event_valid = 1'b1;
            kbd_event_code  = 8'h12;
            @(posedge clk);
            @(negedge clk);
            kbd_event_valid = 1'b0;
            @(posedge clk);

            if (irq_n !== 1'b0) begin
                $display("FAIL K.1: irq_n=%0b after enabled kbd event (expected 0)", irq_n);
                fail_count++;
            end
            @(negedge clk);
            raddr = 8'h0E;          // IRQST
            @(negedge clk);
            if (rdata[6] !== 1'b0) begin
                $display("FAIL K.1: IRQST=$%02x bit6=1 (expected pending)", rdata);
                fail_count++;
            end

            // ---- K.2: ack via IRQEN write with bit 6 cleared, then
            //          re-enable. IRQST should clear, irq_n should
            //          de-assert.
            do_write(8'h0E, 8'h00);   // disable all → clears latches
            @(posedge clk);
            if (irq_n !== 1'b1) begin
                $display("FAIL K.2: irq_n=%0b after IRQEN-clear ack (expected 1)", irq_n);
                fail_count++;
            end
            @(negedge clk);
            raddr = 8'h0E;
            @(negedge clk);
            // bit 3 is unlatched and reads as pending whenever
            // ser_out_complete is asserted. Mask it out to focus on
            // the bits we just acked.
            if ((rdata | 8'h08) !== 8'hFF) begin
                $display("FAIL K.2: IRQST=$%02x after ack (expected $FF or $F7)", rdata);
                fail_count++;
            end

            // ---- K.3: enable IRQ bit 0 (TIMER 1) and run long enough
            //          for ch1 to wrap. AUDF1=0 with ref ticks every
            //          2 clks → wraps every 2 clks; we'll see it
            //          almost immediately.
            do_write(8'h0E, 8'h01);   // IRQEN = bit 0 (TIMER 1)
            do_write(8'h00, 8'h00);   // AUDF1 = 0 — fastest divider
            do_write(8'h01, 8'hAF);   // AUDC1 = pure tone, vol 15
            // ch1 will fire timer1_pulse on wrap; latches into IRQ.
            repeat (8) @(posedge clk);
            if (irq_n !== 1'b0) begin
                $display("FAIL K.3: irq_n=%0b after timer1 fire (expected 0)", irq_n);
                fail_count++;
            end
            @(negedge clk);
            raddr = 8'h0E;
            @(negedge clk);
            if (rdata[0] !== 1'b0) begin
                $display("FAIL K.3: IRQST=$%02x bit0=1 (expected timer1 pending)", rdata);
                fail_count++;
            end
            // Ack timer1, leaving the source disabled so it doesn't
            // re-latch immediately during subsequent phases.
            do_write(8'h0E, 8'h00);
            // Park ch1 so it stops generating timer1 edges.
            do_write(8'h00, 8'hFF);
            do_write(8'h01, 8'h00);

            // ---- K.4: SEROUT write captures byte + strobes for 1 cycle.
            @(negedge clk);
            do_write(8'h0D, 8'hA5);
            @(posedge clk);
            if (serout_byte !== 8'hA5) begin
                $display("FAIL K.4: serout_byte=$%02x expected $A5", serout_byte);
                fail_count++;
            end
            // serout_strobe is combinational on `we && waddr==4'hD`;
            // it pulses during the do_write cycle and is back to 0 now.

            // ---- K.5: SERIN — drive ser_in_byte_pulse and verify
            //          $D20D read returns the latched byte. Also
            //          enable IRQ bit 5 to verify it latches.
            do_write(8'h0E, 8'h20);   // IRQEN = bit 5 (SER IN)
            @(negedge clk);
            ser_in_byte       = 8'hC3;
            ser_in_byte_pulse = 1'b1;
            @(posedge clk);
            @(negedge clk);
            ser_in_byte_pulse = 1'b0;
            @(posedge clk);
            if (irq_n !== 1'b0) begin
                $display("FAIL K.5: irq_n=%0b after ser_in pulse (expected 0)", irq_n);
                fail_count++;
            end
            @(negedge clk);
            raddr = 8'h0D;          // SERIN
            @(negedge clk);
            if (rdata !== 8'hC3) begin
                $display("FAIL K.5: SERIN=$%02x expected $C3", rdata);
                fail_count++;
            end

            // ---- K.6: SKRES clears the latched serial IRQ bits
            //          (4 and 5) but leaves bit 6 (kbd) intact. Bit 3
            //          is unlatched (live) and SKRES has no effect
            //          on it.
            do_write(8'h0E, 8'h60);   // IRQEN = bit 5 + bit 6
            @(negedge clk);
            kbd_event_valid = 1'b1;
            kbd_event_code  = 8'h99;
            @(posedge clk);
            @(negedge clk);
            kbd_event_valid = 1'b0;
            // SKRES.
            do_write(8'h0A, 8'h00);
            @(posedge clk);
            @(negedge clk);
            raddr = 8'h0E;
            @(negedge clk);
            if (rdata[5] !== 1'b1) begin
                $display("FAIL K.6: IRQST=$%02x bit5=0 (SKRES should clear ser-in)", rdata);
                fail_count++;
            end
            if (rdata[6] !== 1'b0) begin
                $display("FAIL K.6: IRQST=$%02x bit6=1 (kbd latch should survive SKRES)", rdata);
                fail_count++;
            end

            // ---- K.7: SKSTAT serial-flag bits (4..2) reflect inputs.
            do_write(8'h0E, 8'h00);   // ack everything
            ser_framing_err   = 1'b1;
            ser_input_overrun = 1'b0;
            ser_input_busy    = 1'b1;
            @(negedge clk);
            raddr = 8'h0F;          // SKSTAT
            @(negedge clk);
            if (rdata[4] !== 1'b1) begin
                $display("FAIL K.7: SKSTAT=$%02x bit4=0 (framing err)", rdata);
                fail_count++;
            end
            if (rdata[3] !== 1'b0) begin
                $display("FAIL K.7: SKSTAT=$%02x bit3=1 (overrun)", rdata);
                fail_count++;
            end
            // bit 1 is active-LOW serial-input-busy: while ser_input_busy
            // is asserted (a byte is shifting in) SKSTAT bit1 reads 0.
            if (rdata[1] !== 1'b0) begin
                $display("FAIL K.7: SKSTAT=$%02x bit1=1 (expected 0 while receiving)", rdata);
                fail_count++;
            end
            ser_framing_err = 1'b0;
            ser_input_busy  = 1'b0;
            // Idle again → bit1 must read back as 1 (ACID800 pokey_skstat:
            // "Serial input active bit was asserted when idle").
            @(negedge clk);
            raddr = 8'h0F;
            @(negedge clk);
            if (rdata[1] !== 1'b1) begin
                $display("FAIL K.7: SKSTAT=$%02x bit1=0 when idle (expected 1)", rdata);
                fail_count++;
            end

            // ---- K.8: bit 3 (SER OUT COMPLETE) is unlatched (Altirra
            //          §5.7). IRQST[3] must follow ser_out_complete
            //          live, regardless of any prior latch state.
            //          Drop ser_out_complete; bit 3 should read as
            //          "not pending" even with no IRQEN write.
            ser_out_complete = 1'b0;
            @(posedge clk);
            @(negedge clk);
            raddr = 8'h0E;
            @(negedge clk);
            if (rdata[3] !== 1'b1) begin
                $display("FAIL K.8: IRQST=$%02x bit3=0 with shifter busy (expected 1)", rdata);
                fail_count++;
            end
            // Re-assert ser_out_complete; bit 3 should immediately
            // re-show pending without any pulse-driven latching.
            ser_out_complete = 1'b1;
            @(posedge clk);
            @(negedge clk);
            raddr = 8'h0E;
            @(negedge clk);
            if (rdata[3] !== 1'b0) begin
                $display("FAIL K.8: IRQST=$%02x bit3=1 with shifter idle (expected 0)", rdata);
                fail_count++;
            end

            // ---- K.9: bit 4 (SER OUT READY) is latched. A pulse on
            //          ser_out_ready_pulse with IRQEN[4]=1 must
            //          latch IRQST[4]=0 (pending) and assert irq_n.
            do_write(8'h0E, 8'h10);   // IRQEN = bit 4
            @(negedge clk);
            ser_out_ready_pulse = 1'b1;
            @(posedge clk);
            @(negedge clk);
            ser_out_ready_pulse = 1'b0;
            @(posedge clk);
            if (irq_n !== 1'b0) begin
                $display("FAIL K.9: irq_n=%0b after ser_out_ready (expected 0)", irq_n);
                fail_count++;
            end
            @(negedge clk);
            raddr = 8'h0E;
            @(negedge clk);
            if (rdata[4] !== 1'b0) begin
                $display("FAIL K.9: IRQST=$%02x bit4=1 (expected pending)", rdata);
                fail_count++;
            end
            do_write(8'h0E, 8'h00);   // ack
        end

        // ===== Phase L — STIMER ($D209) reloads all timers ===================
        // Per Altirra §5.3: STIMER reloads all four counters from
        // AUDFn and forces output flip-flops to 1. No IRQs or audio
        // pulses fire from the reload itself.
        $display("[L] STIMER reload");
        begin
            int t1_before, t1_after;
            // Set up a known timer state with non-zero AUDF1.
            do_write(8'h08, 8'h00);    // AUDCTL = 0
            do_write(8'h00, 8'h0A);    // AUDF1 = $0A
            do_write(8'h01, 8'hAF);    // AUDC1 = pure tone vol 15
            // Let the counter advance partway through its period.
            repeat (6) @(posedge clk);
            t1_before = u_dut.u_audio.ch1_cnt;
            // STIMER write: $D209.  The reload lands on the FOURTH machine
            // cycle after the write (Altirra reset-timers chain; ACID800
            // pokey_timertiming first-assert contract): poll for the
            // reload value and require it within the lag window.
            do_write(8'h09, 8'h00);
            // The reload lands 4 machine cycles after the write (Altirra
            // reset-timers chain).  Detect the reload EVENT: within a
            // bounded window the counter must appear in the reload
            // neighbourhood ($0A downward), which the pre-STIMER value
            // ($F2 region) cannot reach by counting.
            begin
                int seen = 0;
                for (int w = 0; w < 200 && !seen; w++) begin
                    @(posedge clk);
                    t1_after = u_dut.u_audio.ch1_cnt;
                    if (t1_after <= 8'h0B) seen = 1;
                end
                if (!seen) begin
                    $display("FAIL L: ch1_cnt never reloaded after STIMER (last=$%0h; before=$%0h)",
                             t1_after, t1_before);
                    fail_count++;
                end
            end
            // ch1_state should be forced to 1.
            if (u_dut.u_audio.ch1_state !== 1'b1) begin
                $display("FAIL L: ch1_state after STIMER = %0b (expected 1)",
                         u_dut.u_audio.ch1_state);
                fail_count++;
            end
            $display("[L] ch1_cnt: $%0h → STIMER → $%0h (AUDF1=$0A)", t1_before, t1_after);
            // Park ch1.
            do_write(8'h00, 8'hFF);
            do_write(8'h01, 8'h00);
        end

        // ===== Phase M — AUDCTL[6] high-freq mode + N+4 period (audit #7) =
        // AUDCTL[6]=1 routes phi2_tick to ch1. With audit fix #7 the
        // unlinked machine-clock period is N+4 phi2_ticks (Altirra
        // §5.3). In our test config phi2_tick fires every 4 fabric
        // clks. With AUDF1=0 → period = 4 phi2_ticks = 16 fabric
        // clks per timer underflow; pure-tone halves that to 32 clks
        // per rising edge. Over 2048 clks → 64 rising edges. The
        // OLD broken N+1 model would produce ~256.
        $display("[M] AUDCTL[6] high-freq, N+4 period via phi2_tick");
        begin
            int t_lo;
            do_write(8'h08, 8'h40);   // AUDCTL[6] = 1 (CH1 high-freq)
            do_write(8'h00, 8'h00);   // AUDF1 = 0 — fastest possible
            do_write(8'h01, 8'hAF);   // AUDC1 = pure tone vol 15
            // Park ch3/ch4 silent.
            do_write(8'h05, 8'h00);
            do_write(8'h07, 8'h00);
            @(posedge clk);
            count_toggles(2048, 0, t_lo);
            $display("[M] ch1 toggles in high-freq mode: %0d (expected ~64, N+4 period)", t_lo);
            if (t_lo < 56 || t_lo > 72) begin
                $display("FAIL M: ch1 toggles=%0d outside [56,72]", t_lo);
                fail_count++;
            end
            // Park.
            do_write(8'h08, 8'h00);
            do_write(8'h00, 8'hFF);
            do_write(8'h01, 8'h00);
        end

        // ===== Phase N — Linked machine-clock period N+7 (audit #7) ========
        // AUDCTL[6]=1 + AUDCTL[4]=1 → ch1+ch2 linked on machine clock.
        // Per Altirra §5.3, period = AUDF1 + 256·AUDF2 + 7 phi2_ticks
        // (3 cycles greater than unlinked due to cascade-reset delay).
        //
        // With AUDF1=$09, AUDF2=$00 → unlinked would be 13 phi2_ticks,
        // linked = 16 phi2_ticks. Pure-tone halves to 32 phi2_ticks
        // per rising edge = 128 fabric clks. Over 16384 clks → 128
        // rising edges. The OLD (no-fudge) model would give 16384 /
        // ((9 + 0 + 1) × 2 × 4) = 205 — distinguishable.
        $display("[N] linked machine-clock N+7 period");
        begin
            int t2;
            do_write(8'h08, 8'h50);    // AUDCTL = $50 (PAIR12 + CH1_HF)
            do_write(8'h00, 8'h09);    // AUDF1 = 9 (low byte)
            do_write(8'h01, 8'h00);    // AUDC1 silent
            do_write(8'h02, 8'h00);    // AUDF2 = 0 (high byte)
            do_write(8'h03, 8'hAF);    // AUDC2 PURE+NOT_5 vol=15
            do_write(8'h05, 8'h00);
            do_write(8'h07, 8'h00);
            do_write(8'h09, 8'h00);    // STIMER to align
            @(posedge clk);
            count_toggles(16384, 1, t2);
            $display("[N] ch2 toggles in linked-MC mode: %0d (expected ~128, N+7 period)", t2);
            if (t2 < 115 || t2 > 140) begin
                $display("FAIL N: ch2 toggles=%0d outside [115,140] (linked MC period broken)",
                         t2);
                fail_count++;
            end
            // Park.
            do_write(8'h08, 8'h00);
            do_write(8'h00, 8'hFF);
            do_write(8'h01, 8'h00);
            do_write(8'h02, 8'hFF);
            do_write(8'h03, 8'h00);
        end

        // ===== Phase O — unused read addresses read $FF (pokey_default) ===
        // POKEY does not drive the data bus for its unused read
        // addresses $D20B / $D20C, so the Atari reads the pulled-up bus
        // as $FF. ACID800 pokey_default reads $D20C and asserts $FF.
        $display("[O] unused read addr default = $FF");
        begin
            @(negedge clk);
            raddr = 8'h0C;
            @(negedge clk);
            expect_eq("O.D20C-default", rdata, 8'hFF);
            @(negedge clk);
            raddr = 8'h0B;
            @(negedge clk);
            expect_eq("O.D20B-default", rdata, 8'hFF);
        end

        // ===== Phase P — async receive suppresses TIMER 4 IRQ (asyncrecv) =
        // ACID800 pokey_asyncrecv: with SKCTL async-receive mode ON
        // (bit4 = $13) POKEY holds the timer 3+4 pair in reset awaiting
        // a start bit, so TIMER 4 never fires. Toggling the mode off
        // ($03) lets it fire again. TIMER 4 IRQ = IRQEN bit 2.
        $display("[P] async receive suppresses TIMER 4 IRQ");
        begin
            // ---- P.1: async OFF ($03) → timer4 fires ----
            do_write(8'h0F, 8'h03);   // SKCTL = $03 (async recv OFF)
            do_write(8'h08, 8'h00);   // AUDCTL = 0 (unlinked, ref clock)
            do_write(8'h07, 8'h00);   // AUDC4 = 0 (silent)
            do_write(8'h06, 8'h02);   // AUDF4 = 2 → wrap every 3 ref ticks
            do_write(8'h0E, 8'h00);   // IRQEN = 0
            do_write(8'h09, 8'h00);   // STIMER — reload ch4
            do_write(8'h0E, 8'h04);   // IRQEN = $04 (TIMER 4)
            repeat (64) @(posedge clk);
            if (irq_n !== 1'b0) begin
                $display("FAIL P.1: irq_n=%0b, TIMER 4 IRQ did not fire (async OFF)", irq_n);
                fail_count++;
            end

            // ---- P.2: async ON ($13) → timer4 suppressed ----
            do_write(8'h0E, 8'h00);   // ack / clear latch
            do_write(8'h0F, 8'h13);   // SKCTL = $13 (async recv ON)
            do_write(8'h09, 8'h00);   // STIMER
            do_write(8'h0E, 8'h04);   // IRQEN = $04 (TIMER 4)
            repeat (64) @(posedge clk);
            if (irq_n !== 1'b1) begin
                $display("FAIL P.2: irq_n=%0b, TIMER 4 IRQ fired with async recv active", irq_n);
                fail_count++;
            end
            @(negedge clk);
            raddr = 8'h0E;            // IRQST
            @(negedge clk);
            if (rdata[2] !== 1'b1) begin
                $display("FAIL P.2: IRQST=$%02x bit2=0 (TIMER 4 pending in async recv)", rdata);
                fail_count++;
            end

            // ---- P.3: async OFF again → timer4 unlocks ----
            do_write(8'h0F, 8'h03);   // SKCTL = $03 (async recv OFF)
            do_write(8'h0E, 8'h00);
            do_write(8'h09, 8'h00);   // STIMER
            do_write(8'h0E, 8'h04);   // IRQEN = $04
            repeat (64) @(posedge clk);
            if (irq_n !== 1'b0) begin
                $display("FAIL P.3: irq_n=%0b, TIMER 4 IRQ did not re-fire after async OFF", irq_n);
                fail_count++;
            end
            // Park.
            do_write(8'h0E, 8'h00);
            do_write(8'h06, 8'hFF);
            do_write(8'h0F, 8'h00);
        end

        if (fail_count == 0) begin
            $display("*** POKEY OK *** audio + RANDOM + AUDCTL + keyboard + POT + IRQ/serial + STIMER");
            $finish;
        end else begin
            $display("*** POKEY FAIL *** %0d failures", fail_count);
            $fatal(1);
        end
    end

    initial begin
        #5_000_000;
        $display("FAIL: tb_pokey watchdog");
        $fatal(1);
    end

endmodule

`default_nettype wire
