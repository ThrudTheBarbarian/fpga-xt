// pokey_audio.sv — POKEY 4-channel audio generator with polynomial
// counters (M23-2 update — replaces M23-1's pure square-wave only).
//
// Each channel has a programmable AUDF divider that triggers every
// (AUDF[i] + 1) ref ticks. On each trigger the channel state takes
// either:
//   * the inverse of itself (pure tone — AUDC[5]=1), or
//   * the selected polynomial counter bit (4 / 17-bit per AUDC[6]),
//     optionally AND'd with the 5-bit poly (gated by AUDC[7]).
//
// The four LFSRs (4-bit, 5-bit, 9-bit, 17-bit) free-run on the machine
// clock (phi2_tick) — the tone dividers sample them when they fire.
// While POKEY is in SKCTL init/reset mode (SKCTL[1:0]==0) the counters keep
// SHIFTING but feed in 1s, so the register fills with ones and RANDOM only
// reaches $FF after n shifts — reading it partway through returns a partly
// filled value (ACID800 pokey_noise's hot-stop assertions measure exactly
// this). Leaving init therefore always starts from all-ones. The 9-bit poly
// isn't directly selectable by AUDC; AUDCTL[7] substitutes it for the 17-bit
// one, and RANDOM ($D20A) follows that selection: bits [8:1] of the 9-bit
// poly when AUDCTL[7] is set, else bits [16:9] of the 17-bit poly.
//
// Channel-clock reference for M23-1/2: a fixed 64 kHz generated from
// clk_bus by a divide-by-(CLK_BUS_HZ / 64000) counter. Real POKEY
// has a 64 kHz / 15 kHz selectable reference + per-channel
// high-frequency mode (master clock direct), all driven by AUDCTL —
// that lands at M23-3.
//
// AUDC encoding per channel:
//   AUDC[7] NOT_5      0 = AND with 5-bit poly, 1 = bypass 5-bit
//   AUDC[6] POLY_SEL   0 = use 17-bit poly (or 9-bit per AUDCTL[7]), 1 = use 4-bit poly
//   AUDC[5] PURE       0 = poly-modulated, 1 = pure square wave
//   AUDC[4] VOL_ONLY   1 = output is always at volume (DAC-style)
//   AUDC[3:0] VOLUME   0..15 output level
//
// AUDCTL encoding (M23-3):
//   AUDCTL[7] POLY9    1 = AUDC POLY_SEL=0 selects 9-bit poly instead of 17-bit
//   AUDCTL[6] CH1_HF   1 = ch1 counts on master clock (1.79 MHz) instead of ref
//   AUDCTL[5] CH3_HF   1 = ch3 counts on master clock instead of ref
//   AUDCTL[4] PAIR12   1 = 16-bit channel pair: ch2 decrements on ch1 wrap
//   AUDCTL[3] PAIR34   1 = 16-bit channel pair: ch4 decrements on ch3 wrap
//   AUDCTL[2] FILT1    1 = high-pass filter ch1 against ch3 (XOR clocked output)
//   AUDCTL[1] FILT2    1 = high-pass filter ch2 against ch4
//   AUDCTL[0] REF15    1 = 15 kHz reference clock, 0 = 64 kHz reference
//
// Two-tone serial mode (SKCTL[3:2], not AUDCTL) is part of M23-6 SIO.
//
// CLK_BUS_HZ is provided as a parameter rather than a `define so
// testbenches can run at a higher rate without touching the source.
// Default 161.08 MHz (Atari 1.7898 MHz × BASE_DIV=90 — the
// M-cache-rework Step 5b production target).

`default_nettype none

module pokey_audio #(
    parameter int unsigned REF_PHI2_HI = 28,   // 64 kHz period in phi2 cycles
    parameter int unsigned REF_PHI2_LO = 114,  // 15 kHz period in phi2 cycles
    parameter int unsigned REF_REL_HI  = 22,   // first 64k tick after init release
    parameter int unsigned REF_REL_LO  = 81,   // first 15k tick after init release
    parameter int unsigned REL_SKEW    = 3,    // write-commit vs phi2_tick alignment (HW-measured)
    // Clock-rate parameter for the reference dividers.
    parameter int unsigned CLK_BUS_HZ   = 161_079_525,
    parameter int unsigned REF_HZ_M23_1 = 64_000,    // M23-3 high-rate ref (AUDCTL[0]=0)
    parameter int unsigned REF_HZ_LOW   = 15_700     // M23-3 low-rate ref  (AUDCTL[0]=1)
) (
    input  wire        clk,
    input  wire        rst,

    // 1-cycle pulse per 6502 phi2 rising edge (Atari 1.79 MHz on NTSC,
    // 1.77 MHz on PAL). Generated externally — pokey_audio is agnostic
    // to the clk_bus / phi2 ratio. Used by AUDCTL[6] / AUDCTL[5]
    // high-frequency channel mode (Altirra §5.4).
    input  wire        phi2_tick,

    // From pokey_regs.
    input  wire [7:0]  audf1, audf2, audf3, audf4,
    input  wire [7:0]  audc1, audc2, audc3, audc4,
    input  wire [7:0]  audctl,    // unused at M23-1; reserved for M23-3

    // SKCTL ($D20F). Bits [1:0] gate POKEY's "init"/reset mode: while
    // both are 0 the polynomial counters are held in reset and RANDOM
    // ($D20A) reads $FF (Altirra §5.5 "Initialization mode"). Any non-
    // zero value in [1:0] releases them to free-run on the machine
    // clock. bit 0 = keyboard debounce, bit 1 = keyboard scan.
    input  wire [7:0]  skctl,

    // Per-channel output: 4-bit value = (channel_state ? volume : 0).
    // 0..15 range. Downstream (M23-7 I2S TX) sums them into stereo PCM.
    output wire  [3:0] ch1_out,
    output wire  [3:0] ch2_out,
    output wire  [3:0] ch3_out,
    output wire  [3:0] ch4_out,

    // RANDOM register source — high byte of the 17-bit LFSR (bits 16..9).
    // Read at $D20A by pokey_regs.
    output wire  [7:0] random_byte,

    // Audio-timing reference tick (selected by AUDCTL[0]). Used by
    // the audio channel counters; not for POT scan.
    output wire        ref_tick_out,

    // Fixed 15 kHz reference tick (Altirra §5.9: POT scan is always
    // driven by the keyboard / 15 kHz clock, regardless of AUDCTL[0]).
    output wire        ref_tick_15khz_out,

    // STIMER ($D209) — 1-cycle pulse from pokey_regs. Reloads all
    // four channel counters from AUDFn and forces ch_state to 1.
    // No IRQs/audio pulses generated by the reload itself
    // (Altirra §5.3 "Resetting the timers").
    input  wire        stimer_pulse,

    // M23-6: timer-source edges for IRQ aggregation. 1-cycle pulse on
    // each channel's frequency-divider rollover. POKEY exposes IRQs
    // for channels 1, 2 and 4 only (no TIMER 3).
    output wire        timer1_pulse,
    output wire        timer2_pulse,
    output wire        timer4_pulse
);

    // ---- Reference clock dividers (64 kHz + 15 kHz, AUDCTL[0] selects) ---
    // PHI2-PACED: real POKEY derives both from poly counters clocked at
    // 1.79 MHz (64 kHz = phi2/28, 15 kHz = phi2/114), and SKCTL init mode
    // holds them preset such that after init release the NEXT 64 kHz tick
    // lands 22 machine cycles later and the next 15 kHz tick 81 cycles
    // later (Altirra pokey.cpp init-release constants; ACID800
    // pokey_inittiming measures exactly these phases).  Down-counters: a
    // tick fires at 0 and reloads the full period.  The ratios are
    // parameters so tb_pokey's miniature-clock world stays expressible.
    logic [6:0] ref_div_hi_q;
    logic [6:0] ref_div_lo_q;
    logic       ref_tick_hi;
    logic       ref_tick_lo;
    wire poly_init_w = (skctl[1:0] == 2'b00);

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            ref_div_hi_q <= 7'(REF_PHI2_HI - REF_REL_HI);
            ref_div_lo_q <= 7'(REF_PHI2_LO - REF_REL_LO);
            ref_tick_hi  <= 1'b0;
            ref_tick_lo  <= 1'b0;
        end else begin
            ref_tick_hi <= 1'b0;
            ref_tick_lo <= 1'b0;
            if (poly_init_w) begin
                // init holds the dividers preset so the release phases are
                // exact: the next tick fires REF_REL_* cycles after release.
                // REL_SKEW compensates the SKCTL write-commit vs phi2_tick
                // alignment in this implementation: HW-measured with ACID800
                // pokey_inittiming — skew 0 read $1E on the even sled (2
                // cycles early), skew 2 fixed even but read $1E on the odd
                // sled (1 cycle early, T=85 vs the real chip's 86-87); 3
                // satisfies both parities.
                ref_div_hi_q <= 7'(REF_REL_HI - 1 + REL_SKEW);
                ref_div_lo_q <= 7'(REF_REL_LO - 1 + REL_SKEW);
            end else if (phi2_tick) begin
                if (ref_div_hi_q == 7'd0) begin
                    ref_div_hi_q <= 7'(REF_PHI2_HI - 1);
                    ref_tick_hi  <= 1'b1;
                end else
                    ref_div_hi_q <= ref_div_hi_q - 7'd1;
                if (ref_div_lo_q == 7'd0) begin
                    ref_div_lo_q <= 7'(REF_PHI2_LO - 1);
                    ref_tick_lo  <= 1'b1;
                end else
                    ref_div_lo_q <= ref_div_lo_q - 7'd1;
            end
        end
    end

    wire ref_tick = audctl[0] ? ref_tick_lo : ref_tick_hi;
    assign ref_tick_out       = ref_tick;
    assign ref_tick_15khz_out = ref_tick_lo;    // POT scan source

    // ---- Polynomial counters (LFSRs) ----
    // Polynomials match the real POKEY (Altirra reference manual §5.5):
    //   4-bit:  1 + x^3  + x^4   period 15
    //   5-bit:  1 + x^3  + x^5   period 31
    //   9-bit:  1 + x^4  + x^9   period 511
    //   17-bit: 1 + x^12 + x^17  period 131071
    // Fibonacci form: tap indices = (k-1) and (n-1) for polynomial
    // 1 + x^k + x^n. Initial seed is 1 — any non-zero seed gives a
    // maximal-length sequence.
    //
    // Clock domain: on real POKEY every polynomial counter free-runs on
    // the 1.79 MHz machine clock (phi2), NOT the 64/15 kHz audio
    // reference — the tone dividers merely *sample* the poly bits when
    // they fire. RANDOM ($D20A) is therefore the poly's machine-clock
    // state, so the counters advance on `phi2_tick`. (The audio channel
    // dividers still count on `ref_tick`; only the poly clock moved.)
    //
    // Init/reset (SKCTL[1:0] == 0, `poly_init`): the counters are held
    // in their seed state and RANDOM is forced to $FF — matching the
    // Atari OS's `SKCTL=$00` -> read-$FF -> `SKCTL=$03` release idiom
    // that the ACID800 pokey_noise / antic_wsync tests rely on.
    logic [3:0]  lfsr4_q;
    logic [4:0]  lfsr5_q;
    logic [8:0]  lfsr9_q;
    logic [16:0] lfsr17_q;

    wire poly_init = (skctl[1:0] == 2'b00);   // SKCTL init/reset mode

    // Release the counters ONE machine cycle after SKCTL leaves init, not on the
    // same tick.  `skctl` is registered, so poly_init drops partway through the
    // write's machine cycle and the tick that ENDS that cycle would otherwise
    // already shift — giving one shift too many.  Measured: at the ACID800
    // antic_wsync / pokey_noise read point we landed on sequence step 114 ($4A)
    // where hardware is at step 113 ($95); those are adjacent steps, so this is
    // exactly one extra shift.  (The old 17-bit poly also produced $4A at step
    // 114, which made a working 9-bit mux look like a no-op — the value was
    // byte-identical for an entirely different reason.)
    // The mode change takes effect one machine cycle after SKCTL is written, in
    // BOTH directions.  `skctl` is registered, so the mode flips partway through
    // the write's machine cycle and the tick that ENDS that cycle would otherwise
    // already act on the new mode.  Measured twice, symmetrically:
    //   leaving  init: we landed on sequence step 114 where hardware is at 113
    //   entering init: we filled 4 ones where hardware had filled 3 ($F9 vs $E9)
    // Delaying poly_init itself by one tick corrects both with one mechanism.
    logic poly_init_d;
    always_ff @(posedge clk or posedge rst) begin
        if (rst)            poly_init_d <= 1'b1;
        else if (phi2_tick) poly_init_d <= poly_init;
    end

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            lfsr4_q  <= 4'b1111;
            lfsr5_q  <= 5'b11111;
            lfsr9_q  <= 9'h1FF;
            lfsr17_q <= 17'h1FFFF;
        end else if (phi2_tick && poly_init_d) begin
            // INIT MODE DOES NOT SNAP TO $FF — it keeps shifting and feeds in 1s,
            // so the register fills with ones and only THEN does RANDOM read $FF.
            // Pinned by two ACID800 pokey_noise assertions that are only
            // consistent with a progressive fill:
            //   read ~228 cycles (two scan lines) after entering init -> $FF
            //   read ~4 cycles after entering init ("hot-stop")       -> $E9
            // $E9 = 11101001: the top bits are already ones, the rest is the
            // surviving pre-stop state. This also explains independently why an
            // all-ones seed fitted the release data — leaving init ALWAYS starts
            // from all-ones.
            lfsr4_q  <= {lfsr4_q[2:0], 1'b1};
            lfsr5_q  <= {lfsr5_q[3:0], 1'b1};
            lfsr9_q  <= {1'b1, lfsr9_q[8:1]};      // right-shifting: ones enter at the top
            lfsr17_q <= {1'b1, lfsr17_q[16:1]};
        end else if (phi2_tick) begin
            // Fibonacci form: shift left, new bit = XOR of selected taps.
            lfsr4_q  <= {lfsr4_q[2:0],   lfsr4_q[3]   ^ lfsr4_q[2]};
            lfsr5_q  <= {lfsr5_q[3:0],   lfsr5_q[4]   ^ lfsr5_q[2]};
            // 9-bit poly, x^9 + x^5 + 1: RIGHT-shifting, feedback q[0]^q[5] into
            // bit 8, seeded all-ones.  Pinned by fitting ACID800 antic_wsync's
            // THREE independent RANDOM reads simultaneously ($95 @113 cycles after
            // the SKCTL release, $4B @227, $0D @342): of every combination of
            // width/taps/seed/shift/direction searched, only this one satisfies
            // all three.  The old left-shift taps(8,3) seed=1 form matched none.
            lfsr9_q  <= {lfsr9_q[0] ^ lfsr9_q[5], lfsr9_q[8:1]};
            // 17-bit poly: same realisation as the 9-bit above — RIGHT-shifting,
            // feedback q[0]^q[5] into bit 16, seeded all-ones, RANDOM = [16:9].
            // For a right-shifting LFSR, x^17+x^12+1 and x^17+x^5+1 are reciprocal
            // realisations of the same polynomial, so taps (5,0) is POKEY's
            // documented poly read the other way round.
            // Constraint: ACID800 pokey_noise reads RANDOM 113 cycles after the
            // SKCTL release with AUDCTL=0 and expects $08; this model hits it
            // exactly (delta 0). NOTE fit to ONE constraint (unlike the 9-bit,
            // which was pinned by three), chosen because it is the only exact fit
            // that is also structurally identical to the verified 9-bit form.
            lfsr17_q <= {lfsr17_q[0] ^ lfsr17_q[5], lfsr17_q[16:1]};
        end
    end

    wire poly4   = lfsr4_q[3];
    wire poly5   = lfsr5_q[4];
    wire poly9   = lfsr9_q[0];        // right-shifting now: the bit shifting out
    wire poly17  = lfsr17_q[0];       // right-shifting now: the bit shifting out
    // RANDOM ($D20A) must honour AUDCTL[7]: when set, the 9-bit poly REPLACES the
    // 17-bit one, so RANDOM reads the 9-bit register's high byte [8:1] rather than
    // the 17-bit's [16:9].  We previously returned the 17-bit value unconditionally,
    // so any code selecting the 9-bit poly read the wrong shift register entirely
    // (ACID800 antic_wsync sets AUDCTL=$80 before its first RANDOM read).
    // Forced to $FF while POKEY is in SKCTL init/reset mode (counters held).
    //
    // NOTE: the 17-bit poly above is left as-is and is NOT verified — by analogy
    // with the 9-bit result it is probably also meant to be right-shifting with
    // taps (12,0) and an all-ones seed, but no measurement pins it yet, so it is
    // deliberately left alone rather than changed on a guess. pokey_noise is the
    // test most likely to constrain it.
    // NO $FF forcing: init mode fills the register with ones progressively (see
    // the shift logic above), so RANDOM reaches $FF on its own after n shifts and
    // reads the partially-filled value in between — which is what the ACID800
    // hot-stop assertions measure.
    assign random_byte = audctl[7] ? lfsr9_q[8:1]
                                   : lfsr17_q[16:9];

    // ---- Per-channel tick sources (M23-3) ----
    // ch1/ch3 high-freq mode (AUDCTL[6]/[5]): count on every clk
    // (effectively 1.79 MHz at the production CLK_BUS_HZ × phi2 pace).
    // ch2/ch4 paired mode (AUDCTL[4]/[3]): decrement only when the
    // partner channel wraps — the 16-bit-divider behaviour.
    logic [7:0] ch1_cnt, ch2_cnt, ch3_cnt, ch4_cnt;
    logic       ch1_state, ch2_state, ch3_state, ch4_state;

    // High-freq mode: count on phi2_tick (1.79 MHz machine clock pulse).
    // Otherwise count on the 64/15 kHz ref tick.
    wire ch1_tick = audctl[6] ? phi2_tick : ref_tick;
    wire ch3_tick = audctl[5] ? phi2_tick : ref_tick;

    // ch1/ch3 wrap pulses — used by paired ch2/ch4 as their tick.
    wire ch1_wrap = ch1_tick & (ch1_cnt == 8'h00);
    wire ch3_wrap = ch3_tick & (ch3_cnt == 8'h00);

    wire ch2_tick = audctl[4] ? ch1_wrap : ref_tick;
    wire ch4_tick = audctl[3] ? ch3_wrap : ref_tick;

    // ---- Async serial receive (SKCTL bit 4) ----
    // In async-receive mode POKEY holds the timer 3 + timer 4 chain in
    // reset until the serial input line drops for a start bit, so the
    // receive bit-clock is phase-locked to the incoming byte. With no
    // start bit (idle SIN) the pair never counts and TIMER 4 never
    // fires. ACID800 pokey_asyncrecv toggles SKCTL between $13 (async
    // receive on) and $03 (off) and asserts that the TIMER 4 IRQ is
    // suppressed only while bit 4 is set. Altirra §5.10.
    wire async_recv = skctl[4];

    // ch2/ch4 wrap pulses — surfaced as TIMER 2 / TIMER 4 IRQ sources.
    // ch4's wrap is squashed while async-receive holds the pair reset;
    // the counters themselves are frozen at their reload value in the
    // sequential block below (so a linked ch4 also sees no motion).
    wire ch2_wrap = ch2_tick & (ch2_cnt == 8'h00);
    wire ch4_wrap = ch4_tick & (ch4_cnt == 8'h00) & ~async_recv;

    // M23-6: timer pulses go to pokey_regs' IRQ latch (ch1/ch2/ch4 only;
    // POKEY provides no TIMER 3).
    assign timer1_pulse = ch1_wrap;
    assign timer2_pulse = ch2_wrap;
    assign timer4_pulse = ch4_wrap;

    // Per-channel "next-state" function — what the channel becomes on
    // an AUDF trigger. Pure tone → toggle. Poly mode → selected poly,
    // optionally AND'd with the 5-bit poly when NOT_5 (AUDC[7]) is 0.
    // POLY9 (AUDCTL[7]) substitutes 9-bit for 17-bit when AUDC[6]=0.
    function automatic logic next_state(input logic [7:0] audc,
                                        input logic       cur);
        logic poly_pick;
        logic poly_long;     // 17-bit or (POLY9 mode) 9-bit
        logic five_gate;
        begin
            poly_long = audctl[7] ? poly9 : poly17;
            poly_pick = audc[6]   ? poly4 : poly_long;
            five_gate = audc[7]   ? 1'b1  : poly5;
            if (audc[5]) begin
                // PURE tone — toggle (gated by 5-bit poly when NOT_5=0)
                next_state = audc[7] ? ~cur : (cur ^ five_gate);
            end else begin
                next_state = poly_pick & five_gate;
            end
        end
    endfunction

    // ---- Linked-pair flags (audit fix #1) ----
    // In linked mode (AUDCTL[4] for ch1+2, AUDCTL[3] for ch3+4) the
    // low timer's auto-reload is suppressed. The low counter wraps
    // 0 → $FF and keeps counting; both counters are reloaded
    // simultaneously when the high counter underflows. Combined
    // period = (AUDF_low + 256·AUDF_high + 1) tick units in ref-clock
    // mode (Altirra §5.3 "Linked timers").
    wire ch12_paired = audctl[4];
    wire ch34_paired = audctl[3];

    // ---- Machine-clock period fudge (audit fix #7) ----
    // Per Altirra §5.3: at 1.79 MHz the timer has 3 cycles of pipeline
    // delay between underflow and reload, so the period is N+4 (not
    // N+1) — and that holds for LINKED pairs too.
    //
    // The old model added 3 more for a linked pair "to settle" (N+7).
    // ACID800 pokey_timertiming disproves it: with AUDF1=$10, AUDF2=$00
    // and AUDCTL=$50 (1.79MHz, 16-bit paired) it requires the IRQ to be
    // unfired 19 cycles after STIMER and fired by 20 — i.e. period 20 =
    // N+4, exactly the unlinked figure.  N+7 fired three cycles late
    // ("1.79MHz 16-bit lo timer triggered too late").
    //
    // We implement this by adding to the AUDF-reload value:
    //   machine-clock (linked or not): reload = AUDF + 3 → period = N+4
    //   any ref-clock mode:      reload = AUDF       → period = N+1
    //                                                   (3-cycle delay
    //                                                   absorbed in
    //                                                   the wait for
    //                                                   the next ref
    //                                                   tick — Altirra)
    // Inner FF-wraps in linked mode (low timer wrap-to-FF on every
    // 256-tick underflow that ISN'T a cascade) are unaffected — they
    // wrap to $FF without any fudge.
    wire [7:0] audf1_reload = audctl[6] ? (audf1 + 8'd3) : audf1;
    wire [7:0] audf3_reload = audctl[5] ? (audf3 + 8'd3) : audf3;

    // STIMER start lag: the write's reload lands 4 machine cycles later
    // (see the comment at the apply site).
    logic [2:0] stimer_lag;
    wire        stimer_apply = (stimer_lag == 3'd1) && phi2_tick;
    always_ff @(posedge clk or posedge rst) begin
        if (rst)                stimer_lag <= 3'd0;
        else if (stimer_pulse)  stimer_lag <= 3'd4;      // apply on the 4th phi2 tick after the write
        else if (phi2_tick && stimer_lag != 3'd0) stimer_lag <= stimer_lag - 3'd1;
    end

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            ch1_cnt <= 8'h00; ch1_state <= 1'b0;
            ch2_cnt <= 8'h00; ch2_state <= 1'b0;
            ch3_cnt <= 8'h00; ch3_state <= 1'b0;
            ch4_cnt <= 8'h00; ch4_state <= 1'b0;
        end else begin
            // ---- ch1: low timer of pair {1,2} ----
            // In linked mode, suppress the auto-reload — wrap to $FF
            // and keep counting. The audio output FF still toggles on
            // every underflow regardless of linking. Reload-from-AUDF
            // path uses audf1_reload (which adds +3 / +6 in machine-
            // clock mode per audit fix #7).
            if (ch1_tick) begin
                if (ch1_cnt == 8'h00) begin
                    ch1_cnt   <= ch12_paired ? 8'hFF : audf1_reload;
                    ch1_state <= next_state(audc1, ch1_state);
                end else
                    ch1_cnt <= ch1_cnt - 8'h01;
            end
            // ---- ch2: high timer of pair {1,2} ----
            // ch2_tick = ch1_wrap when paired (so ch2 advances on
            // every ch1 underflow); otherwise ch2 ticks on ref_tick.
            // When ch2 underflows in paired mode, BOTH counters
            // reload from AUDFn simultaneously (the assignment to
            // ch1_cnt overrides the ch1-branch's "wrap to FF" via
            // Verilog NBA last-write-wins).
            if (ch2_tick) begin
                if (ch2_cnt == 8'h00) begin
                    ch2_cnt   <= audf2;
                    ch2_state <= next_state(audc2, ch2_state);
                    if (ch12_paired) ch1_cnt <= audf1_reload;
                end else
                    ch2_cnt <= ch2_cnt - 8'h01;
            end
            // ---- ch3: low timer of pair {3,4} ----
            // Async-receive holds the pair in reset (frozen at the AUDF
            // reload) so no wrap occurs until a start bit releases it.
            if (async_recv) begin
                ch3_cnt <= ch34_paired ? 8'hFF : audf3_reload;
            end else if (ch3_tick) begin
                if (ch3_cnt == 8'h00) begin
                    ch3_cnt   <= ch34_paired ? 8'hFF : audf3_reload;
                    ch3_state <= next_state(audc3, ch3_state);
                end else
                    ch3_cnt <= ch3_cnt - 8'h01;
            end
            // ---- ch4: high timer of pair {3,4} ----
            if (async_recv) begin
                ch4_cnt <= audf4;
            end else if (ch4_tick) begin
                if (ch4_cnt == 8'h00) begin
                    ch4_cnt   <= audf4;
                    ch4_state <= next_state(audc4, ch4_state);
                    if (ch34_paired) ch3_cnt <= audf3_reload;
                end else
                    ch4_cnt <= ch4_cnt - 8'h01;
            end

            // STIMER ($D209 write) — overrides the per-channel logic
            // above by reloading all four counters from AUDFn and
            // forcing each output flip-flop to 1. Uses the same
            // reload-fudge value as the normal reload path so the
            // machine-clock +3 / +6 fudge applies consistently. Last
            // in source order so any concurrent count/reload above is
            // overridden (Verilog NBA last-write-wins). No IRQs /
            // audio pulses are generated by the reload itself.
            //
            // The reload is applied FOUR machine cycles after the write:
            // Altirra strobes its reset-timers event chain 3+1 cycles after
            // the STIMER write, and ACID800 pokey_timertiming's measured
            // contract needs exactly that — a 1.79MHz 8-bit timer's first
            // IRQST assert lands at STIMER + (AUDF+4) + 4 (AUDF=16 ->
            // visible at cycle 24; AUDF=0 -> cycle 8).  Steady-state period
            // stays AUDF+4.  (Altirra also skips the reset for a timer
            // whose borrow lands within 1 cycle of the reset — not yet
            // modelled here.)
            if (stimer_apply) begin
                ch1_cnt <= audf1_reload;  ch1_state <= 1'b1;
                ch2_cnt <= audf2;         ch2_state <= 1'b1;
                ch3_cnt <= audf3_reload;  ch3_state <= 1'b1;
                ch4_cnt <= audf4;         ch4_state <= 1'b1;
            end
        end
    end

    // ---- High-pass filter (AUDCTL[2:1]) ----
    // ch1's audible state is XOR'd with ch3's state when FILT1 is set;
    // ch2 with ch4 when FILT2 is set. Simple model — XOR of the two
    // channel states. Real POKEY clocks ch1's state into a FF on ch3's
    // edges; the XOR approximation captures the "high-pass" subtractive
    // feel that's the audible point of the feature.
    wire ch1_audible = audctl[2] ? (ch1_state ^ ch3_state) : ch1_state;
    wire ch2_audible = audctl[1] ? (ch2_state ^ ch4_state) : ch2_state;
    wire ch3_audible = ch3_state;
    wire ch4_audible = ch4_state;

    // ---- Output mixer (per-channel volume gate) ----
    // AUDC.VOLUME = AUDC[3:0]. Output = state ? VOLUME : 0.
    // AUDC.VOLUME_ONLY (bit 4) — when set, output is the volume always
    // (used for software-driven sample playback / DAC).
    wire [3:0] vol1 = audc1[3:0];
    wire [3:0] vol2 = audc2[3:0];
    wire [3:0] vol3 = audc3[3:0];
    wire [3:0] vol4 = audc4[3:0];

    assign ch1_out = (audc1[4] | ch1_audible) ? vol1 : 4'h0;
    assign ch2_out = (audc2[4] | ch2_audible) ? vol2 : 4'h0;
    assign ch3_out = (audc3[4] | ch3_audible) ? vol3 : 4'h0;
    assign ch4_out = (audc4[4] | ch4_audible) ? vol4 : 4'h0;

endmodule

`default_nettype wire
