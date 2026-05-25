// antic_seq.sv — ANTIC native-raster render sequencer (phi2-paced).
//
// docs/video-architecture.md §5.1 ("Coupled scope") / prompts/task-0014.
// Replaces the free-running `kick_counter` scaffold that antic_top used to
// trigger the display-list parse + compose.  That scaffold was a fixed ~12 ms
// timer unrelated to the emulated frame, so the *rendered image* was not phi2-
// correct: mid-frame CPU register writes (raster colour changes, P/M moves)
// and DLIs did not land on the right scanline relative to the CPU.
//
// This sequencer is driven entirely by the phi2 raster (antic_raster):
//
//   * dl_start  — pulsed once per frame at `vbi_start`.  dl_parser parses the
//                 whole display list into its 192-entry, row-indexed meta table
//                 during the vertical blank, before the first active scanline
//                 composes.  (One parse per frame is the right model — the
//                 compositor then looks the table up per row.)
//
//   * cmp_start — pulsed once per active scanline (`line_start` while the row is
//                 in the active band, i.e. ar_atari_row != 0xFF).  The
//                 compositor runs in "one row per start_compose" mode
//                 (compositor option (b), row = ar_atari_row), so render walks
//                 the frame in raster order in lockstep with the beam.  Register
//                 values latched at compose time then reflect CPU writes up to
//                 that row — the whole point of the change.
//
// `parse_pending` gates the active-row compose on the frame's parse having
// completed: it is set at reset (so nothing composes before a DL has ever been
// parsed — avoids a garbage first frame) and at each `vbi_start`, and cleared
// by `parse_done`.  The ~22-line vertical-blank window (vbi_start at line 248 →
// first active row at line 8 of the next frame) gives the parse ample time; the
// gate is belt-and-braces against a pathologically long display list.
//
// All clk_bus domain — same clock as antic_raster, dl_parser and compositor.

`default_nettype none

module antic_seq (
    input  wire clk,            // clk_bus
    input  wire rst,

    // ---- phi2 raster pulses (from antic_raster) -------------------------
    input  wire vbi_start,      // 1-cycle pulse: start of vertical blank
    input  wire line_start,     // 1-cycle pulse: start of each scanline
    input  wire active_row,     // 1 = this scanline is in the active band
    input  wire parse_done,     // 1-cycle pulse from dl_parser (parse complete)

    // ---- Render triggers ------------------------------------------------
    output reg  dl_start,       // 1-cycle pulse: parse the display list
    output reg  cmp_start       // 1-cycle pulse: compose the current row
);

    // 1 from vbi_start (a new parse is starting / in flight) until the
    // matching parse_done.  Held at reset until the first parse completes.
    reg parse_pending;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            dl_start      <= 1'b0;
            cmp_start     <= 1'b0;
            parse_pending <= 1'b1;          // suppress compose until first parse
        end else begin
            dl_start  <= 1'b0;              // both are 1-cycle pulses
            cmp_start <= 1'b0;

            // Start of frame: kick the display-list parse.
            if (vbi_start) begin
                dl_start      <= 1'b1;
                parse_pending <= 1'b1;
            end else if (parse_done) begin
                parse_pending <= 1'b0;      // meta table valid for this frame
            end

            // Per active scanline, once this frame's parse has completed.
            if (line_start && active_row && !parse_pending)
                cmp_start <= 1'b1;
        end
    end

endmodule

`default_nettype wire
