`default_nettype none
//
// antic_color_sel — winning source -> Atari colour byte.
//
// docs/ANTIC-rewrite.md.  The last step before the line buffer: whichever source
// won priority, this produces the 8-bit Atari colour (hue[7:4], luma[3:1]) that
// gets stored.
//
// The source encoding is deliberately WIDER than antic_pf_source produces (0-5),
// leaving room for the player/missile slots the priority walk will add (6-9).
// Writing it once, now, means the priority stage slots in without this module
// changing — and a 10-way mux is the same cost as a 6-way one.
//
//   0  BK          COLBK
//   1  PF0         COLPF0
//   2  PF1         COLPF1
//   3  PF2         COLPF2
//   4  PF3         COLPF3
//   5  HIRES_LIT   COLPF2's HUE with COLPF1's LUMA   <-- the hi-res trick
//   6  PM0         COLPM0
//   7  PM1         COLPM1
//   8  PM2         COLPM2
//   9  PM3         COLPM3
//
// THE HI-RES TRICK is the only non-trivial entry, and it is the one ACID checks.
// In modes 2/3/F a lit pixel takes its hue from COLPF2 and only its LUMINANCE
// from COLPF1 — which is why hi-res text can only change brightness, not colour,
// against its background. Collisions still treat it as PF2, but that is the
// collision stage's business; by here the display answer is all that is left.
//
// CLOCK BUDGET: combinational, zero clocks. A mux.
//
`timescale 1ns/1ps

module antic_color_sel (
    input  wire [3:0]  src,

    input  wire [7:0]  colbk,
    input  wire [7:0]  colpf0,
    input  wire [7:0]  colpf1,
    input  wire [7:0]  colpf2,
    input  wire [7:0]  colpf3,
    input  wire [7:0]  colpm0,
    input  wire [7:0]  colpm1,
    input  wire [7:0]  colpm2,
    input  wire [7:0]  colpm3,

    output logic [7:0] color
);

    localparam logic [3:0] SRC_BK        = 4'd0;
    localparam logic [3:0] SRC_PF0       = 4'd1;
    localparam logic [3:0] SRC_PF1       = 4'd2;
    localparam logic [3:0] SRC_PF2       = 4'd3;
    localparam logic [3:0] SRC_PF3       = 4'd4;
    localparam logic [3:0] SRC_HIRES_LIT = 4'd5;
    localparam logic [3:0] SRC_PM0       = 4'd6;
    localparam logic [3:0] SRC_PM1       = 4'd7;
    localparam logic [3:0] SRC_PM2       = 4'd8;
    localparam logic [3:0] SRC_PM3       = 4'd9;

    always_comb begin
        unique case (src)
            SRC_PF0:       color = colpf0;
            SRC_PF1:       color = colpf1;
            SRC_PF2:       color = colpf2;
            SRC_PF3:       color = colpf3;
            // Hue from PF2, luminance from PF1, bit 0 unused as on hardware.
            SRC_HIRES_LIT: color = {colpf2[7:4], colpf1[3:1], 1'b0};
            SRC_PM0:       color = colpm0;
            SRC_PM1:       color = colpm1;
            SRC_PM2:       color = colpm2;
            SRC_PM3:       color = colpm3;
            default:       color = colbk;      // SRC_BK and anything undefined
        endcase
    end

endmodule

`default_nettype wire
