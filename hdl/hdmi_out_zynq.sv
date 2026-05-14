// hdmi_out_zynq.sv — Zynq-compatible HDMI output block for SiI9022A.
//
// Drop-in replacement for the Efinix-specific hdmi_out.sv (which
// contains TMDS serializers using vendor OSER10 primitives that don't
// exist on Zynq).
//
// This module:
//   1. Instantiates vbeam (same timing engine — identical port map)
//   2. Exposes the same timing ports (h_count, v_count, de, hsync,
//      vsync, line_start, frame_start, vbi_start, atari_row, vcount)
//   3. TMDS output ports are driven low (unused on Zynq — the SiI9022A
//      on the Z-Turn SOM takes parallel RGB565 + sync)
//   4. Audio + packet ports exist but are stubbed (SiI9022A handles
//      audio embedding internally; for initial bring-up video only)
//
// Design: parallel RGB565 is produced by antic_top's top-level
// assignments (rgb_r_o/rgb_g_o/rgb_b_o/rgb_hsync_o/rgb_vsync_o/
// rgb_de_o/rgb_pixclk_o) — not from this module. This module exists
// solely so antic_top's hdmi_out instantiation compiles on Zynq.

`default_nettype none

module hdmi_out #(
    parameter int H_ACTIVE      = 800,
    parameter int H_FRONT_PORCH = 40,
    parameter int H_SYNC_WIDTH  = 128,
    parameter int H_BACK_PORCH  = 88,
    parameter int V_ACTIVE      = 600,
    parameter int V_FRONT_PORCH = 1,
    parameter int V_SYNC_WIDTH  = 4,
    parameter int V_BACK_PORCH  = 23,
    parameter int ANTIC_LINES_NATIVE = 384,
    parameter bit HSYNC_ACTIVE_LOW = 1'b0,
    parameter bit VSYNC_ACTIVE_LOW = 1'b0,
    parameter int N_VALUE        = 6144,
    parameter int CTS_VALUE      = 40000
) (
    input  wire         clk_pix,
    input  wire         clk_bit,         // unused on Zynq (no TMDS serializer)
    input  wire         rst,

    // RGB888 input — valid during de.
    input  wire  [7:0] rgb_r,
    input  wire  [7:0] rgb_g,
    input  wire  [7:0] rgb_b,

    // Audio sample inputs — stubbed on Zynq (SiI9022A handles audio).
    input  wire  [23:0] audio_l0, audio_l1, audio_l2, audio_l3,
    input  wire  [23:0] audio_r0, audio_r1, audio_r2, audio_r3,
    input  wire  [3:0]  audio_present,
    input  wire  [3:0]  audio_flat,
    input  wire  [3:0]  audio_block_start,

    // Packet selector — unused on Zynq.
    input  wire  [2:0]  pkt_select,

    // Timing exposure (driven by vbeam, same as original).
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

    // Period state (exposed for testbench observation).
    output logic [2:0] period,

    // 4 TMDS lanes — tied low on Zynq (no serializer).
    output wire        tmds_r,
    output wire        tmds_g,
    output wire        tmds_b,
    output wire        tmds_clk
);

    // ---- vbeam (identical to original) ----------------------------------
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

    // ---- Period state (simplified — video-only on Zynq) -----------------
    always_comb begin
        if (de_w)   period = 3'd0;   // P_VIDEO
        else        period = 3'd1;   // P_CONTROL (no data islands on Zynq)
    end

    // ---- TMDS outputs (tied low — SiI9022A takes parallel RGB) ---------
    assign tmds_r   = 1'b0;
    assign tmds_g   = 1'b0;
    assign tmds_b   = 1'b0;
    assign tmds_clk = 1'b0;

endmodule

`default_nettype wire
