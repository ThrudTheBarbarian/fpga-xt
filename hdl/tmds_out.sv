// tmds_out.sv — DVI output integration: vbeam sync gen + 3 channel
// TMDS encoders + 4 serializers (R/G/B + clock).
//
// Pixel pipeline (clk_pix):
//   vbeam → hsync, vsync, de, h_count, v_count
//   3 × tmds_encoder takes (rgb_r/g/b, c, de) → 10-bit symbol
//     - blue lane:  c = {vsync, hsync}  (DVI 1.0 §5.2 sync embedding)
//     - red/green:  c = 2'b00
//
// Bit-rate pipeline (clk_bit, exactly 10× clk_pix, phase-aligned):
//   3 × tmds_serializer drains R, G, B symbols LSB-first
//   1 × tmds_serializer for the clock channel — emits a fixed 5-high,
//     5-low pattern (10'b0000011111) that the sink samples to recover
//     the pixel clock (DVI 1.0 §3.3).
//
// Default parameters target 800×600@60 VESA timing (positive sync
// polarity). Override for 640×480 or smaller sim-friendly frames.
//
// In synth (Topaz) the four serializers are replaced by HSIO LVDS
// SERDES primitives via the `EFINITY define inside tmds_serializer;
// this module's wiring is unchanged.

`default_nettype none

module tmds_out #(
    // VESA 800×600@60 defaults.
    parameter int H_ACTIVE      = 800,
    parameter int H_FRONT_PORCH = 40,
    parameter int H_SYNC_WIDTH  = 128,
    parameter int H_BACK_PORCH  = 88,
    parameter int V_ACTIVE      = 600,
    parameter int V_FRONT_PORCH = 1,
    parameter int V_SYNC_WIDTH  = 4,
    parameter int V_BACK_PORCH  = 23,
    // ANTIC active region (line-doubled). For 600 active: 384 ANTIC px,
    // 108 px letterbox top + bottom.
    parameter int ANTIC_LINES_NATIVE = 384,
    // 800×600 VESA = positive sync (active high during pulse).
    parameter bit HSYNC_ACTIVE_LOW = 1'b0,
    parameter bit VSYNC_ACTIVE_LOW = 1'b0
) (
    input  wire        clk_pix,
    input  wire        clk_bit,        // 10 × clk_pix, phase-aligned
    input  wire        rst,

    // RGB888 input — driven by the upstream FB read + palette LUT.
    // Valid during de; values during blanking are don't-cares (encoder
    // ignores them and emits control codes instead).
    input  wire  [7:0] rgb_r,
    input  wire  [7:0] rgb_g,
    input  wire  [7:0] rgb_b,

    // Timing exposure for upstream pipeline.
    output wire [11:0] h_count,
    output wire [11:0] v_count,
    output wire        de,
    output wire        hsync,
    output wire        vsync,
    output wire        line_start,
    output wire        frame_start,
    output wire        vbi_start,
    output wire [15:0] atari_row,
    output wire [7:0]  vcount,

    // 4 TMDS lanes, single-ended (sim). Synth wraps these in LVDS pads.
    output wire        tmds_r,
    output wire        tmds_g,
    output wire        tmds_b,
    output wire        tmds_clk
);

    wire [11:0] h_count_w, v_count_w;
    wire        in_active_w, h_active_w, v_active_w;
    wire        hsync_w, vsync_w, de_w;
    wire        line_start_w, frame_start_w, vbi_start_w;
    wire [15:0] atari_row_w;
    wire [7:0]  vcount_w;

    vbeam #(
        .H_ACTIVE          (H_ACTIVE),
        .H_FRONT_PORCH     (H_FRONT_PORCH),
        .H_SYNC_WIDTH      (H_SYNC_WIDTH),
        .H_BACK_PORCH      (H_BACK_PORCH),
        .V_ACTIVE          (V_ACTIVE),
        .V_FRONT_PORCH     (V_FRONT_PORCH),
        .V_SYNC_WIDTH      (V_SYNC_WIDTH),
        .V_BACK_PORCH      (V_BACK_PORCH),
        .ANTIC_LINES_NATIVE(ANTIC_LINES_NATIVE),
        .HSYNC_ACTIVE_LOW  (HSYNC_ACTIVE_LOW),
        .VSYNC_ACTIVE_LOW  (VSYNC_ACTIVE_LOW)
    ) u_vbeam (
        .clk_pix    (clk_pix),
        .rst        (rst),
        .h_count    (h_count_w),
        .v_count    (v_count_w),
        .in_active  (in_active_w),
        .h_active   (h_active_w),
        .v_active   (v_active_w),
        .hsync      (hsync_w),
        .vsync      (vsync_w),
        .de         (de_w),
        .line_start (line_start_w),
        .frame_start(frame_start_w),
        .vbi_start  (vbi_start_w),
        .atari_row  (atari_row_w),
        .vcount     (vcount_w)
    );

    assign h_count     = h_count_w;
    assign v_count     = v_count_w;
    assign de          = de_w;
    assign hsync       = hsync_w;
    assign vsync       = vsync_w;
    assign line_start  = line_start_w;
    assign frame_start = frame_start_w;
    assign vbi_start   = vbi_start_w;
    assign atari_row   = atari_row_w;
    assign vcount      = vcount_w;

    // ---- Channel encoders ----------------------------------------------
    // Blue lane carries the embedded sync; red/green carry data only.
    // DVI 1.0 §5.2: c[i]=1 means "sync pulse asserted", regardless of
    // the wire-level VESA polarity. vbeam emits hsync/vsync AFTER
    // polarity inversion, so undo it here so the encoder always sees
    // active-high sync.
    wire hsync_ah = hsync_w ^ HSYNC_ACTIVE_LOW;
    wire vsync_ah = vsync_w ^ VSYNC_ACTIVE_LOW;
    wire [1:0] c_blue = {vsync_ah, hsync_ah};
    wire [1:0] c_zero = 2'b00;

    wire [9:0] sym_r;
    wire [9:0] sym_g;
    wire [9:0] sym_b;

    tmds_encoder u_enc_b (
        .clk(clk_pix), .rst(rst),
        .data(rgb_b), .c(c_blue), .de(de_w),
        .q_out(sym_b)
    );

    tmds_encoder u_enc_g (
        .clk(clk_pix), .rst(rst),
        .data(rgb_g), .c(c_zero), .de(de_w),
        .q_out(sym_g)
    );

    tmds_encoder u_enc_r (
        .clk(clk_pix), .rst(rst),
        .data(rgb_r), .c(c_zero), .de(de_w),
        .q_out(sym_r)
    );

    // ---- Serializers ---------------------------------------------------
    // clk_bit is a synchronous 10× multiple of clk_pix from the same PLL,
    // so the encoder→serializer handoff is a same-edge sample (no async
    // CDC path). Serializer captures `symbol` on the clk_bit edge that
    // takes bit_phase from 9→0; that edge coincides with a clk_pix edge,
    // and SV's NBA semantics guarantee the captured value is the
    // pre-edge encoder output — i.e. last pixel's symbol — which is the
    // expected 1-pixel pipeline lag.
    wire [3:0] phase_r, phase_g, phase_b, phase_clk;

    tmds_serializer u_ser_r (
        .bit_clk   (clk_bit),
        .rst       (rst),
        .symbol    (sym_r),
        .serial_out(tmds_r),
        .bit_phase (phase_r)
    );

    tmds_serializer u_ser_g (
        .bit_clk   (clk_bit),
        .rst       (rst),
        .symbol    (sym_g),
        .serial_out(tmds_g),
        .bit_phase (phase_g)
    );

    tmds_serializer u_ser_b (
        .bit_clk   (clk_bit),
        .rst       (rst),
        .symbol    (sym_b),
        .serial_out(tmds_b),
        .bit_phase (phase_b)
    );

    // Clock-channel: emit fixed 1111100000 pattern (LSB-first → wire
    // sequence is 5 ones then 5 zeros, providing a 50% duty pixel-rate
    // clock at the receiver). DVI 1.0 §3.3.
    localparam logic [9:0] CLK_PATTERN = 10'b0000011111;

    tmds_serializer u_ser_clk (
        .bit_clk   (clk_bit),
        .rst       (rst),
        .symbol    (CLK_PATTERN),
        .serial_out(tmds_clk),
        .bit_phase (phase_clk)
    );

endmodule

`default_nettype wire
