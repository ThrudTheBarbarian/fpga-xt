`default_nettype none
//
// antic2_line — the start-of-line bookkeeping, transcribed from
// emu/antic.c:line_start().
//
// SCOPE, STATED SO IT IS NOT MISTAKEN FOR THE WHOLE THING.  This is STAGE 1:
// the row / display-list sequencing that antic2_seq needs to decide row_ends and
// the DLI.  The PLAYFIELD FETCH MAP is deliberately NOT here yet -- it is stage 3
// and it reuses antic_dma_sched, which is already measured correct end to end
// (all 50 of antic_dmapattern's maps, and its steals map 1:1 onto the cycles the
// CPU actually loses).  Building half of it now would make the stage-1 gate
// ambiguous.
//
// WHAT line_start DOES, in order, and what belongs where:
//
//   1  hscrol_line = hscrol          per-line clamp            (stage 3)
//   2  clear blocked[], pf_at[], pf_next, lb_origin, dli_line
//   3  REFRESH on EVERY scanline     nine cycles, unconditional (stage 2)
//   4  pm_dma                                                   (stage 3)
//   5  if dl_done -> return          the list runs until JVB    HERE
//   6  if row_ends -> fetch the next instruction               HERE
//   7+ playfield window and map                                 (stage 3)
//
// THE UNCONDITIONAL REFRESH is worth carrying forward now even though it lands in
// stage 2: emu takes nine cycles for memory refresh on EVERY scanline whatever
// DMACTL says.  Building it only along the playfield path let the CPU run nine
// cycles a line too fast whenever DMA was off, and that is exactly the gap
// gtia_pmretrigger's fourth case shows -- its `sta hposp0` landed on cycle 81
// against an annotated 90.
//
`timescale 1ns/1ps

module antic2_line #(
    parameter int DISPLAY_TOP    = 8,
    parameter int DISPLAY_BOTTOM = 248
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        line_start,        // pulse at cycle 0 of each scanline

    input  wire [8:0]  scanline,
    input  wire [7:0]  dmactl,
    input  wire        row_ends_in,       // from antic2_seq, decided at CYC_ROWEND

    // ---- display-list instruction fetch ------------------------------------
    // No byte port: antic2_dl owns the decode and hands back dl_done_in.
    output logic       dl_fetch_req,      // ask antic2_dl for the next instruction

    // ---- state the sequence needs ------------------------------------------
    output logic [3:0] row_line,
    input  wire        dl_done_in,        // from antic2_dl (JVB parked)
    output logic       dl_done,           // local view, cleared at vblank end
    output logic       row_first          // this is the row's FIRST scanline
);

    // A JVB parks the list until VERTICAL BLANK ENDS -- scanline DISPLAY_TOP --
    // NOT until the frame wraps.  That distinction is what lets a list which
    // overran keep executing through scanlines 0..7 of the new frame, where
    // antic_dlistwrap's DLI actually lands.  Bounding it by the frame is the
    // intuitive reading and silently drops that DLI.
    wire vblank_ends = (scanline == 9'(DISPLAY_TOP));

    // Display-list EXECUTION has NO BOTTOM CUTOFF: the list runs until it
    // executes a JVB, so a list longer than the visible region carries on past
    // the bottom of the frame and into the next one.  antic_dlistwrap builds
    // exactly that -- 248 blank lines then a DLI landing near scanline 256,
    // which must still fire.
    wire in_display = (scanline >= 9'(DISPLAY_TOP)) &&
                      (scanline <  9'(DISPLAY_BOTTOM));

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            row_line     <= 4'd0;
            // START PARKED, as if a JVB had just executed.  A well-formed
            // display list only ever begins after vertical blank ends, and the
            // release at scanline DISPLAY_TOP is what puts it there.  Starting
            // UNPARKED runs the list from scanline 0 and shifts every DLI eight
            // lines early.
            dl_done      <= 1'b1;
            row_first    <= 1'b0;
            dl_fetch_req <= 1'b0;
        end else begin
            dl_fetch_req <= 1'b0;
            if (dl_done_in) dl_done <= 1'b1;

            if (line_start) begin
                row_first <= 1'b0;

                // Nothing reloads the display-list counter at the frame wrap: a
                // list that ran past the bottom simply CONTINUES into the next
                // frame.  A list returns to its start only by executing a JVB,
                // which has already loaded the address.  Reloading from a DLIST
                // latch each frame is the intuitive model and it fails
                // antic_dlistwrap's first assertion outright.  row_line is not
                // reset either -- an overrunning row carries on across the
                // boundary.
                if (vblank_ends && dl_done) begin
                    dl_done <= 1'b0;
                    // force a fetch on the first line
                    dl_fetch_req <= 1'b1;
                    row_first    <= 1'b1;
                    row_line     <= 4'd0;
                end
                else if (!dl_done && row_ends_in) begin
                    // Only FETCHING a new instruction needs display-list DMA.  A
                    // row already in progress keeps running -- and keeps its DLI
                    // -- when DMACTL is cleared out from under it.
                    if (in_display) begin
                        if (dmactl[5]) begin
                            dl_fetch_req <= 1'b1;
                            row_first    <= 1'b1;
                            row_line     <= 4'd0;
                        end
                        // With DL DMA OFF there is no new instruction, so the
                        // CURRENT one is REUSED and the row runs again -- the
                        // playfield goes on being fetched from it.  Skipping the
                        // playfield build here as well as the fetch is wrong:
                        // the two are INDEPENDENT.  antic_hscrolbug's second
                        // test writes DMACTL = $01 mid-line "so that the $5e byte
                        // is reused"; with them coupled its row fetched nothing
                        // and no collision registered anywhere.
                        else row_line <= row_line + 4'd1;
                    end
                end
                else if (!dl_done) begin
                    row_line <= row_line + 4'd1;
                end
            end

            // NO DL DECODE HERE.  antic2_dl owns it.  This module previously
            // latched every `dl_byte_valid` as an instruction, which also caught
            // the OPERAND bytes of LMS and JMP -- so a $40-something operand read
            // as a JVB and parked the list, and the DLI never fired.  That is the
            // "two definitions of one value" trap: the memory port feeds ONE
            // decoder, and `dl_done` comes back from it.
        end
    end

endmodule

`default_nettype wire
