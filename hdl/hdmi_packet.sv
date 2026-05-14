// hdmi_packet.sv — HDMI 1.4a §5.2.3 data island packet formatter.
//
// Each packet occupies 32 TMDS pixel cycles. Per HDMI Table 5-1, the
// 4 nibbles per TMDS lane during data islands carry:
//
//   Lane 0 (blue): bit 0 = HSYNC, bit 1 = VSYNC
//                  bit 2 = "first cycle marker" (0 only on cycle 0)
//                  bit 3 = header bit  (24 data + 8 BCH bits, MSB at cycle 0)
//
//   Lane 1 (green): bit i = subpacket[i] bit (2*cycle)
//   Lane 2 (red):   bit i = subpacket[i] bit (2*cycle + 1)
//
// Each of the 4 subpackets is 56 bits payload + 8 bits BCH = 64 bits.
//
// Inputs are the cooked packet contents:
//   pkt_type    HB0 (e.g. 0x02 = Audio Sample, 0x82 = AVI InfoFrame)
//   pkt_hb1     HB1
//   pkt_hb2     HB2
//   pkt_sp[0..3]  56-bit subpacket payloads
//
// hdmi_bch fills in the 4 ECC bytes (1 header + 4 subpacket).
//
// Output is per-cycle (cycle = 0..31, indexed by `cycle_idx`):
//   lane0_nibble[3:0], lane1_nibble[3:0], lane2_nibble[3:0]
//
// The caller supplies hsync/vsync (lane 0 bits 0/1) since those track
// the wider video timing, not the packet itself.
//
// Status: M15b-3 initial cut. Structure + BCH ECC + lane assignment
// done; specific packet body contents (audio sample subpacket layout,
// InfoFrame field encoding) layered in by callers / refined as the
// HDMI sink integration test lands.

`default_nettype none

module hdmi_packet (
    // Packet contents (snapshot once at packet start, then held across
    // the 32 cycles).
    input  wire  [7:0]  pkt_type,         // HB0
    input  wire  [7:0]  pkt_hb1,          // HB1
    input  wire  [7:0]  pkt_hb2,          // HB2
    input  wire  [55:0] pkt_sp0,          // subpacket 0 payload
    input  wire  [55:0] pkt_sp1,
    input  wire  [55:0] pkt_sp2,
    input  wire  [55:0] pkt_sp3,
    // Per-cycle inputs.
    input  wire  [4:0]  cycle_idx,        // 0..31
    input  wire         hsync,
    input  wire         vsync,
    // Per-cycle outputs.
    output logic [3:0]  lane0_nibble,
    output logic [3:0]  lane1_nibble,
    output logic [3:0]  lane2_nibble
);

    // ---- BCH ECC -------------------------------------------------------
    wire [7:0] header_ecc;
    wire [7:0] sp0_ecc, sp1_ecc, sp2_ecc, sp3_ecc;

    hdmi_bch_24 u_h_ecc (.data({pkt_type, pkt_hb1, pkt_hb2}), .ecc(header_ecc));
    hdmi_bch_56 u_sp0_ecc (.data(pkt_sp0), .ecc(sp0_ecc));
    hdmi_bch_56 u_sp1_ecc (.data(pkt_sp1), .ecc(sp1_ecc));
    hdmi_bch_56 u_sp2_ecc (.data(pkt_sp2), .ecc(sp2_ecc));
    hdmi_bch_56 u_sp3_ecc (.data(pkt_sp3), .ecc(sp3_ecc));

    // ---- Packed header (32 bits, MSB at cycle 0) -----------------------
    // Header bit layout per HDMI Table 5-3:
    //   cycle 0..7   = HB0 (MSB first)
    //   cycle 8..15  = HB1
    //   cycle 16..23 = HB2
    //   cycle 24..31 = ECC
    wire [31:0] hdr_word = {pkt_type, pkt_hb1, pkt_hb2, header_ecc};

    // ---- Packed subpackets (64 bits each) ------------------------------
    // Subpacket bit ordering: bit 0 (LSB of payload) is sent on cycle 0
    // green; bit 1 on cycle 0 red; bit 2 on cycle 1 green; ...
    // Payload [55:0] occupies bits 0..55 of the 64-bit codeword; ECC
    // [7:0] occupies bits 56..63.
    wire [63:0] sp0_word = {sp0_ecc, pkt_sp0};
    wire [63:0] sp1_word = {sp1_ecc, pkt_sp1};
    wire [63:0] sp2_word = {sp2_ecc, pkt_sp2};
    wire [63:0] sp3_word = {sp3_ecc, pkt_sp3};

    // ---- Per-cycle nibble emission -------------------------------------
    always_comb begin : sblk_emit
        logic       hdr_bit;
        logic [5:0] sp_lo_idx;     // 2*cycle_idx
        logic [5:0] sp_hi_idx;     // 2*cycle_idx + 1
        logic       sp0_lo, sp0_hi;
        logic       sp1_lo, sp1_hi;
        logic       sp2_lo, sp2_hi;
        logic       sp3_lo, sp3_hi;

        // Lane 0 — header bit selected MSB-first.
        hdr_bit = hdr_word[31 - {1'b0, cycle_idx}];

        // Subpacket bits at positions 2k and 2k+1.
        sp_lo_idx = {1'b0, cycle_idx, 1'b0};
        sp_hi_idx = sp_lo_idx + 6'd1;

        sp0_lo = sp0_word[sp_lo_idx];
        sp0_hi = sp0_word[sp_hi_idx];
        sp1_lo = sp1_word[sp_lo_idx];
        sp1_hi = sp1_word[sp_hi_idx];
        sp2_lo = sp2_word[sp_lo_idx];
        sp2_hi = sp2_word[sp_hi_idx];
        sp3_lo = sp3_word[sp_lo_idx];
        sp3_hi = sp3_word[sp_hi_idx];

        // Lane 0 (blue) nibble: {hdr_bit, !cycle0, vsync, hsync}.
        lane0_nibble = {hdr_bit,
                         (cycle_idx != 5'd0) ? 1'b1 : 1'b0,
                         vsync, hsync};

        // Lane 1 (green): subpacket bits at even position (2k).
        lane1_nibble = {sp3_lo, sp2_lo, sp1_lo, sp0_lo};

        // Lane 2 (red):   subpacket bits at odd position (2k+1).
        lane2_nibble = {sp3_hi, sp2_hi, sp1_hi, sp0_hi};
    end

endmodule

`default_nettype wire
