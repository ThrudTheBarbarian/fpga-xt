`default_nettype none
//
// antic_wb_adapt — the rewrite's line buffer onto the existing writeback tap.
//
// docs/ANTIC-rewrite.md.  antic_writeback and everything downstream of it — the
// palette, the DDR triple buffer, the plane compositor, HDMI — are keepers, and
// they take a pixel-PAIR stream: color_lo and color_hi for one pair, a pair
// index within the row, and a row_flush when the row is done.  The rewrite
// produces one Atari colour byte per hi-res pixel with a line_start.  This is
// the join, and it is deliberately the only new thing between them: nothing
// downstream changes.
//
// THE WINDOW IS FIXED, NOT THE PLAYFIELD'S.  The writeback framebuffer is
// XL_SRC_W = 320 pixels wide, which is the NORMAL playfield: buffer pixels
// 80..399, since a normal window opens at machine cycle 20 and 20*4 = 80.  A
// narrow playfield paints border either side of its 256 and a wide one is
// clipped, which is what the old path does too — the framebuffer geometry is a
// property of the scan-out, not of DMACTL.
//
// WIDENING PAST 320 IS WANTED EVENTUALLY (a wide playfield is 384, and the
// border either side is real picture on a lot of software).  X0 and W are
// parameters so this module is ready, but it is not the only thing to change:
// XL_SRC_W and XL_STRIDE in fpga_xt_top size the DDR triple buffer, and the
// plane window and scale factor downstream assume 320 too.  Deliberately left
// at 320 for now so the rewrite lands against an unchanged scan-out and any
// difference on screen is the rewrite's, not the geometry's.
//
// THE ROW REPORTED IS THE ONE THAT JUST FINISHED.  lb_line_start arrives four
// hi-res pixels into the NEXT line (the rewrite's pipeline delay), so the line
// number has already moved on and the previous one has to be latched.  Getting
// this wrong tears the display by exactly one row, which looks like a rendering
// bug rather than an off-by-one.
//
// CLOCK BUDGET: a counter, a comparator and a byte register.  It does nothing
// but repackage.
//
`timescale 1ns/1ps

module antic_wb_adapt #(
    // 96, not the historical 80: the display window was four machine cycles
    // early until commit 6d48767a moved it to ANTIC's real position (display
    // begins at nominal + PF_DISPLAY_LEAD, colour clock $40 for normal
    // width), and the capture origin was calibrated against the early
    // picture.  Four cycles x four hi-res pixels = the 16-pixel black band
    // graboverlay measured on hardware (2026-08-08).
    parameter int X0   = 96,      // first buffer pixel captured
    parameter int W    = 320,     // how many (must be even)
    // 31, not the historical 8: commit 110334b0 moved the display list's
    // restart to the start of display (line 8) -- it had been resuming at
    // vblank, wrapping the whole frame so the playfield sat near line 10 --
    // and this origin was calibrated against the wrapped picture.  With the
    // frame in its real position the standard opener's 24 blank lines put
    // the playfield at capture line 31 (measured on HW, graboverlay
    // 2026-08-08; first-principles says 32 -- the +/-1 lives in this tap's
    // line numbering and is logged in the unification plan).  31..222 =
    // exactly the standard 40x24 screen filling the 192-row surface.
    parameter int ROW0 = 31,      // first scanline captured (overscan OFF)
    parameter int ROWS = 192,
    // Overscan capture (runtime, XLCTL SCALE bit 3): the full displayable
    // region instead of the 40x24 playfield.  Top = the pre-playfield lead-in
    // from the display list's blank opener, bottom = the overscan rows under
    // the standard screen.  8..247 in this tap's numbering = 240 rows, the
    // XL surface allocation's height cap.  The desktop resizes the window and
    // the plane clip to match when it flips the bit ("PS does config").
    parameter int OVS_ROW0 = 8,
    parameter int OVS_ROWS = 240
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        overscan,    // XLCTL SCALE bit 3 (clk_sys, quasi-static)

    // ---- from the rewrite -------------------------------------------------
    input  wire        lb_wr,
    input  wire [7:0]  lb_color,
    input  wire        lb_line_start,
    input  wire [8:0]  line,

    // ---- to antic_writeback ----------------------------------------------
    output logic       pix_valid,
    output logic [7:0] pix_pair,
    output logic [7:0] color_lo,
    output logic [7:0] color_hi,
    output logic [7:0] atari_row,
    output logic       row_flush
);

    logic [9:0] px;               // buffer pixel index within the line
    logic [8:0] line_q;           // the line this buffer belongs to

    wire in_win = (px >= 10'(X0)) && (px < 10'(X0 + W));
    wire [9:0] rel = px - 10'(X0);

    wire [8:0] done_row = line_q;
    wire [8:0] row0_c   = overscan ? 9'(OVS_ROW0) : 9'(ROW0);
    wire [8:0] rowend_c = overscan ? 9'(OVS_ROW0 + OVS_ROWS) : 9'(ROW0 + ROWS);
    wire       row_ok   = (done_row >= row0_c) && (done_row < rowend_c);

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            px        <= 10'd0;
            line_q    <= 9'd0;
            pix_valid <= 1'b0;
            pix_pair  <= 8'd0;
            color_lo  <= 8'h00;
            color_hi  <= 8'h00;
            atari_row <= 8'd0;
            row_flush <= 1'b0;
        end else begin
            pix_valid <= 1'b0;
            row_flush <= 1'b0;

            if (lb_line_start) begin
                // The buffer just rewound, so everything written up to here
                // belonged to the PREVIOUS line — report that one, then start
                // counting the new one.
                if (row_ok) begin
                    atari_row <= 8'(done_row - row0_c);
                    row_flush <= 1'b1;
                end
                px     <= 10'd0;
                line_q <= line;
            end else if (lb_wr) begin
                px <= px + 10'd1;
                if (in_win) begin
                    if (!rel[0]) begin
                        color_lo <= lb_color;
                    end else begin
                        color_hi  <= lb_color;
                        pix_pair  <= 8'(rel >> 1);
                        pix_valid <= 1'b1;
                    end
                end
            end
        end
    end

endmodule

`default_nettype wire
