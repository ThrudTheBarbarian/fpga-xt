`default_nettype none
//
// antic_emit_win — when the playfield is actually on screen.
//
// antic_line_render consumes one `emit_en` per hi-res pixel and walks the line
// buffer at that rate.  Something has to decide WHICH pixels of the scanline
// those are, and that is all this does: count hi-res pixels from the top of the
// line and open a window between antic_pf_geom's px_start and px_stop.
//
// FETCHING AND DISPLAYING ARE DIFFERENT WINDOWS, and conflating them is the
// mistake this module exists to avoid.  A scrolled narrow row FETCHES 40 bytes
// and DISPLAYS 32; the fetch window is where the memory scan happens, the
// display window is the rectangle the beam paints.  antic_pf_geom already
// reports them separately -- dma_start/dma_stop against disp_start/disp_stop,
// and px_start/px_stop for this one, which is the display window in hi-res
// pixels with HSCROL already applied.  Tying the renderer to the fetch window
// would shift a scrolled row sideways by the scroll amount.
//
// THE COUNTER IS FREE-RUNNING, not gated by the window, because px_start is
// measured from the top of the scanline.  It resets on line_start and counts
// every px_tick whether anything is displayed or not.
//
// A WIDTH OF ZERO DISPLAYS NOTHING.  px_start and px_stop are equal in that
// case and the comparison closes the window on its own, so there is no separate
// case for it here.
//
// CLOCK BUDGET: one 9-bit counter and two comparators, evaluated once per hi-res
// pixel.  There is nothing per-bit in it.
//
`timescale 1ns/1ps

module antic_emit_win (
    input  wire        clk,
    input  wire        rst,

    input  wire        line_start,   // 1-clk at the top of the scanline
    input  wire        px_tick,      // 1-clk per hi-res pixel

    // The DISPLAY window, in hi-res pixels, HSCROL already applied.
    input  wire [8:0]  px_start,
    input  wire [8:0]  px_stop,

    output wire        emit_en,      // 1-clk per DISPLAYED hi-res pixel
    output logic [8:0] px_pos        // where the beam is, for whoever needs it
);

    always_ff @(posedge clk or posedge rst) begin
        if (rst)             px_pos <= 9'd0;
        else if (line_start) px_pos <= 9'd0;
        else if (px_tick)    px_pos <= px_pos + 9'd1;
    end

    // Qualified by px_tick so it is a PULSE per pixel, not a level across the
    // window -- the renderer advances its buffer index on every asserted clock,
    // and a level would run the whole line off the end of the buffer in a
    // handful of fabric clocks.
    assign emit_en = px_tick && (px_pos >= px_start) && (px_pos < px_stop);

endmodule

`default_nettype wire
