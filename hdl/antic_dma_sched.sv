`default_nettype none
//
// antic_dma_sched — which machine cycles ANTIC takes from the CPU.
//
// docs/ANTIC-rewrite.md step 7, and docs/antic-dma-maps.md for the evidence.
// This is the bus-master behaviour the whole rewrite is premised on: ANTIC does
// not merely draw, it gates the CPU clock.  `steal` here becomes /HALT to the
// core, so getting it wrong makes every cycle-timing test wrong regardless of
// how correct the picture is.
//
// THE SCHEDULE, all of it verified against antic_dmapattern's own expected
// masks, decoded out of the test binary: all 50 of its maps are reproduced
// exactly, across every display mode, both playfield widths, and first and
// later scanlines.
//
// FIXED SLOTS at the head of every scanline:
//     0      missile DMA
//     1      display list instruction   } first scanline of a mode line only
//     2-5    player DMA                 }
//     6-7    the LMS operands           } first scanline, and only with LMS
//
// PLAYFIELD SLOTS from `dma_start`, one every `step` machine cycles.  The step
// comes in from antic_pf_geom rather than being derived here: it is
// span/bytes_per_line, but computing that as a division synthesises a divider
// -- 22 carry chains and a 17 ns path off the mode register, which was the
// whole of a -9.7 ns clk_sys violation.  It is a shift, and pf_geom already
// has the shift amount.
//
//                first scanline                     later scanlines
//   bitmap       one per byte, step apart            NOTHING — read once,
//                                                    replayed from the buffer
//   character    a name, then (glyph, next name)     one glyph per byte,
//                pairs step apart, then the last     step apart
//                glyph
//
// REFRESH is nine requests at cycles 25, 29 ... 57.  The playfield has absolute
// priority; a blocked request slips forward to the next free cycle; and one
// still seeking when the NEXT request arrives is dropped.  That last part is
// why a single pending bit is the whole implementation — a new request simply
// overwrites the old one.
//
// The rule is worth stating because it looks lossy and is not: on a narrow
// character first row the playfield is solid from 26 to 90, and exactly two
// refreshes survive — the one at 25 before it starts, and one that finally
// lands at 91 after it ends.  That falls out; nothing is special-cased.
//
// (Whether the playfield wins and refresh slips, or refresh wins and the
// playfield slips, cannot be told apart from the maps: wherever one collision
// is involved the same pair of cycles ends up used either way.  It makes no
// difference to which cycles are stolen, which is all this module answers.)
//
// THE CHARACTER FIRST-ROW PHASE FOLLOWS THE STEP.  On a character first row the
// fetch pairs begin at dma_start + step/2 + 1.  This looked like a free constant
// at first — modes 2/3/4/5 want 2 and modes 6/7 want 3 — until it became clear
// those are exactly the character modes with step 2 and step 4.
//
// Two data points would normally be a poor basis for a formula.  Here it is not
// an extrapolation but complete coverage: character modes are 2, 3, 4, 5, 6 and
// 7, they pack either 8 or 16 hi-res pixels per byte, and so step is either 2 or
// 4 and never anything else.  Both cases are pinned by the hardware's own maps
// and the module reproduces all 50 of them.  There is no third case to be wrong
// about.
//
// CLOCK BUDGET: one comparator chain per machine cycle, and it only has to be
// right once every 114 of them.  There is no per-pixel work here at all.
//
`timescale 1ns/1ps

module antic_dma_sched (
    input  wire       clk,
    input  wire       rst,

    input  wire       line_start,
    input  wire       tick,                 // 1-clk per machine cycle
    input  wire [6:0] hcount,

    // ---- this scanline's shape, stable across the line -------------------
    input  wire       first_row,
    input  wire       is_char,
    input  wire       is_display,
    input  wire [7:0] bytes_per_line,
    input  wire [6:0] dma_start,
    // One past the last fetch cycle.  ANTIC's clock CLEARS at this cycle's
    // phase, and when HSCROL has moved the stop off the phase the start
    // injected, the clear removes nothing and the fetch runs on.
    input  wire [6:0] dma_stop,
    input  wire [7:0] step,                 // machine cycles between fetches
    input  wire       lms,                  // the instruction carries operands

    // ---- live enables ----------------------------------------------------
    input  wire       dl_dma_en,            // DMACTL[5]
    input  wire       missile_dma_en,       // DMACTL[2]
    input  wire       player_dma_en,        // DMACTL[3]

    output wire       steal,                // this machine cycle is ANTIC's

    // ---- the playfield fetch, for whoever fills the line buffer -----------
    // The schedule ALREADY knows which cycles fetch and which of them is the
    // pair's glyph access; it just kept them to itself.  A fetcher driven by
    // these is progressive -- one byte per scheduled cycle, as emu's antic_tick
    // is -- rather than bursting the line at line_start.  That distinction is
    // not cosmetic: DMACTL and HSCROL can be written PART WAY DOWN a line, and
    // the bytes already fetched must stay fetched while the rest of the map is
    // rebuilt around them.  antic_hscrolbug, antic_pfstarttiming,
    // antic_pfstoptiming and antic_linebuffering all measure exactly that.
    //
    // Tick-aligned PULSES, unlike `steal`, which is deliberately a level (see
    // below) -- a fetch happens once, at the tick, and must not be counted
    // again for the rest of the machine cycle.
    output wire       pf_fetch,             // this tick fetches a playfield byte
    output wire       pf_fetch_glyph        // ...and it is the GLYPH of a pair
);

    // ---- the fixed slots -------------------------------------------------
    wire hdr_steal =
        (hcount == 7'd0  && missile_dma_en)                         ||
        (hcount == 7'd1  && dl_dma_en && first_row)                 ||
        (hcount >= 7'd2 && hcount <= 7'd5 && player_dma_en)         ||
        ((hcount == 7'd6 || hcount == 7'd7) && dl_dma_en && first_row && lms);

    // ---- the playfield walk ----------------------------------------------
    // How many fetches this scanline costs, and where the first one lands.
    wire       pairs   = is_char && first_row;

    // ---- THE DMA CLOCK ----------------------------------------------------
    // ANTIC does not walk a window.  It has an eight-bit clock with (normally)
    // a single bit flying round it, and a cycle fetches when the clock's bit
    // for that cycle's phase is set.  The window's START injects a bit at the
    // start's phase and its STOP clears one at the stop's phase.
    //
    // THAT ASYMMETRY IS THE WHOLE POINT.  The clear only removes the bit if the
    // stop lands on the SAME PHASE the start injected -- and the two edges
    // latch independently, so HSCROL can move the stop without moving the
    // start.  Then nothing is cleared, the bit keeps flying, and the playfield
    // fetches on through horizontal blank and into the next scanline.  That is
    // antic_hscrolbug: seventeen extra fetches, and the next line's display
    // shifted left by seventeen bytes.
    //
    // A WALK CANNOT EXPRESS THAT.  A walk stops because the loop stops; this
    // stops because a bit was cleared, or does not.
    //
    // THE CLOCK IS NOT RESET PER LINE.  Carrying it across the line boundary is
    // how a run-on reaches the next scanline at all.
    logic [7:0] pf_clock;

    // spec_clock[rate][phase], from emu/antic_dma.c: rate 1/2/3 fetch every
    // 8/4/2 cycles, which `step` states as 8/4/2.
    wire [1:0] rate = (step == 8'd8) ? 2'd1 : (step == 8'd4) ? 2'd2 : 2'd3;

    function automatic logic [7:0] clock_mask(input logic [1:0] r,
                                              input logic [2:0] ph);
        case (r)
            2'd1:    clock_mask = 8'h01 << ph;            // 01,02,04...80
            2'd2:    clock_mask = 8'h11 << ph[1:0];       // 11,22,44,88
            2'd3:    clock_mask = ph[0] ? 8'hAA : 8'h55;
            default: clock_mask = 8'h00;
        endcase
    endfunction

    // A row INJECTS only if it fetches at all: a bitmap row reads its bytes on
    // the first scanline only, a character row re-reads the data every line.
    // This gates the INJECTION and never the EMISSION -- gating the emission
    // throws away whatever was carried in, and kills a run-on the moment it
    // reaches a bitmap row's later scanline, which is exactly where
    // antic_hscrolbug's second unstopped case sends it.
    wire fetches = is_display && (is_char || first_row);

    // The injection and the clear both land in the cycle they name, and the
    // bit is tested AFTER them, so the effective clock is combinational.
    wire inject = (hcount == dma_start) && fetches;
    wire clear  = (hcount == dma_stop);
    wire [7:0] clk_eff =
        (pf_clock | (inject ? clock_mask(rate, dma_start[2:0]) : 8'h00))
        & ~(clear ? clock_mask(rate, dma_stop[2:0]) : 8'h00);

    wire hit_now = clk_eff[hcount[2:0]];

    // A character row's DATA is the same window shifted by three: the name is
    // read on the clock's cycle and the glyph three cycles later.  A later
    // character row re-reads only the glyph, so its single access is the
    // delayed one.  That is the whole of the pair logic -- the old
    // P_FIRST/P_PAIR_A/P_PAIR_B states were a walk's way of saying it.
    logic [2:0] hit_dly;
    wire        hit_3 = hit_dly[2];

    // `steal` is a LEVEL across the machine cycle, not a pulse at the tick.
    // The fid core is paced by phi2_tick and samples its rdy input at a commit
    // slot well inside the cycle, so a tick-aligned pulse is invisible to it and
    // the CPU loses nothing.  hcount and the walk state are both stable between
    // ticks, so the comparison is valid throughout the cycle either way.
    // The PRIMARY access -- the one that advances the buffer index.  A bitmap
    // row and a character row's first line take it on the clock's own cycle;
    // a later character row takes its glyph three cycles on, and antic_pf_stream
    // works out for itself that it is a glyph (its `fetch_is_glyph` ORs in
    // `is_char && !first_row`).
    wire pf_want   = is_char ? (first_row ? hit_now : hit_3) : hit_now;
    // ...and the GLYPH of a pair, which only a character first line has.
    wire pf_want_b = pairs && hit_3;

    wire pf_hit    = tick && pf_want;
    wire pf_hit_b  = tick && pf_want_b;

    // A FETCH IS NOT ALWAYS A STEAL.  Cycles from PF_HBLANK_FIRST on still
    // fetch -- that is what a run-on does -- but the CPU is not running there,
    // so they cost it nothing.  And cycle 0 never steals either: a fetch
    // landing there happens and clocks the line buffer, but takes no cycle.
    // Only abnormal DMA can put one there at all.
    localparam int PF_HBLANK_FIRST = 106;
    wire pf_fetching = pf_want || pf_want_b;
    wire pf_steal    = pf_fetching && (hcount != 7'd0) &&
                       (hcount < 7'(PF_HBLANK_FIRST));

    // ---- refresh ---------------------------------------------------------
    // Nine requests, four cycles apart.  A single pending bit IS the drop rule:
    // a new request overwrites one that is still seeking.
    logic [3:0] ref_left;
    logic [6:0] ref_slot;
    logic       ref_pending;

    wire ref_due   = (ref_left != 4'd0) && (hcount == ref_slot);
    wire ref_req   = tick && ref_due;
    wire ref_want  = ref_pending || ref_due;
    wire ref_steal = ref_want && !hdr_steal && !pf_steal;

    assign steal = hdr_steal || pf_steal || ref_steal;

    // Observation only -- these are the SAME pf_hit/pf_hit_b the walk already
    // runs on, so exposing them cannot move a single cycle of `steal`.  The
    // module's 50 ACID maps are the check on that.
    assign pf_fetch       = pf_hit || pf_hit_b;
    assign pf_fetch_glyph = pf_hit_b;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            pf_clock    <= 8'h00;
            hit_dly     <= 3'b000;
            ref_left    <= 4'd0;
            ref_slot    <= 7'd25;
            ref_pending <= 1'b0;
        end else begin
            // The clock and the pair delay advance once per machine cycle,
            // wherever the line boundary happens to fall -- the carry across
            // that boundary is the mechanism, not an edge case.
            if (tick) begin
                pf_clock <= clk_eff;
                hit_dly  <= {hit_dly[1:0], hit_now};
            end

            // THE PLAYFIELD LATCHES NOTHING AT line_start ANY MORE.  The walk
            // pinned the line's whole shape here -- byte count, first slot,
            // pairing -- which is precisely why a mid-line DMACTL or HSCROL
            // write could not move it, and why a run-on could not cross into
            // the next line.  The clock just keeps turning.  Only refresh has
            // per-line state.
            if (line_start) begin
                ref_left <= 4'd9;
                ref_slot <= 7'd25;
                ref_pending <= 1'b0;
            end else begin
                if (ref_req) begin
                    ref_slot <= ref_slot + 7'd4;
                    ref_left <= ref_left - 4'd1;
                end
                // A PREEMPTED REFRESH KEEPS SEEKING until it is taken: seeding
                // from ref_want re-tries every cycle, so all nine are
                // eventually charged.  REVERTED FROM `ref_due` (cb499ca), which
                // dropped a refresh after one cycle of deferral and FAILED 12
                // of the 50 ACID reference maps -- every one a first row, one
                // steal short at the end.  The same defect showed in situ as a
                // missing steal at cycle 91 of narrow mode 2.
                //
                // emu is the arbiter and it does not model contention at all:
                // antic_dma_refresh (emu/antic_dma.c:65) simply sets
                // blocked[c] = 1 for the nine cycles, and the playfield builder
                // writes into the same array -- a UNION, with no deferral and
                // no preemption.  emu passes antic_dmapattern that way.
                //
                // UNRESOLVED, AND DELIBERATELY LEFT SO: cb499ca cited a HARDWARE
                // measurement against this form (100-cycle span, screen on,
                // normal width -- legacy stole 45, `ref_due` stole 51).  That is
                // real evidence pointing the other way.  For ACID conformance
                // the reference maps and emu win, because they ARE the
                // specification the suite encodes; if the hardware figure was
                // sound then real ANTIC and the test's model genuinely differ,
                // which is a question about the hardware, not about this line.
                if (tick) ref_pending <= ref_want && !ref_steal;

            end
        end
    end

endmodule

`default_nettype wire
