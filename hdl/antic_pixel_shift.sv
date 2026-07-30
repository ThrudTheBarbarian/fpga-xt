`default_nettype none
//
// antic_pixel_shift — the one datapath every ANTIC display mode runs through.
//
// docs/ANTIC-rewrite.md.  antic_mode_tbl turns the mode nibble into four
// parameters; this is what consumes them.  There is no per-mode logic here at
// all — mode F and mode 8 differ only in `bpp` and `px_width`.
//
//   load        capture a source byte (glyph for character modes, graphics
//               byte for bitmap modes) and rewind
//   px_tick     advance one HI-RES pixel (2 per colour clock)
//   px_val      the pixel's index: 1 bit for bpp=1, 2 bits for bpp=2
//   exhausted   every bit of the byte has been emitted; fetch the next one
//
// `px_val` is deliberately an INDEX, not a colour.  Which playfield register an
// index selects is mode-dependent (hi-res 1 means PF1's luma over PF2's hue;
// 2bpp 01/10/11 mean PF0/PF1/PF2) and belongs to the colour stage, not here.
// Keeping that out is what stops this growing per-mode branches.
//
// Structure: a shift register and two counters — a sub-pixel counter for the
// pixel WIDTH, and a bit counter for how much of the byte is left.  Per the
// complexity smell test, if this ever needs more than that, the mechanism has
// been missed.
//
// CLOCK BUDGET: one clock per hi-res pixel, and nothing else.  A 456-pixel line
// is 456 clocks of the ~6,300 in a 1.79 MHz scanline.
//
`timescale 1ns/1ps

module antic_pixel_shift (
    input  wire        clk,
    input  wire        rst,

    // ---- from antic_mode_tbl -------------------------------------------
    input  wire [1:0]  bpp,          // 1 or 2
    input  wire [3:0]  px_width,     // 1, 2, 4 or 8 hi-res pixels per pixel

    // ---- source ---------------------------------------------------------
    input  wire        load,         // 1-clk: take `data` and rewind
    input  wire [7:0]  data,

    // ---- beam -----------------------------------------------------------
    input  wire        px_tick,      // 1-clk: advance one hi-res pixel

    output wire [1:0]  px_val,       // current pixel index
    output wire        exhausted     // byte fully emitted
);

    logic [7:0] shift_q;
    logic [3:0] sub_q;               // 0 .. px_width-1, within one pixel
    logic [4:0] bits_q;              // source bits remaining, 8 down to 0

    // The pixel currently being emitted is always the TOP of the shifter, so
    // the same wires serve both widths — 1bpp just ignores the second bit.
    assign px_val    = (bpp == 2'd2) ? shift_q[7:6] : {1'b0, shift_q[7]};
    assign exhausted = (bits_q == 5'd0);

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            shift_q <= 8'h00;
            sub_q   <= 4'd0;
            bits_q  <= 5'd0;
        end else if (load) begin
            shift_q <= data;
            sub_q   <= 4'd0;
            bits_q  <= 5'd8;
        end else if (px_tick && bits_q != 5'd0) begin
            if (sub_q == px_width - 4'd1) begin
                // This pixel is fully drawn: consume its bits and move on.
                sub_q   <= 4'd0;
                shift_q <= (bpp == 2'd2) ? {shift_q[5:0], 2'b00}
                                         : {shift_q[6:0], 1'b0};
                bits_q  <= bits_q - {3'd0, bpp};
            end else begin
                sub_q <= sub_q + 4'd1;
            end
        end
    end

endmodule

`default_nettype wire
