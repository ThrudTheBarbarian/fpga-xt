// hdmi_bch.sv — HDMI 1.4a §5.2.3.5 BCH ECC encoder.
//
// Generator polynomial:  g(x) = x^8 + x^7 + x^6 + x^4 + 1
//                              = 0x1D1 (in 9-bit, MSB at degree 8)
//
// HDMI uses this in two flavours:
//   - Header ECC:    over 24 data bits → 8-bit parity (BCH-shortened)
//   - Subpacket ECC: over 56 data bits → 8-bit parity (per body subpacket)
//
// Both flavours use the same generator. The encoder is combinational —
// 8 parity bits are a fixed XOR over a subset of the data bits.
//
// We implement it as a sequential reference (clock-cycle-style)
// folded into combinational logic via a generate / unrolled loop.
// This is the canonical CRC-style polynomial division, where each
// data bit XORs into the shift register and a feedback tap injects
// the generator polynomial whenever the high bit is 1.

`default_nettype none

module hdmi_bch_24 (
    input  wire  [23:0] data,
    output logic [7:0]  ecc
);
    // 24-bit input → 8-bit ECC. Parallel BCH using sequential feedback.
    integer i;
    logic [7:0] reg_q;
    always_comb begin
        reg_q = 8'h00;
        // Feed data MSB-first; "1" of generator (x^8) is implicit via
        // the bit shifting out the top of reg_q.
        for (i = 0; i < 24; i = i + 1) begin : sblk_step
            logic feedback;
            feedback = reg_q[7] ^ data[23 - i];
            // g(x) low bits (excluding x^8): x^7 + x^6 + x^4 + 1 = 0xD1.
            reg_q = {reg_q[6:0], 1'b0} ^ (feedback ? 8'hD1 : 8'h00);
        end
        ecc = reg_q;
    end
endmodule

module hdmi_bch_56 (
    input  wire  [55:0] data,
    output logic [7:0]  ecc
);
    integer i;
    logic [7:0] reg_q;
    always_comb begin
        reg_q = 8'h00;
        for (i = 0; i < 56; i = i + 1) begin : sblk_step
            logic feedback;
            feedback = reg_q[7] ^ data[55 - i];
            reg_q = {reg_q[6:0], 1'b0} ^ (feedback ? 8'hD1 : 8'h00);
        end
        ecc = reg_q;
    end
endmodule

`default_nettype wire
