`default_nettype none
//
// antic2_seq — ANTIC's per-machine-cycle sequence, transcribed from
// emu/antic.c:antic_tick().
//
// WHY THIS IS ONE BLOCK.  The events below are ORDERED with respect to each
// other, and in the software they are consecutive statements in one function
// where that order is visible.  The previous rewrite spread them across modules
// that each latched at a different point, and the orderings then disagreed:
// `steal` applied in the cycle it named while /RDY trailed by one, and
// "cycle 104" came to mean two different events in two files.  Keeping the
// sequence in a single always_ff, in the SAME ORDER as antic_tick, is the point
// of this module and not a matter of style.
//
// THE FIRST RULE: name the CPU-VISIBLE EVENT, derive the signal.  The software
// says ANTIC_CYC_WSYNC is "the first cycle the CPU gets BACK" and expresses the
// stall as "every cycle EXCEPT that one is taken".  That is what is transcribed.
// The old module defined "the cycle /RDY comes back" and tried to reach the
// CPU-visible behaviour from it; four different retimings are recorded above its
// rdy_q, all of them dead.
//
// A WRITE IS NEVER STALLED.  antic_tick's `else if (!cpu_writing) took = 1` is
// SALLY's rule: /RDY cannot stop a write, so the write completes and the stall
// resumes after it.
//
`timescale 1ns/1ps

module antic2_seq #(
    // Cycle constants.  TRANSCRIBED from emu/, not re-derived: each is pinned by
    // a named test and re-deriving them cost the previous attempt weeks.
    parameter int LINE_CYCLES  = 114,
    parameter int CYC_ROWEND   = 4,    // row end decided PART WAY THROUGH the
                                       // line: a VSCROL write on 3 lands, 4 is
                                       // too late (antic_vscroldli)
    parameter int CYC_NMIST    = 6,    // NMIST sets REGARDLESS of NMIEN; NMIEN
                                       // is sampled the same cycle (antic_nmist)
    parameter int CYC_VCOUNT   = 111,  // vcount advances on ODD scanlines
    parameter int CYC_WSYNC    = 104,  // FIRST CYCLE THE CPU GETS BACK
    parameter int DISPLAY_TOP    = 8,
    // VERTICAL BLANK STARTS AT 248, NOT AT THE END OF THE FRAME.  Both the
    // VBI and the `blanking` test below key off THIS, and using LINES-2 for
    // them put the VBI 12 scanlines late: antic_nmist enables DMA at
    // scanline ~249, so a VBI at 260 fired in the SAME frame -- before any
    // display line had run -- and its handler asserted that the DLIs had
    // already been called.  At 248 the next VBI is a frame away and the
    // display region gets to run first.
    parameter int DISPLAY_BOTTOM = 248,
    parameter int LINES          = 262
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        tick,               // phi2 — one machine cycle

    // ---- position ---------------------------------------------------------
    input  wire [6:0]  cycle,              // 0 .. LINE_CYCLES-1
    input  wire [8:0]  scanline,

    // ---- row / DLI decision inputs (sampled at CYC_ROWEND) -----------------
    input  wire [3:0]  row_line,           // already advanced by line_start
    input  wire [3:0]  row_last,
    input  wire        dl_insn_dli,        // dl_insn[7]
    input  wire        dli_fired,
    output logic       dli_fired_set,

    // ---- register-file interface ------------------------------------------
    input  wire [7:0]  nmien,
    input  wire        nmires_stb,         // CPU wrote NMIRES ($D40F)
    input  wire        wsync_stb,          // CPU wrote WSYNC  ($D40A)
    input  wire        wsync_rmw_readd,    // the write is an RMW's SECOND write
                                           // AND adjacent to the first -> +1
    input  wire        cpu_writing,        // this cycle is a CPU write

    output logic [7:0] nmist,
    output logic [7:0] vcount,
    output logic       nmi,                // ONE-CYCLE PULSE, not a level
    output wire        wsync_take,         // ANTIC takes this cycle for WSYNC
    output logic       row_ends,
    output logic       dli_line
);

    // /NMI is a COUNTDOWN, not a fixed cycle.  A request armed by a LATE NMIEN
    // WRITE costs one cycle more than one armed by the status set itself, and
    // antic_dlitiming's two delay tests are exactly what separate them: both
    // disable NMIEN across the DLI point and re-enable at scanline cycle 7, and
    // both must deliver at the same place.
    //
    // It is a PULSE because real DLI handlers never write NMIRES -- they PHA,
    // set a colour, PLA, RTI -- yet multi-DLI kernels work, so every event needs
    // its own edge.  Holding it low gives the CPU exactly ONE NMI for a run.
    logic [1:0] nmi_arm;

    // WSYNC state.  `wsync_extra` is the RMW re-arm: `inc wsync` releases one
    // cycle later than `sta wsync` because the RMW's SECOND write re-arms the
    // latch -- and only when the two writes are ADJACENT.
    // DISPROVED and not to be reintroduced: making this depend on POSITION IN
    // THE LINE (emu's WSYNC_RMW_ADJ_CYCLE=0) cost antic_dlitiming,
    // antic_dmapattern, gtia_phantomdma, gtia_psuedomodee and pokey_noise.
    logic       wsync_halt;
    logic       wsync_extra;

    wire [6:0] wsync_release = 7'(CYC_WSYNC) + {6'd0, wsync_extra};

    // The row's last scanline, decided at CYC_ROWEND.  The counter is FOUR BITS
    // and the test is EQUALITY, so a VSCROL that overshoots the mode's height
    // makes the row run all the way round rather than ending at once --
    // antic_linebuffering's mode F (height ONE) entered with VSCROL=1 spans
    // sixteen scanlines: 1,2,..15,0.
    wire [3:0] row_line_m1 = row_line - 4'd1;
    wire       at_last     = (row_line_m1 == row_last);

    // A DLI that would re-fire every scanline once the row's last line has
    // passed: whether it does depends on WHY the fetch is stalled.
    //   DL DMA off mid-display -> it DOES keep re-firing (antic_dlistwrap #2)
    //   vertical blank          -> it does NOT (antic_hiresbug)
    // A FIRST firing outside the display region is still allowed -- that is
    // antic_dlistwrap #1, whose DLI lands on scanline 1 of the next frame.
    // THE BEAM'S `line` IS NOT THE CURRENT SCANLINE FOR THE WHOLE LINE.
    // antic_beam advances it at `hcount == vcount_adv - 1` (110), so from cycle
    // 111 to 113 it already reads the NEXT line.  That is right for line_start
    // consumers -- emu increments scanline and THEN runs line_start, so the new
    // line is what line_start sees -- but wrong for anything keyed to a cycle at
    // or after 111, where emu is still on the OLD scanline.
    //
    // It cost the vcount parity: `cycle == 111 && scanline[0]` matched when the
    // BEAM's line was odd, i.e. at the end of every EVEN scanline, so VCOUNT read
    // one too high on every odd line.  antic_nmist's poll for 247/2 then exited a
    // line early and its NMIST read landed at 247, before the VBI at 248, where
    // the DLI bit is legitimately still set.
    //
    // ONE definition, used everywhere in this module: cycles 4 and 6 are below
    // 111 so sl_now == scanline there and nothing changes for them.
    // THE PHASE RULE, and every cycle constant in this module depends on it:
    // ANTIC's effects for cycle N must be VISIBLE TO THE CPU DURING CYCLE N.
    // A register written on the cycle-N edge only reads back at N+1, so the
    // update has to be computed at the edge FROM N-1.  `cyc_eff` is the cycle
    // these updates will be seen in, and every event below compares against IT.
    //
    // antic_vcount is what pins this: its rollover pair reads VCOUNT at cycle
    // 111 and requires the 111 advance to be ALREADY THERE (131), then reads at
    // 112 and requires 0.  Its third probe reads at 111 and wants the advanced
    // value too.  Computing on the 111 edge put every one of them a cycle late.
    //
    // This was HIDDEN until the WSYNC release was fixed: the CPU used to resume
    // at 105 instead of 104, which shifted every read by +1 and cancelled the
    // error.  Two wrongs, one passing test -- and antic_vcount went red the
    // moment the release was corrected, which is how the phase was found.
    wire [6:0] cyc_eff = (cycle == 7'(LINE_CYCLES - 1)) ? 7'd0 : cycle + 7'd1;

    // MEASURED AGAINST THE ORACLE, and the two registers DO NOT share a phase:
    //
    //   VCOUNT  advances at 111 and a read AT 111 sees the NEW value
    //           (emu, antic_vcount scanline 5: "cyc 111 CPU-R $D40B -> $03"),
    //           so it is computed at the edge from 110  -> cyc_eff.
    //   NMIST   sets at 6 and a read AT 6 sees the OLD value; the same test's
    //           next probe, seven cycles later, sees the new one
    //           (emu, antic_nmist scanline 39: "cyc 6 CPU-R $D40F -> $00" from
    //           the lda at $220B, "cyc 7 -> $80" from the lda at $2251),
    //           so it is computed at the edge from 6    -> cycle.
    //
    // Applying VCOUNT's phase to NMIST set the DLI bit a cycle early and cost
    // antic_blockednmi.  ROWEND stays on `cycle` with NMIST: it feeds the same
    // decision two cycles ahead of it.
    //
    // The test's own annotation says that read is on cycle 5.  IT IS NOT -- the
    // oracle's bus trace shows the instruction fetches at 3,4,5 and the data
    // cycle at 6.  Comments in the suite are commentary; the asserts and the
    // oracle are the specification.

    // The scanline cyc_eff belongs to.  antic_beam advances `line` on the edge
    // FROM 110, so at the edges from 111 and 112 -- which produce cycles 112 and
    // 113, still part of the OLD line -- `scanline` already reads the next one.
    // At the edge from 113 (producing cycle 0) it correctly reads the new line.
    wire [8:0] sl_now = (cycle >= 7'd111 && cycle <= 7'd112)
                      ? ((scanline == 9'd0) ? 9'(LINES - 1) : scanline - 9'd1)
                      : scanline;

    wire blanking = (sl_now < 9'(DISPLAY_TOP)) ||
                    (sl_now >= 9'(DISPLAY_BOTTOM));

    // THE STALL APPLIES TO THE CYCLE IT NAMES, so it is COMBINATIONAL.
    // antic_tick returns `took` for the cycle it is evaluating; a REGISTERED
    // wsync_take is computed from this cycle's state but lands on the NEXT one,
    // which is the "/RDY trailed by one" failure this module's header was
    // written about -- and it re-appeared here.  Measured: the CPU's first cycle
    // back after WSYNC was 105 instead of 104, because the release at 104 was
    // still being stalled by the value latched at 103.
    //
    // The asymmetry gave it away: dma_steal (refresh) is combinational from
    // hcount in antic2.sv and applies in the cycle it names, while this one
    // trailed it by a cycle -- two stall sources in one design disagreeing about
    // when a cycle number means that cycle.
    //
    // A WRITE IS NEVER STALLED: SALLY's /RDY cannot stop a write, so the write
    // completes and the stall resumes after it.
    assign wsync_take = wsync_halt && (cycle != wsync_release) && !cpu_writing;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            nmist         <= 8'h00;
            vcount        <= 8'h00;
            nmi           <= 1'b0;
            nmi_arm       <= 2'd0;
            wsync_halt    <= 1'b0;
            wsync_extra   <= 1'b0;
            // ARMED at reset, so the first line after the vertical-blank
            // release actually fetches (emu antic_reset: row_ends = 1).
            row_ends      <= 1'b1;
            dli_line      <= 1'b0;
            dli_fired_set <= 1'b0;
        end else begin
            dli_fired_set <= 1'b0;

            // A WSYNC write arms the halt whenever it happens -- including
            // outside the tick, since the strobe is the CPU's own write.
            if (wsync_stb) begin
                wsync_halt  <= 1'b1;
                wsync_extra <= wsync_rmw_readd;
            end
            if (nmires_stb) nmist <= 8'h00;

            if (tick) begin
                // ---- 1. the NMI countdown ------------------------------
                if (nmi) nmi <= 1'b0;
                if (nmi_arm != 2'd0) begin
                    nmi_arm <= nmi_arm - 2'd1;
                    if (nmi_arm == 2'd1) nmi <= 1'b1;
                end

                // ---- 2. row end and the DLI decision, at CYC_ROWEND -----
                // The DLI's compare is taken from THIS sample, not re-read at
                // NMIST time: NMIST lands at cycle 6, so re-reading there would
                // let a VSCROL write on cycle 4 count, and antic_vscroldli
                // requires exactly that write to be too late.
                if (cycle == 7'(CYC_ROWEND)) begin
                    row_ends <= at_last;
                    dli_line <= dl_insn_dli && !(blanking && dli_fired) && at_last;
                    if (dl_insn_dli && !(blanking && dli_fired) && at_last)
                        dli_fired_set <= 1'b1;
                end

                // ---- 3. status and interrupts, at CYC_NMIST ------------
                // NMIST sets REGARDLESS of NMIEN -- NMIEN gates the INTERRUPT,
                // not the status -- and the DLI and VBI bits clear each other
                // on arrival.
                if (cycle == 7'(CYC_NMIST)) begin
                    if (dli_line) begin
                        nmist <= (nmist & ~8'h40) | 8'h80;
                        if (nmien & 8'h80) nmi_arm <= 2'd1;
                    end
                    if (sl_now == 9'(DISPLAY_BOTTOM)) begin
                        nmist <= (nmist & ~8'h80) | 8'h40;
                        if (nmien & 8'h40) nmi_arm <= 2'd1;
                    end
                end

                // ---- 4. VCOUNT ------------------------------------------
                // vcount is scanline>>1, so it advances at cycle 111 of every
                // ODD scanline.  Because that happens on the LAST scanline too
                // (261 is odd) it momentarily reads lines/2 = 131, and a
                // comparator clears it ONE CYCLE LATER -- not at the line end.
                // That single cycle is the whole of antic_vcount's rollover
                // pair: two probes on the SAME scanline differing only in read
                // cycle, 111 must read 131 and 112 must read 0.
                if (cyc_eff == 7'(CYC_VCOUNT) && sl_now[0])
                    vcount <= vcount + 8'd1;
                if (cyc_eff == 7'(CYC_VCOUNT) + 7'd1 && sl_now == 9'(LINES - 1))
                    vcount <= 8'd0;

                // ---- 5. WSYNC ------------------------------------------
                // Only the STATE is clocked here.  The stall itself is
                // combinational below -- see the note on wsync_take.
                if (wsync_halt && cycle == wsync_release) begin
                    wsync_halt  <= 1'b0;
                    wsync_extra <= 1'b0;
                end
            end
        end
    end

endmodule

`default_nettype wire
