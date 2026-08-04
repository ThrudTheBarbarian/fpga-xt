`default_nettype none
//
// antic2_regs — ANTIC's register file for the from-scratch rewrite.
//
// Plain state plus the three things the sequence needs to be told about, which
// are the only parts with any subtlety:
//
//   WSYNC   ($D40A) a write arms the halt.  The SECOND write of an RMW RE-ARMS
//                   it, pushing the release one cycle later -- and only when the
//                   two writes are ADJACENT machine cycles.
//   NMIRES  ($D40F) a write clears NMIST.
//   NMIEN   ($D40E) gates the INTERRUPT, never the status.
//
// THE RMW RE-ARM, and why it is detected HERE rather than derived downstream.
// emu/antic.c settles this with two tests that look like a contradiction and are
// not:
//
//     sta wsync ... lda random   ;*, 105, 106, 107   -> released 104
//     inc wsync ... lda random   ;105, 106, 107, 108 -> released 105
//
// Same register, different instruction, different release: the RMW's second
// write really does re-arm.  `inc` writes on consecutive CPU cycles, so
// ADJACENCY is the test -- gtia_pmresize's `inc wsync` has a refresh slot
// between its two writes and must NOT take the extra.
//
// DISPROVED AND NOT TO BE REINTRODUCED: making this depend on WHERE IN THE LINE
// the writes fall.  emu carries it as WSYNC_RMW_ADJ_CYCLE = 0 with the result
// recorded -- trying it scored 51/63, costing antic_dlitiming, antic_dmapattern,
// gtia_phantomdma, gtia_psuedomodee and pokey_noise, because the extra is wanted
// at cycles 1-2 AND at 109-110 and unwanted at 30-55, "which no threshold
// expresses: position in the line is the wrong variable".
//
`timescale 1ns/1ps

module antic2_regs (
    input  wire        clk,
    input  wire        rst,
    input  wire        tick,           // phi2 — one machine cycle

    // ---- CPU register port ($D400-$D40F, mirrored every 16) ---------------
    input  wire        cs,             // $D4xx selected
    input  wire        we,             // write strobe, one per machine cycle
    input  wire  [3:0] addr,           // addr[3:0] — $D4xx mirrors every 16
    input  wire  [7:0] wdata,

    // ---- from the sequence ------------------------------------------------
    input  wire  [7:0] nmist_in,
    input  wire  [7:0] vcount_in,

    // ---- register state out -----------------------------------------------
    output logic [7:0] dmactl,
    output logic [7:0] chactl,
    // DLISTL/H ARE NOT STORED HERE.  They ARE the display-list counter, which
    // antic2_dl increments in place as it fetches; a write says where the list
    // RESUMES from and there is nothing to reload it from later.  Keeping a
    // copy in the register file would be a second definition of the same
    // value, so the write leaves here as an EVENT and antic2_dl owns it.
    output logic       dlist_lo_stb,
    output logic       dlist_hi_stb,
    output logic [7:0] dlist_val,
    output logic [7:0] hscrol,
    output logic [7:0] vscrol,
    output logic [7:0] pmbase,
    output logic [7:0] chbase,
    output logic [7:0] nmien,
    output wire  [7:0] rdata,

    // ---- strobes to the sequence ------------------------------------------
    output logic       wsync_stb,
    output logic       wsync_rmw_readd,   // this write is an RMW's SECOND write
                                          // AND adjacent to the first
    output logic       nmires_stb
);

    // Only three ANTIC registers READ back; everything else is write-only and
    // the bus floats.  $D40B VCOUNT and $D40F NMIST come from the sequence,
    // $D40C/$D40D are the light pen (unimplemented, reads 0).
    assign rdata = (addr == 4'hB) ? vcount_in
                 : (addr == 4'hF) ? nmist_in
                 : 8'h00;

    wire wr = cs && we;

    // Adjacency: was there a WSYNC write on the PREVIOUS machine cycle?  An
    // RMW's two writes are consecutive, so a second write with this set is the
    // re-arming one.  Cleared on any tick without a WSYNC write, so a pair
    // separated by a DMA or refresh slot does NOT count -- which is exactly
    // gtia_pmresize's case.
    logic wsync_wr_prev;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            dmactl          <= 8'h00;
            chactl          <= 8'h00;
            dlist_lo_stb    <= 1'b0;
            dlist_hi_stb    <= 1'b0;
            dlist_val       <= 8'h00;
            hscrol          <= 8'h00;
            vscrol          <= 8'h00;
            pmbase          <= 8'h00;
            chbase          <= 8'h00;
            nmien           <= 8'h00;
            wsync_stb       <= 1'b0;
            wsync_rmw_readd <= 1'b0;
            nmires_stb      <= 1'b0;
            wsync_wr_prev   <= 1'b0;
        end else begin
            wsync_stb       <= 1'b0;
            wsync_rmw_readd <= 1'b0;
            nmires_stb      <= 1'b0;
            dlist_lo_stb    <= 1'b0;
            dlist_hi_stb    <= 1'b0;

            if (wr) begin
                case (addr)
                    4'h0: dmactl <= wdata;
                    4'h1: chactl <= wdata;
                    4'h2: begin dlist_lo_stb <= 1'b1; dlist_val <= wdata; end
                    4'h3: begin dlist_hi_stb <= 1'b1; dlist_val <= wdata; end
                    4'h4: hscrol <= wdata;
                    4'h5: vscrol <= wdata;
                    4'h7: pmbase <= wdata;
                    4'h9: chbase <= wdata;
                    4'hA: begin
                        wsync_stb       <= 1'b1;
                        wsync_rmw_readd <= wsync_wr_prev;
                    end
                    4'hE: nmien  <= wdata;
                    4'hF: nmires_stb <= 1'b1;
                    default: ;
                endcase
            end

            // Track adjacency on the machine-cycle boundary, not on every
            // fabric clock: "adjacent" means consecutive CPU cycles.
            if (tick)
                wsync_wr_prev <= wr && (addr == 4'hA);
        end
    end

endmodule

`default_nettype wire
