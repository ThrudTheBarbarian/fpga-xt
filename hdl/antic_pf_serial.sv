`default_nettype none
//
// antic_pf_serial — playfield byte stream -> per-colour-clock nibble.
//
// docs/video/gtia-streaming.md, the missing link between the two halves that
// already exist: antic_timing emits the playfield byte stream in beam order
// (pf_valid/pf_byte/pf_code), and gtia_stream resolves one pixel per colour
// clock. This turns the former into the pf_nibble the latter consumes.
//
// Scope: BITMAP modes only for now (8-F). Character modes need CHBASE glyph
// lookup, which antic_timing already performs — its pf_byte for a char mode is
// the GLYPH, with pf_code carrying the character. Wiring those is the next
// step; keeping them out here means this module is small enough to verify
// exhaustively against the burst's pack_pair, which is the whole point of doing
// the migration in pieces rather than in one jump.
//
// Pixel rates (colour clocks per source byte), matching pack_pair:
//     mode F        1bpp hires : 8 px over  4 cc  (2 px per cc)
//     modes D,E     2bpp       : 4 px over  4 cc
//     modes 9,B,C   1bpp lores : 8 px over  8 cc
//     modes 8,A     2bpp lores : 4 px over  8 cc
//
// The nibble is one-hot PF0..PF3, or 0 for background — color_resolver's
// contract. For 1bpp modes a set bit selects PF1 (lit) and a clear bit is
// background, which is the same mapping the burst uses before the hi-res
// collision remap.
//
`timescale 1ns/1ps

module antic_pf_serial (
    input  wire        clk,
    input  wire        rst,

    input  wire [3:0]  mode,          // ANTIC mode 8..F
    input  wire        pf_valid,      // 1-clk: pf_byte is fresh
    input  wire [7:0]  pf_byte,

    input  wire        cc_tick,       // 1-clk per colour clock
    // COMBINATIONAL from the shifter, not registered: gtia_stream samples this
    // on the SAME cc_tick that advances the shifter, so a registered output
    // would hand it the previous colour clock's pixel.  Presenting it
    // combinationally makes the pair a clean one-stage pipeline.
    output wire  [3:0] pf_nibble,     // one-hot PF0..PF3, 0 = background
    output logic       pf_active      // 1 while a byte is being shifted out
);

    // colour clocks per byte, and bits consumed per colour clock
    wire is_1bpp   = (mode == 4'hF) || (mode == 4'h9) ||
                     (mode == 4'hB) || (mode == 4'hC);
    wire is_hires  = (mode == 4'hF) || (mode == 4'hD) || (mode == 4'hE);

    // 2 px/cc for hires, 1 px/cc otherwise
    wire [3:0] cc_per_byte = is_1bpp ? (is_hires ? 4'd4 : 4'd8)
                                     : (is_hires ? 4'd4 : 4'd8);

    logic [7:0] shifter_q;
    logic [3:0] left_q;

    assign pf_active = (left_q != 4'd0);

    // Bit-pair -> PF index for 2bpp modes; 00 is background, and the burst maps
    // 01/10/11 to PF0/PF1/PF2 respectively.
    function automatic logic [3:0] pf2bpp(input logic [1:0] v);
        case (v)
            2'b01:   pf2bpp = 4'b0001;   // PF0
            2'b10:   pf2bpp = 4'b0010;   // PF1
            2'b11:   pf2bpp = 4'b0100;   // PF2
            default: pf2bpp = 4'b0000;   // background
        endcase
    endfunction

    assign pf_nibble = (left_q == 4'd0) ? 4'h0
                     : is_1bpp           ? (shifter_q[7] ? 4'b0010 : 4'h0)
                                         : pf2bpp(shifter_q[7:6]);

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            shifter_q <= 8'h00;
            left_q    <= 4'd0;
        end else begin
            if (pf_valid) begin
                shifter_q <= pf_byte;
                left_q    <= cc_per_byte;
            end else if (cc_tick && left_q != 4'd0) begin
                left_q <= left_q - 4'd1;
                if (is_1bpp) begin
                    // hires consumes 2 bits per cc, lores 1
                    if (is_hires) shifter_q <= {shifter_q[5:0], 2'b00};
                    else          shifter_q <= {shifter_q[6:0], 1'b0};
                end else begin
                    shifter_q <= {shifter_q[5:0], 2'b00};
                end
            end
        end
    end

endmodule

`default_nettype wire
