`timescale 1ns/1ps
`default_nettype none
//
// NOT VALID YET — DO NOT TRUST RESULTS FROM THIS HARNESS.
//
// It runs the test image with NO OS ROM.  The ACID framework installs handlers
// in the OS vectors (VDSLST, VVBLKI) and relies on the OS ROM's NMI dispatcher
// at $FFFA to read NMIST and jump through them.  The XEX does not cover $FFFA —
// antic_vcount's segments are $1A20-$1F30, $2000-$21F2, $02E0-$02E1 — so with
// no ROM that vector is RAM, reads as zero, and the first DLI or VBI kills the
// machine.  There is also no VBI, no SIO and no E: handler.
//
// A result out of this harness therefore means nothing, and it will still print
// a confident PASS or FAIL, which is worse than printing nothing.
//
// What it needs to be real: RAM + the XL OS ROM at $C000 (rsrc/atari-xl.rom) +
// PIA for PORTB banking (pia_regs.sv) + POKEY (pokey.sv) + the display chips,
// cold-booted, with the XEX injected afterwards the way loader/test/freertos/
// progs/xexload.c does it on the board.  Every piece is already in the repo.
//
//
// tb_acid — run one ACID800 standalone test against the ANTIC rewrite.
//
// The board runs these through xexload with a hardware breakpoint at the ACID
// framework's _testEnd, then classifies the Y register: _testPassed leaves Y at
// $00 and _testFailed at $80. This is the same arrangement in simulation, so a
// test can be run against the rewrite before the new path exists in a
// bitstream.
//
// tools/acid2mem.py produces acid.mem (the 64K image, with a stack-setting stub
// at $0700 and the reset vector aimed at it) and acid_cfg.mem (the _testEnd
// address out of the test's own .lab, because it moves between builds).
//
// A standalone ANTIC test needs nothing but RAM and the display chips — the
// framework's _waitVBL polls VCOUNT and touches no OS, no POKEY and no PIA.
// Reads of other hardware pages return $FF, which is what an unpopulated bus
// gives.
//
module tb_acid #(
    // Selects the ANTIC implementation.  A PARAMETER on the top module so it can
    // be set with iverilog -Ptb_acid.USE_ANTIC2=1, and a SEPARATE BINARY rather
    // than a -D toggle: `make` does not rebuild for a changed define, which has
    // silently re-run the previous build twice in this project.
    parameter bit USE_ANTIC2 = 1'b0,
    // Fabric clocks per machine cycle.  56 is the real ratio and the only
    // value known to work.
    //
    // This is a knob because 56:1 looks like pure simulation cost -- the core
    // is gated on tick/px_tick, and the only thing counting raw fabric clocks
    // is the memory pipeline (mem_valid is mem_req delayed one clock, data two
    // clocks after the request), which still has slack at 16.  MEASURED, AND
    // THE ARGUMENT IS WRONG: antic_nmist takes 437s at 56 and had not finished
    // after 58 MINUTES at 16.  Fewer edges to the same 6502 state cannot be
    // slower unless the behaviour changed, so at 16 it never reaches its
    // verdict and grinds to the guard.  The ratio is NOT free to alter.
    //
    // Kept, rather than reverted, so the next person who has the same idea
    // finds the result instead of repeating the experiment.  Must be a
    // multiple of 4 -- px_tick fires four times per machine cycle, evenly
    // spaced -- and at 56 the generator below yields exactly the phases it
    // always did: 13, 27, 41, 55.
    parameter int PHASES = 56
);

    logic clk = 0, rst = 1, cold = 0;
    always #5 clk = ~clk;

    localparam int PXSTEP = PHASES / 4;

    logic [5:0] phase = 6'd0;
    logic       tick, px_tick;
    always_ff @(posedge clk) begin
        phase   <= (phase == 6'(PHASES-1)) ? 6'd0 : phase + 6'd1;
        tick    <= (phase == 6'(PHASES-1));
        px_tick <= (phase == 6'(PXSTEP-1))   || (phase == 6'(2*PXSTEP-1)) ||
                   (phase == 6'(3*PXSTEP-1)) || (phase == 6'(4*PXSTEP-1));
    end

    wire [15:0] cpu_addr, antic_addr;
    wire [7:0]  cpu_wdata;
    wire        cpu_we;
    logic [7:0] cpu_rdata, antic_rdata;

    wire        lb_wr, lb_line_start, dma_steal, rdy_n, nmi_n, sync;
    wire [7:0]  lb_color;
    wire [15:0] dbg_pc;
    wire [7:0]  dbg_a, dbg_x, dbg_y, dbg_s, dbg_p;
    wire [6:0]  hcount;
    wire [8:0]  line;

    reg [15:0] tune_v;

    // VCOUNT-read probe.  The open question after the WSYNC sweep is whether
    // the CPU reaches `lda $D40B` on the cycle the test's comments name, so
    // report the beam position at each such read.  Off unless +PROBE=1, so
    // ordinary runs are byte-identical.
    reg probe_on;
    always_ff @(posedge clk) begin
        if (probe_on && tick && !rst && dut.c_rw && (dut.c_addr == 16'hD40B))
            $display("PROBE vcount-read pc=%04h line=%0d hcount=%0d value=%02h",
                     dbg_pc, line, hcount, dut.c_din);
    end

    // The SAME read, sampled where the CPU actually samples it: SUB_DATA,
    // N-7 fabric clocks into the machine cycle.  If this disagrees with the
    // boundary probe above on a given cycle, the register is changing MID
    // machine cycle and the CPU sees the far side of that change.
    always_ff @(posedge clk) begin
        if (probe_on && !rst && dut.c_rw && (dut.c_addr == 16'hD40B)
            && (dut.c_sub == 8'(dut.SUB_DATA)))
            $display("PROBE-SUB    pc=%04h line=%0d hcount=%0d value=%02h",
                     dbg_pc, line, hcount, dut.c_din);
    end

    // The WSYNC resume gap, measured rather than argued.  The oracle's
    // ANTIC_CYC_WSYNC is "the first cycle the CPU gets BACK"; the RTL's
    // WSYNC_RELEASE is "the cycle /RDY comes back".  Print both the cycle /RDY
    // deasserts and the first cycle the CPU actually retires after it, so the
    // gap between the two semantics is a number and not an inference.
    // DMA APPLICATION: which cycles ANTIC INTENDS to steal (dma_steal) versus
    // which the CPU actually LOSES (c_rdy low).  Both sampled at the SAME
    // trigger (`tick`), so the hcount sampling offset applies equally to both
    // sets and CANCELS in the comparison -- the sets are what matter, not the
    // absolute numbers.  WSYNC also pulls c_rdy low, so `w` flags whether rdy_n
    // was asserted; a lost cycle with w=0 and steal=0 is unaccounted for.
    always_ff @(posedge clk) begin
        if (probe_on && tick && !rst && (line == 9'd40) &&
            (dma_steal || !dut.c_rdy))
            $display("PROBE-DMA hcount=%0d steal=%0d lost=%0d w=%0d",
                     hcount, dma_steal, !dut.c_rdy, rdy_n);
    end

    // Collision-register reads.  Trigger: the CPU reading $D000-$D00F, sampled
    // at SUB_DATA where the core actually latches, so the value printed is the
    // one the CPU gets.  The oracle's ACID_COLPROBE shows gtia_collision's
    // samples are almost all ppf=0000/mpf=0000 -- it mostly asserts collisions
    // do NOT happen -- so a NON-ZERO here is a spurious collision, i.e. a VALUE
    // error rather than a timing one.
    always_ff @(posedge clk) begin
        if (probe_on && !rst && dut.c_rw
            && (dut.c_addr[15:4] == 12'hD00)
            && (dut.c_sub == 8'(dut.SUB_DATA)))
            $display("PROBE-COL addr=%03h value=%02h line=%0d hcount=%0d",
                     dut.c_addr[11:0], dut.c_din, line, hcount);
    end

    // The TRUE scanline.  antic2's beam counter steps on at hcount 111, so the
    // raw register reads one too high at the end of a line; every probe that
    // prints a scanline must use this or they disagree with each other.
    // Declared HERE, above the probes, because a wire referenced before its
    // declaration does not elaborate.
    wire [8:0] bus_line = (dut.u_antic2.hcount >= 7'd111)
                        ? ((dut.u_antic2.line == 9'd0) ? 9'd261
                                                       : dut.u_antic2.line - 9'd1)
                        : dut.u_antic2.line;

    // Collision-latch probe (antic2 only).  gtia_collision asserts that objects
    // parked in horizontal blank latch NOTHING, and the window that is supposed
    // to enforce that already exists in gtia_stage -- so the question is not
    // "is there a window" but "which colour clock is the hit actually recorded
    // at".  Print every transition of p_pl from clear to set, with the position
    // and presence that produced it.
    logic [15:0] ppl_prev, ppf_prev, mpl_prev;
    integer      colcnt = 0;
    integer      pfcnt  = 0;
    integer      mplcnt = 0;
    generate if (USE_ANTIC2) begin : g_colprobe
        always_ff @(posedge clk) begin
            if (rst) ppl_prev <= 16'h0000;
            else begin
                if (probe_on && dut.u_a2_video.u_gtia.u_col.p_pf != ppf_prev &&
                    pfcnt < 16) begin
                    pfcnt <= pfcnt + 1;
                    $display("COLPF p_pf %04h -> %04h  cc_pos=%0d pres=%02h pf_src=%0d line=%0d",
                             ppf_prev, dut.u_a2_video.u_gtia.u_col.p_pf,
                             dut.u_a2_video.u_gtia.cc_pos,
                             dut.u_a2_video.u_gtia.pres,
                             dut.u_a2_video.u_gtia.u_col.pf_src,
                             line);
                end
                ppf_prev <= dut.u_a2_video.u_gtia.u_col.p_pf;
                if (probe_on && dut.u_a2_video.u_gtia.u_col.p_pl != ppl_prev &&
                    colcnt < 24) begin
                    colcnt <= colcnt + 1;
                    $display("COL p_pl %04h -> %04h  cc_pos=%0d pres=%02h active=%0d win=%0d line=%0d",
                             ppl_prev, dut.u_a2_video.u_gtia.u_col.p_pl,
                             dut.u_a2_video.u_gtia.cc_pos,
                             dut.u_a2_video.u_gtia.pres,
                             dut.u_a2_video.u_gtia.active,
                             dut.u_a2_video.u_gtia.cc_in_window,
                             line);
                end
                ppl_prev <= dut.u_a2_video.u_gtia.u_col.p_pl;

                // MISSILE-to-player is a DIFFERENT REGISTER from player-to-
                // player, and gtia_pmoverlap reads M0PL..M3PL.  Watching p_pl
                // for it is watching the wrong thing: on that test p_pl never
                // moves at all (only one player is lit), so the COL probe is
                // silent and says nothing whatever about the missiles.
                if (probe_on && dut.u_a2_video.u_gtia.u_col.m_pl != mpl_prev &&
                    mplcnt < 24) begin
                    mplcnt <= mplcnt + 1;
                    $display("MPL m_pl %04h -> %04h  cc_pos=%0d pres=%02h active=%0d win=%0d line=%0d",
                             mpl_prev, dut.u_a2_video.u_gtia.u_col.m_pl,
                             dut.u_a2_video.u_gtia.cc_pos,
                             dut.u_a2_video.u_gtia.pres,
                             dut.u_a2_video.u_gtia.active,
                             dut.u_a2_video.u_gtia.cc_in_window,
                             line);
                end
                mpl_prev <= dut.u_a2_video.u_gtia.u_col.m_pl;
            end
        end
    end endgenerate

    // lb_origin probe (antic2 only).  The counter has never been observed
    // non-zero; antic_hscrolbug's abnormal line has nine fetches before the
    // window opens, so it should read nine there.  Printed at the end of each
    // line so the value is the whole line's count, not a partial one.
    // Its own selector, declared HERE: reaching forward to +LBDUMP's does not
    // elaborate, because a wire must be declared before it is referenced --
    // the third time this session that rule has bitten in a testbench.
    int LBOINSN = -1;
    initial if (!$value$plusargs("LBOINSN=%h", LBOINSN)) LBOINSN = -1;
    integer lbocnt = 0;
    generate if (USE_ANTIC2) begin : g_lboprobe
        always_ff @(posedge clk) begin
            // ANCHORED ON THE INSTRUCTION.  Left unanchored it spent all
            // twelve prints on the blank lines of an early frame and never
            // reached the row under test -- the same trap the MAP probe's
            // comment warns about.
            if (probe_on && !rst && tick && dut.u_antic2.hcount == 7'd113 &&
                LBOINSN >= 0 && dut.u_antic2.dl_insn == 8'(LBOINSN) &&
                lbocnt < 12) begin
                lbocnt <= lbocnt + 1;
                // bus_line, not `line`: the beam's counter has already stepped
                // on by hcount 111, so the raw register reads one too high
                // here and would disagree with the MAP probe about which
                // scanline this is.
                $display("LBO line=%0d insn=%02h lb_origin=%0d dma_start=%0d row_first=%0d",
                         bus_line, dut.u_antic2.dl_insn,
                         dut.u_antic2.lb_origin, dut.u_antic2.pf_dma_start,
                         dut.u_antic2.row_first);
            end
        end
    end endgenerate

    // THE LATE FETCHES OF A LINE (antic2 only), for the virtual-slot work.
    //
    // The steal map cannot answer this: cycles from PF_HBLANK_FIRST = 106 on
    // still fetch but steal nothing, so antic2 and emu can agree on every
    // blocked cycle and still disagree about whether a fetch happens at 106.
    // emu's own list stops at 103 (`LN 32 n 24 fetch: 11 ... 103`), while
    // antic2's `pf_want_b = pairs && hit_3` would fire three cycles after the
    // last name.  This prints every scheduled fetch at or past cycle 96 so the
    // two can be compared directly.
    //
    // Its own selector, next to the probe -- see the LBO comment above.
    int VFETINSN = -1;
    initial if (!$value$plusargs("VFETINSN=%h", VFETINSN)) VFETINSN = -1;
    integer vfetcnt = 0;
    generate if (USE_ANTIC2) begin : g_vfetprobe
        always_ff @(posedge clk) begin
            if (probe_on && !rst && tick && VFETINSN >= 0 &&
                dut.u_antic2.dl_insn == 8'(VFETINSN) &&
                dut.u_antic2.hcount >= 7'd96 &&
                dut.u_antic2.sched_pf_fetch && vfetcnt < 40) begin
                vfetcnt <= vfetcnt + 1;
                $display("VFET line=%0d insn=%02h cyc=%0d glyph=%0d",
                         bus_line, dut.u_antic2.dl_insn, dut.u_antic2.hcount,
                         dut.u_antic2.sched_pf_fetch_glyph);
            end
        end
    end endgenerate

    // THE PHANTOM P/M LATCH (antic2 only), to diff against emu's PHAN.
    //
    // emu prints 184 of these on gtia_phantomdma and THE ONE THAT MATTERS IS
    // THE LAST -- `sl 33 cyc 3 p0 <- $AD`.  So this must NOT be capped low
    // enough to lose the tail: a budget that runs out before the interesting
    // line is the same trap as an unanchored probe, one step further on.
    // 400 is comfortably past emu's 184 and still bounded.
    int PHANPROBE = 0;
    initial if (!$value$plusargs("PHANPROBE=%d", PHANPROBE)) PHANPROBE = 0;
    integer phancnt = 0;
    generate if (USE_ANTIC2) begin : g_phanprobe
        always_ff @(posedge clk) begin
            // pm_take, NOT pm_we.  GRACTL decides whether GTIA latches at
            // all, and that gate lives in gtia_reg_file -- printing the raw
            // strobe counts cycles the register file then throws away, which
            // is not what emu's PHAN prints.
            if (PHANPROBE != 0 && !rst &&
                dut.u_a2_video.u_regs.pm_take && phancnt < 400) begin
                phancnt <= phancnt + 1;
                $display("A2PHAN sl %0d cyc %0d p%0d <- %02h",
                         bus_line, dut.u_antic2.hcount,
                         dut.u_antic2.pm_obj - 3'd1, dut.u_antic2.pm_data);
            end
        end
    end endgenerate

    // Line-buffer dump (antic2 only).  The DMA map, lb_origin and the read
    // index have all been checked against emu and agree; what has not been
    // checked is what actually landed IN the buffer.  antic_hscrolbug's own
    // comment gives the answer it expects -- 55 AA 55 AA ... 55 AA FF 00 -- so
    // printing the first 48 entries at the end of the named line turns that
    // into a diff rather than an argument.
    //
    // ANCHORED ON THE INSTRUCTION (+LBDUMP=<insn>, decimal), not a scanline:
    // the same scanline recurs every frame, and the first hits are from before
    // the test has even set its display list up -- which is what the MAP probe
    // below already says, and what this one caught me doing.
    int LBDUMP = -1;
    initial if (!$value$plusargs("LBDUMP=%h", LBDUMP)) LBDUMP = -1;
    integer lbdcnt = 0;
    generate if (USE_ANTIC2) begin : g_lbdump
        always_ff @(posedge clk) begin
            if (!rst && tick && LBDUMP >= 0 && lbdcnt < 3 &&
                dut.u_antic2.hcount == 7'd113 &&
                dut.u_antic2.dl_insn == 8'(LBDUMP)) begin
                lbdcnt <= lbdcnt + 1;
                $write("LBDUMP sl %0d insn %02h org %0d:",
                       bus_line, dut.u_antic2.dl_insn, dut.u_antic2.lb_origin);
                for (int k = 0; k < 48; k++)
                    $write(" %02h", dut.u_antic2.u_pf.buf_mem[k][7:0]);
                $write("\n");
            end
        end
    end endgenerate

    // The GTIA-mode nibble, per colour clock, against the objects that see it.
    // gtia_stage keeps the nibble in TWO registers -- `nib_ready` completes on
    // the odd colour clock and `gtia_nib` is what goes on display for the next
    // aligned pair -- and the collision path has to pick one.  Guessing between
    // them cost two builds, so print BOTH beside `pres` and let emu's ruler
    // OBJECT PRESENCE ALONG ONE SCANLINE.  +PRES=<scanline>.
    //
    // The collision probes only fire when a collision REGISTERS, so they cannot
    // tell "the object was never drawn here" from "it was drawn and did not
    // collide" -- and on gtia_pmoverlap that is exactly the open question: the
    // right collisions appear two lines earlier and none at all on the line the
    // test reads.  This prints every colour clock of one line where ANY object
    // is present, so an empty line and a present-but-not-colliding line look
    // different.  pres bit 0..3 = players, 4..7 = missiles.
    // FRAME COUNTER FOR THE PROBES.  A scanline number alone is ambiguous: the
    // kernel repeats every frame, so "line 35" names one line in EVERY frame and
    // a probe anchored on it reports the FIRST one -- which is how a pass-0
    // measurement gets mistaken for a pass-3 one.  emu's own PFPROBE prints `f%d`
    // for the same reason; this is the matching field on this side.
    integer a2_frame = 0;
    always_ff @(posedge clk) begin
        if (!rst && dut.u_antic2.line_start && dut.u_antic2.line == 9'd0)
            a2_frame <= a2_frame + 1;
    end

    int PRESLN = -1;
    initial if (!$value$plusargs("PRES=%d", PRESLN)) PRESLN = -1;
    integer prescnt = 0;
    generate if (USE_ANTIC2) begin : g_pres
        always_ff @(posedge clk) begin
            if (!rst && PRESLN >= 0 && prescnt < 250 &&
                dut.u_a2_video.u_gtia.cc_tick && bus_line == PRESLN &&
                dut.u_a2_video.u_gtia.pres != 8'h00) begin
                prescnt <= prescnt + 1;
                $display("PRES f%0d sl %0d cc %02h hc %0d pres %02h active %0d win %0d hposp0 %02h",
                         a2_frame, bus_line, dut.u_a2_video.u_gtia.cc_pos, dut.u_antic2.hcount,
                         dut.u_a2_video.u_gtia.pres,
                         dut.u_a2_video.u_gtia.active,
                         dut.u_a2_video.u_gtia.cc_in_window,
                         dut.u_a2_video.u_gtia.hposp0);
            end
        end
    end endgenerate

    // (ACID_PFPROBE, `pf` per cc) say which lines up.  +GMNIB=<scanline>.
    int GMNIB = -1;
    initial if (!$value$plusargs("GMNIB=%d", GMNIB)) GMNIB = -1;
    integer gmnibcnt = 0;
    generate if (USE_ANTIC2) begin : g_gmnib
        always_ff @(posedge clk) begin
            if (!rst && GMNIB >= 0 && gmnibcnt < 200 &&
                dut.u_a2_video.u_gtia.cc_tick && bus_line == GMNIB &&
                dut.u_a2_video.u_gtia.cc_pos >= 8'h78 &&
                dut.u_a2_video.u_gtia.cc_pos <= 8'h98) begin
                gmnibcnt <= gmnibcnt + 1;
                $display("GMNIB sl %0d cc %02h pair %b rdy %h nib %h col %0d pres %02h",
                         bus_line, dut.u_a2_video.u_gtia.cc_pos,
                         dut.u_a2_video.u_gtia.an_pair,
                         dut.u_a2_video.u_gtia.nib_ready,
                         dut.u_a2_video.u_gtia.gtia_nib,
                         dut.u_a2_video.u_gtia.col_pf,
                         dut.u_a2_video.u_gtia.pres);
            end
        end
    end endgenerate

    // Per-colour-clock playfield SOURCE (antic2 only), in emu's PFSRC shape so
    // the two lines can be diffed character for character.  The buffer being
    // right does not make the picture right: this is the one stage between a
    // verified fetch path and a missing collision.  '.' is background/outside.
    // +PFSRC=<insn hex>.
    int PFSRC = -1;
    initial if (!$value$plusargs("PFSRC=%d", PFSRC)) PFSRC = -1;
    int PFSRCN = 2;
    initial void'($value$plusargs("PFSRCN=%d", PFSRCN));
    logic [2:0] pfsrc_row [0:227];
    integer pfsrccnt = 0;
    logic pfsrc_any = 1'b0;
    // The print fires at hcount 113, where `line` has ALREADY advanced to the
    // next scanline -- so label the row with the number it had at hcount 0.
    logic [8:0] pfsrc_sl = 9'd0;
    always_ff @(posedge clk) begin
        if (rst) begin
            for (int k = 0; k < 228; k++) pfsrc_row[k] <= 3'd7;   // 7 = none
        end else if (USE_ANTIC2 && PFSRC >= 0) begin
            // SAMPLE ON EVERY CLOCK, NOT ON `tick`.  px_wr is qualified by
            // px_tick, which fires more than once per machine cycle -- one
            // machine cycle spans two colour clocks and the renderer emits at
            // each.  Gating the capture on `tick` therefore records one emit in
            // two and produces a map whose columns come in identical pairs,
            // which reads exactly like a design that paints at half resolution.
            // The objects in antic_charcontrol are ONE colour clock wide, so
            // that artefact hid the whole question.
            if (tick && dut.u_antic2.hcount == 7'd0) pfsrc_sl <= dut.u_antic2.line;
            if (dut.u_antic2.px_line_start) begin
                for (int k = 0; k < 228; k++) pfsrc_row[k] <= 3'd7;
                pfsrc_any <= 1'b0;
            end else if (dut.u_antic2.px_wr) begin
                pfsrc_row[dut.u_antic2.px_pos[8:1]] <= dut.u_antic2.px_pf_src;
                pfsrc_any <= 1'b1;
            end
            // SELECT BY SCANLINE, AND ONLY ONCE THE LIST IS ACTUALLY RUNNING.
            // Keying on dl_insn and capping at 3 spent the whole budget on the
            // power-on frames, where dl_insn is 00 and nothing is emitted --
            // which is why this probe read as dead for three sessions.
            if (tick && dut.u_antic2.hcount == 7'd113 && pfsrccnt < PFSRCN &&
                (PFSRC == 255 ? pfsrc_any : (dut.u_antic2.vcount == 8'(PFSRC))) &&
                dut.u_antic2.dl_insn != 8'h00) begin
                pfsrccnt <= pfsrccnt + 1;
                $write("PFSRC sl %0d (raw %0d) insn %02h:", pfsrc_sl,
                       dut.u_antic2.line, dut.u_antic2.dl_insn);
                for (int k = 0; k < 228; k++)
                    $write("%c", (pfsrc_row[k] == 3'd7) ? "." : ("0" + pfsrc_row[k]));
                $write("\n");
            end
        end
    end

    // RAW XMR CALIBRATION.  Three probes into antic2 have read as constant
    // zero while the design demonstrably works.  Before building anything else
    // on those hierarchical paths, print the raw values of every signal the
    // dead probes used, unconditionally, for one window of one scanline.  If a
    // signal reads zero here on a PASSING test it is the path that is wrong,
    // not the model.  +RAWXMR=<scanline>.
    int RAWXMR = -1;
    initial if (!$value$plusargs("RAWXMR=%d", RAWXMR)) RAWXMR = -1;
    integer rawcnt = 0;
    integer rawwr = 0;
    integer rawlbmax = 0;
    integer rawinsn = 0;
    final begin
        if (RAWXMR >= 0) $display("RAWSUM pxwr_ticks=%0d insn_nz_ticks=%0d shown=%0d lb_len_max=%0d", rawwr, rawinsn, rawcnt, rawlbmax);
    end
    always_ff @(posedge clk) begin
        if (!rst && USE_ANTIC2 && RAWXMR >= 0 && tick && dut.u_antic2.px_wr) begin
            rawwr <= rawwr + 1;
        end
        if (!rst && USE_ANTIC2 && RAWXMR >= 0 && tick &&
            int'(dut.u_antic2.lb_len) > rawlbmax) begin
            rawlbmax <= int'(dut.u_antic2.lb_len);
        end
        if (!rst && USE_ANTIC2 && RAWXMR >= 0 && tick && dut.u_antic2.dl_insn != 8'h00) begin
            rawinsn <= rawinsn + 1;
        end
        if (!rst && USE_ANTIC2 && RAWXMR >= 0 && rawcnt < 40 && tick &&
            (dut.u_antic2.px_wr || dut.u_antic2.dl_insn != 8'h00)) begin
            rawcnt <= rawcnt + 1;
            $display("RAW n=%0d tick=%b hc=%0d insn=%02h pxwr=%b pxpos=%0d src=%0d ls=%b emit=%b inwin=%b st=%0d",
                     rawcnt, tick, dut.u_antic2.hcount, dut.u_antic2.dl_insn,
                     dut.u_antic2.px_wr, dut.u_antic2.px_pos,
                     dut.u_antic2.px_pf_src, dut.u_antic2.px_line_start,
                     dut.u_antic2.pf_emit_en, dut.u_antic2.px_in_window,
                     dut.u_antic2.u_render.state);
            $display("RAW+ lb_len=%0d pf_bytes=%0d pf_on=%b fetching=%b pxstart=%0d pxstop=%0d",
                     dut.u_antic2.lb_len, dut.u_antic2.pf_bytes,
                     dut.u_antic2.u_geom.pf_on, dut.u_antic2.pf_fetching,
                     dut.u_antic2.pf_px_start, dut.u_antic2.pf_px_stop);
        end
    end

    // DLI chain probe (antic2 only).  antic_nmist fails on "The DLI1 handler was
    // not called" while the VBI fires, so the break is somewhere in
    // fetch -> dl_insn[7] -> row_ends -> dli_line.  Print the whole chain once
    // per scanline so the broken link is visible rather than guessed.
        logic [2:0] dl_st_prev = 3'd0;

    // Every CPU read of NMIST, with where the beam was: "the DLI bit was not
    // cleared at 248" is a claim about a VALUE AT A MOMENT, so both halves have
    // to be measured together.
    // Where does each machine cycle go across the WSYNC release at line 38?
    // Print the PC once per machine cycle so the instruction boundaries are
    // visible against the test's own cycle annotation.
    integer pccnt = 0;
    logic [15:0] pc_prev = 16'h0000;
    generate if (USE_ANTIC2) begin : g_pcprobe
        always_ff @(posedge clk) begin
            if (!rst && tick && pccnt < 40 && dbg_pc >= 16'h2200 &&
                dbg_pc <= 16'h2215 && !dut.u_antic2.wsync_take &&
                !dut.u_antic2.dma_steal) begin
                pccnt <= pccnt + 1;
                $display("PCT sl=%0d cyc=%0d pc=%04h halt=%0d steal=%0d",
                         dut.u_antic2.line, dut.u_antic2.hcount, dbg_pc,
                         dut.u_antic2.wsync_take, dut.u_antic2.dma_steal);
            end
        end
    end endgenerate

    // A bus trace in emu's ACID_BUSTRACE format: one line per CPU-serviced
    // cycle, sampled at SUB_DATA where the access actually happens.  Lets the
    // two designs be diffed cycle-for-cycle on the same scanline.
    integer bcnt = 0;
    int BUSLINE = 17;
    int MAPINSN = 'h42;
    initial if (!$value$plusargs("MAPINSN=%h", MAPINSN)) MAPINSN = 'h42;
    // OFF unless asked for.  A trace probe that runs by default is not free:
    // this one wrote 114 KB into every run of an unattended sweep, nobody having
    // requested a single line of it.  -1 matches no scanline.
    initial if (!$value$plusargs("BUSLINE=%d", BUSLINE)) BUSLINE = -1;
    generate if (USE_ANTIC2) begin : g_busprobe
        always_ff @(posedge clk) begin
            // Anchored on the EVENT, not on a scanline number: the same
            // scanline recurs every frame and the two designs are at different
            // program points on most of them.  This catches the origin_test
            // sled, the NMI vector fetch and the DLI handler wherever they land.
            // WHOLE SCANLINE, EVERY FRAME, so the sequence can be diffed
            // against emu's ACID_BUSTRACE for the same scanline from the FIRST
            // difference.  The cap must not truncate mid-run: a low cap showed
            // only the first frame and made two different frames look like a
            // disagreement.
            // PHYSICAL scanline, not the beam's: antic_beam advances `line` on
            // the edge from 110, so cycles 111..113 still belong to the line
            // before.  Without this the trace attributes them to the next
            // scanline and cannot be aligned with emu's, which does not.
            // GATED ON c_rdy AS WELL AS SUB_DATA.  The core can SIT in SUB_DATA
            // while stalled -- xt6502f advances only on `slot_commit && rdy` --
            // so SUB_DATA alone reports cycles the CPU never completed, and a
            // DMA-stolen cycle looks like a CPU access.  A probe is a DUT too.
            if (!rst && bcnt < 4000 && bus_line == 9'(BUSLINE) &&
                dut.c_rdy && dut.c_sub == 8'(dut.SUB_DATA)) begin
                bcnt <= bcnt + 1;
                $display("BUS sl %0d cyc %0d %s $%04h", bus_line,
                         dut.u_antic2.hcount, dut.c_rw ? "CPU-R" : "CPU-W",
                         dut.c_addr);
            end
        end
    end endgenerate

    // The NMI ARM path, cycle by cycle, on the scanline under test: the DLI can
    // be armed by the STATUS set (arm=1) or by a NMIEN write in the same cycle
    // (arm=2), and the two deliver one cycle apart.
    integer acnt = 0;
    generate if (USE_ANTIC2) begin : g_armprobe
        always_ff @(posedge clk) begin
            // Gated on NMIEN being enabled: the early frames run with NMIEN=0
            // and would eat the whole event budget before the DLI phase starts.
            if (!rst && tick && acnt < 42 && bus_line == 9'(BUSLINE) &&
                dut.u_antic2.nmien != 8'h00 && dut.u_antic2.hcount <= 7'd20) begin
                acnt <= acnt + 1;
                $display("ARM cyc=%0d dli=%0d nmist=%02h nmien=%02h arm=%0d nmi=%0d setnow=%0d",
                         dut.u_antic2.hcount, dut.u_antic2.dli_line,
                         dut.u_antic2.nmist, dut.u_antic2.nmien,
                         dut.u_antic2.u_seq.nmi_arm, dut.u_antic2.nmi,
                         dut.u_antic2.u_seq.nmist_set_now);
            end
        end
    end endgenerate

    // POKEY's RANDOM plumbing: what the LFSR holds, what SKCTL holds, and what
    // the CPU actually gets back from $D20A.  antic_dmapattern reads $FF for
    // both halves of its LFSR pair on BOTH ANTIC paths, so the fault is here,
    // not in the DMA map.
    // Every POKEY register WRITE that actually reaches the register file.
    integer pwcnt = 0;
    always_ff @(posedge clk) begin
        if (!rst && pwcnt < 16 && dut.u_pokey.we) begin
            pwcnt <= pwcnt + 1;
            $display("PWR waddr=%02h wdata=%02h", dut.u_pokey.waddr,
                     dut.u_pokey.wdata);
        end
    end

    // ...and every CPU write into the $D2xx page, whether or not POKEY took it.
    integer cwcnt = 0;
    always_ff @(posedge clk) begin
        if (!rst && cwcnt < 16 && !dut.c_rw && dut.cs_pokey &&
            dut.c_sub == 8'(dut.SUB_DATA)) begin
            cwcnt <= cwcnt + 1;
            $display("CWR addr=%04h data=%02h rdy=%0d cpu_we=%0d",
                     dut.c_addr, dut.c_dout, dut.c_rdy, dut.cpu_we);
        end
    end

    // THE STAGE-2 MAP, in emu's ACID_GLYPHPROBE=9 shape: one character per
    // machine cycle, '#' where ANTIC steals it.  Printed at the END of the line
    // so a mid-line DMACTL or HSCROL rebuild is reflected, which is what emu's
    // own END map does -- a map captured at line_start shows only what was
    // planned at cycle 0.
    logic [113:0] steal_map;
    integer mpcnt = 0;
    generate if (USE_ANTIC2) begin : g_mapprobe
        always_ff @(posedge clk) begin
            if (rst) steal_map <= '0;
            else if (tick) begin
                if (dut.u_antic2.hcount == 7'd0) steal_map <= '0;
                else if (dut.u_antic2.dma_steal)
                    steal_map[dut.u_antic2.hcount] <= 1'b1;
                // ANCHORED ON THE INSTRUCTION, not a scanline number: the same
                // scanline recurs every frame and the first hits would be from
                // before the test even sets this mode up.  MAPINSN selects the
                // display-list instruction whose map is wanted.
                if (dut.u_antic2.hcount == 7'd113 && mpcnt < 4 &&
                    dut.u_antic2.dl_insn == 8'(MAPINSN)) begin
                    mpcnt <= mpcnt + 1;
                    $write("MAP sl %0d insn %02h ", bus_line, dut.u_antic2.dl_insn);
                    for (int k = 0; k < 114; k++)
                        $write("%s", steal_map[k] ? "#" : ".");
                    $display("");
                end
            end
        end
    end endgenerate

    // WHEN does dl_insn settle, relative to the machine cycle?  antic_dma_sched
    // latches the whole line shape on the line_start pulse, so if the new
    // instruction lands after that, the map is built from the PREVIOUS one.
    // Printed with the fabric-clock offset within the machine cycle.
    logic [7:0] insn_prev;
    integer icnt = 0;
    integer subclk = 0;
    generate if (USE_ANTIC2) begin : g_insnprobe
        always_ff @(posedge clk) begin
            if (rst) begin insn_prev <= 8'h00; subclk <= 0; end
            else begin
                subclk <= tick ? 0 : subclk + 1;
                if (dut.u_antic2.dl_insn !== insn_prev && icnt < 10) begin
                    icnt <= icnt + 1;
                    $display("INSN hcount=%0d subclk=%0d %02h -> %02h line_start=%0d",
                             dut.u_antic2.hcount, subclk, insn_prev,
                             dut.u_antic2.dl_insn, dut.u_antic2.u_line.line_start);
                end
                insn_prev <= dut.u_antic2.dl_insn;
            end
        end
    end endgenerate

    integer rncnt = 0;
    always_ff @(posedge clk) begin
        if (!rst && rncnt < 12 && dut.c_rw && dut.c_addr == 16'hD20A &&
            dut.c_sub == 8'(dut.SUB_DATA)) begin
            rncnt <= rncnt + 1;
            $display("RND skctl=%02h random_byte=%02h cpu_sees=%02h",
                     dut.u_pokey.skctl_out, dut.u_pokey.random_byte, dut.c_din);
        end
    end

    integer nmcnt = 0;
    logic [7:0] vc_prev = 8'h00;
    integer vccnt = 0;
    generate if (USE_ANTIC2) begin : g_nmprobe
        always_ff @(posedge clk) begin
            if (!rst && nmcnt < 60 &&
                dut.cs_antic && dut.c_rw && dut.c_addr[3:0] == 4'hF &&
                dut.c_sub == 8'(dut.SUB_DATA)) begin
                nmcnt <= nmcnt + 1;
                $display("NMR pc=%04h sl=%0d cyc=%0d rd=%02h nmist=%02h dli=%0d insn=%02h",
                         dbg_pc, dut.u_antic2.line, dut.u_antic2.hcount, dut.c_din,
                         dut.u_antic2.nmist, dut.u_antic2.dli_line,
                         dut.u_antic2.dl_insn);
            end
        end
    end endgenerate

    // WHEN does VCOUNT change, and where is the beam?  emu advances it at cycle
    // 111 of every ODD scanline, so the new value is visible for the last few
    // cycles of that line -- a poll can legitimately catch it there.
    // VCOUNT against its DEFINITION, sampled at hcount 50 -- before the cycle-111
    // advance, so the correct value is exactly line>>1 on EVERY line of EVERY
    // frame.  Printing only MISMATCHES answers "does the drift accumulate?"
    // without drowning in 262 lines a frame.
    // Where does the beam's `line` actually change, and what does antic2_seq see
    // at cycle 111?  The two have to be read at the SAME instant.
    logic [8:0] ln_prev = 9'd0;
    integer lncnt = 0;
    generate if (USE_ANTIC2) begin : g_lnprobe
        always_ff @(posedge clk) begin
            if (!rst && tick) begin
                if (dut.u_antic2.line !== ln_prev && lncnt < 6) begin
                    lncnt <= lncnt + 1;
                    $display("LN change at hcount=%0d : %0d -> %0d",
                             dut.u_antic2.hcount, ln_prev, dut.u_antic2.line);
                end
                if (dut.u_antic2.hcount == 7'd111 && lncnt < 12 && lncnt >= 6) begin
                    lncnt <= lncnt + 1;
                    $display("LN at cyc111: line=%0d odd=%0d vcount=%02h",
                             dut.u_antic2.line, dut.u_antic2.line[0],
                             dut.u_antic2.vcount);
                end
                ln_prev <= dut.u_antic2.line;
            end
        end
    end endgenerate

    integer vdcnt = 0;
    integer vdframe = 0;
    generate if (USE_ANTIC2) begin : g_vdprobe
        always_ff @(posedge clk) begin
            if (!rst && tick && dut.u_antic2.hcount == 7'd50) begin
                if (dut.u_antic2.line == 9'd0) vdframe <= vdframe + 1;
                if (dut.u_antic2.vcount !== 8'(dut.u_antic2.line >> 1) &&
                    vdcnt < 24) begin
                    vdcnt <= vdcnt + 1;
                    $display("VD frame=%0d sl=%0d vcount=%02h expected=%02h",
                             vdframe, dut.u_antic2.line, dut.u_antic2.vcount,
                             8'(dut.u_antic2.line >> 1));
                end
            end
        end
    end endgenerate

    // Every WSYNC write and every release, with the PC: "the read landed a line
    // early" is a claim about the STALL, so measure the stall itself.
    integer wscnt = 0;
    generate if (USE_ANTIC2) begin : g_wsprobe
        always_ff @(posedge clk) begin
            if (!rst && wscnt < 24 && dut.u_antic2.line >= 9'd14 &&
                dut.u_antic2.line <= 9'd24) begin
                if (dut.u_antic2.u_regs.wsync_stb) begin
                    wscnt <= wscnt + 1;
                    $display("WS ARM pc=%04h sl=%0d cyc=%0d",
                             dbg_pc, dut.u_antic2.line, dut.u_antic2.hcount);
                end
                if (dut.u_antic2.u_seq.wsync_halt && tick &&
                    dut.u_antic2.hcount == dut.u_antic2.u_seq.wsync_release) begin
                    wscnt <= wscnt + 1;
                    $display("WS REL pc=%04h sl=%0d cyc=%0d extra=%0d",
                             dbg_pc, dut.u_antic2.line, dut.u_antic2.hcount,
                             dut.u_antic2.u_seq.wsync_extra);
                end
            end
        end
    end endgenerate

    generate if (USE_ANTIC2) begin : g_vcprobe
        always_ff @(posedge clk) begin
            if (!rst && tick && dut.u_antic2.vcount !== vc_prev &&
                dut.u_antic2.line >= 9'd240 && vccnt < 12) begin
                vccnt <= vccnt + 1;
                $display("VC sl=%0d cyc=%0d vcount %02h -> %02h",
                         dut.u_antic2.line, dut.u_antic2.hcount,
                         vc_prev, dut.u_antic2.vcount);
            end
            if (tick) vc_prev <= dut.u_antic2.vcount;
        end
    end endgenerate

    generate if (USE_ANTIC2) begin : g_dlprobe
        // The DL executor's own state machine.  Print on every state change and
        // on every DLIST write, so "no instruction is ever latched" resolves to
        // WHICH step stops: the request, the memory answer, or the decode.
        integer dlcnt = 0;
        // cap raised AGAIN: 400 events run out inside frame 1, so the histogram
        // only ever showed the display list the loader leaves behind -- the
        // test's own DL is not installed until frame 2.  A probe's budget has to
        // reach the interesting part.
        always_ff @(posedge clk) begin
            if (!rst && dlcnt < 20000) begin
                if (dut.u_antic2.u_regs.dlist_lo_stb ||
                    dut.u_antic2.u_regs.dlist_hi_stb) begin
                    dlcnt <= dlcnt + 1;
                    $display("DLW lo=%0d hi=%0d val=%02h dl_addr=%04h",
                             dut.u_antic2.u_regs.dlist_lo_stb,
                             dut.u_antic2.u_regs.dlist_hi_stb,
                             dut.u_antic2.u_regs.dlist_val,
                             dut.u_antic2.u_dl.dl_addr);
                end
                if (dut.u_antic2.u_line.line_start &&
                    dut.u_antic2.dmactl != 8'h00) begin
                    dlcnt <= dlcnt + 1;
                    $display("DLL sl=%0d dmactl=%02h insn=%02h dldone=%0d rowends=%0d rowline=%0d fetch=%0d",
                             dut.u_antic2.line, dut.u_antic2.dmactl,
                             dut.u_antic2.dl_insn,
                             dut.u_antic2.dl_done, dut.u_antic2.row_ends,
                             dut.u_antic2.row_line, dut.u_antic2.dl_fetch_req);
                end
                if (dut.u_antic2.u_dl.st !== dl_st_prev) begin
                    dlcnt <= dlcnt + 1;
                    $display("DLS st=%0d req=%0d addr=%04h valid=%0d data=%02h exec=%0d insn=%02h",
                             dut.u_antic2.u_dl.st, dut.u_antic2.mem_req,
                             dut.u_antic2.mem_addr, dut.u_antic2.mem_valid,
                             dut.u_antic2.mem_data, dut.u_antic2.dl_fetch_req,
                             dut.u_antic2.dl_insn);
                end
            end
            dl_st_prev <= dut.u_antic2.u_dl.st;
        end
    end endgenerate

    generate if (USE_ANTIC2) begin : g_dliprobe
        always_ff @(posedge clk) begin
            if (probe_on && tick && !rst && (hcount == 7'd8) && (line >= 9'd30) && (line < 9'd50))
                $display("DLI sl=%0d insn=%02h row_line=%0d row_last=%0d rowends=%0d dli=%0d nmist=%02h nmien=%02h",
                         line, dut.u_antic2.dl_insn, dut.u_antic2.row_line,
                         dut.u_antic2.row_last, dut.u_antic2.row_ends,
                         dut.u_antic2.dli_line, dut.u_antic2.nmist,
                         dut.u_antic2.nmien);
        end
    end endgenerate

    // Stall LENGTH: machine cycles the CPU is held (c_rdy low) per WSYNC.
    // Trigger semantics, stated because three probes tonight were misread:
    // counts `tick`s where c_rdy is LOW, reset when /RDY comes back.  That is a
    // COUNT of held cycles, independent of the hcount sampling offset.
    int stall_len;
    reg rdy_n_d;
    reg awaiting_resume;
    always_ff @(posedge clk) begin
        if (rst) begin
            rdy_n_d <= 1'b0; awaiting_resume <= 1'b0;
        end else if (tick) begin
            rdy_n_d <= rdy_n;
            stall_len <= dut.c_rdy ? 0 : stall_len + 1;
            if (rdy_n_d && !rdy_n) begin              // /RDY just came back
                if (probe_on)
                    $display("PROBE-RDY    released, hcount=%0d line=%0d stall_cycles=%0d",
                             hcount, line, stall_len);
                awaiting_resume <= 1'b1;
            end else if (awaiting_resume && dut.c_rdy) begin
                // The first cycle the CPU is actually RUNNING -- gated on c_rdy,
                // NOT on `sync`.  Gating on sync reports the first OPCODE FETCH,
                // which lands after whatever remained of the stalled instruction
                // plus the whole next one, so it measures instruction length as
                // much as resume latency.
                if (probe_on)
                    $display("PROBE-RESUME running, hcount=%0d line=%0d pc=%04h sync=%0d",
                             hcount, line, dbg_pc, sync);
                awaiting_resume <= 1'b0;
            end
        end
    end

    a8_core #(.USE_ANTIC2(USE_ANTIC2)) dut (
        .clk(clk), .rst(rst), .cold(cold),
        .tick(tick), .px_tick(px_tick), .tune(tune_v),
        .cpu_addr(cpu_addr), .cpu_wdata(cpu_wdata), .cpu_we(cpu_we),
        .cpu_rdata(cpu_rdata),
        .antic_addr(antic_addr), .antic_rdata(antic_rdata),
        .irq_n(1'b1),
        .trig0(8'h01), .trig1(8'h01), .trig2(8'h01), .trig3(8'h01),
        .pal_sense(8'h0F), .consol_keys(8'hFF),
        .lb_wr(lb_wr), .lb_color(lb_color), .lb_line_start(lb_line_start),
        .dma_steal(dma_steal), .rdy_n(rdy_n), .nmi_n(nmi_n), .sync(sync),
        .dbg_pc(dbg_pc), .dbg_a(dbg_a), .dbg_x(dbg_x), .dbg_y(dbg_y),
        .dbg_s(dbg_s), .dbg_p(dbg_p),
        .hcount(hcount), .line(line)
    );

    logic [7:0] mem [0:65535];
    // FOUR entries: _testEnd, _testPassed, _testFailed, _testSkipped.  Sized to
    // match acid2mem's output -- an array a slot short does not fail loudly, it
    // just reads x, and an x compares equal to nothing, so the verdict it holds
    // is silently never recognised.
    logic [15:0] cfg [0:3];

    // $D000-$D0FF and $D400-$D4FF are answered inside a8_core; anything else in
    // the hardware page reads as an unpopulated bus.
    wire in_hw   = (cpu_addr[15:8] >= 8'hD0) && (cpu_addr[15:8] <= 8'hD7);
    wire is_chip = (cpu_addr[15:8] == 8'hD0) || (cpu_addr[15:8] == 8'hD2)
                || (cpu_addr[15:8] == 8'hD4);   // POKEY is real now, not $FF

    always_ff @(posedge clk) begin
        if (cpu_we && !in_hw) mem[cpu_addr] <= cpu_wdata;
        cpu_rdata   <= (in_hw && !is_chip) ? 8'hFF : mem[cpu_addr];
        antic_rdata <= mem[antic_addr];
    end

    logic [15:0] test_end, t_pass, t_fail, t_skip;
    logic        verdict_fail, verdict_skip, verdict_ran;
    logic [7:0]  fail_sp;
    int          guard;
    // Cycle budget before the harness gives up.  antic_dmapattern walks 50 maps
    // by 7 offsets and needs far more than the rest, so the limit is
    // overridable with +GUARD=<n> rather than being raised for everything --
    // a bigger default makes every genuine hang take proportionally longer to
    // report.
    int          guard_limit;
    initial if (!$value$plusargs("GUARD=%d", guard_limit))
        guard_limit = 200_000_000;
    logic        done;

    // Progress, so a hang is distinguishable from a slow test.  Without this a
    // stuck run and a long one look identical from outside.
    wire frame_top = tick && (hcount == 7'd0) && (line == 9'd0);

    // Trap the moment the CPU leaves the loaded image: that tells a framework
    // dependency (a jump into OS ROM) apart from a bug in the design under test
    // (a jump into nowhere).
    logic [15:0] pc_d;
    int          traps;
    always_ff @(posedge clk) begin
        if (rst) begin
            pc_d <= 16'h0700; traps <= 0;
        end else if (sync && tick) begin
            pc_d <= dbg_pc;
            // $FF00-$FFFF is the harness's own stub page (NMI/IRQ dispatcher,
            // RTCLOK ticker, the _vputchar RTS sink). Jumping there is CORRECT
            // and reporting it drowns the real derail -- the sink alone fires on
            // every character the suite prints.
            if (traps < 12 &&
                (dbg_pc < 16'h0700 || dbg_pc > 16'h3FFF) &&
                (dbg_pc < 16'hFF00) &&
                (pc_d  >= 16'h0700 && pc_d  <= 16'h3FFF)) begin
                $display("  [left the image] $%04h -> $%04h  a=$%02h x=$%02h y=$%02h s=$%02h",
                         pc_d, dbg_pc, dbg_a, dbg_x, dbg_y, dbg_s);
                traps <= traps + 1;
            end
        end
    end

    // ---- PC ring, dumped at the first FATAL derail ------------------------
    //
    // "It ended up at $00CA" says nothing; the TRAIL that got it there says
    // everything -- the software harness (emu/test/acid.c, PC_RING 64) was built
    // for exactly this and it is what turned three ACID mysteries into one-line
    // fixes. A PC below $0200 is the fatal signature: zero page and the stack
    // are full of zeros, every $00 is a BRK, and the CPU walks upward until it
    // hits a $02 and jams. Print once, then stop.
    localparam int PC_RING = 64;
    logic [15:0] ring [0:PC_RING-1];
    int          rn;
    int          derail_shown;
    always_ff @(posedge clk) begin
        if (rst) begin
            rn <= 0; derail_shown <= 0;
        end else if (sync && tick) begin
            ring[rn % PC_RING] <= dbg_pc;
            rn <= rn + 1;
            if (!derail_shown && dbg_pc < 16'h0200 && rn > PC_RING) begin
                derail_shown <= 1;
                $display("  *** DERAIL into $%04h after %0d instructions.  a=$%02h x=$%02h y=$%02h s=$%02h  trail (oldest first):", dbg_pc, rn, dbg_a, dbg_x, dbg_y, dbg_s);
                for (int k = 0; k < PC_RING; k++)
                    $write(" %04h", ring[(rn + k) % PC_RING]);
                $write("\n");
            end
        end
    end

    int frames;
    always_ff @(posedge clk) begin
        if (rst) frames <= 0;
        else if (frame_top) begin
            frames <= frames + 1;
            if (frames % 20 == 0)
                $display("  [frame %0d] pc=$%04h a=$%02h x=$%02h y=$%02h",
                         frames, dbg_pc, dbg_a, dbg_x, dbg_y);
        end
    end

    // TESTNAME as a RUNTIME plusarg, not a compile-time -D: as a define, `make`
    // does not rebuild when it changes, so a sweep silently re-runs the previous
    // test -- and every test paid a full iverilog rebuild of ~25 RTL files.
    // One compile now serves all 63, which is what makes a full sweep practical.
    reg [8*40-1:0] tname;
    initial begin
        if (!$value$plusargs("TEST=%s", tname)) tname = "acid";
        // TUNE likewise a RUNTIME plusarg, and read HERE so it is stable before
        // reset is released a few lines below.
        if (!$value$plusargs("TUNE=%d", tune_v)) tune_v = 16'd0;
        if (!$value$plusargs("PROBE=%d", probe_on)) probe_on = 1'b0;
        $readmemh("acid.mem", mem);
        $readmemh("acid_cfg.mem", cfg);
        test_end  = cfg[0];
        t_pass    = cfg[1];
        t_fail    = cfg[2];
        t_skip    = cfg[3];
        done = 1'b0; verdict_fail = 1'b0;
        verdict_skip = 1'b0; verdict_ran = 1'b0;

        repeat (4) @(posedge clk);
        rst = 0;

        // The framework waits several frames; give it plenty and fail loudly
        // rather than hanging if it never reaches the end.
        // ~30 frames is generous: the framework waits a handful.
        guard = 0;
        while (!done && guard < guard_limit) begin
            @(posedge clk);
            guard++;
            // Score as the model does: the ADDRESS is the verdict.  Reaching
            // _testPassed or _testFailed is unambiguous and lands earlier than
            // _testEnd, which programs a POKEY timer and spins on IRQST.
            if (sync && tick && (dbg_pc == t_pass)) begin
                done = 1'b1; verdict_fail = 1'b0;
            end else if (sync && tick && (dbg_pc == t_fail)) begin
                done = 1'b1; verdict_fail = 1'b1;
                // The stack pointer AT THE MOMENT OF ENTRY, which is the only
                // moment it points at the caller's return address -- see the
                // message reconstruction below.
                fail_sp = dbg_s;
            // A test that finds its hardware absent signals _testSkipped and
            // parks -- cpu_65c816 does it 35 cycles in.  Watching only pass and
            // fail runs a deliberate skip all the way to the guard and then
            // calls it a TIMEOUT, which is both wrong and slow.
            end else if (sync && tick && (t_skip != 16'h0000) &&
                         (dbg_pc == t_skip)) begin
                done = 1'b1; verdict_skip = 1'b1;
            // ...and a test can reach _testEnd having asserted nothing at all.
            // The model calls that "ran": a real outcome, distinct from a
            // verdict AND from a hang.  Checked last, because pass and fail
            // both land earlier and must win.
            end else if (sync && tick && (dbg_pc == test_end)) begin
                done = 1'b1; verdict_ran = 1'b1;
            // ...and a module can simply RETURN.  DOS calls RUNAD with JSR, so
            // a module that finishes its work does a plain `rts` and lands on
            // the loader's park -- $FF60 here, installed as _exitTest.  That is
            // an ORDINARY ENDING, not a hang: the model classifies it as "ran"
            // on exactly this condition (`pc == 0xFF70` -> R_RET,
            // emu/test/acid.c:540), and all three mod_* tests end this way.
            //
            // Without this the run is CORRECT but mislabelled -- the module
            // parks quietly and the harness still grinds out the full 200M
            // guard before calling a clean return a TIMEOUT, at about ninety
            // minutes each.
            //
            // Checked LAST on purpose.  _testFailed itself exits through
            // _exitTest, so a failing test reaches the park too; pass, fail and
            // skip all land earlier in this chain and must win.
            end else if (sync && tick && (dbg_pc == 16'hFF60)) begin
                done = 1'b1; verdict_ran = 1'b1;
            end
        end

        if (!done) begin
            $display("ACID %0s: TIMEOUT (pc $%04h, never reached _testEnd $%04h)",
                     tname, dbg_pc, test_end);
            // The PC trail out of a TIMEOUT, printed unconditionally rather
            // than under +PROBE=1.  A timeout is the one verdict that carries
            // no information of its own -- a single PC says "spinning", but not
            // spinning WHERE -- and it is usually met in a long unattended
            // sweep that nobody thought to pass +PROBE=1 to.  Sixteen fetches
            // is enough to show the shape of the loop it is stuck in, and it
            // costs one line on a path that has already given up.
            $write("  PC trail at TIMEOUT:");
            for (int k = 16; k > 0; k--)
                $write(" %04h", ring[(rn - k) % PC_RING]);
            $write("\n");
            $display("tb_acid: 1 FAIL");
        end else if (verdict_skip) begin
            // Not a failure and not a pass: the test declined to run.
            $display("ACID %0s: SKIP (reached _testSkipped $%04h)", tname, t_skip);
            $display("tb_acid: skipped");
        end else if (verdict_ran) begin
            // Reached the end having asserted nothing.  Reported plainly rather
            // than dressed up as either verdict.
            // Distinguish the two ways of ending without a verdict: reaching
            // _testEnd having asserted nothing, and simply returning to the
            // loader.  Both are "ran"; they are not the same event.
            if (dbg_pc == 16'hFF60)
                $display("ACID %0s: RAN (returned to the loader park $FF60)",
                         tname);
            else
                $display("ACID %0s: RAN (reached _testEnd $%04h, no verdict)",
                         tname, test_end);
            $display("tb_acid: no verdict");
        end else if (!verdict_fail) begin
            $display("ACID %0s: PASS", tname);
            $display("tb_acid: all checks PASS");
        end else begin
            $display("ACID %0s: FAIL (reached _testFailed $%04h)", tname, t_fail);
            // WHICH assertion failed, in the test's own words.
            //
            // ACID's _ASSERT macros put the message INLINE, immediately after
            // the `jsr _testFailed` -- so the return address on the stack is a
            // pointer to the text, minus one.  Sixteen tests can share one
            // `d1=0f` and mean sixteen different things; the string does not.
            // Reconstructing it here turns every FAIL into a sentence and costs
            // nothing but the stack pointer captured at entry.
            begin
                logic [15:0] msg;
                int          n;
                msg = {mem[16'h0102 + 16'(fail_sp)],
                       mem[16'h0101 + 16'(fail_sp)]} + 16'd1;
                $write("  said: \"");
                n = 0;
                while (mem[msg + 16'(n)] != 8'h00 && n < 96) begin
                    $write("%c", mem[msg + 16'(n)]);
                    n++;
                end
                $write("\"\n");
            end
            $display("tb_acid: 1 FAIL");
            // The PC trail INTO _testFailed.  The ring was only dumped on a
            // derail, but a test that fails cleanly never derails -- so the one
            // question that matters ("which assert, and how far did it get?")
            // had no answer.  Print the last 16 fetches under +PROBE=1.
            if (probe_on) begin
                $write("  PC trail into _testFailed:");
                for (int k = 16; k > 0; k--)
                    $write(" %04h", ring[(rn - k) % PC_RING]);
                $write("\n");
            end
        end
        // The result bytes, on EVERY path.  Without these a tune sweep prints
        // 16 identical verdict lines and a flat-looking result is indis-
        // tinguishable from an instrument that never reported anything.
        // NB d1 is CLOBBERED when assert #1 fails: _ASSERT1 does `sta d1`
        // before `jsr _testFailed`, so it holds a copy of the bad d0.
        // SIX, not four.  gtia_pmoverlap's message is "Pass %d.%d: Pos=%x,
        // Expected %x, Got %x" and the two that say what actually went wrong
        // are d4 and d5 -- stopping at d3 reports only WHERE it failed.
        // EIGHT, not six.  antic_charcontrol builds its EXPECTED value at run
        // time (testres is filled from the collision registers) and reports it
        // in d6 -- without it the got value alone says nothing about what the
        // glyph should have collided with.
        $display("ACID %0s: d0=%02h d1=%02h d2=%02h d3=%02h d4=%02h d5=%02h d6=%02h d7=%02h",
                 tname, mem[16'h00C8], mem[16'h00C9], mem[16'h00CA], mem[16'h00CB],
                 mem[16'h00CC], mem[16'h00CD], mem[16'h00CE], mem[16'h00CF]);
        $finish;
    end

endmodule

`default_nettype wire
