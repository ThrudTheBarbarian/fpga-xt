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
//     object is drawn a second time.  Here that falls out for free: the match is
//     tested every colour clock whether or not the object is already drawing.  A
//     positional formula draws once per line and cannot pass.
//
// A PLAYER CARRIES CONCURRENT RUNS; A MISSILE CARRIES EXACTLY ONE.  That
// asymmetry is emu's, and it is in the data structure rather than in any
// constant: gtia.h declares p_bit[4][GTIA_RUNS] against a scalar m_bit[4], and
// obj_step APPENDS on a player match where the missile path reloads.  A second
// HPOS match while the player is still emitting therefore starts a second run
// beside the first instead of replacing it, and gtia_pmoverlap fails without it
// — grafp0 = $81 lights two regions from one run where the hardware lights
// three.
//
// HOW MANY RUNS: EIGHT, as emu's GTIA_RUNS.  This module carried TWO, on the
// strength of instrumenting emu over pmoverlap/pmresize/pmretrigger and finding
// the peak was two (n2 = 4580 occurrences, n3 never).  That measurement was
// sound and its conclusion was still wrong, because every one of those tests
// runs at NORMAL width, where a run is 8 colour clocks and a third overlap needs
// two rewrites inside 8cc.  At QUAD width a run is 32 colour clocks, and
// BallBlazer draws its goalposts by MULTIPLEXING one player across the line, so
// three and more overlap routinely.  The surplus match was dropped, the bar
// never re-anchored, and it kept drawing at the previous x — a step partway down
// a goalpost that should have been straight.  tb_gtia_stage's TR pins it, and
// pins the COUNT: it drives eight overlapping runs and fails naming the slot it
// ran out at, so dropping NSLOT below 8 is a visible regression rather than a
// silent one.
//
// A MATCH DOES THREE THINGS, NOT ONE (gtia.c, the hpos == hposp[i] block):
//   1. RE-ANCHOR every run still emitting — phase restarts here and the bit
//      counter advances with it, because the boundary it was heading for is
//      superseded by this one.  A run that already rolled on this very clock is
//      left alone.  Since a run either rolled (phase now 0) or did not (phase
//      now non-zero), the two paths collapse: on a match clock EVERY live run
//      advances by exactly one bit and resets its phase.
//   2. RETIRE the runs that have shifted out.
//   3. APPEND the new run beside the survivors.
// Dropping (1) is the subtle one: it is worth 19 collision cells in emu's own
// notes, and it does not fall out of an append-only reading.
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
// mux, one comparator, and per run a shifter and a small counter — the whole
// engine.  ALL of a player's runs ride in the SAME step rather than taking one
// each, and that is what makes the slot count nearly free: the mux, the
// comparator and the size decode are shared, so a slot costs only its own
// shifter and 2-bit counter and NO extra clock.  Adding steps instead is the
// trap — tb_gtia_stage measures the budget and a 12-step walk already overruns
// it (30 of 28), so the count could never have been raised that way.
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
    // 1 colour clock per player: a SIZEP write reaches the object on this clock.
    // A WRITE, not a change -- rewriting the same size still resizes.
    input  wire [3:0] resize,
    input  wire [7:0] sizem,          // 2 bits per missile
    input  wire [7:0] grafp0, grafp1, grafp2, grafp3,
    input  wire [7:0] grafm,          // m0=[1:0] m1=[3:2] m2=[5:4] m3=[7:6]

    // ---- presence for this colour clock ----------------------------------
    output logic [7:0] pres,          // [3:0] players 0-3, [7:4] missiles 0-3
    output logic       pres_valid     // 1-clk: pres is settled for this cc
);

    // ---- per-RUN state ----------------------------------------------------
    // Slots, not objects.  Only `live` needs clearing at line start; an append
    // resets the rest, and nothing is read while a run is not live.
    //
    // NSLOT runs per PLAYER, one per missile.  Two was not a model of the
    // hardware, it was a bet that three would never overlap -- and the comment
    // that justified it says so: "instrumenting it over the P/M tests never sees
    // a third".  Those tests are NORMAL width, where a run is 8 colour clocks.
    // At QUAD width a run is 32, and BallBlazer draws its goalposts by
    // MULTIPLEXING one player across the line -- HPOSP rewritten every few
    // colour clocks -- so three and more overlap routinely.  The third match was
    // silently dropped, the bar never re-anchored, and it kept drawing at the
    // previous x: the offset segment at the tail of a scrolling goalpost.
    // emu carries eight (GTIA_RUNS, emu/gtia.h) and is the reference here.
    //
    // Slots are added IN PARALLEL WITHIN A STEP, never as extra steps: the
    // object's hpos comparator, size decode and graphics byte are shared, so a
    // slot costs only its shifter and its 2-bit counter.  Extra steps would cost
    // a fabric clock each and the stage has two to spare out of 28.
    localparam int NSLOT      = 8;                 // runs per player
    localparam int NSLOTS_TOT = 4 * NSLOT + 4;     // players, then one per missile

    logic [7:0]  sr   [0:NSLOTS_TOT-1];
    logic [1:0]  cnt  [0:NSLOTS_TOT-1];
    logic [3:0]  bits [0:NSLOTS_TOT-1];
    logic [NSLOTS_TOT-1:0] live;
    logic [NSLOTS_TOT-1:0] locked;    // 1xalt lockup; see the resize clock below

    // ---- the walk --------------------------------------------------------
    logic [3:0] step;                 // 0..11 walking, 12 = idle
    logic [7:0] acc;

    wire [2:0] i          = step[2:0];        // object
    wire       is_missile = i[2];
    wire [1:0] mi         = i[1:0];   // which missile

    // ALL of a player's runs are stepped in the SAME clock.  They share an
    // object, so they share the hpos comparator, the size decode and the
    // graphics byte; only the shifter and its little counter are per run.
    // Walking them as a step each costs a clock each and tb_gtia_stage rejects it
    // outright — even 12 steps needs 30 of the 28 clocks a colour clock has.  The
    // arbitration falls out for free here: every run is resolved combinationally
    // beside the others, so no note has to be carried between steps.
    //
    // Player i owns slots i*NSLOT .. i*NSLOT+NSLOT-1; missile mi owns the single
    // slot 4*NSLOT+mi.  A missile therefore only ever uses run 0.
    function automatic int slot_of(input logic [2:0] obj, input int r);
        slot_of = obj[2] ? (4 * NSLOT + int'(obj[1:0]))
                         : (int'(obj) * NSLOT + r);
    endfunction

    // A run index is live logic for this object only if the object owns it:
    // players own all NSLOT, a missile owns run 0 alone.

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

    // ---- one run's step ---------------------------------------------------
    wire       walking  = (step < 4'd8);
    wire       match    = walking && (cc_pos == obj_hpos);

    // A live run moves on a bit boundary — and, for a player, on ANY match,
    // which re-anchors it (see the header).  A missile does not move on its
    // match clock because the match reloads it outright.
    //
    // >=, not ==.  SIZEP/SIZEM can change PART WAY THROUGH a bit: ACID
    // gtia_pmresize shrinks a player from quad to normal mid-draw and requires
    // the already-emitted pixels to stand while the ADVANCE RATE changes
    // immediately.  With an equality the counter has already passed the new
    // (smaller) size_max, so it never matches — the object stalls until the
    // 2-bit counter wraps all the way round, three colour clocks late, and the
    // shape comes out shifted a bit position ($40 where $80 is required).
    // ---- the resize clock -------------------------------------------------
    // On the clock a SIZEP write lands the roll rule is NOT "has the phase
    // reached the new width".  It is "are the low log2(w) bits about to CARRY",
    // (ph & (w-1)) == (w-1), which differs only at phase 2 of width 2 -- and
    // those four cells are exactly what gtia_pmresize's 4x-to-2x row was
    // missing.  Neither this nor the lock below was guessed: emu's
    // tools/pmresize-check.py searched the roll decision as twelve free
    // booleans, one per (phase, new width), and a UNIQUE setting scores 80/80
    // over the five non-alt transitions.  Width 4 phases 2 and 3 never arise --
    // a run widening to 4x comes from 1x or 2x, so its phase is 0 or 1 -- so
    // that corner is consistent with every cell the test constrains and is an
    // inference beyond them, flagged as one.
    //
    // SIZEP 2 is "1xalt": it divides by one exactly as SIZEP 0 does, yet the
    // test expects a DIFFERENT answer, and the difference is a LOCKUP.  The run
    // advances only while the phase counter's two bits AGREE; the moment they
    // disagree it stops dead and never advances again, emitting its current bit
    // for the rest of the line.  That is the $FE -- every probe lit -- standing
    // at four of the sixteen positions in each alt row.  Searched the same way:
    // four booleans for "does phase p lock" against four for "does phase p
    // roll", unique setting, 32/32.
    //
    // A locked run therefore never reaches bit 8 and never retires; only the
    // line-start clear takes it down.  Miss that and it emits for ever.
    wire       obj_resize = walking && !is_missile && resize[mi];
    wire       obj_alt    = (obj_size == 2'b10);

    // size_max is w-1, so "the low bits are all ones for the new width" is
    // simply (cnt & size_max) == size_max.
    // Per-run, for the object being stepped.  Everything below is indexed by the
    // RUN number r; slot_of(i, r) turns that into the state array index.
    logic [NSLOT-1:0] rz_roll, rz_lock, rmoved, rfin, rfree, rhit, rlive_next;
    logic [7:0]       rsr_next [0:NSLOT-1];
    logic             obj_lit_c;

    // Loop scratch.  iverilog does not accept `automatic` locals inside a
    // procedural block, so these are declared once: c* for the combinational
    // walk, q* for the clocked update.
    integer cs, qs;                   // slot index of the run being considered
    reg     cowned, cearlier, qowned;

    always_comb begin
        rz_roll    = '0; rz_lock = '0; rmoved = '0; rfin = '0;
        rfree      = '0; rhit    = '0; rlive_next = '0;
        obj_lit_c  = 1'b0;
        cs = 0; cowned = 1'b0; cearlier = 1'b0;
        for (int r = 0; r < NSLOT; r++) rsr_next[r] = 8'h00;

        for (int r = 0; r < NSLOT; r++) begin
            cs     = slot_of(i, r);
            cowned = (r == 0) || !is_missile;
            if (cowned) begin
                rz_roll[r] = ((cnt[cs] & size_max) == size_max);
                rz_lock[r] = obj_alt && (cnt[cs][1] != cnt[cs][0]);

                // A missile does not move on its match clock: the match reloads
                // it outright.
                rmoved[r]  = walking && live[cs] && !locked[cs] &&
                             (match      ? !is_missile
                            : obj_resize ? (!rz_lock[r] && rz_roll[r])
                                         : (cnt[cs] >= size_max));

                rfin[r]    = rmoved[r] && (bits[cs] == last_bit);
                rfree[r]   = !live[cs] || rfin[r];
            end
        end

        // A player appends into the FIRST free slot; a missile reloads run 0
        // unconditionally.  Only when every slot is still emitting is the match
        // dropped -- with NSLOT of them that is now genuinely unreachable rather
        // than merely unobserved.
        for (int r = 0; r < NSLOT; r++) begin
            cowned   = (r == 0) || !is_missile;
            cearlier = 1'b0;
            for (int q = 0; q < NSLOT; q++)
                if (q < r) cearlier = cearlier | rfree[q];
            if (cowned)
                rhit[r] = match && (is_missile || (rfree[r] && !cearlier));
        end

        for (int r = 0; r < NSLOT; r++) begin
            cs     = slot_of(i, r);
            cowned = (r == 0) || !is_missile;
            if (cowned) begin
                rsr_next[r]   = rhit[r]   ? obj_graf
                              : rmoved[r] ? {sr[cs][6:0], 1'b0}
                                          : sr[cs];
                rlive_next[r] = rhit[r] ? 1'b1 : (rfin[r] ? 1'b0 : live[cs]);
                obj_lit_c     = obj_lit_c | (rlive_next[r] && rsr_next[r][7]);
            end
        end
    end
    // An object is lit if ANY of its runs is; obj_lit_c is that OR-reduction,
    // built in the always_comb above.
    wire       obj_lit = obj_lit_c;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            step       <= 4'd8;
            live       <= '0;
            locked     <= '0;
            acc        <= 8'h00;
            pres       <= 8'h00;
            pres_valid <= 1'b0;
            for (int k = 0; k < NSLOTS_TOT; k++) begin
                sr[k]   <= 8'h00;
                cnt[k]  <= 2'd0;
                bits[k] <= 4'd0;
            end
        end else begin
            pres_valid <= 1'b0;

            if (line_start) begin
                live   <= '0;
                locked <= '0;
                step <= 4'd8;
                acc  <= 8'h00;
                pres <= 8'h00;
            end else if (cc_tick) begin
                step <= 4'd0;
                acc  <= 8'h00;
            end else if (walking) begin
                // Every run this object owns, in the same clock.  A missile owns
                // run 0 alone, so the loop must not write a player's slots with a
                // missile's size and graphics -- hence the `owned` guard rather
                // than a bare loop over NSLOT.
                for (int r = 0; r < NSLOT; r++) begin
                    qs     = slot_of(i, r);
                    qowned = (r == 0) || !is_missile;
                    if (qowned) begin
                        sr[qs]   <= rsr_next[r];
                        live[qs] <= rlive_next[r];
                        // A new run starts unlocked; otherwise the lock latches
                        // on the resize clock and never clears until line start.
                        if (rhit[r])         locked[qs] <= 1'b0;
                        else if (obj_resize) locked[qs] <= locked[qs] | rz_lock[r];
                        cnt[qs]  <= (rhit[r] || rmoved[r]) ? 2'd0
                                  : (live[qs] ? cnt[qs] + 2'd1 : cnt[qs]);
                        bits[qs] <= rhit[r]   ? 4'd0
                                  : rmoved[r] ? bits[qs] + 4'd1
                                              : bits[qs];
                    end
                end

                // Presence is taken from the state AFTER this colour clock's
                // load or advance, so the first bit appears on the very clock
                // HPOS matches.
                acc[i] <= obj_lit;

                if (step == 4'd7) begin
                    // acc[7] is only being written this clock, so splice this
                    // object's result in rather than reading it back.
                    pres       <= {obj_lit, acc[6:0]};
                    pres_valid <= 1'b1;
                end
                step <= step + 4'd1;
            end
        end
    end

endmodule

`default_nettype wire
