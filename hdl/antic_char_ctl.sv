`default_nettype none
//
// antic_char_ctl — CHACTL ($D401), the three character-control bits.
//
// docs/ANTIC-rewrite.md, and directly ACID's antic_charcontrol.
//
//   [2] reflect — the glyph is mirrored vertically (upside down)
//   [1] invert  — inverse-video characters are shown in inverse video
//   [0] blank   — inverse-video characters are blanked instead
//
// WHICH CHARACTERS ARE "INVERSE" depends on the mode, and this is the part that
// is easy to get wrong.  Bit 7 of the character code is the inverse-video flag
// in modes 2 and 3 ONLY.  In modes 4 and 5 the top bit selects a colour, and in
// modes 6 and 7 the top TWO bits do — applying blank/invert there would corrupt
// perfectly ordinary coloured text.  We derive that from the shape the mode
// table already publishes (a 1bpp, 1-pixel-wide character mode is 2 or 3) rather
// than adding a second mode decode.
//
// REFLECT IS AN ADDRESS XOR, not a data reversal.  ANTIC inverts the row counter
// bits going into the character-set address, so a 10-row mode 3 cell reflects to
// whatever that XOR produces rather than to a tidy 9-row.  That is the hardware
// behaviour, and it is one gate — special-casing mode 3 here would be the
// "we've missed something" smell.
//
// BLANK BEATS INVERT when both bits are set: blanking forces the glyph data low
// and the inverter has nothing left to flip.
//
// The OS leaves CHACTL at $02, which is why ordinary ATASCII inverse video works
// with no program doing anything.
//
// CLOCK BUDGET: an XOR on three address bits and a mux on eight data bits.
// There is no state.
//
`timescale 1ns/1ps

module antic_char_ctl (
    input  wire [2:0] chactl,          // $D401[2:0]
    input  wire       is_char,
    input  wire [1:0] bpp,
    input  wire [3:0] px_width,
    input  wire [7:0] char_code,
    input  wire [2:0] glyph_row_in,
    input  wire [7:0] glyph_data_in,

    output wire [2:0] glyph_row,       // address the character set with this
    output wire [7:0] glyph_data       // shift this
);

    // Modes 2 and 3: the only character modes whose top code bit means
    // "inverse video" rather than "colour".
    wire has_inverse = is_char && (bpp == 2'd1) && (px_width == 4'd1);
    wire inv_char    = has_inverse && char_code[7];

    assign glyph_row = chactl[2] ? ~glyph_row_in : glyph_row_in;

    wire blanked  = inv_char && chactl[0];
    wire inverted = inv_char && chactl[1];

    assign glyph_data = blanked  ? 8'h00
                      : inverted ? ~glyph_data_in
                                 : glyph_data_in;

endmodule

`default_nettype wire
