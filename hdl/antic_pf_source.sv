`default_nettype none
//
// antic_pf_source — pixel index -> playfield SOURCE.
//
// docs/ANTIC-rewrite.md.  antic_pixel_shift emits a 1- or 2-bit index; this says
// which playfield that index means.  It deliberately does NOT produce a colour.
//
// Why a source and not a colour: the real ANTIC sends GTIA a few bits per colour
// clock saying WHICH playfield is showing (AN0-AN2), and GTIA decides the pixel
// from that plus its own registers and priority.  Three things downstream need
// the source rather than the colour:
//
//   * collisions — P?PF records which playfield a player hit
//   * priority   — playfield-vs-player ordering is per source
//   * the hi-res trick — a lit hi-res pixel DISPLAYS as COLPF1's luma over
//     COLPF2's hue, but COLLIDES as plain PF2.  One value cannot be both, so
//     the distinction has to survive to the colour stage.
//
// That last point is exactly what ACID's antic_hiresbug and antic_charcontrol
// pin, and getting it wrong is why the old path reported $00 where $10 was
// expected.
//
// The mapping, from the mode parameters — no per-mode branches beyond the four
// families the hardware actually has:
//
//   hi-res (2,3,F)      1 -> HIRES_LIT, 0 -> PF2   (background IS PF2 here)
//   char 2bpp (4,5)     00 BK, 01 PF0, 10 PF1, 11 -> PF3 if char bit7 else PF2
//   char 1bpp (6,7)     0 BK, 1 -> PF0..PF3 chosen by char code bits [7:6]
//   bitmap 1bpp (9,B,C) 0 BK, 1 PF0
//   bitmap 2bpp (8,A,D,E) 00 BK, 01 PF0, 10 PF1, 11 PF2
//
// CLOCK BUDGET: combinational, zero clocks — a mux, as it should be.
//
`timescale 1ns/1ps

module antic_pf_source (
    // ---- from antic_mode_tbl -------------------------------------------
    input  wire        is_char,
    input  wire [1:0]  bpp,
    input  wire        is_hires,     // px_width==1 && bpp==1: modes 2, 3, F

    // ---- from antic_pixel_shift ----------------------------------------
    input  wire [1:0]  px_val,

    // ---- the character that produced this pixel (char modes only) -------
    input  wire [7:0]  char_code,

    output logic [2:0] pf_src
);

    // Source encoding.  HIRES_LIT is a distinct value precisely so the colour
    // stage can apply the luma trick while the collision stage treats it as PF2.
    localparam logic [2:0] SRC_BK        = 3'd0;
    localparam logic [2:0] SRC_PF0       = 3'd1;
    localparam logic [2:0] SRC_PF1       = 3'd2;
    localparam logic [2:0] SRC_PF2       = 3'd3;
    localparam logic [2:0] SRC_PF3       = 3'd4;
    localparam logic [2:0] SRC_HIRES_LIT = 3'd5;

    always_comb begin
        if (is_hires) begin
            // Modes 2/3/F: background is COLPF2, not COLBK.
            pf_src = px_val[0] ? SRC_HIRES_LIT : SRC_PF2;
        end else if (bpp == 2'd2) begin
            unique case (px_val)
                2'b00:   pf_src = SRC_BK;
                2'b01:   pf_src = SRC_PF0;
                2'b10:   pf_src = SRC_PF1;
                // Character modes 4/5 promote the 11 pair to PF3 when the
                // character's top bit is set; bitmap modes have no such bit.
                default: pf_src = (is_char && char_code[7]) ? SRC_PF3 : SRC_PF2;
            endcase
        end else if (is_char) begin
            // Modes 6/7: one bit of shape, and the character code picks which
            // playfield colour the lit pixels take.
            if (!px_val[0]) pf_src = SRC_BK;
            else unique case (char_code[7:6])
                2'b00:   pf_src = SRC_PF0;
                2'b01:   pf_src = SRC_PF1;
                2'b10:   pf_src = SRC_PF2;
                default: pf_src = SRC_PF3;
            endcase
        end else begin
            // Modes 9/B/C: plain one-bit bitmap.
            pf_src = px_val[0] ? SRC_PF0 : SRC_BK;
        end
    end

endmodule

`default_nettype wire
