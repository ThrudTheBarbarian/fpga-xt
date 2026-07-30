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
    output logic [6:0] dma_start,      // first machine cycle of playfield DMA
    output logic [6:0] dma_stop,       // one past the last fetch cycle
    output logic [6:0] disp_start,     // first machine cycle displayed
    output logic [6:0] disp_stop,      // one past the last displayed
    output wire  [2:0] hs_delay,       // HSCROL in whole machine cycles
    output wire        hs_fine         // ...and the odd colour clock
);

    assign pf_on = (pf_width != 2'd0);

    // HSCROL is in colour clocks; a machine cycle is two of them.  The odd bit
    // is a one-colour-clock shift the pixel path applies, not a fetch offset.
    assign hs_delay = hscrol[3:1];
    assign hs_fine  = hscrol[0];

    // Scrolling fetches one width up so there is data to scroll in.
    wire [1:0] fetch_width = (hscrol_en && pf_on && pf_width != 2'd3)
                             ? (pf_width + 2'd1) : pf_width;

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

    always_comb bytes_per_line = 8'((fetch_px >> px_shift));

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
        disp_start = win_start(pf_width);
        disp_stop  = win_stop(pf_width);
    end

    // Character modes start fetching two cycles early: name, then glyph.
    always_comb begin
        if (!pf_on) begin
            dma_start = 7'd0;
            dma_stop  = 7'd0;
        end else begin
            dma_start = win_start(fetch_width) - (is_char ? 7'd2 : 7'd0);
            dma_stop  = win_stop(fetch_width);
        end
    end

endmodule

`default_nettype wire
