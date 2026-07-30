`default_nettype none
//
// antic_beam — the counter chain everything else hangs off.
//
// docs/ANTIC-rewrite.md.  Horizontal position within the scanline, vertical
// position within the frame, and the VCOUNT register the CPU reads.
//
// THE ONE QUIRK, and it is the whole of ACID's antic_vcount: the scanline
// counter advances entering cycle 111, NOT at the line boundary.  A program
// that reads VCOUNT during cycles 111-113 sees the NEXT line's value.  Model it
// anywhere else and antic_vcount fails.
//
// VCOUNT is the scanline number halved — it counts every other line, so a
// 262-line frame reads 0..130.
//
// CLOCK BUDGET: one counter chain, advanced once per machine cycle.  Everything
// here is a compare against a constant; there is nothing to spread out.
//
`timescale 1ns/1ps

module antic_beam #(
    parameter int CYCLES_PER_LINE = 114,   // machine cycles per scanline
    parameter int LINES_PER_FRAME = 262,
    parameter int DISPLAY_TOP     = 8,     // first line the playfield may use
    parameter int DISPLAY_LINES   = 192,
    parameter int VCOUNT_ADVANCE  = 111    // <-- antic_vcount pins this
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        tick,               // 1-clk per machine cycle (phi2)

    output logic [6:0] hcount,             // 0 .. CYCLES_PER_LINE-1
    output logic [8:0] line,               // 0 .. LINES_PER_FRAME-1
    output wire  [7:0] vcount,             // $D40B — the scanline halved

    output wire        line_start,         // 1-clk at the start of each line
    output wire        in_display,         // this line may draw playfield
    output wire        in_vblank
);

    wire last_cycle = (hcount == 7'(CYCLES_PER_LINE - 1));
    wire last_line  = (line   == 9'(LINES_PER_FRAME - 1));

    assign vcount     = line[8:1];
    assign line_start = tick && (hcount == 7'd0);
    assign in_display = (line >= 9'(DISPLAY_TOP)) &&
                        (line <  9'(DISPLAY_TOP + DISPLAY_LINES));
    assign in_vblank  = !in_display;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            hcount <= 7'd0;
            line   <= 9'd0;
        end else if (tick) begin
            hcount <= last_cycle ? 7'd0 : hcount + 7'd1;

            // The scanline advances ENTERING cycle 111, so VCOUNT reads as the
            // next line for the last few cycles of this one.  This is the
            // behaviour antic_vcount measures; advancing at the wrap instead
            // puts every VCOUNT read three cycles late.
            if (hcount == 7'(VCOUNT_ADVANCE - 1))
                line <= last_line ? 9'd0 : line + 9'd1;
        end
    end

endmodule

`default_nettype wire
