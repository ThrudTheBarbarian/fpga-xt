// color_resolver.sv — combinational priority + colour resolution.
//
// Takes one idx_buf byte (the per-pixel layered presence emitted by the
// compositor) and the live GTIA register state (PRIOR + COLPM/COLPF/
// COLBK) and returns the 8-bit Atari hue:luma value the scan-out path
// should display. Standalone / no clocking — meant to be instantiated
// at scan-out time, not in the compositor.
//
// idx_buf layout (rp-antic convention):
//   bit 0 = PF0 present     bit 4 = P0 / M0 present
//   bit 1 = PF1 present     bit 5 = P1 / M1 present
//   bit 2 = PF2 present     bit 6 = P2 / M2 present
//   bit 3 = PF3 present     bit 7 = P3 / M3 present
//
// Within the playfield nibble at most one bit is set (one PF source per
// pixel). Within the PM nibble multiple bits can be set (overlap).
// Missiles share their player's bit — distinguishing them needs a wider
// idx_buf and lands in M10b along with the GTIA modes.
//
// PRIOR layout ($D01B):
//   [3:0] = priority ordering (only one bit set):
//      bit 0 → P0,P1,P2,P3, PF0,PF1,PF2,PF3, BG
//      bit 1 → P0,P1,       PF0,PF1,PF2,PF3, P2,P3, BG
//      bit 2 → PF0,PF1,PF2,PF3, P0,P1,P2,P3, BG
//      bit 3 → PF0,PF1, P0,P1,P2,P3, PF2,PF3, BG
//   [4]   = PM5     (deferred — needs missile-vs-player split)
//   [5]   = OR-mode (multiple players → OR'd colour)
//   [7:6] = GTIA mode (deferred — needs source-nibble in idx_buf)

`default_nettype none

module color_resolver (
    input  wire [11:0] idx_buf,         // M10c: widened from 8 → 12 bits
                                        //   [3:0]   = PF source / GTIA nibble
                                        //   [7:4]   = P|M shared (legacy)
                                        //   [11:8]  = M-only (NEW for PM5)
    input  wire  [7:0] prior,
    input  wire  [7:0] colpm0,
    input  wire  [7:0] colpm1,
    input  wire  [7:0] colpm2,
    input  wire  [7:0] colpm3,
    input  wire  [7:0] colpf0,
    input  wire  [7:0] colpf1,
    input  wire  [7:0] colpf2,
    input  wire  [7:0] colpf3,
    input  wire  [7:0] colbk,
    output logic [7:0] color_out
);
    // Convenience aliases.
    wire pf0 = idx_buf[0];
    wire pf1 = idx_buf[1];
    wire pf2 = idx_buf[2];
    wire pf3 = idx_buf[3];
    // PM5 (PRIOR[4]=1) routes missiles through COLPF3 instead of their
    // player colour. The high-nibble bits stay "P|M shared" for legacy
    // / non-PM5 use; the new M-only nibble lets us strip the missile
    // contribution from the player slot when PM5 is active.
    wire pm5_active = prior[4];
    wire m0 = idx_buf[8];
    wire m1 = idx_buf[9];
    wire m2 = idx_buf[10];
    wire m3 = idx_buf[11];
    // Legacy P|M shared bits — under PM5 we mask out the missile so
    // only the actual player paints in COLPMx.
    wire p0  = pm5_active ? (idx_buf[4] & ~m0) : idx_buf[4];
    wire p1  = pm5_active ? (idx_buf[5] & ~m1) : idx_buf[5];
    wire p2  = pm5_active ? (idx_buf[6] & ~m2) : idx_buf[6];
    wire p3  = pm5_active ? (idx_buf[7] & ~m3) : idx_buf[7];
    wire any_missile = m0 | m1 | m2 | m3;

    // OR-mode helper: when PRIOR[5]=1, players that overlap each other
    // contribute their colour ORed together. This treats P-vs-P conflict
    // as additive instead of strictly priority-resolved.
    wire or_mode = prior[5];

    // Pre-computed "winning player" colour. In normal mode this is just
    // the topmost player. In OR-mode it's the bitwise OR of all present
    // players' colours.
    logic [7:0] pm_color;
    logic        pm_present;
    always_comb begin
        pm_present = p0 | p1 | p2 | p3;
        if (or_mode) begin
            pm_color = (p0 ? colpm0 : 8'h0)
                     | (p1 ? colpm1 : 8'h0)
                     | (p2 ? colpm2 : 8'h0)
                     | (p3 ? colpm3 : 8'h0);
        end else begin
            // Strict priority within PMs: P0 > P1 > P2 > P3.
            if      (p0) pm_color = colpm0;
            else if (p1) pm_color = colpm1;
            else if (p2) pm_color = colpm2;
            else if (p3) pm_color = colpm3;
            else         pm_color = 8'h0;
        end
    end

    // Within-PF priority for normal modes: PF0 > PF1 > PF2 > PF3.
    // For GTIA modes (PRIOR[7:6] != 00) the low nibble of idx_buf carries
    // a 4-bit GTIA pixel value rather than a 1-of-4 PF presence bitmap;
    // we decode that into an 8-bit Atari hue:luma below and force
    // pf_present high (every GTIA pixel paints).
    wire [1:0] gtia_mode  = prior[7:6];
    wire       gtia_active = (gtia_mode != 2'b00);
    wire [3:0] gtia_nibble = idx_buf[3:0];

    // Normal-mode PF colour decode. PM5 (PRIOR[4]) injects the missile
    // presence into the PF3 slot — missiles colour as COLPF3 and live in
    // the PF-lo group (PF2,PF3) for sub-priority purposes.
    wire pf3_eff = pf3 | (pm5_active & any_missile);

    logic [7:0] pf_color_normal;
    logic       pf_present_normal;
    always_comb begin
        pf_present_normal = pf0 | pf1 | pf2 | pf3_eff;
        if      (pf0)     pf_color_normal = colpf0;
        else if (pf1)     pf_color_normal = colpf1;
        else if (pf2)     pf_color_normal = colpf2;
        else if (pf3_eff) pf_color_normal = colpf3;
        else              pf_color_normal = 8'h0;
    end

    // GTIA decode. Mode F's source byte is reinterpreted as 80 4-bit
    // GTIA pixels per scanline (each 4 atari px wide); the compositor
    // already extracted the relevant 4-bit nibble into idx_buf[3:0].
    //   GTIA 9  (01): 16 luma, hue from COLBK   → {colbk[7:4], nibble}
    //   GTIA 10 (10): 9-colour palette from PM/PF/BG, indexed by nibble
    //   GTIA 11 (11): 16 hues, luma from COLBK  → {nibble, colbk[3:0]}
    logic [7:0] pf_color_gtia;
    always_comb begin
        case (gtia_mode)
            2'b01: pf_color_gtia = {colbk[7:4], gtia_nibble};
            2'b10: case (gtia_nibble)
                4'd0:    pf_color_gtia = colpm0;
                4'd1:    pf_color_gtia = colpm1;
                4'd2:    pf_color_gtia = colpm2;
                4'd3:    pf_color_gtia = colpm3;
                4'd4:    pf_color_gtia = colpf0;
                4'd5:    pf_color_gtia = colpf1;
                4'd6:    pf_color_gtia = colpf2;
                4'd7:    pf_color_gtia = colpf3;
                default: pf_color_gtia = colbk;       // 8..15 → BG
            endcase
            2'b11:   pf_color_gtia = {gtia_nibble, colbk[3:0]};
            default: pf_color_gtia = 8'h00;
        endcase
    end

    wire [7:0] pf_color  = gtia_active ? pf_color_gtia    : pf_color_normal;
    wire       pf_present = gtia_active ? 1'b1            : pf_present_normal;

    // For PRIOR[1] / PRIOR[3] the priority list splits PMs / PFs into two
    // groups — we need the high-priority half and the low-priority half
    // separately. Names: pm_hi = P0/P1, pm_lo = P2/P3, pf_hi = PF0/PF1,
    // pf_lo = PF2/PF3.
    logic [7:0] pm_hi_color;
    logic       pm_hi_present;
    logic [7:0] pm_lo_color;
    logic       pm_lo_present;
    logic [7:0] pf_hi_color_normal;
    logic       pf_hi_present_normal;
    logic [7:0] pf_lo_color_normal;
    logic       pf_lo_present_normal;
    logic [7:0] pf_hi_color;
    logic       pf_hi_present;
    logic [7:0] pf_lo_color;
    logic       pf_lo_present;
    always_comb begin
        pm_hi_present = p0 | p1;
        pm_lo_present = p2 | p3;
        if (or_mode) begin
            pm_hi_color = (p0 ? colpm0 : 8'h0) | (p1 ? colpm1 : 8'h0);
            pm_lo_color = (p2 ? colpm2 : 8'h0) | (p3 ? colpm3 : 8'h0);
        end else begin
            pm_hi_color = p0 ? colpm0 : (p1 ? colpm1 : 8'h0);
            pm_lo_color = p2 ? colpm2 : (p3 ? colpm3 : 8'h0);
        end

        pf_hi_present_normal = pf0 | pf1;
        pf_lo_present_normal = pf2 | pf3_eff;     // PM5 missile joins pf_lo
        pf_hi_color_normal   = pf0 ? colpf0 : (pf1 ? colpf1 : 8'h0);
        pf_lo_color_normal   = pf2 ? colpf2 : (pf3_eff ? colpf3 : 8'h0);
        // GTIA mode collapses the PF-hi/PF-lo split — everything becomes
        // a single GTIA-coloured "high-priority" PF for layering. PRIOR[1]
        // (P-hi > PF > P-lo) and PRIOR[3] (PF-hi > PM > PF-lo) both
        // degenerate to "PF on top of PM" / "P-hi > PF > P-lo > BG"
        // accordingly.
        pf_hi_present = gtia_active ? 1'b1            : pf_hi_present_normal;
        pf_lo_present = gtia_active ? 1'b0            : pf_lo_present_normal;
        pf_hi_color   = gtia_active ? pf_color_gtia   : pf_hi_color_normal;
        pf_lo_color   = gtia_active ? pf_color_gtia   : pf_lo_color_normal;
    end

    // Final pick. PRIOR[3:0] selects the ordering; default (no bit set)
    // falls through to PRIOR[0]'s semantics.
    always_comb begin
        unique case (prior[3:0])
            // PRIOR[1]: P-hi > PF > P-lo > BG
            4'b0010: begin
                if      (pm_hi_present) color_out = pm_hi_color;
                else if (pf_present)    color_out = pf_color;
                else if (pm_lo_present) color_out = pm_lo_color;
                else                    color_out = colbk;
            end
            // PRIOR[2]: PF > PM > BG
            4'b0100: begin
                if      (pf_present) color_out = pf_color;
                else if (pm_present) color_out = pm_color;
                else                 color_out = colbk;
            end
            // PRIOR[3]: PF-hi > PM > PF-lo > BG
            4'b1000: begin
                if      (pf_hi_present) color_out = pf_hi_color;
                else if (pm_present)    color_out = pm_color;
                else if (pf_lo_present) color_out = pf_lo_color;
                else                    color_out = colbk;
            end
            // PRIOR[0] and undefined fallthrough: PM > PF > BG
            default: begin
                if      (pm_present) color_out = pm_color;
                else if (pf_present) color_out = pf_color;
                else                 color_out = colbk;
            end
        endcase
    end

endmodule

`default_nettype wire
