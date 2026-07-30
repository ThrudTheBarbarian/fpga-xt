`default_nettype none
//
// gtia_collide — the sixteen collision latches.
//
// docs/ANTIC-rewrite.md step 6.  Eight objects walked once per colour clock,
// each contributing its collisions as it is visited.  Nothing here is a separate
// engine: the presence vector is already computed, so accumulating collisions is
// one OR per object per step.
//
// The latches, all read-only and all four bits wide:
//   $D000-$D003  M0PF-M3PF   missile n against playfield 0-3
//   $D004-$D007  P0PF-P3PF   player  n against playfield 0-3
//   $D008-$D00B  M0PL-M3PL   missile n against players 0-3
//   $D00C-$D00F  P0PL-P3PL   player  n against players 0-3
//
// A PLAYER NEVER COLLIDES WITH ITSELF, so bit n of PnPL is always clear —
// pinned by tb_pm_collide T5.  A missile CAN collide with its own player;
// there is no self-bit to mask, because they are different objects.
//
// There is no player-versus-missile register.  A player and a missile touching
// is recorded once, in that missile's MnPL.
//
// GTIA DOES NOT COMPARE DURING VERTICAL BLANK.  Without the active-line gate the
// latches accumulate all the way down the frame and gtia_collision reports
// collisions in VBLANK.  Horizontal windowing alone is not enough — this is a
// per-line gate, not a per-pixel one.
//
// A LIT HI-RES PIXEL COLLIDES AS PLAYFIELD 2 (antic_hiresbug), even though it
// displays as COLPF1 luma over COLPF2 hue.  The mapping is the same one the
// priority walk applies, and for the same reason.
//
// PRIOR DOES NOT REACH HERE.  The fifth-player bit changes what colour a missile
// is drawn in; it does not change which latch records it.
//
// CLOCK BUDGET: 8 clocks, one per object, and they overlap the priority walk
// entirely — both consume the same presence vector and neither feeds the other.
// So the pair costs max(8, 10) = 10 clocks of the ~28, not 18.
//
`timescale 1ns/1ps

module gtia_collide (
    input  wire       clk,
    input  wire       rst,

    input  wire       start,          // 1-clk: accumulate this colour clock
    input  wire [7:0] pres,           // [3:0] players 0-3, [7:4] missiles 0-3
    input  wire [2:0] pf_src,         // antic_pf_source encoding
    input  wire       active,         // this is an active display line
    input  wire       hitclr,         // 1-clk: $D01E write

    // Four nibbles each, object 0 in the low nibble.
    output logic [15:0] m_pf,
    output logic [15:0] p_pf,
    output logic [15:0] m_pl,
    output logic [15:0] p_pl,

    output logic        busy
);

    localparam logic [2:0] SRC_PF0       = 3'd1;
    localparam logic [2:0] SRC_PF3       = 3'd4;
    localparam logic [2:0] SRC_HIRES_LIT = 3'd5;

    // A lit hi-res pixel collides as playfield 2.
    wire [2:0] pf_c = (pf_src == SRC_HIRES_LIT) ? 3'd3 : pf_src;

    // Which playfield the beam is over, as a one-hot nibble.  Background is
    // not a playfield and collides with nothing.
    logic [3:0] pf_hit;
    always_comb begin
        if (pf_c >= SRC_PF0 && pf_c <= SRC_PF3) pf_hit = 4'b0001 << (pf_c - SRC_PF0);
        else                                    pf_hit = 4'b0000;
    end

    // ---- the walk --------------------------------------------------------
    logic [3:0] step;                  // 0..7 walking, 8 = idle
    wire        walking = (step < 4'd8);
    wire [2:0]  i       = step[2:0];
    wire        is_miss = i[2];
    wire [1:0]  n       = i[1:0];

    // Players seen by this object.  A player masks itself out; a missile has
    // nothing to mask, since it is not one of the four.
    wire [3:0] players = pres[3:0];
    wire [3:0] vs_players = is_miss ? players : (players & ~(4'b0001 << n));

    wire hit = walking && active && pres[i];

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            step <= 4'd8;
            m_pf <= 16'h0000;
            p_pf <= 16'h0000;
            m_pl <= 16'h0000;
            p_pl <= 16'h0000;
            busy <= 1'b0;
        end else if (hitclr) begin
            // HITCLR wins over an in-flight accumulation: the write is what the
            // program just did, and it clears everything.
            m_pf <= 16'h0000;
            p_pf <= 16'h0000;
            m_pl <= 16'h0000;
            p_pl <= 16'h0000;
        end else begin
            if (start) begin
                step <= 4'd0;
                busy <= 1'b1;
            end else if (walking) begin
                if (hit) begin
                    if (is_miss) begin
                        m_pf[{n, 2'b00} +: 4] <= m_pf[{n, 2'b00} +: 4] | pf_hit;
                        m_pl[{n, 2'b00} +: 4] <= m_pl[{n, 2'b00} +: 4] | vs_players;
                    end else begin
                        p_pf[{n, 2'b00} +: 4] <= p_pf[{n, 2'b00} +: 4] | pf_hit;
                        p_pl[{n, 2'b00} +: 4] <= p_pl[{n, 2'b00} +: 4] | vs_players;
                    end
                end
                if (step == 4'd7) busy <= 1'b0;
                step <= step + 4'd1;
            end
        end
    end

endmodule

`default_nettype wire
