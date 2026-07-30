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
    input  wire [7:0] step,                 // machine cycles between fetches
    input  wire       lms,                  // the instruction carries operands

    // ---- live enables ----------------------------------------------------
    input  wire       dl_dma_en,            // DMACTL[5]
    input  wire       missile_dma_en,       // DMACTL[2]
    input  wire       player_dma_en,        // DMACTL[3]

    output wire       steal                 // this machine cycle is ANTIC's
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
    // A later bitmap row costs nothing at all: the block was read on its first
    // row and is replayed from the internal buffer.
    wire [8:0] n_fetch = (!is_display || (!is_char && !first_row))
                       ? 9'd0 : {1'b0, bytes_per_line};

    // Where the first (glyph, next name) pair sits, relative to the opening
    // name.  step is 2 or 4 for every character mode there is, giving 2 or 3.
    wire [6:0] char_phase = 7'((step >> 1) + 8'd1);

    typedef enum logic [2:0] {
        P_IDLE, P_FIRST, P_PAIR_A, P_PAIR_B, P_PLAIN, P_DONE
    } pstate_t;
    pstate_t pstate;

    logic [6:0] pf_at;                      // the cycle the next fetch wants
    logic [8:0] pf_k;                       // how many bytes are done
    logic [8:0] pf_n;                       // how many this line needs

    // `steal` is a LEVEL across the machine cycle, not a pulse at the tick.
    // The fid core is paced by phi2_tick and samples its rdy input at a commit
    // slot well inside the cycle, so a tick-aligned pulse is invisible to it and
    // the CPU loses nothing.  hcount and the walk state are both stable between
    // ticks, so the comparison is valid throughout the cycle either way.
    wire pf_want   = (hcount == pf_at) &&
                     (pstate == P_FIRST || pstate == P_PAIR_A ||
                      pstate == P_PLAIN);
    wire pf_want_b = (hcount == pf_at) && (pstate == P_PAIR_B);

    wire pf_hit    = tick && pf_want;
    wire pf_hit_b  = tick && pf_want_b;

    wire pf_steal  = pf_want || pf_want_b;

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

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            pstate      <= P_IDLE;
            pf_at       <= 7'd0;
            pf_k        <= 9'd0;
            pf_n        <= 9'd0;
            ref_left    <= 4'd0;
            ref_slot    <= 7'd25;
            ref_pending <= 1'b0;
        end else begin
            if (line_start) begin
                pf_k     <= 9'd0;
                pf_n     <= n_fetch;
                ref_left <= 4'd9;
                ref_slot <= 7'd25;
                ref_pending <= 1'b0;
                if (n_fetch == 9'd0) begin
                    pstate <= P_DONE;
                end else if (pairs) begin
                    pf_at  <= dma_start;
                    pstate <= P_FIRST;
                end else begin
                    // A later character row starts three cycles into the
                    // window; a bitmap row starts at the window edge.
                    pf_at  <= is_char ? (dma_start + 7'd3) : dma_start;
                    pstate <= P_PLAIN;
                end
            end else begin
                if (ref_req) begin
                    ref_slot <= ref_slot + 7'd4;
                    ref_left <= ref_left - 4'd1;
                end
                if (tick) ref_pending <= ref_want && !ref_steal;

                case (pstate)
                    // The opening name of a character first row, on its own.
                    P_FIRST: if (pf_hit) begin
                        pf_at  <= dma_start + char_phase;
                        pstate <= P_PAIR_A;
                    end

                    // (glyph, next name) go out back to back...
                    P_PAIR_A: if (pf_hit) begin
                        if (pf_k == pf_n - 9'd1) begin
                            pstate <= P_DONE;   // the last glyph stands alone
                        end else begin
                            pf_at  <= pf_at + 7'd1;
                            pstate <= P_PAIR_B;
                        end
                    end

                    // ...and the pair as a whole repeats every `step`.
                    P_PAIR_B: if (pf_hit_b) begin
                        pf_at  <= pf_at - 7'd1 + 7'(step);
                        pf_k   <= pf_k + 9'd1;
                        pstate <= P_PAIR_A;
                    end

                    // One fetch per byte: bitmap rows and later character rows.
                    P_PLAIN: if (pf_hit) begin
                        pf_k <= pf_k + 9'd1;
                        if (pf_k == pf_n - 9'd1) pstate <= P_DONE;
                        else                     pf_at  <= pf_at + 7'(step);
                    end

                    default: ;
                endcase
            end
        end
    end

endmodule

`default_nettype wire
