// hdmi_out.sv — HDMI 1.4a output: vbeam + 3 TMDS encoders + 4 serializers
// + period sequencer with control / preamble / guard band / data island
// scheduling.
//
// Supersedes tmds_out for HDMI mode (carries audio via data islands).
// tmds_out is kept for pure-DVI sink interop testing.
//
// Per-line layout (defaults are 800×600@60):
//   h_count 0..(H_ACTIVE-1)      P_VIDEO       — RGB → tmds_encoder, de=1
//   ... H_ACTIVE..+11            P_CONTROL_F   — front-of-line control (≥12)
//   ... +12..+19                 P_DI_PRE      — data island preamble (8)
//   ... +20..+21                 P_DI_GLEAD    — leading guard band (2)
//   ... +22..+53                 P_DATA_ISL    — TERC4 packet payload (32)
//   ... +54..+55                 P_DI_GTRAIL   — trailing guard band (2)
//   ... +56..(H_TOTAL-11)        P_CONTROL_B   — back-of-line control
//   ... (H_TOTAL-10)..(H_TOTAL-3) P_VID_PRE    — video preamble (8)
//   ... (H_TOTAL-2)..(H_TOTAL-1) P_VID_GUARD   — leading video guard (2)
//
// The data island carries one packet per line. The packet selector is
// driven externally (`pkt_select` input) so the caller can rotate
// audio sample / clock-regen / InfoFrames / null per its own pacing
// policy. A FIFO + scheduler is left to the integration milestone.
//
// Per-lane symbol selection per period:
//
//   Lane 0 (blue):
//     P_VIDEO              tmds_encoder(rgb_b)
//     P_CONTROL_F/B,
//     P_VID_PRE,           tmds_encoder(de=0, c={vsync_ah, hsync_ah})
//     P_DI_PRE
//     P_VID_GUARD          0b1011001100  (HDMI §5.2.2.1)
//     P_DI_GLEAD/GTRAIL    0b1011001100 if hsync=0, else 0b0100110011
//     P_DATA_ISL           terc4_encoder(lane0_nibble)
//
//   Lane 1 (green):
//     P_VIDEO              tmds_encoder(rgb_g)
//     P_CONTROL_F/B        tmds_encoder(de=0, c={CTL1, CTL0} = 00)
//     P_VID_PRE            tmds_encoder(de=0, c=01)  (CTL[3:0] = 0001)
//     P_DI_PRE             tmds_encoder(de=0, c=01)  (CTL[3:0] = 0101)
//     P_VID_GUARD,
//     P_DI_GLEAD/GTRAIL    0b0100110011
//     P_DATA_ISL           terc4_encoder(lane1_nibble)
//
//   Lane 2 (red):
//     P_VIDEO              tmds_encoder(rgb_r)
//     P_CONTROL_F/B,
//     P_VID_PRE            tmds_encoder(de=0, c={CTL3, CTL2} = 00)
//     P_DI_PRE             tmds_encoder(de=0, c=01)  (CTL2=1)
//     P_VID_GUARD          0b1011001100
//     P_DI_GLEAD/GTRAIL    0b1011001100
//     P_DATA_ISL           terc4_encoder(lane2_nibble)

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
    parameter int N_VALUE        = 6144,    // 48 kHz @ 40 MHz pixel clock
    parameter int CTS_VALUE      = 40000
) (
    input  wire        clk_pix,
    input  wire        clk_bit,
    input  wire        rst,

    // RGB888 input — valid during de.
    input  wire  [7:0] rgb_r,
    input  wire  [7:0] rgb_g,
    input  wire  [7:0] rgb_b,

    // Audio sample inputs for the audio sample packet.
    input  wire  [23:0] audio_l0, audio_l1, audio_l2, audio_l3,
    input  wire  [23:0] audio_r0, audio_r1, audio_r2, audio_r3,
    input  wire  [3:0]  audio_present,
    input  wire  [3:0]  audio_flat,
    input  wire  [3:0]  audio_block_start,

    // Packet selector — caller rotates between audio sample, audio clk
    // regen, AVI / Audio InfoFrame, null per their own policy.
    input  wire  [2:0]  pkt_select,

    // Timing exposure.
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

    // 4 TMDS lanes, single-ended (sim).
    output wire        tmds_r,
    output wire        tmds_g,
    output wire        tmds_b,
    output wire        tmds_clk
);

    // ---- vbeam ----------------------------------------------------------
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

    wire hsync_ah = hsync_w ^ HSYNC_ACTIVE_LOW;
    wire vsync_ah = vsync_w ^ VSYNC_ACTIVE_LOW;

    // ---- Period state machine -------------------------------------------
    localparam logic [2:0] P_VIDEO     = 3'd0;
    localparam logic [2:0] P_CONTROL_F = 3'd1;
    localparam logic [2:0] P_DI_PRE    = 3'd2;
    localparam logic [2:0] P_DI_GLEAD  = 3'd3;
    localparam logic [2:0] P_DATA_ISL  = 3'd4;
    localparam logic [2:0] P_DI_GTRAIL = 3'd5;
    localparam logic [2:0] P_CONTROL_B = 3'd6;
    localparam logic [2:0] P_VID_PRE   = 3'd7;
    // P_VID_GUARD overloaded onto P_VIDEO since the symbol mux is
    // distinct anyway — but to keep the FSM legible use a separate
    // "is_video_guard" derived signal below.

    localparam int H_TOTAL_INT = H_ACTIVE + H_FRONT_PORCH + H_SYNC_WIDTH + H_BACK_PORCH;

    // Boundary thresholds (computed once at elaboration).
    localparam int CTRL_F_END  = H_ACTIVE + 12;          // 812 for 800×600
    localparam int DI_PRE_END  = CTRL_F_END + 8;         // 820
    localparam int DI_GL_END   = DI_PRE_END + 2;         // 822
    localparam int DI_END      = DI_GL_END + 32;         // 854
    localparam int DI_GT_END   = DI_END + 2;             // 856
    localparam int VID_PRE_BEG = H_TOTAL_INT - 10;       // H_TOTAL - 10
    localparam int VID_GD_BEG  = H_TOTAL_INT - 2;        // H_TOTAL - 2

    // is_video_guard exists outside the period enum — output-side only.
    logic is_video_guard;

    always_comb begin
        if (h_count_w < H_ACTIVE[11:0])
            period = P_VIDEO;
        else if (h_count_w < CTRL_F_END[11:0])
            period = P_CONTROL_F;
        else if (h_count_w < DI_PRE_END[11:0])
            period = P_DI_PRE;
        else if (h_count_w < DI_GL_END[11:0])
            period = P_DI_GLEAD;
        else if (h_count_w < DI_END[11:0])
            period = P_DATA_ISL;
        else if (h_count_w < DI_GT_END[11:0])
            period = P_DI_GTRAIL;
        else if (h_count_w < VID_PRE_BEG[11:0])
            period = P_CONTROL_B;
        else if (h_count_w < VID_GD_BEG[11:0])
            period = P_VID_PRE;
        else
            period = P_VIDEO;        // overloaded — actual handling via guard flag
    end
    assign is_video_guard = (h_count_w >= VID_GD_BEG[11:0]);

    // CTL[3:0] per period.
    logic [3:0] ctl;
    always_comb begin
        case (period)
            P_VID_PRE: ctl = 4'b0001;     // CTL0 = 1
            P_DI_PRE:  ctl = 4'b0101;     // CTL0 = 1, CTL2 = 1
            default:   ctl = 4'b0000;
        endcase
    end

    // Per-lane c bits. Encoder ignores c when de=1.
    wire [1:0] c_blue  = {vsync_ah, hsync_ah};
    wire [1:0] c_green = {ctl[1], ctl[0]};
    wire [1:0] c_red   = {ctl[3], ctl[2]};

    wire is_video = (period == P_VIDEO) && !is_video_guard;

    // ---- TMDS encoders (sequential, 1-cycle latency) -------------------
    wire [9:0] tmds_sym_r, tmds_sym_g, tmds_sym_b;

    tmds_encoder u_enc_b (
        .clk(clk_pix), .rst(rst),
        .data(rgb_b), .c(c_blue), .de(is_video), .q_out(tmds_sym_b));
    tmds_encoder u_enc_g (
        .clk(clk_pix), .rst(rst),
        .data(rgb_g), .c(c_green), .de(is_video), .q_out(tmds_sym_g));
    tmds_encoder u_enc_r (
        .clk(clk_pix), .rst(rst),
        .data(rgb_r), .c(c_red), .de(is_video), .q_out(tmds_sym_r));

    // ---- Packet source + packet formatter ------------------------------
    wire [7:0]  pkt_type_w, pkt_hb1_w, pkt_hb2_w;
    wire [55:0] pkt_sp0_w, pkt_sp1_w, pkt_sp2_w, pkt_sp3_w;

    hdmi_pkt_source #(.N_VALUE(N_VALUE), .CTS_VALUE(CTS_VALUE)) u_pkt_src (
        .pkt_select        (pkt_select),
        .audio_l0(audio_l0), .audio_l1(audio_l1),
        .audio_l2(audio_l2), .audio_l3(audio_l3),
        .audio_r0(audio_r0), .audio_r1(audio_r1),
        .audio_r2(audio_r2), .audio_r3(audio_r3),
        .audio_present     (audio_present),
        .audio_flat        (audio_flat),
        .audio_block_start (audio_block_start),
        .pkt_type(pkt_type_w), .pkt_hb1(pkt_hb1_w), .pkt_hb2(pkt_hb2_w),
        .pkt_sp0(pkt_sp0_w), .pkt_sp1(pkt_sp1_w),
        .pkt_sp2(pkt_sp2_w), .pkt_sp3(pkt_sp3_w));

    // hdmi_packet — combinational output: which 4-bit nibble each lane
    // carries on the current data-island cycle.
    wire [4:0] di_cycle = h_count_w[4:0] - DI_GL_END[4:0];
    wire [3:0] lane0_nib_w, lane1_nib_w, lane2_nib_w;

    hdmi_packet u_pkt (
        .pkt_type(pkt_type_w), .pkt_hb1(pkt_hb1_w), .pkt_hb2(pkt_hb2_w),
        .pkt_sp0(pkt_sp0_w), .pkt_sp1(pkt_sp1_w),
        .pkt_sp2(pkt_sp2_w), .pkt_sp3(pkt_sp3_w),
        .cycle_idx(di_cycle),
        .hsync(hsync_ah), .vsync(vsync_ah),
        .lane0_nibble(lane0_nib_w),
        .lane1_nibble(lane1_nib_w),
        .lane2_nibble(lane2_nib_w));

    // TERC4 encoders for the data island period.
    wire [9:0] terc4_sym_b, terc4_sym_g, terc4_sym_r;
    terc4_encoder u_terc_b (.data(lane0_nib_w), .q_out(terc4_sym_b));
    terc4_encoder u_terc_g (.data(lane1_nib_w), .q_out(terc4_sym_g));
    terc4_encoder u_terc_r (.data(lane2_nib_w), .q_out(terc4_sym_r));

    // ---- Guard band symbols -------------------------------------------
    // Both video + data-island guards use these on lanes 1/2; lane 0
    // depends on hsync for data-island guards (but the dominant case
    // is hsync=0 in the back porch).
    localparam logic [9:0] GUARD_LANE1 = 10'b0100110011;
    localparam logic [9:0] GUARD_LANE0_HS0 = 10'b1011001100;
    localparam logic [9:0] GUARD_LANE0_HS1 = 10'b0100110011;
    localparam logic [9:0] GUARD_LANE2 = 10'b1011001100;

    wire is_di_guard = (period == P_DI_GLEAD) || (period == P_DI_GTRAIL);

    wire [9:0] guard_lane0 = (is_di_guard && hsync_ah)
                                ? GUARD_LANE0_HS1 : GUARD_LANE0_HS0;

    // ---- Final per-lane symbol mux -------------------------------------
    // Note on timing: tmds_encoder is 1-cycle registered, so its q_out
    // at cycle T reflects inputs from T-1. terc4 + guard are
    // combinational. To align, we register the period selection one
    // cycle so it points at the period that the encoder INPUTS were
    // computed for — i.e. what the OUTPUT now corresponds to.
    logic [2:0] period_q;
    logic       is_video_guard_q;
    logic [9:0] terc4_sym_b_q, terc4_sym_g_q, terc4_sym_r_q;
    logic [9:0] guard_lane0_q;

    always_ff @(posedge clk_pix or posedge rst) begin
        if (rst) begin
            period_q          <= P_VIDEO;
            is_video_guard_q  <= 1'b0;
            terc4_sym_b_q     <= 10'h0;
            terc4_sym_g_q     <= 10'h0;
            terc4_sym_r_q     <= 10'h0;
            guard_lane0_q     <= GUARD_LANE0_HS0;
        end else begin
            period_q         <= period;
            is_video_guard_q <= is_video_guard;
            terc4_sym_b_q    <= terc4_sym_b;
            terc4_sym_g_q    <= terc4_sym_g;
            terc4_sym_r_q    <= terc4_sym_r;
            guard_lane0_q    <= guard_lane0;
        end
    end

    logic [9:0] sym_r, sym_g, sym_b;
    always_comb begin
        if (is_video_guard_q) begin
            sym_b = GUARD_LANE0_HS0;     // video guard always hsync=0 in back porch end
            sym_g = GUARD_LANE1;
            sym_r = GUARD_LANE2;
        end else begin
            case (period_q)
                P_DI_GLEAD, P_DI_GTRAIL: begin
                    sym_b = guard_lane0_q;
                    sym_g = GUARD_LANE1;
                    sym_r = GUARD_LANE2;
                end
                P_DATA_ISL: begin
                    sym_b = terc4_sym_b_q;
                    sym_g = terc4_sym_g_q;
                    sym_r = terc4_sym_r_q;
                end
                default: begin
                    sym_b = tmds_sym_b;
                    sym_g = tmds_sym_g;
                    sym_r = tmds_sym_r;
                end
            endcase
        end
    end

    // ---- Serializers (same as tmds_out) --------------------------------
    wire [3:0] phase_r, phase_g, phase_b, phase_clk;

    tmds_serializer u_ser_r (
        .bit_clk(clk_bit), .rst(rst), .symbol(sym_r),
        .serial_out(tmds_r), .bit_phase(phase_r));
    tmds_serializer u_ser_g (
        .bit_clk(clk_bit), .rst(rst), .symbol(sym_g),
        .serial_out(tmds_g), .bit_phase(phase_g));
    tmds_serializer u_ser_b (
        .bit_clk(clk_bit), .rst(rst), .symbol(sym_b),
        .serial_out(tmds_b), .bit_phase(phase_b));

    localparam logic [9:0] CLK_PATTERN = 10'b0000011111;
    tmds_serializer u_ser_clk (
        .bit_clk(clk_bit), .rst(rst), .symbol(CLK_PATTERN),
        .serial_out(tmds_clk), .bit_phase(phase_clk));

endmodule

`default_nettype wire
