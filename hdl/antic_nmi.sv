`default_nettype none
//
// antic_nmi — NMIEN, NMIST and the /NMI line.
//
// docs/ANTIC-rewrite.md step 7.  Two events, one output: a display list
// interrupt on any scanline whose instruction carried the DLI bit, and a
// vertical blank interrupt on the first scanline of vertical blank.
//
// THE STATUS AND THE /NMI ARE ON DIFFERENT CYCLES, and that is the whole reason
// antic_dlitiming was still failing after the CPU side was closed out.  The
// status bit is set at machine cycle 7 and /NMI is asserted at cycle 8, so a
// CPU read of NMIST that lands between them already sees the flag.  Both numbers
// were bisected against hardware and neither is free to move:
//
//   cycle 8 for /NMI   — antic_dlitiming's delivery sled
//   cycle 7 for NMIST  — antic_nmist: 8 fails "set too late (>cycle 6)" and
//                        6 fails "set too early (<cycle 6)"
//
// Modelling them as one event is what made the two sleds move together no matter
// what was tried on the CPU side; they are one cycle apart in the chip.
//
// THE TWO FLAGS ARE MUTUALLY EXCLUSIVE, not accumulated.  A DLI sets NMIST to
// $80 and clears the VBI bit; a VBI sets it to $40 and clears the DLI bit.  A
// program that misses one interrupt therefore cannot see both flags at once,
// which is what a status register driven by a 2-bit latch does rather than a
// pair of independent set-reset flip-flops.  If the two coincide the VBI wins.
//
// NMIST READS AS flags | $1F: the low five bits are not driven.
//
// NMIEN GATES THE INTERRUPT, NOT THE STATUS.  The flag latches whether or not
// the interrupt is enabled, so a polling program still sees the event.
//
// A SET BEATS A COINCIDENT NMIRES.  The event is happening now and the clear is
// acknowledging something already past, so the clear is consumed and the new
// flag stands — otherwise an interrupt arriving during its own handler's
// acknowledge would be lost silently.
//
// CLOCK BUDGET: two comparators against the line position and a small counter.
// It does nothing at all for 112 of the 114 cycles in a scanline.
//
`timescale 1ns/1ps

module antic_nmi #(
    parameter int STATUS_CYCLE   = 7,   // NMIST is set here...
    parameter int NMI_CYCLE      = 8,   // ...and /NMI is asserted here
    parameter int NMI_LOW_CYCLES = 4    // how long /NMI stays down
) (
    input  wire       clk,
    input  wire       rst,

    input  wire       tick,             // 1-clk per machine cycle
    input  wire [6:0] hcount,
    input  wire       line_start,

    input  wire       dli,              // 1-clk from the display list machine
    input  wire       vbi_line,         // this scanline is the VBI line

    // Cycle numbers, live rather than parameterised, so the pair can be
    // bisected against ACID on HARDWARE instead of one bitstream per guess.
    // Reset to STATUS_CYCLE/NMI_CYCLE, so tune=0 is exactly the old behaviour.
    input  wire [6:0] status_cyc,       // NMIST is set here...
    input  wire [6:0] nmi_cyc,          // ...and /NMI asserted here
    input  wire [7:0] nmien,            // $D40E
    input  wire       nmires,           // 1-clk: write to $D40F

    output wire [7:0] nmist,            // $D40F read
    output wire       nmi_n             // active low, to the CPU
);

    // The display list reports its DLI early in the line; hold it as a level so
    // the cycle comparators below can sample it.
    logic dli_armed;
    always_ff @(posedge clk or posedge rst) begin
        if (rst)              dli_armed <= 1'b0;
        else if (dli)         dli_armed <= 1'b1;
        else if (line_start)  dli_armed <= 1'b0;
    end

    wire at_status = tick && (hcount == status_cyc);
    wire at_nmi    = tick && (hcount == nmi_cyc);

    wire dli_status = at_status && dli_armed;
    wire vbi_status = at_status && vbi_line;
    wire dli_fire   = at_nmi    && dli_armed && nmien[7];
    wire vbi_fire   = at_nmi    && vbi_line  && nmien[6];

    // ---- NMIST -----------------------------------------------------------
    logic [7:0] flags;
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            flags <= 8'h00;
        end else if (vbi_status) begin
            flags <= 8'h40;             // VBI wins a coincidence
        end else if (dli_status) begin
            flags <= 8'h80;
        end else if (nmires) begin
            flags <= 8'h00;
        end
    end

    assign nmist = flags | 8'h1F;

    // ---- /NMI ------------------------------------------------------------
    // Held low for a few machine cycles: long enough for the core to see the
    // edge, and released by ANTIC rather than by the acknowledge.
    logic [3:0] low_ctr;
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            low_ctr <= 4'd0;
        end else if (dli_fire || vbi_fire) begin
            low_ctr <= 4'(NMI_LOW_CYCLES);
        end else if (tick && low_ctr != 4'd0) begin
            low_ctr <= low_ctr - 4'd1;
        end
    end

    assign nmi_n = (low_ctr == 4'd0);

endmodule

`default_nettype wire
