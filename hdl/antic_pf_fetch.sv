`default_nettype none
//
// antic_pf_fetch — fill ANTIC's internal playfield line buffer.
//
// docs/ANTIC-rewrite.md.  ANTIC does not fetch a byte, draw it, then fetch the
// next.  It fetches the whole line into a 48-entry internal buffer and the
// display reads back out of it.  antic_hscrolbug proves the buffer exists by
// dumping it ("the first 32 bytes of the internal contents to be: 55 AA 55 AA
// ...") and antic_linebuffering tests its semantics directly.
//
// SEPARATING FETCH FROM EMIT IS NOT AN OPTIMISATION, IT IS REQUIRED.  Emission
// is paced by the beam and stops when the display window closes; fetching is
// not, and must always consume exactly bytes_per_line bytes so the memory scan
// pointer lands in the right place for the next scanline.  A scrolled narrow
// line fetches 40 bytes and displays 32 — tie the two together and the scan
// pointer drifts 8 bytes per scanline.
//
// A CHARACTER NAME IS FETCHED ONCE PER MODE LINE, NOT ONCE PER SCANLINE, and
// that is the buffer's real purpose.  antic_dmapattern's own DMA maps settle it:
// a later scanline of a narrow mode 2 line has exactly 32 fetches for 32
// characters, and a normal one exactly 40 for 40 — one each, where the first
// scanline has two.  The names sit in the buffer for the whole block and only
// the glyph is re-read, because only the glyph ROW changes.
//
// A BITMAP MODE WITH SEVERAL ROWS FETCHES NOTHING AT ALL on its later scanlines:
// mode 8's eight scanlines all show the same bytes, so they are read once and
// replayed.  The same maps show mode8b, mode9b, modeAb, modeBb and modeDb as
// refresh cycles and nothing else.  Halving — and for bitmap modes eliminating —
// the playfield DMA on later rows is most of what the CPU gets back.
//
// ONE 16-BIT ENTRY PER BYTE, holding the character code alongside the glyph.
// Real ANTIC splits these; we do not, because a 48x16 distributed RAM is a
// single primitive and the character code is needed at display time anyway to
// pick the colour in modes 4/5/6/7.  Buffers are explicitly outside the
// transistor smell test — there is no 1979 analogue to be small about.
//
// GLYPH ROW SELECTION lives here, with the two quirks the hardware has:
//   * 16-row modes (5, 7) show each glyph row twice, so the glyph row is row>>1
//   * mode 3 has a 10-row cell.  Characters with code[6:5] == 11 are descenders:
//     their rows 0 and 1 come from glyph rows 6 and 7 and rows 2..9 from glyph
//     rows 0..7.  Ordinary characters use rows 0..7 and are BLANK on rows 8/9.
// CHACTL applies on both sides of the glyph fetch (see antic_char_ctl).
//
// THE SCAN POINTER THEREFORE ADVANCES ONCE PER MODE LINE, not once per
// scanline, which falls out of the above rather than needing its own rule: a
// later row does not fetch names, and it is the name fetch that steps the
// pointer.  Advancing it every scanline would have run a mode 2 block through
// 320 bytes instead of 40.
//
// CLOCK BUDGET: 2 clocks per fetch, 2 fetches per character.  Worst case is 48
// characters = ~192 clocks out of the ~6,300 in a 1.79 MHz scanline, and it all
// happens before the display window opens.
//
`timescale 1ns/1ps

module antic_pf_fetch #(
    parameter int ENTRIES = 48          // wide playfield, 8 hi-res px per byte
) (
    input  wire        clk,
    input  wire        rst,

    // ---- what to fetch ---------------------------------------------------
    input  wire        start,           // 1-clk: fetch this scanline
    input  wire        first_row,       // first scanline of this mode line
    input  wire [3:0]  mode,
    input  wire [15:0] scan_addr_in,
    input  wire [4:0]  row,
    input  wire [7:0]  chbase,
    input  wire [2:0]  chactl,
    input  wire [7:0]  bytes_per_line,

    // ---- memory (1-clock read latency) -----------------------------------
    output logic [15:0] mem_addr,
    input  wire  [7:0]  mem_data,

    // ---- buffer read port, for the renderer ------------------------------
    input  wire  [5:0]  rd_idx,
    output wire  [7:0]  rd_data,        // glyph or graphics byte, CHACTL applied
    output wire  [7:0]  rd_code,        // character code, for the colour select

    output logic [15:0] scan_addr_out,  // advanced past this line
    output logic        busy,
    output logic        done            // 1-clk when the line is in the buffer
);

    // ---- mode parameters -------------------------------------------------
    wire       is_char, descender, is_display;
    wire [1:0] bpp;
    wire [3:0] px_width;
    wire [4:0] rows;

    antic_mode_tbl u_tbl (
        .mode(mode), .is_char(is_char), .bpp(bpp), .px_width(px_width),
        .rows(rows), .descender(descender), .is_display(is_display)
    );

    // ---- the buffer ------------------------------------------------------
    logic [15:0] buf_mem [0:ENTRIES-1];
    logic [5:0]  wr_idx;

    assign rd_code = buf_mem[rd_idx][15:8];
    assign rd_data = buf_mem[rd_idx][7:0];

    // On the first scanline the name has just been fetched; on later ones it is
    // already in the buffer, so the glyph address comes from there.
    logic [7:0] char_code_q;
    wire  [7:0] char_code = (is_char && !first_row) ? buf_mem[wr_idx][15:8]
                                                    : char_code_q;

    // ---- glyph row -------------------------------------------------------
    logic [2:0] glyph_row;
    logic       row_blank;              // mode 3 rows 8/9 of a non-descender

    always_comb begin
        row_blank = 1'b0;
        if (descender) begin
            if (char_code[6:5] == 2'b11) begin
                // Descender: rows 0/1 come from glyph rows 6/7, then 0..7.
                glyph_row = (row < 5'd2) ? (3'd6 + row[0]) : 3'(row - 5'd2);
            end else begin
                glyph_row = row[2:0];
                if (row >= 5'd8) row_blank = 1'b1;
            end
        end else if (rows == 5'd16) begin
            glyph_row = row[3:1];
        end else begin
            glyph_row = row[2:0];
        end
    end

    // CHACTL sits on both sides of the character-set access: reflect XORs the
    // row going in, blank and invert rewrite the data coming out.
    wire [2:0] glyph_row_ctl;
    wire [7:0] glyph_data_ctl;

    antic_char_ctl u_chactl (
        .chactl(chactl), .is_char(is_char), .bpp(bpp), .px_width(px_width),
        .char_code(char_code),
        .glyph_row_in(glyph_row), .glyph_data_in(mem_data),
        .glyph_row(glyph_row_ctl), .glyph_data(glyph_data_ctl)
    );

    wire [15:0] glyph_addr = {chbase[7:2], char_code[6:0], glyph_row_ctl};

    // ---- the walk --------------------------------------------------------
    typedef enum logic [2:0] {
        S_IDLE, S_NAME, S_NAME_D, S_DATA, S_DATA_D, S_DONE
    } state_t;
    state_t state;

    logic [15:0] scan_q;
    logic [7:0]  left;

    assign scan_addr_out = scan_q;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state     <= S_IDLE;
            scan_q    <= 16'h0000;
            left      <= 8'd0;
            wr_idx    <= 6'd0;
            char_code_q <= 8'h00;
            busy      <= 1'b0;
            done      <= 1'b0;
        end else begin
            done <= 1'b0;

            if (start) begin
                // A restart from any state: the previous line's fetch is
                // finished with, whatever it was doing.
                scan_q <= scan_addr_in;
                left   <= bytes_per_line;
                wr_idx <= 6'd0;
                busy   <= 1'b1;
                if (!is_display || bytes_per_line == 8'd0)  state <= S_DONE;
                // A bitmap block is read once and replayed for its other rows.
                else if (!is_char && !first_row)            state <= S_DONE;
                // A character name is read once per block; later rows re-read
                // only the glyph, using the name already in the buffer.
                else if (is_char && !first_row)             state <= S_DATA;
                else if (is_char)                           state <= S_NAME;
                else                                        state <= S_DATA;
            end else
            case (state)
                S_IDLE: busy <= 1'b0;

                // ---- character name ------------------------------------
                S_NAME:   state <= S_NAME_D;
                S_NAME_D: begin
                    char_code_q <= mem_data;
                    // The playfield scan pointer wraps within 4K
                    // (antic_addresswrap).
                    scan_q    <= {scan_q[15:12], scan_q[11:0] + 12'd1};
                    state     <= S_DATA;
                end

                // ---- graphics byte or glyph ----------------------------
                S_DATA:   state <= S_DATA_D;
                S_DATA_D: begin
                    // A blanked mode-3 row still occupies its pixels, so store
                    // zeros rather than skipping the entry.
                    buf_mem[wr_idx] <= {char_code,
                                        row_blank ? 8'h00 : glyph_data_ctl};
                    wr_idx <= wr_idx + 6'd1;
                    if (!is_char)
                        scan_q <= {scan_q[15:12], scan_q[11:0] + 12'd1};
                    if (left <= 8'd1) begin
                        state <= S_DONE;
                    end else begin
                        left  <= left - 8'd1;
                        // Only a FIRST row goes back for another name; a later
                        // one reads glyph after glyph straight out of the
                        // buffer, which is what halves its DMA.
                        if (is_char && first_row) state <= S_NAME;
                        else                      state <= S_DATA;
                    end
                end

                S_DONE: begin
                    done  <= 1'b1;
                    busy  <= 1'b0;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    // The glyph fetch reads the character set; everything else reads the scan
    // pointer.  S_NAME_D is included because the address must be settled the
    // cycle BEFORE S_DATA samples it.
    always_comb begin
        if (is_char && (state == S_DATA || state == S_NAME_D)) mem_addr = glyph_addr;
        else                                                   mem_addr = scan_q;
    end

endmodule

`default_nettype wire
