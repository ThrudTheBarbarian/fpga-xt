`default_nettype none
//
// gtia_priority — which source wins this colour clock.
//
// docs/ANTIC-rewrite.md step 6.  Nine candidate sources — four players, four
// playfields and the background — walked once, serially, in one pass.  The old
// resolver was a wide combinational cone evaluated per pixel; GTIA is a priority
// encoder and a handful of product terms, so a cone was the wrong shape.
//
// PRIOR[3:0] SELECTS AN ORDERING, and there are four:
//
//   $01   P0 P1 P2 P3 PF0 PF1 PF2 PF3 BAK
//   $02   P0 P1 PF0 PF1 PF2 PF3 P2 P3 BAK
//   $04   PF0 PF1 PF2 PF3 P0 P1 P2 P3 BAK
//   $08   PF0 PF1 P0 P1 P2 P3 PF2 PF3 BAK
//
// MORE THAN ONE BIT SET IS LEGAL AND MEANS SOMETHING.  Each asserted line
// enables its own ordering's terms, and a source only lights if it wins under
// every enabled ordering; where they disagree, nothing is enabled and the pixel
// comes out BLACK.  So rather than picking one ordering, we walk once and keep
// the best-ranked present source PER ORDERING, then check they agree.
//
// AND THAT ALSO EXPLAINS PRIOR = $00, which is the power-on value and must not
// break ordinary displays.  With no line asserted no term fires, which is the
// same answer as every ordering disagreeing — so $00 is handled by treating it
// as all four enabled, with no special case.  It works out exactly right: the
// playfield sources rank in the same order in all four tables, so a
// playfield-only display is unaffected, a player over background wins in all
// four, and only a genuine player/playfield overlap goes black.  Which is
// precisely what the hardware does with GPRIOR left at zero.
//
// PRIOR[4], the "fifth player": missiles stop taking their player's colour and
// priority and all four become COLPF3 instead.  One mux on the presence vector.
//
// PRIOR[5], multi-colour players: where P0 and P1 overlap the colour is
// COLPM0 OR COLPM1, and likewise P2/P3.  That changes the COLOUR only, never
// the priority, so it is reported as a flag and resolved downstream.
//
// THE HI-RES QUIRK (antic_hiresbug): a lit pixel in modes 2/3/F displays as
// COLPF1 luma over COLPF2 hue but ranks — and collides — as playfield 2.  So the
// playfield source is mapped to PF2 for the walk and restored afterwards.
//
// CLOCK BUDGET: 9 steps, one per source, plus one to compare the winners.
// Four 4-bit running minima; the rank table is 4 x 9 x 4 bits of constants.
// With the object walk's 8 clocks that is ~19 of the ~28 in a colour clock.
//
`timescale 1ns/1ps

module gtia_priority (
    input  wire       clk,
    input  wire       rst,

    input  wire       start,          // 1-clk: resolve this colour clock
    input  wire [7:0] pres,           // [3:0] players 0-3, [7:4] missiles 0-3
    input  wire [2:0] pf_src,         // antic_pf_source encoding
    input  wire [7:0] prior,          // $D01B

    output logic [3:0] win_src,       // antic_color_sel encoding
    output logic       win_black,     // orderings disagreed: emit black
    output logic       win_multi01,   // P0/P1 multi-colour applies
    output logic       win_multi23,   // P2/P3 multi-colour applies
    output logic       valid          // 1-clk
);

    // antic_pf_source encoding, repeated here rather than shared: these are the
    // only two modules that speak it and a package for six constants would be
    // more machinery than the constants.
    localparam logic [2:0] SRC_BK        = 3'd0;
    localparam logic [2:0] SRC_PF0       = 3'd1;
    localparam logic [2:0] SRC_PF1       = 3'd2;
    localparam logic [2:0] SRC_PF2       = 3'd3;
    localparam logic [2:0] SRC_PF3       = 3'd4;
    localparam logic [2:0] SRC_HIRES_LIT = 3'd5;

    // Walk indices: 0-3 players, 4-7 playfields, 8 background.
    localparam int IDX_BAK = 8;

    wire pm5   = prior[4];
    wire multi = prior[5];

    // A hi-res lit pixel ranks and collides as playfield 2.
    wire [2:0] pf_pri = (pf_src == SRC_HIRES_LIT) ? SRC_PF2 : pf_src;
    wire       hires  = (pf_src == SRC_HIRES_LIT);

    // ---- who is present --------------------------------------------------
    // Without the fifth-player bit a missile shares its player's priority, so
    // it simply joins that player's presence.  With it, all four join PF3.
    wire any_missile = |pres[7:4];

    wire [8:0] present = {
        1'b1,                                                   // 8: BAK
        (pf_pri == SRC_PF3) | (pm5 & any_missile),              // 7: PF3
        (pf_pri == SRC_PF2),                                    // 6: PF2
        (pf_pri == SRC_PF1),                                    // 5: PF1
        (pf_pri == SRC_PF0),                                    // 4: PF0
        pres[3] | (~pm5 & pres[7]),                             // 3: P3
        pres[2] | (~pm5 & pres[6]),                             // 2: P2
        pres[1] | (~pm5 & pres[5]),                             // 1: P1
        pres[0] | (~pm5 & pres[4])                              // 0: P0
    };

    // ---- the four orderings, as ranks ------------------------------------
    // Rank 0 is highest.  Written as a table because it IS a table: four
    // constant permutations, not four pieces of logic.
    function automatic logic [3:0] rank_of(input int scheme, input int src);
        case (scheme)
            //        P0 P1 P2 P3 PF0 PF1 PF2 PF3 BAK
            0: case (src)   // $01
                   0: rank_of = 4'd0;  1: rank_of = 4'd1;
                   2: rank_of = 4'd2;  3: rank_of = 4'd3;
                   4: rank_of = 4'd4;  5: rank_of = 4'd5;
                   6: rank_of = 4'd6;  7: rank_of = 4'd7;
                   default: rank_of = 4'd8;
               endcase
            1: case (src)   // $02
                   0: rank_of = 4'd0;  1: rank_of = 4'd1;
                   2: rank_of = 4'd6;  3: rank_of = 4'd7;
                   4: rank_of = 4'd2;  5: rank_of = 4'd3;
                   6: rank_of = 4'd4;  7: rank_of = 4'd5;
                   default: rank_of = 4'd8;
               endcase
            2: case (src)   // $04
                   0: rank_of = 4'd4;  1: rank_of = 4'd5;
                   2: rank_of = 4'd6;  3: rank_of = 4'd7;
                   4: rank_of = 4'd0;  5: rank_of = 4'd1;
                   6: rank_of = 4'd2;  7: rank_of = 4'd3;
                   default: rank_of = 4'd8;
               endcase
            default: case (src)   // $08
                   0: rank_of = 4'd2;  1: rank_of = 4'd3;
                   2: rank_of = 4'd4;  3: rank_of = 4'd5;
                   4: rank_of = 4'd0;  5: rank_of = 4'd1;
                   6: rank_of = 4'd6;  7: rank_of = 4'd7;
                   default: rank_of = 4'd8;
               endcase
        endcase
    endfunction

    // PRIOR $00 asserts nothing, which lights nothing, which is the same answer
    // as every ordering disagreeing.  Treat it as all four enabled.
    wire [3:0] sch_en = (prior[3:0] == 4'd0) ? 4'b1111 : prior[3:0];

    // ---- the walk --------------------------------------------------------
    logic [3:0] step;                  // 0..8 walking, 9 = idle
    logic [3:0] best_rank [0:3];
    logic [3:0] best_src  [0:3];

    wire        walking = (step < 4'd9);
    wire [3:0]  s       = step;

    // ---- the winner ------------------------------------------------------
    // Every ordering always has a winner, because BAK is always present and
    // ranks last in all four.  Disagreement between ENABLED orderings is the
    // black case.
    logic [3:0] agreed;
    logic       disagree;
    always_comb begin
        agreed   = 4'd0;
        disagree = 1'b0;
        for (int k = 0; k < 4; k++) begin
            if (sch_en[k]) begin
                if (agreed == 4'd0 && best_src[k] != 4'd15) agreed = best_src[k] + 4'd1;
                else if (best_src[k] + 4'd1 != agreed)      disagree = 1'b1;
            end
        end
    end

    wire [3:0] won = agreed - 4'd1;

    // Map the walk index onto antic_color_sel's encoding.
    logic [3:0] mapped;
    always_comb begin
        case (won)
            4'd0:    mapped = 4'd6;              // P0
            4'd1:    mapped = 4'd7;              // P1
            4'd2:    mapped = 4'd8;              // P2
            4'd3:    mapped = 4'd9;              // P3
            4'd4:    mapped = 4'd1;              // PF0
            4'd5:    mapped = 4'd2;              // PF1
            4'd6:    mapped = hires ? 4'd5 : 4'd3;   // PF2, or the hi-res blend
            4'd7:    mapped = 4'd4;              // PF3
            default: mapped = 4'd0;              // BAK
        endcase
    end

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            step        <= 4'd9;
            valid       <= 1'b0;
            win_src     <= 4'd0;
            win_black   <= 1'b0;
            win_multi01 <= 1'b0;
            win_multi23 <= 1'b0;
            for (int k = 0; k < 4; k++) begin
                best_rank[k] <= 4'd15;
                best_src[k]  <= 4'd15;
            end
        end else begin
            valid <= 1'b0;

            if (start) begin
                step <= 4'd0;
                for (int k = 0; k < 4; k++) begin
                    best_rank[k] <= 4'd15;
                    best_src[k]  <= 4'd15;
                end
            end else if (walking) begin
                if (present[s]) begin
                    for (int k = 0; k < 4; k++) begin
                        if (rank_of(k, int'(s)) < best_rank[k]) begin
                            best_rank[k] <= rank_of(k, int'(s));
                            best_src[k]  <= s;
                        end
                    end
                end

                if (step == 4'd8) begin
                    step <= 4'd9;
                end else begin
                    step <= step + 4'd1;
                end
            end else if (step == 4'd9 && !valid) begin
                // One settling clock after the walk so the running minima have
                // landed before the winners are compared.
                step        <= 4'd10;
                win_black   <= disagree;
                win_src     <= mapped;
                // Multi-colour applies where BOTH of a pair are present and the
                // winner is one of them; it recolours, it does not re-rank.
                win_multi01 <= multi && present[0] && present[1] &&
                               (won == 4'd0 || won == 4'd1);
                win_multi23 <= multi && present[2] && present[3] &&
                               (won == 4'd2 || won == 4'd3);
                valid       <= 1'b1;
            end
        end
    end

endmodule

`default_nettype wire
