`default_nettype none
//
// gtia_special — GTIA modes 9, 10 and 11.
//
// docs/ANTIC-rewrite.md step 7.  PRIOR[7:6] stops GTIA interpreting ANTIC's
// playfield bits as a playfield at all and treats them as a 4-bit value instead,
// one per TWO colour clocks — so a GTIA pixel is four hi-res pixels wide and a
// normal-width line carries 80 of them.
//
//   01  mode 9   16 luminances: the nibble is the LUMA, the hue comes from COLBK
//   10  mode 10  9 colours: the nibble indexes COLPM0-3, COLPF0-3, then COLBK
//   11  mode 11  16 hues: the nibble is the HUE, the luma comes from COLBK
//
// Mode 10's table runs out after nine entries; values 8-15 all give COLBK.  That
// is not a tidy-up, it is what the chip does — there are only nine registers to
// point at.
//
// WHERE THE NIBBLE COMES FROM is the part that explains gtia_psuedomodee, and it
// is more general than "mode F reinterpreted".  ANTIC hands GTIA two playfield
// bits per colour clock whatever mode it is in, and GTIA shifts two colour
// clocks' worth together:
//
//   mode F   two hi-res pixels of one bit each   -> 2 bits per colour clock
//   mode E   one 2-bit pixel spanning both       -> 2 bits per colour clock
//
// So a GTIA mode laid over mode E assembles its nibbles out of pairs of mode E
// pixel values, which is exactly the "pseudo" display those tests probe.  There
// is no special case for it here: the same two bits arrive either way.
//
// COLLISIONS ACROSS A MID-LINE PRIOR CHANGE ARE SETTLED, AND NOT HERE.  This
// module was deferred on the grounds that gtia_psuedomodee could not be
// reproduced without measuring real hardware.  That was wrong: emu carries the
// measurement (system.c:25-45), and the rule is not about the nibble decode at
// all.  GTIA latches ONCE PER SCANLINE whether ANTIC mode F is hi-res, and a
// GTIA mode still selected at that instant disables hi-res for the whole line;
// afterwards the mode F pair is read as a direct playfield index.  That lives
// in a2_video, which has both PRIOR and ANTIC's machine cycle.  emu's threshold
// is bracketed from both sides and so is ours: one cycle early and both of the
// test's cases go pseudo, one cycle late and neither does.
//
// CLOCK BUDGET: a 4-bit mux and a nibble concatenation, evaluated once per GTIA
// pixel.  There is no state.
//
`timescale 1ns/1ps

module gtia_special (
    input  wire [1:0] gtia_mode,       // PRIOR[7:6]
    input  wire [3:0] nibble,
    input  wire [7:0] colbk,
    input  wire [7:0] colpf0, colpf1, colpf2, colpf3,
    input  wire [7:0] colpm0, colpm1, colpm2, colpm3,

    output wire       active,          // a GTIA mode is selected
    output logic [7:0] color
);

    assign active = (gtia_mode != 2'b00);

    always_comb begin
        case (gtia_mode)
            // Mode 9: sixteen luminances of COLBK's hue.
            2'b01: color = {colbk[7:4], nibble};

            // Mode 10: nine colours, and only nine.
            2'b10: begin
                case (nibble)
                    4'd0:    color = colpm0;
                    4'd1:    color = colpm1;
                    4'd2:    color = colpm2;
                    4'd3:    color = colpm3;
                    4'd4:    color = colpf0;
                    4'd5:    color = colpf1;
                    4'd6:    color = colpf2;
                    4'd7:    color = colpf3;
                    default: color = colbk;      // 8-15: there is nothing else
                endcase
            end

            // Mode 11: sixteen hues at COLBK's luminance.
            2'b11: color = {nibble, colbk[3:0]};

            default: color = colbk;
        endcase
    end

endmodule

`default_nettype wire
