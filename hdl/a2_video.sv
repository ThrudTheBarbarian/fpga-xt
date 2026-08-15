`default_nettype none
//
// a2_video — the gap between what ANTIC produces and what the framebuffer needs.
//
// THIS IS NOT A GTIA.  There is no real GTIA analogue in this design and none is
// wanted.  What there is, is a stream of playfield SOURCES coming out of antic2
// and a line buffer that wants one colour per hi-res pixel, and something has to
// stand between them.  That something also happens to be where the $D0xx
// registers live, where players and missiles are drawn, and where collisions are
// latched, because all four are the same question asked once per colour clock:
// given the playfield here and the objects here, what colour is this, and what
// touched what.
//
// WHY IT IS A SEPARATE MODULE AND NOT PART OF antic2.  ANTIC does not know what
// colour anything is.  It sends two bits per colour clock and a playfield
// number; the colour registers are $D016-$D01A, on the other chip.  Keeping the
// lookup here means antic2 has no colour ports to tie off and no second copy of
// COLBK to disagree with this one.
//
// THE PAIRING, which is the one genuinely awkward thing here.  antic2 emits ONE
// hi-res pixel per emit_en.  A colour clock is TWO of them.  So the two pixels
// are captured on the even and odd hi-res pixel of each colour clock and handed
// over together on the next colour clock's tick -- the non-blocking assignment
// IS the pipeline stage, and gtia_stage samples the pair that is one colour
// clock old.  cc_pos is therefore the PREVIOUS colour clock's position, because
// the objects have to be evaluated where that pair actually was.
//
// OUTSIDE THE WINDOW THERE IS NO PLAYFIELD, ONLY BACKGROUND.  The border is not
// a special case with its own path: it is source 0 fed through the same stage as
// everything else, so a player over the border collides with nothing and is
// coloured by the same priority logic.  That is why px_in_window is a LEVEL from
// antic2 and not merely the emit pulse -- the pulse says the renderer emitted,
// the level says the beam is on the playfield, and the border needs the second.
//
// EVERY PIXEL OF THE LINE IS WRITTEN.  lb_wr is px_tick, unconditionally: the
// framebuffer wants a full scanline, borders included. The line-start rewind is
// delayed by the pipeline depth so the pixels still in flight when the beam
// crosses the line boundary land at the end of the line they belong to, not at
// the start of the next one.
//
// The capture, the pairing, the stage wiring and the delayed rewind are the same
// hardware the legacy raster uses (antic_scanline), for the same reason: it is
// measured good against the ACID collision tests. What is different is where the
// pixels come from.
//
`timescale 1ns/1ps

module a2_video (
    input  wire        clk,
    input  wire        rst,
    input  wire        px_tick,          // 1-clk per hi-res pixel

    // ---- CPU bus: $D0xx ---------------------------------------------------
    input  wire        cs,
    input  wire        we,
    input  wire [7:0]  addr,             // low byte of $D0xx
    input  wire [7:0]  wdata,
    output wire [7:0]  rdata,

    // ---- the pixel stream from antic2 -------------------------------------
    input  wire        px_wr,            // the renderer emitted this pixel
    input  wire [2:0]  px_pf_src,        // which playfield it is
    input  wire [1:0]  px_val,           // ...or the raw pair a GTIA mode reads
    input  wire        px_hires,
    input  wire        px_in_window,     // LEVEL: the beam is on the playfield
    input  wire [6:0]  px_hcount,        // ANTIC's machine cycle
    input  wire [3:0]  px_mode,          // ...and the mode it is running
    input  wire [8:0]  px_pos,           // hi-res pixel index along the line
    input  wire        px_line_start,    // 1-clk at the top of the scanline
    input  wire        px_active,        // an active display line
    // GTIA's vertical blank, inverted: antic2 folds "ANTIC is still emitting"
    // into it, so it stays HIGH past the display bottom on a list that never
    // stops.  antic_hiresbug measures that line.  Collisions only.
    input  wire        px_collide,

    // ---- P/M DMA store, for when antic2 fetches them ----------------------
    input  wire        pm_we,
    input  wire [2:0]  pm_obj,
    input  wire [7:0]  pm_data,
    input  wire        pm_fetch,

    // ---- console and controllers ------------------------------------------
    input  wire [7:0]  trig0, trig1, trig2, trig3,
    input  wire [7:0]  pal_sense,
    input  wire [7:0]  consol_keys,

    // ---- the scanline out --------------------------------------------------
    output wire        lb_wr,
    output wire [7:0]  lb_color,
    output wire        lb_line_start
);

    // ---- the registers -----------------------------------------------------
    wire [7:0] hposp0, hposp1, hposp2, hposp3;
    wire [7:0] hposm0, hposm1, hposm2, hposm3;
    wire [1:0] sizep0, sizep1, sizep2, sizep3;
    wire [3:0] sizep_we;
    wire [7:0] sizem;
    wire [7:0] grafp0, grafp1, grafp2, grafp3;
    wire [7:0] grafm;
    wire [7:0] colpm0, colpm1, colpm2, colpm3;
    wire [7:0] colpf0, colpf1, colpf2, colpf3;
    wire [7:0] colbk, prior, vdelay, gractl;
    wire       hitclr;
    wire [15:0] m_pf, p_pf, m_pl, p_pl;

    gtia_reg_file u_regs (
        .clk(clk), .rst(rst),
        .addr(addr), .we(cs && we), .wdata(wdata), .rdata(rdata),
        .pm_we(pm_we), .pm_obj(pm_obj), .pm_data(pm_data), .pm_fetch(pm_fetch),
        .m_pf(m_pf), .p_pf(p_pf), .m_pl(m_pl), .p_pl(p_pl),
        .trig0(trig0), .trig1(trig1), .trig2(trig2), .trig3(trig3),
        .pal_sense(pal_sense), .consol_keys(consol_keys),
        .hposp0(hposp0), .hposp1(hposp1), .hposp2(hposp2), .hposp3(hposp3),
        .hposm0(hposm0), .hposm1(hposm1), .hposm2(hposm2), .hposm3(hposm3),
        .sizep0(sizep0), .sizep1(sizep1), .sizep2(sizep2), .sizep3(sizep3),
        .sizep_we(sizep_we),
        .sizem(sizem),
        .grafp0(grafp0), .grafp1(grafp1), .grafp2(grafp2), .grafp3(grafp3),
        .grafm(grafm),
        .colpm0(colpm0), .colpm1(colpm1), .colpm2(colpm2), .colpm3(colpm3),
        .colpf0(colpf0), .colpf1(colpf1), .colpf2(colpf2), .colpf3(colpf3),
        .colbk(colbk), .prior(prior), .vdelay(vdelay), .gractl(gractl),
        .hitclr(hitclr)
    );

    // ---- the playfield pair ------------------------------------------------
    localparam logic [2:0] SRC_BK = 3'd0;

    wire [2:0] this_px_src = px_wr ? px_pf_src : SRC_BK;

    // px_pos counts hi-res pixels from the top of the line, so bit 0 says which
    // half of the colour clock this is and bits [8:1] say which colour clock.
    wire px_odd = px_pos[0];

    logic [2:0] pf_cap_a, pf_cap_b;
    logic [1:0] pv_cap_a, pv_cap_b;
    logic       win_cap;
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            pf_cap_a <= SRC_BK;
            pf_cap_b <= SRC_BK;
            pv_cap_a <= 2'd0;
            pv_cap_b <= 2'd0;
            win_cap  <= 1'b0;
        end else if (px_tick) begin
            if (!px_odd) begin
                pf_cap_a <= this_px_src;
                pv_cap_a <= px_wr ? px_val : 2'd0;
                win_cap  <= px_in_window;
            end else begin
                pf_cap_b <= this_px_src;
                pv_cap_b <= px_wr ? px_val : 2'd0;
            end
        end
    end

    // ANTIC sends GTIA two playfield bits per colour clock whatever mode it is
    // in.  A hi-res colour clock carries two one-bit pixels; every other mode
    // carries one pixel whose value is already two bits wide.  That single fact
    // is the whole of "pseudo mode E" -- see gtia_special.
    wire [1:0] an_pair = px_hires ? {pv_cap_a[0], pv_cap_b[0]} : pv_cap_a;

    // ---- pseudo mode E -----------------------------------------------------
    //
    // GTIA decides ONCE PER SCANLINE whether ANTIC mode F is hi-res, and a GTIA
    // mode still selected at that instant disables hi-res for the WHOLE line.
    // Leave the GTIA mode afterwards and the playfield keeps arriving with
    // hi-res off -- and then the two bits of a mode F colour clock are read as a
    // playfield INDEX rather than reduced to "lit or not".  Not mode E's
    // mapping either: a DIRECT index, so `00` is PF0 and not background.  That
    // is what the test is named for -- it looks like mode E and its colours are
    // not mode E's.
    //
    // emu states the latch as two lines (system.c:202-203):
    //     if (cyc == 0)  hires_ok = 1;
    //     if (cyc == 15) hires_ok = !((prior >> 6) & 3);
    // and its comment records that 15 is MEASURED and bracketed from both
    // sides: at 14 and below gtia_psuedomodee's first case also goes pseudo, at
    // 16 and above its second case does not go pseudo at all.  Exactly one
    // value separates them, which is why the decision has to be made against
    // ANTIC's own machine cycle rather than anything derived from px_pos.
    logic [6:0] hc_q;
    logic       hires_ok;
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            hc_q     <= 7'd0;
            hires_ok <= 1'b1;
        end else begin
            hc_q <= px_hcount;
            if (px_hcount != hc_q) begin
                if      (px_hcount == 7'd0)  hires_ok <= 1'b1;
                else if (px_hcount == 7'd16) hires_ok <= (prior[7:6] == 2'b00);
            end
        end
    end

    // The pair IS the class, and only inside the playfield window -- emu's
    // antic_pf_pair returns -1 outside it, and painting the border as PF0 would
    // collide everywhere.  Replacing the source also drops the hi-res encoding
    // (5/6), which is what stops gtia_collide applying "lit collides as PF2"
    // and throwing the class away.
    wire       pseudo_e   = !hires_ok && (px_mode == 4'hF) && win_cap;
    wire [2:0] pseudo_src = 3'd1 + {1'b0, an_pair};
    wire [2:0] pf_src_a_eff = pseudo_e ? pseudo_src : pf_cap_a;
    wire [2:0] pf_src_b_eff = pseudo_e ? pseudo_src : pf_cap_b;

    // A colour clock starts on the even hi-res pixel.  At that same edge
    // gtia_stage samples pf_cap_a/b, which still hold the PREVIOUS colour
    // clock's pair -- non-blocking assignment is doing the pipelining here.
    wire cc_tick = px_tick && !px_odd;

    // The DISPLAY nibble needs its pair a colour clock sooner than cc_tick
    // gives it (cc_tick fires at the START of a clock and the captures still
    // hold the PREVIOUS one).  Sampled at the END of the clock, this pair is
    // for cc_pos + 1.  Collisions keep the original, later pair.
    wire       cc_tick_e = px_tick && px_odd;
    wire [1:0] an_pair_e = px_hires ? {pv_cap_a[0], (px_wr ? px_val[0] : 1'b0)}
                                    : (px_wr ? px_val : 2'd0);

    // ...and the objects must be evaluated where that pair was, one colour
    // clock back.  px_pos[8:1] is constant across a colour clock, so subtracting
    // one gives the previous one throughout.
    wire [7:0] cc_pos = px_pos[8:1] - 8'd1;

    // ANTIC'S CYCLE 0 IS NOT COLOUR CLOCK 0.  GTIA's counter LEADS the machine
    // cycle by six colour clocks -- emu states it as a constant, GTIA_CC_ORIGIN
    // = 6, and computes every colour clock as `cc = cyc*2 + h + 6`
    // (system.c:216).  Its comment names the test that forces the value:
    // gtia_pmretrigger commits an HPOS write on scanline cycle 29 and requires
    // the player to have ALREADY been drawn at $40, so cc(29) must be just past
    // $40 = 64 = 2*29 + 6; with no offset the write lands at 58 and the first
    // draw never happens.
    //
    // antic2 has no such origin: measured, cc_pos = 2*hcount + {-1,0}, i.e. the
    // beam sits SIX COLOUR CLOCKS BEHIND emu's at the same machine cycle.
    //
    // THE FIX IS NOT TO SHIFT cc_pos.  Everything positional here is derived
    // from the emit window -- the playfield source arrives with the pixel
    // stream and the objects compare against cc_pos, both anchored to the same
    // origin -- so moving cc_pos alone would slide the objects ACROSS the
    // playfield and break the four playfield-timing tests that pass by
    // measuring exactly that relative alignment.
    //
    // What is actually wrong is WHEN A CPU WRITE BECOMES VISIBLE TO THE BEAM,
    // and a delay fixes that without touching any steady-state position: a
    // position written during vertical blank is already settled long before the
    // beam arrives, so delaying it changes nothing, while a MID-LINE write --
    // the only thing these tests measure -- lands six colour clocks later, which
    // is precisely emu's origin.  gtia_pmoverlap and gtia_pmretrigger are both
    // built on that deadline.
    localparam int HPOS_CC_DELAY = 6;

    logic [7:0] hp_pipe [0:7][1:HPOS_CC_DELAY];
    always_ff @(posedge clk) begin
        if (cc_tick) begin
            for (int o = 0; o < 8; o++) begin
                for (int d = HPOS_CC_DELAY; d > 1; d--)
                    hp_pipe[o][d] <= hp_pipe[o][d-1];
            end
            hp_pipe[0][1] <= hposp0;  hp_pipe[1][1] <= hposp1;
            hp_pipe[2][1] <= hposp2;  hp_pipe[3][1] <= hposp3;
            hp_pipe[4][1] <= hposm0;  hp_pipe[5][1] <= hposm1;
            hp_pipe[6][1] <= hposm2;  hp_pipe[7][1] <= hposm3;
        end
    end

    wire [7:0] dl_hposp0 = hp_pipe[0][HPOS_CC_DELAY];
    wire [7:0] dl_hposp1 = hp_pipe[1][HPOS_CC_DELAY];
    wire [7:0] dl_hposp2 = hp_pipe[2][HPOS_CC_DELAY];
    wire [7:0] dl_hposp3 = hp_pipe[3][HPOS_CC_DELAY];
    wire [7:0] dl_hposm0 = hp_pipe[4][HPOS_CC_DELAY];
    wire [7:0] dl_hposm1 = hp_pipe[5][HPOS_CC_DELAY];
    wire [7:0] dl_hposm2 = hp_pipe[6][HPOS_CC_DELAY];
    wire [7:0] dl_hposm3 = hp_pipe[7][HPOS_CC_DELAY];

    // SIZE RIDES THE SAME DEADLINE AS POSITION.  The origin offset above is a
    // property of the clock the objects are walked on, not of HPOS in
    // particular, so every register the walk reads mid-line owes it the same six
    // colour clocks -- and SIZEP/SIZEM were arriving undelayed, six clocks ahead
    // of the positions they scale.  A write during vertical blank is unaffected
    // either way; only the mid-line writes gtia_pmresize is built out of move.
    // SIZEP TAKES THE SAME SIX, NOT SEVEN.  emu holds a SIZEP write pending for
    // SIZEP_DELAY=1 colour clock before it reaches the object, but that figure
    // is relative to emu's own write timing and does NOT stack on top of the
    // origin offset here -- antic2's register path already carries a clock emu
    // does not.  Swept rather than composed, because adding two constants that
    // are measured against different origins is how you get a plausible wrong
    // answer: over 6..9, gtia_pmresize's 4x-to-1x block fails at index 3 with 6
    // and at index 0 with 7, 8 and 9 alike, while gtia_pmoverlap and
    // gtia_pmretrigger are insensitive across the whole range and constrain
    // nothing.  8 and 9 give $E0 where $80 is wanted, which is exactly the
    // symptom emu's own notes attribute to re-deriving the bit index.
`ifndef SIZEP_CC_DELAY
  `define SIZEP_CC_DELAY HPOS_CC_DELAY
`endif
    localparam int SIZEP_CC_DELAY = `SIZEP_CC_DELAY;

    // The WRITE EVENT rides the same pipe as the value.  The walk needs to know
    // which colour clock a SIZEP write lands on, not merely that the size now
    // differs, so a per-player strobe is delayed alongside sizep and emerges as
    // a one-colour-clock pulse.  The strobe from the register file is a fabric
    // pulse and the pipe only advances on cc_tick, so it is held until the tick
    // that consumes it -- otherwise a write landing between ticks is lost.
    logic [1:0] szp_pipe [0:3][1:SIZEP_CC_DELAY];
    logic       szw_pipe [0:3][1:SIZEP_CC_DELAY];
    logic [7:0] szm_pipe [1:HPOS_CC_DELAY];
    logic [3:0] szw_hold;
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            szw_hold <= 4'd0;
            for (int o = 0; o < 4; o++)
                for (int d = 1; d <= SIZEP_CC_DELAY; d++) szw_pipe[o][d] <= 1'b0;
        end else begin
            szw_hold <= szw_hold | sizep_we;
            if (cc_tick) begin
                for (int o = 0; o < 4; o++) begin
                    for (int d = SIZEP_CC_DELAY; d > 1; d--) begin
                        szp_pipe[o][d] <= szp_pipe[o][d-1];
                        szw_pipe[o][d] <= szw_pipe[o][d-1];
                    end
                    szw_pipe[o][1] <= szw_hold[o] | sizep_we[o];
                end
                for (int d = HPOS_CC_DELAY; d > 1; d--)
                    szm_pipe[d] <= szm_pipe[d-1];
                szp_pipe[0][1] <= sizep0;  szp_pipe[1][1] <= sizep1;
                szp_pipe[2][1] <= sizep2;  szp_pipe[3][1] <= sizep3;
                szm_pipe[1]    <= sizem;
                szw_hold       <= 4'd0;
            end
        end
    end

    wire [3:0] dl_resize = {szw_pipe[3][SIZEP_CC_DELAY], szw_pipe[2][SIZEP_CC_DELAY],
                            szw_pipe[1][SIZEP_CC_DELAY], szw_pipe[0][SIZEP_CC_DELAY]};

    wire [1:0] dl_sizep0 = szp_pipe[0][SIZEP_CC_DELAY];
    wire [1:0] dl_sizep1 = szp_pipe[1][SIZEP_CC_DELAY];
    wire [1:0] dl_sizep2 = szp_pipe[2][SIZEP_CC_DELAY];
    wire [1:0] dl_sizep3 = szp_pipe[3][SIZEP_CC_DELAY];
    wire [7:0] dl_sizem  = szm_pipe[HPOS_CC_DELAY];

    wire       gtia_valid;
    wire [7:0] gtia_a, gtia_b;

    gtia_stage u_gtia (
        .clk(clk), .rst(rst),
        .line_start(px_line_start), .cc_tick(cc_tick), .cc_pos(cc_pos),
        .active(px_collide), .hitclr(hitclr),
        .pf_src_a(pf_src_a_eff), .pf_src_b(pf_src_b_eff),
        .an_pair(an_pair), .pf_win(win_cap),
        .cc_tick_e(cc_tick_e), .an_pair_e(an_pair_e),
        .hposp0(dl_hposp0), .hposp1(dl_hposp1),
        .hposp2(dl_hposp2), .hposp3(dl_hposp3),
        .hposm0(dl_hposm0), .hposm1(dl_hposm1),
        .hposm2(dl_hposm2), .hposm3(dl_hposm3),
        .sizep0(dl_sizep0), .sizep1(dl_sizep1),
        .sizep2(dl_sizep2), .sizep3(dl_sizep3),
        .resize(dl_resize),
        .sizem(dl_sizem),
        .grafp0(grafp0), .grafp1(grafp1), .grafp2(grafp2), .grafp3(grafp3),
        .grafm(grafm), .prior(prior),
        .colbk(colbk), .colpf0(colpf0), .colpf1(colpf1),
        .colpf2(colpf2), .colpf3(colpf3),
        .colpm0(colpm0), .colpm1(colpm1), .colpm2(colpm2), .colpm3(colpm3),
        .out_valid(gtia_valid), .out_color_a(gtia_a), .out_color_b(gtia_b),
        .m_pf(m_pf), .p_pf(p_pf), .m_pl(m_pl), .p_pl(p_pl)
    );

    // The resolved pair waits here for the colour clock after next.
    logic [7:0] pend_a, pend_b;
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            pend_a <= 8'h00;
            pend_b <= 8'h00;
        end else if (gtia_valid) begin
            pend_a <= gtia_a;
            pend_b <= gtia_b;
        end
    end

    // Every pixel of the line is written; the border is background that came
    // through the same path as everything else.
    assign lb_wr    = px_tick;
    assign lb_color = px_odd ? pend_b : pend_a;

    // ---- the delayed rewind -------------------------------------------------
    // Four hi-res pixels, the pipeline depth.  The four pixels written between
    // the beam's line start and this are the PREVIOUS line's last four, and the
    // pointer has not rewound yet, so they land where they belong.
    localparam int PIPE_PX = 4;

    logic [2:0] ls_cnt;
    logic       ls_arm;
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            ls_arm <= 1'b0;
            ls_cnt <= 3'd0;
        end else if (px_line_start) begin
            ls_arm <= 1'b1;
            ls_cnt <= 3'd0;
        end else if (ls_arm && px_tick) begin
            if (ls_cnt == 3'(PIPE_PX - 1)) ls_arm <= 1'b0;
            else                           ls_cnt <= ls_cnt + 3'd1;
        end
    end

    assign lb_line_start = ls_arm && px_tick && (ls_cnt == 3'(PIPE_PX - 1));

endmodule

`default_nettype wire
