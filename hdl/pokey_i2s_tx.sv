// pokey_i2s_tx.sv — dual-POKEY stereo mixer → HDMI audio-packet feed (M23-7).
//
// Per the M23-7 roadmap entry, the rp-XT board allocates no external
// I2S pins: the audio path from POKEY into the HDMI audio packetiser
// is a direct fabric feed. This module replaces what would have been
// an I2S TX driving an external pin + I2S RX consuming it; the 4-deep
// audio buffer that hdmi_pkt_source reads is generated here directly.
//
// Stereo via the 130XE-style stereo POKEY mod: a second POKEY mapped
// at $D21x carries the right channel. This module takes 4-channel
// input from each POKEY and produces independent L+R 24-bit LPCM.
//
// Stages:
//
//   1. Channel sum (per side) — ch1..ch4_l (4-bit each, 0..15) → 6-bit
//      sum (0..60). Mapped to 24-bit unsigned LPCM by left-shifting
//      18 places. Same for ch1..ch4_r. POKEY is naturally
//      positive-valued; sinks AC-couple, so the DC offset is not
//      audible. Left and right are independent.
//
//   2. Sample strobe — fractional-N divider from clk_bus to SAMPLE_HZ
//      (default 48 kHz). Phase accumulator: phase += inc each clk;
//      strobe pulses when phase wraps. inc = SAMPLE_HZ × 2^PHASE_BITS
//      / CLK_BUS_HZ.
//
//   3. 4-deep ring buffer — every 4 sample strobes, latch buf[0..3]L
//      and buf[0..3]R into audio_l0..3 / r0..3, set audio_present =
//      4'hF, fire frame_ready for one cycle. audio_flat[i] = both L
//      and R for slot i are zero. audio_block_start[i] = 1 when
//      sample_i sits on a 192-frame IEC block boundary.
//
// Signals are produced in the clk_bus domain. The wrapping HDMI module
// (in clk_pix domain) is expected to add 2-FF synchronisers; the
// outputs are slow-changing enough (≥ 83 µs between updates) that
// CDC is straightforward.

`default_nettype none

module pokey_i2s_tx #(
    parameter int unsigned CLK_BUS_HZ = 161_079_525,    // 90 × NTSC phi2 (M-cache-rework Step 5b)
    parameter int unsigned SAMPLE_HZ  = 48_000,
    parameter int unsigned PHASE_BITS = 24
) (
    input  wire        clk,
    input  wire        rst,

    // From left POKEY ($D20x) — drives the left audio channel.
    input  wire  [3:0] ch1_l,
    input  wire  [3:0] ch2_l,
    input  wire  [3:0] ch3_l,
    input  wire  [3:0] ch4_l,

    // From right POKEY ($D21x) — drives the right audio channel.
    input  wire  [3:0] ch1_r,
    input  wire  [3:0] ch2_r,
    input  wire  [3:0] ch3_r,
    input  wire  [3:0] ch4_r,

    // M-aux-audio: stereo ADC inputs (PCM1808 via pcm1808_rx). Both
    // treated as mono signals from independent sources (Lin = SIO
    // AUDIO_IN, Rin = PBI/cart AUDIO_IN); summed into BOTH sides of
    // the final stereo output. Soft saturation (clamp to ±max) on
    // overflow — see docs/future-work.md § Cart/PBI AUDIO_IN.
    // Default is 24'h0 (silence) so existing testbenches that don't
    // drive these ports get unchanged behaviour.
    input  wire signed [23:0] adc_l_in,
    input  wire signed [23:0] adc_r_in,

    // To hdmi_pkt_source. 4 stereo subpackets, 24-bit LPCM, true stereo
    // (left from POKEY1, right from POKEY2). Stable until the next
    // frame_ready.
    output logic [23:0] audio_l0, audio_l1, audio_l2, audio_l3,
    output logic [23:0] audio_r0, audio_r1, audio_r2, audio_r3,
    output logic [3:0]  audio_present,
    output logic [3:0]  audio_flat,
    output logic [3:0]  audio_block_start,
    output logic        frame_ready,

    // Diagnostics.
    output wire         sample_strobe,
    output wire  [23:0] last_sample_l,
    output wire  [23:0] last_sample_r
);

    // ---- Phase-accumulator divider for SAMPLE_HZ ----
    // 64-bit intermediate keeps the parameter expression overflow-safe
    // for any reasonable CLK_BUS_HZ / SAMPLE_HZ ratio.
    localparam logic [63:0] PHASE_INC_FULL =
        ((64'(SAMPLE_HZ) * (64'h1 << PHASE_BITS)) / 64'(CLK_BUS_HZ));
    localparam logic [PHASE_BITS-1:0] PHASE_INC = PHASE_INC_FULL[PHASE_BITS-1:0];

    logic [PHASE_BITS-1:0] phase_q;
    logic                  phase_carry_q;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            phase_q       <= '0;
            phase_carry_q <= 1'b0;
        end else begin
            // Sum is one bit wider than phase_q so the carry-out lands
            // in [PHASE_BITS]; truncating the store back to PHASE_BITS
            // gives the modulo-2^PHASE_BITS phase.
            logic [PHASE_BITS:0] sum;
            sum           = {1'b0, phase_q} + {1'b0, PHASE_INC};
            phase_q       <= sum[PHASE_BITS-1:0];
            phase_carry_q <= sum[PHASE_BITS];
        end
    end

    assign sample_strobe = phase_carry_q;

    // ---- Channel sum → 24-bit LPCM (left and right) + ADC mix ----
    // POKEY's channel-sum (0..60) left-shifted 18 places is the
    // unsigned-positive base. ADC inputs are signed 24-bit two's
    // complement and treated as a delta on top. Sum in a 26-bit
    // signed intermediate to absorb both negative ADC swing and
    // additive overflow, then clamp to 24-bit unsigned [0, 0xFFFFFF].
    //
    // With adc_l_in = adc_r_in = 0 (silence / unpopulated PCM1808),
    // the sum reduces to the original `{sum_w[5:0], 18'b0}` value
    // exactly — so existing audio tests (tb_pokey_i2s) see no
    // behaviour change.
    wire [6:0]  sum_l_w           = ch1_l + ch2_l + ch3_l + ch4_l;
    wire [6:0]  sum_r_w           = ch1_r + ch2_r + ch3_r + ch4_r;
    wire [23:0] pokey_lpcm_l_w    = {sum_l_w[5:0], 18'b0};
    wire [23:0] pokey_lpcm_r_w    = {sum_r_w[5:0], 18'b0};

    // 26-bit signed sum: POKEY zero-extended (always positive) plus
    // both ADC inputs sign-extended. Worst case range:
    //   max = 0x0F00000 + 0x07FFFFF + 0x07FFFFF = +0x01EFFFFE  (26 bits)
    //   min = 0x0000000 - 0x0800000 - 0x0800000 = -0x01000000  (26 bits)
    wire signed [25:0] mix_l_full = $signed({2'b00, pokey_lpcm_l_w})
                                  + $signed({{2{adc_l_in[23]}}, adc_l_in})
                                  + $signed({{2{adc_r_in[23]}}, adc_r_in});
    wire signed [25:0] mix_r_full = $signed({2'b00, pokey_lpcm_r_w})
                                  + $signed({{2{adc_l_in[23]}}, adc_l_in})
                                  + $signed({{2{adc_r_in[23]}}, adc_r_in});

    // Soft saturation to 24-bit unsigned [0, 0xFFFFFF].
    function automatic logic [23:0] sat24u(input logic signed [25:0] x);
        if (x < 0)                            sat24u = 24'h000000;
        else if (x > $signed(26'sh00FFFFFF))  sat24u = 24'hFFFFFF;
        else                                   sat24u = x[23:0];
    endfunction

    wire [23:0] lpcm_l_w = sat24u(mix_l_full);
    wire [23:0] lpcm_r_w = sat24u(mix_r_full);

    assign last_sample_l = lpcm_l_w;
    assign last_sample_r = lpcm_r_w;

    // ---- 4-deep ring buffer + IEC 192-frame block tracker ----
    // Slot buffers carry both L and R for each of the 3 captured
    // samples; slot 3 lands directly into the output regs.
    logic [23:0] buf0_l_q, buf1_l_q, buf2_l_q;
    logic [23:0] buf0_r_q, buf1_r_q, buf2_r_q;
    logic [1:0]  buf_idx_q;                    // 0..3 — next slot to fill
    logic [7:0]  iec_idx_q;                    // 0..191 cycle position
    logic [3:0]  block_start_acc_q;            // accumulating mask

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            buf0_l_q <= 24'h0; buf1_l_q <= 24'h0; buf2_l_q <= 24'h0;
            buf0_r_q <= 24'h0; buf1_r_q <= 24'h0; buf2_r_q <= 24'h0;
            buf_idx_q          <= 2'd0;
            iec_idx_q          <= 8'd0;
            block_start_acc_q  <= 4'h0;
            audio_l0 <= 24'h0; audio_l1 <= 24'h0; audio_l2 <= 24'h0; audio_l3 <= 24'h0;
            audio_r0 <= 24'h0; audio_r1 <= 24'h0; audio_r2 <= 24'h0; audio_r3 <= 24'h0;
            audio_present     <= 4'h0;
            audio_flat        <= 4'hF;          // start silent
            audio_block_start <= 4'h0;
            frame_ready       <= 1'b0;
        end else begin
            frame_ready <= 1'b0;

            if (sample_strobe) begin
                // Stash sample into the right slot (L+R together).
                case (buf_idx_q)
                    2'd0: begin buf0_l_q <= lpcm_l_w; buf0_r_q <= lpcm_r_w; end
                    2'd1: begin buf1_l_q <= lpcm_l_w; buf1_r_q <= lpcm_r_w; end
                    2'd2: begin buf2_l_q <= lpcm_l_w; buf2_r_q <= lpcm_r_w; end
                    default: ;     // slot 3 lands directly into outputs
                endcase

                // Track block-start mask: bit set when a sample in this
                // packet lands on the 192-frame IEC boundary.
                if (iec_idx_q == 8'd0) begin
                    block_start_acc_q[buf_idx_q] <= 1'b1;
                end

                // Advance IEC frame index modulo 192.
                if (iec_idx_q == 8'd191) iec_idx_q <= 8'd0;
                else                     iec_idx_q <= iec_idx_q + 8'd1;

                if (buf_idx_q == 2'd3) begin
                    // Frame complete — present 4 stereo samples.
                    audio_l0 <= buf0_l_q;  audio_r0 <= buf0_r_q;
                    audio_l1 <= buf1_l_q;  audio_r1 <= buf1_r_q;
                    audio_l2 <= buf2_l_q;  audio_r2 <= buf2_r_q;
                    audio_l3 <= lpcm_l_w;  audio_r3 <= lpcm_r_w;
                    audio_present <= 4'hF;
                    // Per-slot flat: set when BOTH L and R were silent.
                    audio_flat    <= {(lpcm_l_w  == 24'h0) & (lpcm_r_w  == 24'h0),
                                      (buf2_l_q == 24'h0) & (buf2_r_q == 24'h0),
                                      (buf1_l_q == 24'h0) & (buf1_r_q == 24'h0),
                                      (buf0_l_q == 24'h0) & (buf0_r_q == 24'h0)};
                    audio_block_start <= block_start_acc_q
                                       | ((iec_idx_q == 8'd0) ? 4'b1000 : 4'b0000);
                    frame_ready       <= 1'b1;
                    buf_idx_q         <= 2'd0;
                    block_start_acc_q <= 4'h0;
                end else begin
                    buf_idx_q <= buf_idx_q + 2'd1;
                end
            end
        end
    end

endmodule

`default_nettype wire
