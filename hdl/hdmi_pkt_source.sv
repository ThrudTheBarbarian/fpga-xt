// hdmi_pkt_source.sv — produces the (pkt_type, hb1, hb2, sp[0..3])
// content tuple for the five HDMI packet types we emit:
//
//   PKT_NULL          — Type 0x00, all zeros. Filler island.
//   PKT_AUDIO_CLK     — Type 0x01, Audio Clock Regen. Carries N/CTS so
//                       the sink reconstructs Fs from the TMDS character
//                       rate. Hard-coded for 48 kHz audio at the M15
//                       40 MHz pixel clock (N=6144, CTS=40000).
//   PKT_AUDIO_SAMPLE  — Type 0x02, 4 stereo IEC 60958 sub-frame pairs.
//                       Layout 0 (2-channel L+R), 24-bit LPCM. V/U/C
//                       stubbed to 0 (consumer LPCM); P (parity) computed
//                       per sub-frame.
//   PKT_AVI_INFOFRAME — Type 0x82, 800×600 RGB full-range, 4:3 aspect.
//                       Fixed contents + pre-computed checksum.
//   PKT_AUD_INFOFRAME — Type 0x84, 2-ch LPCM 48 kHz 24-bit. Fixed.
//
// Output feeds directly into hdmi_packet (which adds BCH ECC + lays
// the bits across the 32-cycle data island).
//
// Channel status (the 192-bit IEC block) is stubbed at C=0 for every
// frame. Bits 0-1 = "consumer LPCM" — coincidentally correct for the
// first 2 frames of the block. Sample rate + word length live in the
// Audio InfoFrame, which sinks prefer over the channel status block,
// so this stub is "spec-violating but accepted" rather than incorrect.
// A proper 192-bit cycler can layer in later if a real sink rejects.

`default_nettype none

module hdmi_pkt_source #(
    // Pre-computed N / CTS for 48 kHz audio at the named pixel clock.
    // Defaults: 40 MHz (M15's 800×600 mode). For 25.175 MHz (640×480)
    // the caller should override CTS to the appropriate value.
    parameter int N_VALUE   = 6144,
    parameter int CTS_VALUE = 40000
) (
    input  wire  [2:0]  pkt_select,

    // Audio sample packet inputs (only used when pkt_select == AUDIO_SAMPLE).
    input  wire  [23:0] audio_l0, audio_l1, audio_l2, audio_l3,
    input  wire  [23:0] audio_r0, audio_r1, audio_r2, audio_r3,
    input  wire  [3:0]  audio_present,       // bit i = subpacket i is valid
    input  wire  [3:0]  audio_flat,          // bit i = subpacket i is silent
    input  wire  [3:0]  audio_block_start,   // bit i = subpacket i is start of an IEC block

    // Outputs to hdmi_packet.
    output logic [7:0]  pkt_type,
    output logic [7:0]  pkt_hb1,
    output logic [7:0]  pkt_hb2,
    output logic [55:0] pkt_sp0,
    output logic [55:0] pkt_sp1,
    output logic [55:0] pkt_sp2,
    output logic [55:0] pkt_sp3
);

    localparam logic [2:0] PKT_NULL          = 3'd0;
    localparam logic [2:0] PKT_AUDIO_CLK     = 3'd1;
    localparam logic [2:0] PKT_AUDIO_SAMPLE  = 3'd2;
    localparam logic [2:0] PKT_AVI_INFOFRAME = 3'd3;
    localparam logic [2:0] PKT_AUD_INFOFRAME = 3'd4;

    // Audio Clock Regen subpacket. N occupies bits 0..19 (split as
    // N[7:0] @ 0..7, N[15:8] @ 8..15, N[19:16] @ 16..19, 4 reserved
    // zeros @ 20..23). CTS occupies bits 24..43 with the same split,
    // 12 reserved zeros @ 44..55.
    localparam logic [55:0] AUDIO_CLK_SUBPACKET =
        {12'h0,
         4'h0, CTS_VALUE[19:16], CTS_VALUE[15:8], CTS_VALUE[7:0],
         4'h0, N_VALUE[19:16],   N_VALUE[15:8],   N_VALUE[7:0]};

    // ---- AVI InfoFrame (Type 0x82) — fixed for 800×600 RGB ------------
    // Spec: HDMI 1.4a Section 8.2.1, Table 8-3.
    //   PB1 = 0x00 (Y=00 RGB, A=0 no AFI, B=00, S=00)
    //   PB2 = 0x10 (M=01 4:3 aspect, C=00 no colorimetry data)
    //   PB3 = 0x08 (Q=10 full range, others 0)
    //   PB4..PB13 = 0
    //   Checksum PB0 = (0x100 - (HB0+HB1+HB2 + sum(PB1..PB13))) & 0xFF
    //                = 0x100 - (0x82 + 0x02 + 0x0D + 0x10 + 0x08) & 0xFF
    //                = 0x100 - 0xA9 = 0x57
    localparam logic [7:0]  AVI_PB0 = 8'h57;
    localparam logic [7:0]  AVI_PB1 = 8'h00;
    localparam logic [7:0]  AVI_PB2 = 8'h10;
    localparam logic [7:0]  AVI_PB3 = 8'h08;
    localparam logic [55:0] AVI_SP0 = {8'h00, 8'h00, 8'h00,        // PB6 PB5 PB4
                                       AVI_PB3, AVI_PB2, AVI_PB1, AVI_PB0};
    // PB7..PB13 all zero; subpackets 1..3 carry no payload.

    // ---- Audio InfoFrame (Type 0x84) — 2-ch LPCM 48 kHz 24-bit -------
    //   PB1 = 0x11 (CT=1 LPCM, CC=1 → 2 channels)
    //   PB2 = 0x6C (SF=3 48kHz at bits[7:5]=011, SS=3 24-bit at bits[4:2]=011)
    //   PB3 = 0x00, PB4 = 0x00 (CA = default), PB5 = 0x00 (LSV/DM_INH = 0)
    //   PB6..PB10 = 0
    //   Checksum: 0x100 - (0x84 + 0x01 + 0x0A + 0x11 + 0x6C) & 0xFF
    //           = 0x100 - 0x10C & 0xFF = 0xF4
    localparam logic [7:0]  AUD_PB0 = 8'hF4;
    localparam logic [7:0]  AUD_PB1 = 8'h11;
    localparam logic [7:0]  AUD_PB2 = 8'h6C;
    localparam logic [55:0] AUD_SP0 = {8'h00, 8'h00, 8'h00, 8'h00,  // PB6..PB3
                                       AUD_PB2, AUD_PB1, AUD_PB0};

    // Build a 56-bit Audio Sample subpacket from a stereo frame.
    // Layout (HDMI 1.4a Table 5-13, IEC 60958 truncated to 28 bits per
    // sub-frame):
    //   bits  0..23 : L sample (LSB at bit 0, MSB at 23)
    //   bit   24    : P_L  (even parity over L sample + V + U + C)
    //   bit   25    : C_L
    //   bit   26    : U_L
    //   bit   27    : V_L  (validity, 0 = valid)
    //   bits 28..51 : R sample
    //   bit   52    : P_R
    //   bit   53    : C_R
    //   bit   54    : U_R
    //   bit   55    : V_R
    function automatic logic [55:0] audio_subpacket(
        input logic [23:0] l, r,
        input logic v_l, u_l, c_l,
        input logic v_r, u_r, c_r);
        logic p_l, p_r;
        p_l = ^{v_l, u_l, c_l, l};
        p_r = ^{v_r, u_r, c_r, r};
        // {MSB ... LSB}: V_R U_R C_R P_R R[23:0] V_L U_L C_L P_L L[23:0]
        return {v_r, u_r, c_r, p_r, r, v_l, u_l, c_l, p_l, l};
    endfunction

    always_comb begin
        case (pkt_select)
            PKT_AUDIO_CLK: begin
                pkt_type = 8'h01;
                pkt_hb1  = 8'h00;
                pkt_hb2  = 8'h00;
                pkt_sp0  = AUDIO_CLK_SUBPACKET;
                pkt_sp1  = AUDIO_CLK_SUBPACKET;
                pkt_sp2  = AUDIO_CLK_SUBPACKET;
                pkt_sp3  = AUDIO_CLK_SUBPACKET;
            end

            PKT_AUDIO_SAMPLE: begin
                pkt_type = 8'h02;
                // HB1: bits 7:5 reserved (0), bit 4 = layout (0 = 2-ch),
                //      bits 3:0 = sample_present[3:0].
                pkt_hb1  = {3'b000, 1'b0, audio_present};
                // HB2: bits 7:4 = block_start[3:0], bits 3:0 = sample_flat.
                pkt_hb2  = {audio_block_start, audio_flat};
                pkt_sp0  = audio_subpacket(audio_l0, audio_r0,
                                            1'b0, 1'b0, 1'b0,
                                            1'b0, 1'b0, 1'b0);
                pkt_sp1  = audio_subpacket(audio_l1, audio_r1,
                                            1'b0, 1'b0, 1'b0,
                                            1'b0, 1'b0, 1'b0);
                pkt_sp2  = audio_subpacket(audio_l2, audio_r2,
                                            1'b0, 1'b0, 1'b0,
                                            1'b0, 1'b0, 1'b0);
                pkt_sp3  = audio_subpacket(audio_l3, audio_r3,
                                            1'b0, 1'b0, 1'b0,
                                            1'b0, 1'b0, 1'b0);
            end

            PKT_AVI_INFOFRAME: begin
                pkt_type = 8'h82;
                pkt_hb1  = 8'h02;        // version
                pkt_hb2  = 8'h0D;        // length = 13
                pkt_sp0  = AVI_SP0;
                pkt_sp1  = 56'h0;        // PB7..PB13 all zero
                pkt_sp2  = 56'h0;
                pkt_sp3  = 56'h0;
            end

            PKT_AUD_INFOFRAME: begin
                pkt_type = 8'h84;
                pkt_hb1  = 8'h01;        // version
                pkt_hb2  = 8'h0A;        // length = 10
                pkt_sp0  = AUD_SP0;
                pkt_sp1  = 56'h0;        // PB7..PB10 all zero
                pkt_sp2  = 56'h0;
                pkt_sp3  = 56'h0;
            end

            default: begin               // PKT_NULL
                pkt_type = 8'h00;
                pkt_hb1  = 8'h00;
                pkt_hb2  = 8'h00;
                pkt_sp0  = 56'h0;
                pkt_sp1  = 56'h0;
                pkt_sp2  = 56'h0;
                pkt_sp3  = 56'h0;
            end
        endcase
    end

endmodule

`default_nettype wire
