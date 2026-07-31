`default_nettype none
//
// gtia_obj_walk — the player/missile object walk.
//
// docs/ANTIC-rewrite.md step 6, and the clearest case of the serial rule in the
// whole rewrite.  Eight objects — four players, four missiles — share ONE
// datapath, stepped eight times per colour clock.  The old engine unrolled all
// sixteen object-steps into a single combinational block evaluated every machine
// cycle; that is a wide cone the real chip could not have contained, which was
// independent confirmation that the shape was wrong.
//
// THE MODEL IS A SHIFT REGISTER, NOT A FORMULA, and two ACID tests exist purely
// to prove it:
//
//   * gtia_pmretrigger — if HPOS matches AGAIN later on the same line the
//     register RELOADS and the object is drawn a second time.  Here that falls
//     out for free: the match is tested every colour clock whether or not the
//     object is already drawing.  A positional formula draws once per line and
//     cannot pass.
//   * gtia_pmresize — changing SIZE mid-draw changes the ADVANCE RATE only.
//     Pixels already emitted stand and the register carries on from where it
//     is.  Here that is free too, because SIZE is read live each step and
//     nothing re-derives a bit index.  A formula recomputes the index from dx
//     and re-indexes the whole shape, which is why 4x->1x gave $E0 where the
//     hardware gives $80.
//
// GEOMETRY, pinned by tb_pm_collide T7/T8:
//     x_left = (HPOS - 48) * 2      in hi-res pixels
// so HPOS counts COLOUR CLOCKS, one player bit is one colour clock at normal
// size, and a normal player is 8 colour clocks = 16 hi-res pixels wide.
// Missiles are two bits from GRAFM, most significant first.
//
// SIZE is colour clocks per bit minus one: 01 -> 2cc, 11 -> 4cc, 00 and 10 -> 1cc.
// Note that 10 is normal size, not a third setting.
//
// COLLISIONS ARE NOT HERE.  This produces presence only; accumulating collisions
// during the same walk is the collision module's business, and it needs an
// active-line gate this module has no opinion about.
//
// CLOCK BUDGET: 8 clocks per colour clock, out of ~28 available.  One 8:1 input
// mux, one comparator, one shifter, one small counter — the whole engine.
//
`timescale 1ns/1ps

module gtia_obj_walk (
    input  wire       clk,
    input  wire       rst,

    input  wire       line_start,     // 1-clk: nothing carries across lines
    input  wire       cc_tick,        // 1-clk per colour clock
    input  wire [7:0] cc_pos,         // colour clock position on the line

    // ---- live registers --------------------------------------------------
    input  wire [7:0] hposp0, hposp1, hposp2, hposp3,
    input  wire [7:0] hposm0, hposm1, hposm2, hposm3,
    input  wire [1:0] sizep0, sizep1, sizep2, sizep3,
    input  wire [7:0] sizem,          // 2 bits per missile
    input  wire [7:0] grafp0, grafp1, grafp2, grafp3,
    input  wire [7:0] grafm,          // m0=[1:0] m1=[3:2] m2=[5:4] m3=[7:6]

    // ---- presence for this colour clock ----------------------------------
    output logic [7:0] pres,          // [3:0] players 0-3, [7:4] missiles 0-3
    output logic       pres_valid     // 1-clk: pres is settled for this cc
);

    // ---- per-object state ------------------------------------------------
    // Only `live` needs clearing at line start; a match resets the rest, and
    // nothing is read while an object is not live.
    logic [7:0] sr   [0:7];
    logic [1:0] cnt  [0:7];
    logic [3:0] bits [0:7];
    logic [7:0] live;

    // ---- the walk --------------------------------------------------------
    logic [3:0] step;                 // 0..7 walking, 8 = idle
    logic [7:0] acc;

    wire [2:0] i          = step[2:0];
    wire       is_missile = i[2];
    wire [1:0] mi         = i[1:0];   // which missile

    // ---- the shared input mux -------------------------------------------
    logic [7:0] obj_hpos;
    always_comb begin
        case (i)
            3'd0: obj_hpos = hposp0;
            3'd1: obj_hpos = hposp1;
            3'd2: obj_hpos = hposp2;
            3'd3: obj_hpos = hposp3;
            3'd4: obj_hpos = hposm0;
            3'd5: obj_hpos = hposm1;
            3'd6: obj_hpos = hposm2;
            default: obj_hpos = hposm3;
        endcase
    end

    logic [1:0] obj_size;
    always_comb begin
        case (i)
            3'd0: obj_size = sizep0;
            3'd1: obj_size = sizep1;
            3'd2: obj_size = sizep2;
            3'd3: obj_size = sizep3;
            // Missile k takes SIZEM bits [2k+1:2k].
            default: obj_size = sizem[{mi, 1'b0} +: 2];
        endcase
    end

    // A missile's two bits sit at the top of the register, most significant
    // first, so the same shifter serves both kinds of object.
    logic [7:0] obj_graf;
    always_comb begin
        case (i)
            3'd0: obj_graf = grafp0;
            3'd1: obj_graf = grafp1;
            3'd2: obj_graf = grafp2;
            3'd3: obj_graf = grafp3;
            default: obj_graf = {grafm[{mi, 1'b0} +: 2], 6'b000000};
        endcase
    end

    // Colour clocks per bit, minus one.  10 is normal size, not a third rate.
    logic [1:0] size_max;
    always_comb begin
        case (obj_size)
            2'b01:   size_max = 2'd1;   // double
            2'b11:   size_max = 2'd3;   // quad
            default: size_max = 2'd0;   // normal
        endcase
    end

    wire [3:0] last_bit = is_missile ? 4'd1 : 4'd7;

    // ---- one object's step ------------------------------------------------
    wire       walking  = (step < 4'd8);
    wire       match    = walking && (cc_pos == obj_hpos);
    // >=, not ==.  SIZEP/SIZEM can change PART WAY THROUGH a bit: ACID
    // gtia_pmresize shrinks a player from quad to normal mid-draw and requires
    // the already-emitted pixels to stand while the ADVANCE RATE changes
    // immediately.  With an equality the counter has already passed the new
    // (smaller) size_max, so it never matches — the object stalls until the
    // 2-bit counter wraps all the way round, three colour clocks late, and the
    // shape comes out shifted a bit position ($40 where $80 is required).
    wire       advance  = walking && live[i] && !match && (cnt[i] >= size_max);
    wire       finished = advance && (bits[i] == last_bit);

    wire [7:0] sr_next   = match   ? obj_graf
                         : advance ? {sr[i][6:0], 1'b0}
                                   : sr[i];
    wire       live_next = match ? 1'b1 : (finished ? 1'b0 : live[i]);

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            step       <= 4'd8;
            live       <= 8'h00;
            acc        <= 8'h00;
            pres       <= 8'h00;
            pres_valid <= 1'b0;
            for (int k = 0; k < 8; k++) begin
                sr[k]   <= 8'h00;
                cnt[k]  <= 2'd0;
                bits[k] <= 4'd0;
            end
        end else begin
            pres_valid <= 1'b0;

            if (line_start) begin
                live <= 8'h00;
                step <= 4'd8;
                acc  <= 8'h00;
                pres <= 8'h00;
            end else if (cc_tick) begin
                step <= 4'd0;
                acc  <= 8'h00;
            end else if (walking) begin
                sr[i]   <= sr_next;
                live[i] <= live_next;
                cnt[i]  <= match   ? 2'd0
                         : advance ? 2'd0
                         : (live[i] ? cnt[i] + 2'd1 : cnt[i]);
                bits[i] <= match   ? 4'd0
                         : advance ? bits[i] + 4'd1
                                   : bits[i];

                // Presence is taken from the state AFTER this colour clock's
                // load or advance, so the first bit appears on the very clock
                // HPOS matches.
                acc[i] <= live_next && sr_next[7];

                if (step == 4'd7) begin
                    // acc[7] is only being written this clock, so splice this
                    // object's result in rather than reading it back.
                    pres       <= {(live_next && sr_next[7]), acc[6:0]};
                    pres_valid <= 1'b1;
                end
                step <= step + 4'd1;
            end
        end
    end

endmodule

`default_nettype wire
