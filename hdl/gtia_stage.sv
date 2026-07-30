`default_nettype none
//
// gtia_stage — one colour clock of GTIA.
//
// docs/ANTIC-rewrite.md step 6.  Takes the colour clock's pair of playfield
// sources, walks the objects, resolves priority and collisions for each half,
// and emits a pair of finished Atari colour bytes.
//
// WHY A PAIR.  Object presence changes once per colour clock — HPOS counts
// colour clocks and a normal player bit is one colour clock wide.  The playfield
// changes once per HI-RES PIXEL, because mode F has one pixel per hi-res pixel.
// So the object walk runs once and priority runs twice, and GTIA's natural unit
// is the pair, not the pixel.
//
// THE SCHEDULE, in fabric clocks out of the ~28 in a colour clock at 100 MHz:
//
//     9   object walk            once per colour clock
//     8   priority for pixel A   } collisions for A walk alongside: they
//     8   priority for pixel B   } consume the same presence and feed nothing
//    ---
//    26   of 28, measured -- tb_gtia_stage T1 counts the clocks from cc_tick to
//          out_valid over every case it exercises and fails above 28.  Two
//          clocks of margin; anything added here has to come out elsewhere.
//
// The collision walk is 8 clocks and neither feeds nor is fed by priority, so it
// overlaps for free.  It runs twice as well, because a hi-res colour clock can
// have one half lit and the other not, and they collide differently.
//
// ONE COLOUR CLOCK OF DELAY, AND IT IS UNIFORM.  The pair is not resolved until
// 26 clocks into the colour clock, by which time the beam has passed both of its
// pixels.  So the consumer writes the resolved pair during the FOLLOWING colour
// clock.  Everything — playfield, objects, border — goes through the same delay,
// so nothing shifts relative to anything else; the picture simply sits two
// hi-res pixels to the right, inside a border that is generated the same way.
//
// The alternative would be to resolve at some instant early enough to write in
// time, and that is exactly the mistake this rewrite exists to undo: the old
// compositor's compose instant had to be TUNED until it fell inside a test's
// read window, which is a coincidence rather than a model.
//
// A GTIA MODE COSTS ONE MORE PAIR OF COLOUR CLOCKS, and that is causal rather
// than a choice.  A GTIA pixel's nibble is only complete once BOTH of its colour
// clocks have delivered their two bits, so it cannot be displayed until the
// following aligned pair.  Real GR.9/10/11 displays sit shifted for the same
// reason.  The shift is uniform within a GTIA mode, so nothing moves relative to
// anything else while one is selected.
//
// THE GTIA COLOUR REPLACES THE PLAYFIELD, NOT THE PICTURE.  Priority still runs
// normally and a player that wins still shows its own colour; only a playfield
// or background win is recoloured, and only inside the playfield window — the
// border is not part of the playfield and stays COLBK.  In a GTIA mode the
// playfield is always present, which is why a background win is recoloured too:
// there are no gaps for the background to show through.
//
// MULTI-COLOUR PLAYERS are applied by ORing the two COLPM registers together
// before the colour select, not by adding a case to it: where P0 and P1 overlap
// both take COLPM0|COLPM1, so feeding the select the combined value gives the
// right answer whichever of the two won.
//
// CLOCK BUDGET: stated above — 26 of 28, with one shared colour select used
// serially for the two halves rather than two copies of it.
//
`timescale 1ns/1ps

module gtia_stage (
    input  wire       clk,
    input  wire       rst,

    input  wire       line_start,
    input  wire       cc_tick,          // 1-clk at the start of a colour clock
    input  wire [7:0] cc_pos,           // colour clock position on the line
    input  wire       active,           // an active display line
    input  wire       hitclr,           // 1-clk: $D01E write

    // ---- the playfield pair for this colour clock ------------------------
    input  wire [2:0] pf_src_a,         // first hi-res pixel
    input  wire [2:0] pf_src_b,         // second

    // ---- what a GTIA mode sees instead -----------------------------------
    input  wire [1:0] an_pair,          // this colour clock's two playfield bits
    input  wire       pf_win,           // ...and whether it is inside the window

    // ---- live registers --------------------------------------------------
    input  wire [7:0] hposp0, hposp1, hposp2, hposp3,
    input  wire [7:0] hposm0, hposm1, hposm2, hposm3,
    input  wire [1:0] sizep0, sizep1, sizep2, sizep3,
    input  wire [7:0] sizem,
    input  wire [7:0] grafp0, grafp1, grafp2, grafp3,
    input  wire [7:0] grafm,
    input  wire [7:0] prior,
    input  wire [7:0] colbk, colpf0, colpf1, colpf2, colpf3,
    input  wire [7:0] colpm0, colpm1, colpm2, colpm3,

    // ---- the resolved pair, one colour clock late ------------------------
    output logic       out_valid,       // 1-clk
    output logic [7:0] out_color_a,
    output logic [7:0] out_color_b,

    // ---- collision latches ------------------------------------------------
    output wire [15:0] m_pf,
    output wire [15:0] p_pf,
    output wire [15:0] m_pl,
    output wire [15:0] p_pl
);

    // ---- the object walk -------------------------------------------------
    wire [7:0] pres;
    wire       pres_valid;

    gtia_obj_walk u_obj (
        .clk(clk), .rst(rst),
        .line_start(line_start), .cc_tick(cc_tick), .cc_pos(cc_pos),
        .hposp0(hposp0), .hposp1(hposp1), .hposp2(hposp2), .hposp3(hposp3),
        .hposm0(hposm0), .hposm1(hposm1), .hposm2(hposm2), .hposm3(hposm3),
        .sizep0(sizep0), .sizep1(sizep1), .sizep2(sizep2), .sizep3(sizep3),
        .sizem(sizem),
        .grafp0(grafp0), .grafp1(grafp1), .grafp2(grafp2), .grafp3(grafp3),
        .grafm(grafm),
        .pres(pres), .pres_valid(pres_valid)
    );

    // ---- which half we are resolving -------------------------------------
    typedef enum logic [1:0] { S_IDLE, S_OBJ, S_A, S_B } state_t;
    state_t state;

    logic [2:0] pf_a_q, pf_b_q;
    wire  [2:0] cur_pf = (state == S_A) ? pf_a_q : pf_b_q;

    wire [3:0] win_src;
    wire       win_black, win_multi01, win_multi23, pri_valid;

    // Combinational, not registered: a registered strobe would cost a clock at
    // each of the two handshakes and the pair no longer fits in a colour clock.
    wire pri_start = (state == S_OBJ && pres_valid) || (state == S_A && pri_valid);
    wire col_start = pri_start;

    gtia_priority u_pri (
        .clk(clk), .rst(rst),
        .start(pri_start), .pres(pres), .pf_src(cur_pf), .prior(prior),
        .win_src(win_src), .win_black(win_black),
        .win_multi01(win_multi01), .win_multi23(win_multi23),
        .valid(pri_valid)
    );

    // ---- the collision window --------------------------------------------
    // GTIA does not compare in HORIZONTAL blank either, and the per-line
    // `active` gate does not cover it: without this, objects parked off-screen
    // in the border still latch collisions, and every ACID test that asserts
    // "no collision" fails on a hit that never appeared on screen —
    // gtia_collision says so in as many words ("P/P collisions were detected in
    // HBLANK on left"), and antic_addresswrap fails the same way while looking
    // like a display-list bug, because its whole pass condition is P0PF == $00.
    //
    // The bound is an EDGE, not an approximation: with GRAFP=$80 an object at
    // HPOS $22 sits exactly ON it and MUST register, while the same object at
    // $21 falls just outside and must NOT. ACID pins both halves.
    //
    // Carried across from the legacy path, which passes this test, but restated
    // in this design's coordinates rather than lifted: there the window was
    // x in [-28, 346] with x = 2*cc - 96, so cc = (x + 96)/2 gives [34, 221] --
    // and 34 is $22, which is the check the comment above describes.
    // `cc_pos` is the same coordinate HPOS is compared against in the object
    // walk, so an object is inside the window exactly when its own HPOS is.
    localparam logic [7:0] CC_LO = 8'd34;    // HPOS $22
    localparam logic [7:0] CC_HI = 8'd221;
    wire cc_in_window = (cc_pos >= CC_LO) && (cc_pos <= CC_HI);

    gtia_collide u_col (
        .clk(clk), .rst(rst),
        .start(col_start), .pres(pres), .pf_src(cur_pf),
        .active(active && cc_in_window), .hitclr(hitclr),
        .m_pf(m_pf), .p_pf(p_pf), .m_pl(m_pl), .p_pl(p_pl), .busy()
    );

    // ---- the GTIA-mode nibble --------------------------------------------
    // Two bits per colour clock, two colour clocks to a nibble.  It takes two
    // registers, not one: the pair COMPLETES on an odd colour clock, but it must
    // go on display for a whole aligned pair, so it waits in nib_ready and is
    // handed over on the next even clock.  With a single register the second
    // half of every GTIA pixel showed the following pixel instead.
    logic [1:0] an_prev;
    logic [3:0] nib_ready, gtia_nib;
    logic       win_ready, gtia_win;

    always_ff @(posedge clk or posedge rst) begin
        if (rst || line_start) begin
            an_prev   <= 2'd0;
            nib_ready <= 4'd0;
            gtia_nib  <= 4'd0;
            win_ready <= 1'b0;
            gtia_win  <= 1'b0;
        end else if (cc_tick) begin
            an_prev <= an_pair;
            if (cc_pos[0]) begin
                // The pair is complete; hold it until the next pair begins.
                nib_ready <= {an_prev, an_pair};
                win_ready <= pf_win;
            end else begin
                gtia_nib <= nib_ready;
                gtia_win <= win_ready;
            end
        end
    end

    wire       gtia_active;
    wire [7:0] gtia_color;

    gtia_special u_special (
        .gtia_mode(prior[7:6]), .nibble(gtia_nib), .colbk(colbk),
        .colpf0(colpf0), .colpf1(colpf1), .colpf2(colpf2), .colpf3(colpf3),
        .colpm0(colpm0), .colpm1(colpm1), .colpm2(colpm2), .colpm3(colpm3),
        .active(gtia_active), .color(gtia_color)
    );

    // ---- colour ----------------------------------------------------------
    // Multi-colour players OR the pair's registers together before the select,
    // so whichever of the two won produces the same combined colour.
    wire [7:0] pm01 = colpm0 | colpm1;
    wire [7:0] pm23 = colpm2 | colpm3;

    wire [7:0] pm0_eff = win_multi01 ? pm01 : colpm0;
    wire [7:0] pm1_eff = win_multi01 ? pm01 : colpm1;
    wire [7:0] pm2_eff = win_multi23 ? pm23 : colpm2;
    wire [7:0] pm3_eff = win_multi23 ? pm23 : colpm3;

    wire [7:0] sel_color;

    // One select, used serially for the two halves: its input is whichever
    // winner has just landed.
    antic_color_sel u_sel (
        .src(win_src),
        .colbk(colbk), .colpf0(colpf0), .colpf1(colpf1),
        .colpf2(colpf2), .colpf3(colpf3),
        .colpm0(pm0_eff), .colpm1(pm1_eff), .colpm2(pm2_eff), .colpm3(pm3_eff),
        .color(sel_color)
    );

    // Players win as normal and keep their own colour; a playfield or
    // background win inside the window is recoloured by the GTIA mode.
    wire win_is_object = (win_src >= 4'd6);

    wire [7:0] resolved =
        win_black                                        ? 8'h00       :
        (gtia_active && gtia_win && !win_is_object)      ? gtia_color  :
                                                           sel_color;

    // ---- the sequence ----------------------------------------------------
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state       <= S_IDLE;
            pf_a_q      <= 3'd0;
            pf_b_q      <= 3'd0;
            out_valid   <= 1'b0;
            out_color_a <= 8'h00;
            out_color_b <= 8'h00;
        end else begin
            out_valid <= 1'b0;

            if (cc_tick) begin
                // Latch the pair now: the playfield registers may be written
                // partway through the walk, and this colour clock's pixels were
                // decided when the beam was over them.
                pf_a_q <= pf_src_a;
                pf_b_q <= pf_src_b;
                state  <= S_OBJ;
            end else begin
                case (state)
                    S_OBJ: if (pres_valid) state <= S_A;

                    S_A: if (pri_valid) begin
                        out_color_a <= resolved;
                        state       <= S_B;
                    end

                    S_B: if (pri_valid) begin
                        out_color_b <= resolved;
                        out_valid   <= 1'b1;
                        state       <= S_IDLE;
                    end

                    default: ;
                endcase
            end
        end
    end

endmodule

`default_nettype wire
