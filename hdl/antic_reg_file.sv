`default_nettype none
//
// antic_reg_file — ANTIC's registers, $D400-$D40F.
//
// docs/ANTIC-rewrite.md.  Sixteen addresses, mirrored sixteen times across
// $D400-$D4FF: ANTIC decodes four address bits and nothing above them, which is
// the whole of antic_addrmirror.
//
// ALMOST EVERYTHING IS WRITE-ONLY and reads back $FF — DMACTL, CHACTL, the
// display list pointer, the scroll registers, PMBASE, CHBASE, WSYNC and NMIEN.
// Only VCOUNT and NMIST read anything, and the two unassigned addresses ($D406
// and $D408) read $FF like the rest.  That is what antic_default measures.
//
// THE DISPLAY LIST POINTER IS NOT HELD HERE.  DLISTL/DLISTH are the display
// list machine's live counter, so this file forwards the writes to it rather
// than keeping a copy — see antic_dl.  A CPU write moves the fetch point
// immediately, and reading gives $FF because ANTIC never drives the bus for it.
//
// WSYNC IS A LATCH WITH A DELAY SLOT, and all three parts of that matter.
//
// ANTIC holds a LATCH, not a countdown: any write to $D40A sets it, the value
// written is irrelevant, and the release point clears it once per scanline.
//
// /RDY IS A REGISTERED OUTPUT OF THAT LATCH, one machine cycle behind it in
// BOTH directions.  Avery Lee, from a logic-analyser capture of a real XE:
// "there is a one-cycle delay before RDY is pulled.  That delay is on ANTIC's
// side, so it is one cycle regardless of whether the next cycle is a DMA or CPU
// cycle."  Cycles numbered from the opcode fetch:
//
//     STA wsync                      INC wsync
//     3: write to wsync              4: write ORIGINAL value
//     4: /RDY still high             5: write NEW value, /RDY still high
//     5: /RDY low, CPU stalls        6: /RDY low, CPU stalls
//
// A combinational /RDY has no delay slot at all, so a plain STA parks the CPU
// one position early.  The delay has to be on BOTH edges: delaying only the
// assert breaks the case where an RMW's two writes straddle the release.
//
// A read-modify-write writes $D40A twice.  Because the latch is level state the
// second write merely re-sets an already-set latch and changes nothing — the
// stall is timed from the FIRST write, and the extra machine cycle the RMW
// spends is exactly the one the delay slot allows.  That is the whole
// difference between STA WSYNC and INC WSYNC in antic_wsync.
//
// CLEAR BEATS SET.  A write landing on the same cycle as the release does not
// start a fresh line-long stall; the release wins and the CPU carries on.  That
// is antic_wsync's "Late INC WSYNC" case.
//
// The other strobes are EDGES, not levels: a `we`-derived level held across a
// stalled bus cycle re-triggers as soon as it is released
// (antic_strobe_level_deadlock).
//
// NMIRES is the same shape: writing $D40F is a strobe that clears the interrupt
// status, and reading the same address returns it.
//
// CLOCK BUDGET: a register file and two comparators.  Nothing here is on a
// per-pixel or even a per-cycle path except the WSYNC release compare.
//
`timescale 1ns/1ps

module antic_reg_file #(
    parameter int WSYNC_RELEASE = 104   // the cycle /RDY comes back
) (
    input  wire       clk,
    input  wire       rst,

    input  wire       tick,             // 1-clk per machine cycle
    input  wire [6:0] hcount,

    // ---- CPU bus ---------------------------------------------------------
    input  wire [7:0] addr,             // low byte of $D4xx
    input  wire       we,
    input  wire [7:0] wdata,
    output logic [7:0] rdata,

    // ---- status in -------------------------------------------------------
    input  wire [7:0] vcount,
    input  wire [7:0] nmist,

    // ---- register outputs -------------------------------------------------
    output logic [7:0] dmactl,
    output logic [7:0] chactl,
    output logic [7:0] hscrol,
    output logic [7:0] vscrol,
    output logic [7:0] pmbase,
    output logic [7:0] chbase,
    output logic [7:0] nmien,

    // ---- strobes ----------------------------------------------------------
    output wire        dlist_we_l,      // straight through to antic_dl
    output wire        dlist_we_h,
    output wire [7:0]  dlist_wdata,
    output wire        nmires,          // 1-clk
    output wire        rdy_n            // 1 = the CPU is held for WSYNC
);

    wire [3:0] a = addr[3:0];

    // A strobe is an EDGE.  Derived from the level instead, a stalled write
    // holds it asserted and re-arms WSYNC the instant it is released.
    logic we_d;
    always_ff @(posedge clk or posedge rst) begin
        if (rst) we_d <= 1'b0;
        else     we_d <= we;
    end
    wire we_edge = we && !we_d;

    assign dlist_we_l  = we_edge && (a == 4'h2);
    assign dlist_we_h  = we_edge && (a == 4'h3);
    assign dlist_wdata = wdata;
    assign nmires      = we_edge && (a == 4'hF);

    // ---- the writable registers -------------------------------------------
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            dmactl <= 8'h00;
            chactl <= 8'h00;
            hscrol <= 8'h00;
            vscrol <= 8'h00;
            pmbase <= 8'h00;
            chbase <= 8'h00;
            nmien  <= 8'h00;
        end else if (we) begin
            case (a)
                4'h0: dmactl <= wdata;
                4'h1: chactl <= wdata;
                4'h4: hscrol <= wdata;
                4'h5: vscrol <= wdata;
                4'h7: pmbase <= wdata;
                4'h9: chbase <= wdata;
                4'hE: nmien  <= wdata;
                default: ;   // 2/3 go to the DL machine, A and F are strobes
            endcase
        end
    end

    // ---- WSYNC -------------------------------------------------------------
    wire wsync_set = we_edge && (a == 4'hA);
    wire wsync_clr = tick && (hcount == 7'(WSYNC_RELEASE));

    logic latch;
    always_ff @(posedge clk or posedge rst) begin
        if (rst)             latch <= 1'b0;
        else if (wsync_clr)  latch <= 1'b0;   // clear beats a coincident set
        else if (wsync_set)  latch <= 1'b1;
    end

    // One machine cycle behind the latch, both edges: this is the delay slot.
    logic rdy_q;
    always_ff @(posedge clk or posedge rst) begin
        if (rst)       rdy_q <= 1'b0;
        else if (tick) rdy_q <= latch;
    end

    assign rdy_n = rdy_q;

    // ---- reads -------------------------------------------------------------
    always_comb begin
        case (a)
            4'hB:    rdata = vcount;
            4'hF:    rdata = nmist;
            default: rdata = 8'hFF;      // everything else is write-only
        endcase
    end

endmodule

`default_nettype wire
