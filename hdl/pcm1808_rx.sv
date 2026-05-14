// pcm1808_rx.sv — TI PCM1808 stereo I²S ADC receiver.
//
// rp-XT routes two mono audio sources into a PCM1808 (slave mode, no
// SCKI; pin-strapped to **left-justified** 24-bit format):
//
//   PCM1808 Lin  ← SIO AUDIO_IN
//   PCM1808 Rin  ← PBI / cart AUDIO_IN
//
// This module drives BCK (64 × SAMPLE_HZ) + LRCK (= SAMPLE_HZ) out to
// the PCM1808 and clocks SDATA in. After each 24-bit channel half, the
// shifted sample is latched into adc_l / adc_r. Treated as signed
// two's-complement 24-bit (standard I²S/PCM convention).
//
// At SAMPLE_HZ = 48 kHz, BCK = 3.072 MHz, LRCK = 48 kHz. The phase-
// accumulator divider gives long-term-exact BCK rate from the
// CLK_BUS_HZ = 161 MHz clk_bus (same divider style as pokey_i2s_tx).
//
// Format: **left-justified 24-bit** (PCM1808 pin-strap FMT0=0, FMT1=0,
// MD0=0, MD1=0). No 1-bit BCK delay after LRCK transition — MSB of
// the new channel appears on the very next BCK rising edge.
//
//   LRCK ──┐ ┌────── ... ─────────┐ ┌──── ... ───────
//   BCK   _│_│_______... _________│_│____... _________
//   SDATA  X[MSB][b22][b21]...[LSB] X[MSB] ...
//          ^                    ^
//          first L bit         last L bit (bit 24 of L period)
//
// Bits 25..32 of each LRCK half are ignored (driven by PCM1808 but
// out of our 24-bit sample window).
//
// `adc_strobe` pulses for one clk_bus cycle each time both channels
// have been freshly latched — useful for downstream consumers that
// want sample-rate-coincident updates.

`default_nettype none

module pcm1808_rx #(
    parameter int unsigned CLK_BUS_HZ = 161_079_525,   // 90 × NTSC phi2
    parameter int unsigned SAMPLE_HZ  = 48_000,
    parameter int unsigned PHASE_BITS = 24
) (
    input  wire        clk,
    input  wire        rst,

    // PCM1808 pads.
    output wire        adc_bclk_o,    // 64 × SAMPLE_HZ ≈ 3.072 MHz
    output wire        adc_lrck_o,    // SAMPLE_HZ = 48 kHz
    input  wire        adc_sdata_i,   // PCM1808 DOUT, MSB first

    // Latched samples (signed 24-bit two's complement, clk_bus domain).
    // Stable between adc_strobe pulses.
    output logic signed [23:0] adc_l,
    output logic signed [23:0] adc_r,
    output logic               adc_strobe
);

    // ---- BCK phase-accumulator divider --------------------------------
    // BCK toggles at 2 × BCK_HZ events per second. Phase increment chosen
    // so the accumulator wraps that many times per second.
    localparam int unsigned BCK_HZ = SAMPLE_HZ * 64;
    localparam logic [63:0] BCK_PHASE_INC_FULL =
        ((64'(BCK_HZ * 2) * (64'h1 << PHASE_BITS)) / 64'(CLK_BUS_HZ));
    localparam logic [PHASE_BITS-1:0] BCK_PHASE_INC =
        BCK_PHASE_INC_FULL[PHASE_BITS-1:0];

    logic [PHASE_BITS-1:0] bck_phase_q;
    logic                  bck_phase_carry_q;
    logic                  bclk_q;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            bck_phase_q       <= '0;
            bck_phase_carry_q <= 1'b0;
            bclk_q            <= 1'b0;
        end else begin
            logic [PHASE_BITS:0] sum;
            sum                = {1'b0, bck_phase_q} + {1'b0, BCK_PHASE_INC};
            bck_phase_q        <= sum[PHASE_BITS-1:0];
            bck_phase_carry_q  <= sum[PHASE_BITS];
            if (sum[PHASE_BITS]) bclk_q <= ~bclk_q;
        end
    end

    assign adc_bclk_o = bclk_q;

    // ---- BCK edge detect (BCK is FPGA-generated, in clk_bus domain) ---
    logic bclk_prev_q;
    always_ff @(posedge clk or posedge rst) begin
        if (rst) bclk_prev_q <= 1'b0;
        else     bclk_prev_q <= bclk_q;
    end
    wire bclk_rise = bclk_q & ~bclk_prev_q;
    wire bclk_fall = bclk_prev_q & ~bclk_q;

    // ---- LRCK + bit counter -------------------------------------------
    // 64 BCK cycles per LRCK period: 32 for left, 32 for right.
    // bit_cnt advances on BCK rising edge.
    //   bit_cnt 0..31, LRCK=0  → left channel
    //   bit_cnt 0..31, LRCK=1  → right channel
    // LRCK transitions at the start of each 32-bit half.
    logic [4:0] bit_cnt_q;     // 0..31 within a half
    logic       lrck_q;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            bit_cnt_q <= 5'd0;
            lrck_q    <= 1'b1;     // start in "right" state so first transition is to left
        end else if (bclk_rise) begin
            if (bit_cnt_q == 5'd31) begin
                bit_cnt_q <= 5'd0;
                lrck_q    <= ~lrck_q;
            end else begin
                bit_cnt_q <= bit_cnt_q + 5'd1;
            end
        end
    end
    assign adc_lrck_o = lrck_q;

    // ---- I²S left-justified RX shift ----------------------------------
    // PCM1808 drives a new bit on each BCK rising edge. Sample SDATA on
    // BCK falling edge (settled-data window).
    // Left-justified: bit_cnt 0..23 = MSB..bit-0 of current channel,
    // bit_cnt 24..31 = padding (ignored).
    logic signed [23:0] shift_l_q, shift_r_q;
    logic               adc_strobe_q;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            shift_l_q    <= 24'h0;
            shift_r_q    <= 24'h0;
            adc_l        <= 24'h0;
            adc_r        <= 24'h0;
            adc_strobe_q <= 1'b0;
        end else begin
            adc_strobe_q <= 1'b0;

            if (bclk_fall && bit_cnt_q <= 5'd23) begin
                // Shift in the bit that just settled (it became valid
                // on the previous BCK rising edge).
                if (lrck_q == 1'b0)
                    shift_l_q <= {shift_l_q[22:0], adc_sdata_i};
                else
                    shift_r_q <= {shift_r_q[22:0], adc_sdata_i};
            end

            // Latch the just-completed channel at the end of its 24-bit
            // window (bit_cnt=23 with this BCK falling edge captures the
            // LSB).
            if (bclk_fall && bit_cnt_q == 5'd23) begin
                if (lrck_q == 1'b0)
                    adc_l <= {shift_l_q[22:0], adc_sdata_i};
                else begin
                    adc_r        <= {shift_r_q[22:0], adc_sdata_i};
                    adc_strobe_q <= 1'b1;     // both channels now fresh
                end
            end
        end
    end

    assign adc_strobe = adc_strobe_q;

endmodule

`default_nettype wire
