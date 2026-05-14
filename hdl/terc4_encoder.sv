// terc4_encoder.sv — HDMI 1.4a §5.4.2 TERC4 4-bit-to-10-bit encoder.
//
// Used during the data island period (one of the three transmission
// periods alongside video data and control). Each TMDS lane carries
// 4 bits of packet payload per pixel cycle, encoded into a 10-bit
// symbol with bounded transition density.
//
// Combinational LUT — the spec defines a fixed mapping (no running
// disparity). Spec values per Table 5-7:
//
//   D[3:0]    Q_out[9:0]
//   ------    ----------
//    0x0      1010011100
//    0x1      1001100011
//    0x2      1011100100
//    0x3      1011100010
//    0x4      0101110001
//    0x5      0100011110
//    0x6      0110001110
//    0x7      0100111100
//    0x8      1011001100
//    0x9      0100111001
//    0xA      0110011100
//    0xB      1011000110
//    0xC      1010001110
//    0xD      1001110001
//    0xE      0101100011
//    0xF      1011000011
//
// Bit ordering: serializer sends LSB first (DVI/HDMI convention),
// matching tmds_encoder.sv.

`default_nettype none

module terc4_encoder (
    input  wire  [3:0] data,
    output logic [9:0] q_out
);

    always_comb begin
        case (data)
            4'h0: q_out = 10'b1010011100;
            4'h1: q_out = 10'b1001100011;
            4'h2: q_out = 10'b1011100100;
            4'h3: q_out = 10'b1011100010;
            4'h4: q_out = 10'b0101110001;
            4'h5: q_out = 10'b0100011110;
            4'h6: q_out = 10'b0110001110;
            4'h7: q_out = 10'b0100111100;
            4'h8: q_out = 10'b1011001100;
            4'h9: q_out = 10'b0100111001;
            4'hA: q_out = 10'b0110011100;
            4'hB: q_out = 10'b1011000110;
            4'hC: q_out = 10'b1010001110;
            4'hD: q_out = 10'b1001110001;
            4'hE: q_out = 10'b0101100011;
            4'hF: q_out = 10'b1011000011;
            default: q_out = 10'b0;
        endcase
    end

endmodule

`default_nettype wire
