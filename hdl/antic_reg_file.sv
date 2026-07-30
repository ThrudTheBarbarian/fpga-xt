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
// WSYNC IS A STROBE, NOT A REGISTER.  Writing $D40A halts the CPU by releasing
// /RDY, and it is released again at cycle 104.  Two things about it are
// hard-won and easy to undo:
//
//   * the strobe must be an EDGE, not a level.  A `we`-derived level held
//     across a stalled write re-arms WSYNC as soon as it is released, and the
//     machine never restarts (recorded in antic_strobe_level_deadlock).
//   * a read-modify-write instruction writes $D40A twice, and the delay arms on
//     the FIRST write.  Arming uniformly on every write regresses VCOUNT
//     (wsync_rmw_rearm).
//
// So the arm is `we && !we_d` — one clock, on the leading edge — and re-arming
// while already waiting is ignored.
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
    // Arm on the LEADING edge of the first write.  A read-modify-write
    // instruction writes twice; arming on both regresses VCOUNT.
    logic waiting;
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            waiting <= 1'b0;
        end else if (we_edge && (a == 4'hA) && !waiting) begin
            waiting <= 1'b1;
        end else if (waiting && tick && (hcount == 7'(WSYNC_RELEASE))) begin
            waiting <= 1'b0;
        end
    end

    assign rdy_n = waiting;

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
