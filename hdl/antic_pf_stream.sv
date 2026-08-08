`default_nettype none
//
// antic_pf_stream — fill ANTIC's playfield line buffer ONE SCHEDULED CYCLE AT
// A TIME.
//
// This is the progressive counterpart to antic_pf_fetch, which bursts the whole
// line at line_start.  The burst is simpler and it is wrong, for one reason:
// DMACTL and HSCROL are not latched for the line.  ANTIC compares the window
// edges against the horizontal counter as it runs, so a write part way down the
// line moves the edges for whatever is still to come, while the cycles already
// past keep what they did — the bytes they fetched stay fetched and the running
// count carries on.  Shortening the window mid-fetch therefore truncates the
// row and widening it extends it.  antic_pfstarttiming and antic_pfstoptiming
// measure that from opposite directions, antic_hscrolbug measures it through
// the fetch grid's phase, and antic_linebuffering measures it by killing DMA
// across the centre of a row.  A fetcher that has already consumed the whole
// line before the first of those writes lands cannot express any of it.
//
// THE INDEX IS A RUNNING COUNT, NOT THE MAP'S OWN SLOT NUMBER.  This is emu's
// `int i = a->pf_next++` and it is the whole point: because the map can be
// rebuilt underneath it, the row's byte count follows from how many fetch
// cycles ACTUALLY happened.  "STOP is a cycle comparison, never a count."
//
// THE SCAN POINTER ADVANCES PER ACTUAL FETCH, so the stride the address tests
// measure falls out rather than being asserted.  It wraps within 4 KB
// (antic_addresswrap).
//
// WHAT EACH SCHEDULED CYCLE MEANS depends on the row, and the scheduler cannot
// say on its own — it reports the shape of the walk, not the meaning:
//
//   character, first row : PAIRS.  The first access reads the NAME and steps
//                          the scan pointer; the second reads that character's
//                          GLYPH and steps nothing.  Two steals, one buffer
//                          entry.
//   character, later row : SINGLES, and each one is a GLYPH — the name is
//                          already in the buffer from the row's first line.
//                          Only the glyph row changed.  This is what halves a
//                          character row's DMA after its first line.
//   bitmap, first row    : SINGLES, each a graphics byte, each stepping the
//                          pointer.
//   bitmap, later row    : NOTHING.  The block was read on its first row and is
//                          replayed from the buffer.
//
// THE BUFFER IS NOT CLEARED between lines.  If playfield DMA is off, the
// previous row's contents stay and are displayed again — antic_linebuffering's
// "mid-interrupted" and "replayed" cases are built on exactly that, and so is
// the rule that lb_len is only reloaded when the row actually fetches.
//
// ONE 16-BIT ENTRY PER BYTE, character code alongside glyph.  Real ANTIC splits
// these; we do not, because a 48x16 distributed RAM is a single primitive and
// the code is needed at display time anyway to pick the colour in modes 4/5/6/7.
//
// CLOCK BUDGET: one memory access per scheduled machine cycle, which is the
// same budget the DMA schedule already granted itself.  There is no burst to
// fit into horizontal blank any more.
//
`timescale 1ns/1ps

module antic_pf_stream #(
    parameter int ENTRIES = 64          // 48 are written; the reader needs 64
) (
    input  wire        clk,
    input  wire        rst,

    // ---- the line ---------------------------------------------------------
    input  wire        line_start,      // 1-clk at the top of the scanline
    input  wire        first_row,       // first scanline of this mode line
    input  wire [3:0]  mode,
    input  wire [4:0]  row,             // scanline within the mode line
    input  wire [7:0]  chbase,
    input  wire [2:0]  chactl,
    input  wire [7:0]  bytes_per_line,  // the row's nominal length, for lb_len

    // ---- the schedule -----------------------------------------------------
    // Tick pulses from antic_dma_sched.  pf_fetch_glyph marks the second half
    // of a character pair; every other fetch is a name, a graphics byte or a
    // later row's glyph, which the row shape below tells apart.
    input  wire        pf_fetch,
    input  wire        pf_fetch_glyph,

    // ---- the VIRTUAL slot --------------------------------------------------
    // High when THIS scheduled fetch is the line's virtual one.  ANTIC accounts
    // for the slot and clocks the line buffer, but drives neither address nor
    // data: what the buffer takes is whatever the last bus access left behind.
    // antic2 decides which cycle that is; this module only needs to know that
    // the fetch in front of it is that one.
    input  wire        virt_slot,
    // What was last on the DATA BUS, whoever drove it.  Latched in a8_core at
    // the CPU's data phase, which is EARLIER in the machine cycle than the tick
    // this fetch rides on -- so by the time the slot reads it, it already holds
    // this cycle's byte, which is the "after the access, not before it" rule
    // emu's antic_virt_latch is built on.
    input  wire [7:0]  bus_byte,

    // ---- the playfield scan pointer ---------------------------------------
    input  wire [15:0] scan_addr_in,
    input  wire        scan_load,       // 1-clk: adopt scan_addr_in (LMS)
    output logic [15:0] scan_addr_out,

    // ---- memory (mem_valid is mem_req delayed one clock) ------------------
    output logic [15:0] mem_addr,
    output logic        mem_req,
    input  wire  [7:0]  mem_data,
    input  wire         mem_valid,

    // ---- buffer read port, for the renderer -------------------------------
    input  wire  [5:0]  rd_idx,
    // How many entries were filled BEFORE the line's fetch window opened, so
    // the display can skip them.  Applied HERE because this module owns the
    // buffer and therefore owns its wrap, which is the same place emu applies
    // it (antic.c's lb(): `i += a->lb_origin; return i % sizeof a->linebuf`).
    input  wire  [5:0]  rd_origin,
    output wire  [7:0]  rd_data,         // glyph or graphics byte, CHACTL applied
    output wire  [7:0]  rd_code,         // character code, for the colour select
    output logic [6:0]  lb_len           // how wide this row is
);

    // ---- mode parameters --------------------------------------------------
    wire       is_char, descender, is_display;
    wire [1:0] bpp;
    wire [3:0] px_width;
    wire [4:0] rows;

    antic_mode_tbl u_tbl (
        .mode(mode), .is_char(is_char), .bpp(bpp), .px_width(px_width),
        .rows(rows), .descender(descender), .is_display(is_display)
    );

    // ---- the buffer -------------------------------------------------------
    logic [15:0] buf_mem [0:ENTRIES-1];

    // SIZED BY ITS READER, not by its writer.  A wide row writes 48 entries and
    // never more, but the read index is rd_idx + rd_origin, which runs past 47
    // whenever the origin is non-zero -- and emu wraps that sum modulo 64
    // (`uint8_t linebuf[64]`).  At 64 entries the 6-bit sum below IS that
    // modulo, and the top sixteen hold whatever the last row left, exactly as
    // emu's array does.
    wire [5:0] rd_at = rd_idx + rd_origin;

    assign rd_code = buf_mem[rd_at][15:8];
    assign rd_data = buf_mem[rd_at][7:0];

    // ---- the running count ------------------------------------------------
    // Reset per scanline, incremented per BUFFER ENTRY -- so a character pair
    // advances it once, on the name, not twice.
    logic [6:0]  pf_next;
    logic [15:0] scan_q;

    assign scan_addr_out = scan_q;

    // The character code the glyph access needs.  On a first row it is the name
    // just fetched; on a later row it comes back out of the buffer, and through
    // a REGISTER rather than combinationally -- feeding a distributed RAM's
    // output straight into the memory address path costs a RAMD64E plus five
    // MUXF stages out to the screen bank's read register.
    logic [7:0] char_code;

    // ---- glyph row --------------------------------------------------------
    // Two quirks: 16-row modes (5, 7) show each glyph row twice, and mode 3 has
    // a ten-row cell whose descenders (code[6:5] == 11) take rows 0/1 from glyph
    // rows 6/7 and rows 2..9 from glyph rows 0..7, while ordinary characters use
    // rows 0..7 and are BLANK on rows 8/9.
    logic [2:0] glyph_row;
    logic       row_blank;

    logic [6:0] pend_idx [0:1];
    logic [1:0] pend_cnt;
    wire [6:0] glyph_idx = pend_idx[0];

    // THE NAME THIS GLYPH ACCESS BELONGS TO.  Same reason as the pending-index
    // queue below: by the time a pair's glyph goes out, char_code has already
    // been overwritten by the NEXT name.  The descender decode reads the
    // character's own code, so it has to use this too -- a mode 3 row whose
    // code is in $60..$7F takes its rows 0/1 from glyph rows 6/7 and must be
    // BLANK where an ordinary character is not, which is what
    // antic_charcontrol's "3 inv desc" case measures.
    wire [7:0] glyph_code = (is_char && first_row) ? buf_mem[glyph_idx[5:0]][15:8]
                                                   : char_code;

    always_comb begin
        row_blank = 1'b0;
        if (descender) begin
            // A TEN-ROW CELL BLANKS BY CHARACTER, IT DOES NOT SHIFT ROWS.  The
            // glyph row is row mod 8 for every character; what a descender
            // (code[6:5] == 11) changes is WHICH two rows come out blank --
            // its own 0 and 1 rather than 8 and 9.  antic_charcontrol's tables
            // say so directly: "3 inv desc" wants rows 2..7 to match plain
            // mode 3's rows 2..7 and its rows 8/9 to repeat mode 3's rows 0/1,
            // which only holds if the index never moves.  Taking rows 0/1 from
            // glyph rows 6/7 put three lit colour clocks where the test wants
            // none.  Same rule as compositor.sv.
            glyph_row = row[2:0];
            row_blank = (glyph_code[6:5] == 2'b11) ? (row < 5'd2)
                                                   : (row >= 5'd8);
        end else if (rows == 5'd16) begin
            glyph_row = row[3:1];
        end else begin
            glyph_row = row[2:0];
        end
    end

    // CHACTL sits on BOTH sides of the character-set access: reflect XORs the
    // row going in, blank and invert rewrite the data coming out.
    wire [2:0] glyph_row_ctl;
    wire [7:0] glyph_data_ctl;

    // TWO INSTANCES, BECAUSE THE TWO OUTPUTS ARE CONSUMED IN DIFFERENT CYCLES
    // AND SO NEED DIFFERENT CODES.  glyph_row feeds glyph_addr when the access
    // is ISSUED, and the code that matters there is the one the pair's name
    // read (glyph_code).  glyph_data rewrites the byte when it COMES BACK, and
    // by then the code that matters is the one latched with that access
    // (inflight_code).  Feeding both from the live char_code register meant an
    // inverse-video character was decided by whichever name had landed most
    // recently -- so with CHACTL invert set, a $81 cell was not inverted at
    // all.  antic_charcontrol's chactl=$02 pass measures exactly that.
    // In flight, so the write-back knows what the data means (assigned in the
    // access block below; declared HERE because iverilog cannot bind a port
    // expression to a symbol declared after the instance that uses it).
    logic       inflight, inflight_glyph, inflight_blank;
    logic [6:0] inflight_idx;
    logic [7:0] inflight_code;

    wire [7:0] unused_data_a;
    antic_char_ctl u_chactl_row (
        .chactl(chactl), .is_char(is_char), .bpp(bpp), .px_width(px_width),
        .char_code(glyph_code),
        .glyph_row_in(glyph_row), .glyph_data_in(mem_data),
        .glyph_row(glyph_row_ctl), .glyph_data(unused_data_a)
    );

    wire [2:0] unused_row_b;
    antic_char_ctl u_chactl_data (
        .chactl(chactl), .is_char(is_char), .bpp(bpp), .px_width(px_width),
        .char_code(inflight_code),
        // THE TEN-ROW CELL'S BLANK GOES IN BEFORE THE INVERTER, NOT AFTER IT.
        // Zeroing the byte on the way out left an inverse-video character's
        // blank rows dark, but ANTIC blanks the GLYPH and CHACTL then flips it,
        // so those rows come out fully LIT.  antic_charcontrol's chactl=$02
        // mode 3 wants $f0 on row 8, and forcing the store to zero gave $00.
        .glyph_row_in(glyph_row), .glyph_data_in(inflight_blank ? 8'h00 : mem_data),
        .glyph_row(unused_row_b), .glyph_data(glyph_data_ctl)
    );

    wire [15:0] glyph_addr = {chbase[7:2], glyph_code[6:0], glyph_row_ctl};

    // ---- what this scheduled cycle is -------------------------------------
    // A later character row's single access is a GLYPH even though the schedule
    // calls it a plain fetch, because its name is already buffered.  That is the
    // one case the scheduler's own state cannot distinguish.
    wire fetch_is_glyph = pf_fetch_glyph || (is_char && !first_row);

    // TWO DIFFERENT QUESTIONS, which the first cut of this conflated:
    //
    //   does this access move the SCAN POINTER?  Only a name or a graphics
    //   byte does -- a glyph is read from the character set and leaves the
    //   playfield pointer where it stands.
    //
    //   does this access consume a BUFFER INDEX?  Everything except the second
    //   half of a character pair, which shares the entry its name claimed.
    //
    // They coincide for a first row, which is what hid it: there, every
    // index-consuming access is also a pointer-stepping one.  A LATER
    // character row is the case that separates them -- each single fetch is a
    // glyph, so it steps nothing, yet each one IS its own entry.  Tying the
    // count to the pointer froze pf_next at zero and every character in the row
    // rewrote entry 0.
    wire ptr_steps = !fetch_is_glyph;
    wire idx_takes = !pf_fetch_glyph;

    // A GLYPH BELONGS TO THE NAME ITS PAIR READ, NOT TO THE LATEST ONE.
    // antic_dma_sched pairs a name at cycle c with its glyph at c+3, while the
    // names themselves come every two cycles -- so by the time the first glyph
    // is issued, TWO names have already gone out.  `pf_next - 1` assumes the
    // glyph immediately follows its own name and so files every glyph one cell
    // too high: cell 0's glyph landed in entry 1, and entry 0 kept the 8'h00 it
    // started with and drew blank.  Measured on antic_charcontrol at cycle 29.
    //
    // Queue the pending name indices and let each glyph take the oldest.  Two
    // entries is enough: the names run at most two ahead of the glyphs.
    wire [6:0] idx = pf_fetch_glyph ? glyph_idx : pf_next;

    // ---- the access -------------------------------------------------------
    // In flight, so the write-back knows what the data means.  mem_valid is
    // mem_req delayed exactly one clock, so one stage is enough.  (The
    // declarations live up by u_chactl_data — see the note there.)

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            pf_next        <= 7'd0;
            scan_q         <= 16'h0000;
            char_code      <= 8'h00;
            lb_len         <= 7'd0;
            pend_idx[0]    <= 7'd0;
            pend_idx[1]    <= 7'd0;
            pend_cnt       <= 2'd0;
            mem_req        <= 1'b0;
            mem_addr       <= 16'h0000;
            inflight       <= 1'b0;
            inflight_glyph <= 1'b0;
            inflight_blank <= 1'b0;
            inflight_idx   <= 7'd0;
            inflight_code  <= 8'h00;
        end else begin
            mem_req  <= 1'b0;
            // inflight is NOT cleared every clock.  mem_req is registered and
            // mem_valid is mem_req delayed one more, so the data lands TWO
            // clocks after the fetch pulse; a flag that survives only one is
            // already low when it arrives and the write-back never happens.
            // Fetches are machine cycles apart, so at most one is outstanding.
            if (mem_valid && inflight) inflight <= 1'b0;

            // An LMS operand replaces the pointer; it does not disturb the
            // count, which belongs to the scanline.
            if (scan_load) scan_q <= scan_addr_in;

            if (line_start) begin
                pf_next  <= 7'd0;
                pend_cnt <= 2'd0;
                // The length is reloaded ONLY when this row actually fetches.
                // Otherwise the buffer keeps its contents AND its length, and
                // the previous row is displayed again -- a DMACTL width of zero
                // is not a width, it is no playfield DMA at all.
                if (is_display && bytes_per_line != 8'd0 &&
                    (is_char || first_row))
                    lb_len <= 7'(bytes_per_line);
                // A later character row reads its names back out of the buffer
                // as it goes, so the FIRST one has to be standing before the
                // first glyph access computes its address.
                if (is_char && !first_row) char_code <= buf_mem[0][15:8];
            end

            if (pf_fetch) begin
                // THE VIRTUAL SLOT TAKES THE BUS INSTEAD OF MEMORY.  No
                // request, nothing in flight, and the byte lands in the DATA
                // half of the entry -- the glyph, which is what gets displayed.
                // The code half is left alone: emu writes only glyphbuf here
                // (its fetch-loop special case never runs, measured), so
                // touching the name would be inventing a second effect.
                //
                // Everything else about the cycle is unchanged: it still takes
                // its index and still steps the pointer if the mode says so,
                // because ANTIC accounts for the slot as a fetch either way.
                if (virt_slot) begin
                    buf_mem[idx] <= {buf_mem[idx][15:8], bus_byte};
                end else begin
                    mem_req  <= 1'b1;
                    mem_addr <= fetch_is_glyph ? glyph_addr : scan_q;

                    inflight       <= 1'b1;
                    inflight_glyph <= fetch_is_glyph;
                    inflight_blank <= row_blank;
                    inflight_idx   <= idx;
                    inflight_code  <= fetch_is_glyph ? glyph_code : char_code;
                end

                // A later character row takes the name it needs for the NEXT
                // access out of the buffer as it goes.
                if (is_char && !first_row)
                    char_code <= buf_mem[idx + 7'd1][15:8];

                if (idx_takes) pf_next <= pf_next + 7'd1;

                // Push the name's index; the glyph of that pair pops it.
                if (pf_fetch_glyph) begin
                    pend_idx[0] <= pend_idx[1];
                    if (pend_cnt != 2'd0) pend_cnt <= pend_cnt - 2'd1;
                end else if (is_char && first_row) begin
                    if (pend_cnt == 2'd0) pend_idx[0] <= pf_next;
                    else                  pend_idx[1] <= pf_next;
                    if (pend_cnt != 2'd2) pend_cnt <= pend_cnt + 2'd1;
                end
                // The playfield counter wraps within 4 KB during the fetch, so
                // a row crossing that boundary reads from the bottom of the
                // same page (antic_addresswrap).
                if (ptr_steps) scan_q <= {scan_q[15:12], scan_q[11:0] + 12'd1};
            end

            // ---- the data comes back ------------------------------------
            if (mem_valid && inflight) begin
                if (inflight_glyph) begin
                    // A blanked mode-3 row still occupies its pixels, so store
                    // zeros rather than skipping the entry.
                    buf_mem[inflight_idx] <= {inflight_code, glyph_data_ctl};
                end else if (is_char) begin
                    // A name: hold it for the glyph access that follows, and
                    // park it in the entry so a later row can read it back.
                    char_code             <= mem_data;
                    buf_mem[inflight_idx] <= {mem_data, 8'h00};
                end else begin
                    // A graphics byte is its own data and has no code.
                    buf_mem[inflight_idx] <= {8'h00, mem_data};
                end
            end
        end
    end

endmodule

`default_nettype wire
