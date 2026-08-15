// audio_lpf.sv — band-limit POKEY before it is decimated to 48 kHz.
//
// WHY
//
// POKEY is a megahertz-rate square-wave source.  Its channel outputs switch at
// up to ~1.79 MHz with hard edges, and two of its four channels can be driven
// by poly counters, which are broadband by construction.  Sampling that at
// 48 kHz — which is what the HDMI audio path must do — folds every component
// above 24 kHz back into the audible band at an unrelated frequency.  The tune
// survives, because its fundamentals sit well under Nyquist, but everything
// above them returns as inharmonic hash.  It is heard as harshness and
// roughness, it gets worse the busier the music is, and nothing downstream can
// undo it: the information is destroyed at the moment of sampling.
//
// So band-limit FIRST, here in clk_sys, where POKEY is still oversampled by
// ~80x and the filter is cheap.
//
// WHAT
//
// Two cascaded one-pole IIRs, each
//
//     acc <= acc - (acc >> K) + x            y = acc >> K
//
// which has exactly unity DC gain and a corner at CLK_HZ / (2*pi*2^K).  At
// 150 MHz with K=11 that is ~11.6 kHz per pole.  One pole is not enough — at
// 6 dB/octave, content at 36 kHz (which folds to 12 kHz) would come back only
// ~10 dB down; two poles put it ~19 dB down.  Three would start dulling the
// passband without buying much, since the worst offenders are far above the
// corner.
//
// This is also closer to the machine being emulated than no filter at all.  A
// stock Atari runs POKEY through an RC network into a television speaker;
// neither passes anything remotely like 24 kHz.  The unfiltered path was
// reproducing content the original hardware never delivered.
//
// CENTRING AND HEADROOM
//
// POKEY is unipolar: the mixer's 24-bit LPCM runs 0 .. (60 << 18), never
// negative.  Emitting that as-is puts a large DC offset on the wire and, worse,
// makes digital silence sit at one end of the range rather than the middle.
// Subtracting the midpoint here produces a genuinely centred two's-complement
// sample, so silence is zero and the swing is symmetric.
//
// Four channels at volume 15 are a full-scale square wave.  At unity that would
// occupy ~94 % of digital full scale — louder than almost any real programme
// material, with no headroom, which reads as loud and hard before any other
// problem is considered.  GAIN_SHIFT backs that off; 1 (halve) leaves ~6 dB.

`default_nettype none

module audio_lpf #(
    // Corner = CLK_HZ / (2*pi*2^SHIFT) per pole.  The two stages are separately
    // adjustable because a shift is a power of two, so moving both together
    // halves or doubles the corner — far too coarse when the verdict is "a bit
    // bright, not much".  Staggering them (11 -> ~11.6 kHz, 12 -> ~5.8 kHz)
    // lands the pair around 8 kHz and takes roughly 4 dB off at 11 kHz, which is
    // the small step that description asks for.
    parameter int unsigned LPF_SHIFT  = 11,   // first pole
    parameter int unsigned LPF_SHIFT2 = 12,   // second pole
    // Right-shift applied after centring, for headroom.  1 = -6 dB.
    parameter int unsigned GAIN_SHIFT = 1,
    // Midpoint of the incoming unsigned range: the mixer's full scale is
    // (60 << 18) = 0xF00000, so half of it is 0x780000.
    parameter logic [23:0] MIDPOINT   = 24'h780000
) (
    input  wire        clk,
    input  wire        rst,

    input  wire [23:0] in_l,          // unsigned LPCM from pokey_i2s_tx
    input  wire [23:0] in_r,

    output wire signed [23:0] out_l,  // centred two's complement, band-limited
    output wire signed [23:0] out_r
);

    // Each stage's accumulator holds x * 2^shift, so it needs that many extra
    // bits; size them independently now the shifts differ.
    localparam int unsigned ACC1_W = 24 + LPF_SHIFT;
    localparam int unsigned ACC2_W = 24 + LPF_SHIFT2;

    logic [ACC1_W-1:0] a1_l, a1_r;
    logic [ACC2_W-1:0] a2_l, a2_r;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            a1_l <= '0; a2_l <= '0; a1_r <= '0; a2_r <= '0;
        end else begin
            a1_l <= a1_l - (a1_l >> LPF_SHIFT)  + ACC1_W'(in_l);
            a2_l <= a2_l - (a2_l >> LPF_SHIFT2) + ACC2_W'(a1_l >> LPF_SHIFT);
            a1_r <= a1_r - (a1_r >> LPF_SHIFT)  + ACC1_W'(in_r);
            a2_r <= a2_r - (a2_r >> LPF_SHIFT2) + ACC2_W'(a1_r >> LPF_SHIFT);
        end
    end

    // acc holds x * 2^K, so shifting back down recovers the filtered value.
    wire [23:0] filt_l = 24'(a2_l >> LPF_SHIFT2);
    wire [23:0] filt_r = 24'(a2_r >> LPF_SHIFT2);

    // Centre, then scale for headroom.  The subtraction is done at 25 bits so
    // a sample below the midpoint stays negative rather than wrapping.
    wire signed [24:0] cen_l = $signed({1'b0, filt_l}) - $signed({1'b0, MIDPOINT});
    wire signed [24:0] cen_r = $signed({1'b0, filt_r}) - $signed({1'b0, MIDPOINT});

    assign out_l = 24'(cen_l >>> GAIN_SHIFT);
    assign out_r = 24'(cen_r >>> GAIN_SHIFT);

endmodule

`default_nettype wire
