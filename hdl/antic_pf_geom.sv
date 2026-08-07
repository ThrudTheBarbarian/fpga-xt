`default_nettype none
//
// antic_pf_geom — where the playfield starts, where it stops, how wide it is.
//
// docs/ANTIC-rewrite.md.  Three ACID tests share one mechanism:
//   antic_pfstarttiming — changing DMACTL mid-line moves where the playfield
//                         STARTS on that very line
//   antic_pfstoptiming  — ...and where it STOPS
//   antic_hscrolbug     — HSCROL shifts the start by half its value
// They are one module because they are one piece of hardware: a pair of
// comparators against the live registers.
//
// PURELY COMBINATIONAL, AND THAT IS THE POINT.  Nothing here is sampled once
// per row.  The consumer compares the beam's live cycle against these outputs
// every colour clock, so a DMACTL write partway along a scanline takes effect
// partway along that scanline.  The old burst renderer decided the whole row at
// one instant and could not express that at all — it is the single reason those
// three tests were unreachable.
//
// THE GEOMETRY, in machine cycles (2 colour clocks = 4 hi-res pixels each):
//
//   width    display starts   spans   ends    hi-res px
//   narrow        28            64      92       256
//   normal        20            80     100       320
//   wide          12            96     108       384
//
// All three are centred on cycle 60, which is the cross-check: a narrow
// playfield is inset by 8 machine cycles at BOTH ends, not just the left.
//
// CHARACTER MODES BEGIN THEIR DMA TWO CYCLES EARLY (26/18/10 rather than
// 28/20/12) because each character costs two fetches — the name, then the glyph
// — and the glyph has to be in hand at the same display cycle a bitmap byte
// would be.  Display start is common to both; only the fetch moves.  The
// 2-cycle split is precisely what antic_pfstarttiming measures.
//
// SCROLLING FETCHES WIDER THAN IT DISPLAYS.  With HSCROL enabled a narrow
// playfield fetches normal-width data and a normal one fetches wide, so there is
// something off the edge to scroll in.  Wide stays wide and simply runs out.
// The DISPLAY window does not widen — only the fetch does.
//
// AND THE FETCH WINDOW MOVES WITH IT, which is not a guess: antic_hscrolbug
// prints the DMA map for a scrolled NARROW mode E and it fetches at cycles
// 20, 22 ... 98 — forty fetches over the NORMAL window, not the narrow one.
// So dma_start/dma_stop follow the fetch width while disp_start/disp_stop
// follow the programmed width.  The same map puts the display list fetch at
// cycle 1 and nine refresh cycles at 25, 29 ... 57, which the DMA schedule
// module will need later.
//
// WHERE HSCROL PUTS THE PICTURE.  The scroll is one adder on the existing start
// comparator, not a "discard some of the middle" mechanism: with scrolling on,
// the display begins at the WIDER window's start plus HSCROL.  So HSCROL=0 sits
// 16 colour clocks right of the unscrolled position and HSCROL=15 brings it back
// to within half a colour clock of it, giving the full 16-colour-clock range the
// extra fetch pays for — and explaining why merely enabling the scroll bit moves
// the display.  One adder is the small answer; "display the middle 256 of the
// fetched 320" is not.  antic_hscrolbug is the arbiter.
//
// THE 320 INVARIANT ties this to the mode table and is the most useful
// cross-check in the whole design:
//     bytes_per_line * (8/bpp) * px_width == hi-res pixels
// for every one of the 14 display modes at every width.  Because (8/bpp) *
// px_width is always a power of two, the divide is a shift — no divider, which
// is the smell test passing.
//
// CLOCK BUDGET: two comparators and a shift, evaluated continuously.  There is
// no state here at all.
//
`timescale 1ns/1ps

module antic_pf_geom (
    // ---- live registers --------------------------------------------------
    input  wire [1:0] pf_width,        // DMACTL[1:0]: 0 off, 1 narrow, 2 normal, 3 wide
    input  wire       hscrol_en,       // this mode line's HSCROL bit
    input  wire [3:0] hscrol,          // $D404

    // ---- the mode's shape, from antic_mode_tbl --------------------------
    input  wire       is_char,
    input  wire [1:0] bpp,
    input  wire [3:0] px_width,

    // ---- geometry --------------------------------------------------------
    output wire       pf_on,           // DMACTL width is non-zero
    output logic [7:0] bytes_per_line,
    output logic [7:0] pf_step,        // machine cycles between fetches
    output logic [6:0] dma_start,      // first machine cycle of playfield DMA
    output logic [6:0] dma_stop,       // one past the last fetch cycle
    output logic [6:0] disp_start,     // first machine cycle displayed, unscrolled
    output logic [6:0] disp_stop,      // one past the last displayed
    output logic [8:0] px_start,       // first hi-res pixel displayed, HSCROL applied
    output logic [8:0] px_stop,        // one past the last
    output wire  [2:0] hs_delay,       // HSCROL in whole machine cycles
    output wire        hs_fine         // ...and the odd colour clock
);

    assign pf_on = (pf_width != 2'd0);

    // A DMACTL WIDTH OF ZERO IS NOT A WIDTH -- IT IS NO PLAYFIELD DMA AT ALL.
    // emu's width_of() (antic.c:524) maps DMACTL[1:0] == 0 to NORMAL, and
    // suppresses the FETCH separately: "the fetch map has to be dropped
    // explicitly or a screen with playfield DMA off would quietly fetch a
    // normal row".  Collapsing the geometry to zero instead takes the DISPLAY
    // window with it, and then a line whose playfield DMA is off paints
    // nothing -- when what ANTIC really does is re-display the line buffer it
    // was not allowed to refill.  That is antic_linebuffering's whole "aliased"
    // family: turn DMA off, let a row start under it, and check the stale
    // buffer still reaches the screen.  pf_on below keeps the fetch off; this
    // only decides where the beam paints.
    wire [1:0] eff_width = (pf_width == 2'd0) ? 2'd2 : pf_width;

    // HSCROL is in colour clocks; a machine cycle is two of them.  The odd bit
    // is a one-colour-clock shift the pixel path applies, not a fetch offset.
    assign hs_delay = hscrol[3:1];
    assign hs_fine  = hscrol[0];

    // Scrolling fetches one width up so there is data to scroll in.
    wire [1:0] fetch_width = (hscrol_en && pf_on && eff_width != 2'd3)
                             ? (eff_width + 2'd1) : eff_width;

    // Hi-res pixels fetched, and hi-res pixels displayed.  They differ only
    // when scrolling widens the fetch.
    logic [9:0] fetch_px;
    always_comb begin
        case (fetch_width)
            2'd1:    fetch_px = 10'd256;
            2'd2:    fetch_px = 10'd320;
            2'd3:    fetch_px = 10'd384;
            default: fetch_px = 10'd0;
        endcase
    end

    // (8/bpp) * px_width is always a power of two, so this is a shift.
    logic [2:0] pw_log2;
    always_comb begin
        case (px_width)
            4'd1:    pw_log2 = 3'd0;
            4'd2:    pw_log2 = 3'd1;
            4'd4:    pw_log2 = 3'd2;
            4'd8:    pw_log2 = 3'd3;
            default: pw_log2 = 3'd0;
        endcase
    end

    wire [2:0] px_shift = pw_log2 + ((bpp == 2'd2) ? 3'd2 : 3'd3);

    // ...but the LENGTH stays zero, because emu's antic_pf_bytes does: it is
    // the zero that stops antic_pf_stream reloading lb_len and so preserves
    // the previous row's contents for the aliased cases.
    always_comb bytes_per_line = pf_on ? 8'((fetch_px >> px_shift)) : 8'd0;

    // Machine cycles between playfield fetches.  This is span/bytes_per_line,
    // but writing it as a division synthesises a real divider: 22 carry chains
    // and a 17 ns path from the mode register, which was the whole of a -9.7 ns
    // clk_sys violation on the first build.  It is a SHIFT, and always was --
    // span is fetch_px/4 and bytes_per_line is fetch_px >> px_shift, so the
    // quotient is 2^(px_shift-2) and the width cancels out entirely.  A step
    // depends only on how many hi-res pixels a byte carries.
    always_comb pf_step = 8'd1 << (px_shift - 3'd2);

    // One window table, read twice: by the PROGRAMMED width for what is
    // displayed and by the FETCH width for what is fetched.
    function automatic logic [6:0] win_start(input logic [1:0] w);
        case (w)
            2'd1:    win_start = 7'd28;   // narrow
            2'd2:    win_start = 7'd20;   // normal
            2'd3:    win_start = 7'd12;   // wide
            default: win_start = 7'd0;
        endcase
    endfunction

    function automatic logic [6:0] win_stop(input logic [1:0] w);
        case (w)
            2'd1:    win_stop = 7'd92;
            2'd2:    win_stop = 7'd100;
            2'd3:    win_stop = 7'd108;
            default: win_stop = 7'd0;
        endcase
    endfunction

    always_comb begin
        disp_start = win_start(eff_width);
        disp_stop  = win_stop(eff_width);
    end

    // THE DISPLAY LAGS THE FETCH, AND THE TABLE ABOVE IS THE FETCH.
    //
    // The header calls 28/20/12 "display starts", and that was wrong: they are
    // where a BITMAP row begins FETCHING.  emu keeps a separate NOMINAL window
    // -- antic_pf_nominal, 29/21/13 -- and derives both edges from it: the
    // bitmap fetch is nominal - 1, and the display is nominal + PF_DISPLAY_LEAD
    // with the lead fixed at 3 for every width (antic_dma.h:51, "display begins
    // exactly PF_DISPLAY_LEAD cycles after this, for every width, so the two
    // cannot drift apart").  Display therefore starts FOUR machine cycles after
    // this table, at 32/24/16 -- colour clocks $40/$30/$20, which is what
    // emu's own decode comment quotes and what antic_pmdma's left-edge
    // collision against a narrow playfield pins.
    //
    // Painting the playfield four cycles early moves every pixel sixteen hi-res
    // positions left.  The fetch is unaffected: the bytes are right and land in
    // the right buffer slots -- verified against emu byte for byte -- and only
    // the beam position they are painted at is wrong.  That is why the fetch
    // path checked out link by link while the picture stayed broken.
    localparam logic [6:0] DISP_LAG = 7'd4;

    // The live display window in hi-res pixels: four per machine cycle.  The
    // consumer compares the beam against THIS every pixel, so a mid-line DMACTL
    // or HSCROL write moves the edge mid-line.
    //
    // HSCROL's ODD BIT DOES NOT REACH THE DISPLAY.  emu adds 2*(hscrol >> 1)
    // COLOUR CLOCKS -- whole machine cycles -- and HSCROL_CC_DISPLAY, which
    // would add the odd one, is defined 0.  hs_fine belongs to the fetch grid's
    // sub-cycle accounting, not here.
    logic [6:0] eff_start_cyc;
    always_comb begin
        if (hscrol_en && pf_on) eff_start_cyc = win_start(fetch_width) + DISP_LAG
                                              + {4'd0, hs_delay};
        else                    eff_start_cyc = win_start(eff_width) + DISP_LAG;
    end

    always_comb begin
        px_start = {eff_start_cyc, 2'b00};
        px_stop  = px_start + {2'd0, (win_stop(eff_width) - win_start(eff_width)), 2'b00};
    end

    // Character modes start fetching two cycles early: name, then glyph.
    always_comb begin
        if (!pf_on) begin
            dma_start = 7'd0;
            dma_stop  = 7'd0;
        end else begin
            // HSCROL DELAYS THE FETCH WINDOW TOO, by one machine cycle per two
            // units -- emu's spec_window adds the same `off = (hscrol & 14) >> 1`
            // to BOTH edges.  Widening the window for a scrolled row (above) is
            // only half of what scrolling does; without this the fetch grid
            // stays put while the display slides across it, and the two
            // disagree by up to seven machine cycles.
            //
            // The odd bit is the FINE colour clock and belongs to the display,
            // not to the fetch grid: hs_delay is hscrol[3:1], so HSCROL 4 and 5
            // delay the fetch by the same two cycles.
            //
            // BOTH edges move together here, which is why static geometry alone
            // cannot produce abnormal DMA -- the stop stays on the phase the
            // start injected and the clear always succeeds.  Missing the stop
            // needs the start LATCHED and the stop moving under it, which is a
            // mid-line effect and lives in antic2.
            dma_start = win_start(fetch_width) - (is_char ? 7'd2 : 7'd0)
                      + (hscrol_en ? {4'd0, hs_delay} : 7'd0);
            // THE STOP CARRIES THE CHARACTER SHIFT TOO.  emu's window is
            // `st + span` where `st` is the character-adjusted start, so a
            // character row's stop is two cycles early exactly as its start
            // is -- the span is the same 64/80/96 either way.  Taking the stop
            // from the unshifted table instead leaves the window two cycles
            // long on character modes, which is one extra fetch.
            dma_stop  = win_stop(fetch_width) - (is_char ? 7'd2 : 7'd0)
                      + (hscrol_en ? {4'd0, hs_delay} : 7'd0);
        end
    end

endmodule

`default_nettype wire
