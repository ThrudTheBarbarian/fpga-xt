`default_nettype none
//
// antic_line_render — render one scanline into the line buffer.
//
// docs/ANTIC-rewrite.md.  Given a mode, a memory-scan address and which row of
// the character/graphics block we are on, this walks the line: fetch a byte,
// emit its pixels, fetch the next.  It drives antic_pixel_shift ->
// antic_pf_source -> antic_color_sel and writes the resulting colour bytes into
// antic_line_buf.
//
// FETCH-THEN-EMIT IS NOT THE BURST MISTAKE.  The old compositor decided a whole
// row's pixels at one instant, so a register written partway along the line
// could not affect it.  Here the colour registers are sampled AS EACH PIXEL IS
// EMITTED, so a mid-line COLPF write lands exactly where the beam was.  What
// this model does not yet reproduce is WHICH CYCLE each fetch happens on — that
// is the DMA schedule, and it matters for CPU cycle stealing, not for pixel
// correctness.  It arrives when the CPU is reattached.
//
// Character modes cost two fetches per character: the NAME from the scan
// address, then the GLYPH from CHBASE.  Bitmap modes fetch once.  CHACTL sits
// on both sides of that second fetch — reflect XORs the row going in, blank and
// invert rewrite the data coming out (antic_char_ctl).
//
// GLYPH ROW SELECTION carries the two quirks the hardware has:
//   * 16-row modes (5, 7) show each glyph row twice, so the glyph row is
//     row >> 1.
//   * mode 3 has a 10-row cell.  Characters with code[6:5] == 11 are
//     descenders: their rows 0 and 1 come from glyph rows 6 and 7, and rows
//     2..9 from glyph rows 0..7.  Ordinary characters use rows 0..7 and are
//     BLANK on rows 8 and 9.
//
// CLOCK BUDGET: 2 clocks per fetch plus one per hi-res pixel.  Worst case is a
// character mode at 40 characters: 40*(2+2) fetch clocks + 320 pixel clocks =
// ~480 of the ~6,300 clocks in a 1.79 MHz scanline.
//
`timescale 1ns/1ps

module antic_line_render (
    input  wire        clk,
    input  wire        rst,

    // ---- what to draw ---------------------------------------------------
    input  wire        start,          // 1-clk: render a line
    input  wire [3:0]  mode,
    input  wire [15:0] scan_addr_in,   // memory scan pointer for this line
    input  wire [4:0]  row,            // row within the block, 0..rows-1
    input  wire [7:0]  chbase,
    input  wire [2:0]  chactl,         // $D401 blank/invert/reflect
    input  wire [7:0]  bytes_per_line, // 40, 20 or 10 (width-dependent)

    // ---- colour registers, sampled as each pixel is emitted -------------
    input  wire [7:0]  colbk, colpf0, colpf1, colpf2, colpf3,

    // ---- memory (1-clock read latency, no wait states) -------------------
    output logic [15:0] mem_addr,
    input  wire  [7:0]  mem_data,

    // ---- line buffer write port ----------------------------------------
    output wire         lb_wr,
    output wire  [7:0]  lb_color,

    output logic [15:0] scan_addr_out,  // advanced past this line
    output logic        busy,
    output logic        done            // 1-clk when the line is complete
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

    wire is_hires = (px_width == 4'd1) && (bpp == 2'd1);

    // ---- pixel datapath --------------------------------------------------
    logic       sh_load;
    wire        sh_tick;
    logic [7:0] sh_data;
    wire  [1:0] px_val;
    wire        exhausted;

    antic_pixel_shift u_shift (
        .clk(clk), .rst(rst), .bpp(bpp), .px_width(px_width),
        .load(sh_load), .data(sh_data), .px_tick(sh_tick),
        .px_val(px_val), .exhausted(exhausted)
    );

    logic [7:0] char_code;
    wire  [2:0] pf_src;

    antic_pf_source u_src (
        .is_char(is_char), .bpp(bpp), .is_hires(is_hires),
        .px_val(px_val), .char_code(char_code), .pf_src(pf_src)
    );

    wire [7:0] pixel_color;

    antic_color_sel u_col (
        .src({1'b0, pf_src}),
        .colbk(colbk), .colpf0(colpf0), .colpf1(colpf1),
        .colpf2(colpf2), .colpf3(colpf3),
        .colpm0(8'h00), .colpm1(8'h00), .colpm2(8'h00), .colpm3(8'h00),
        .color(pixel_color)
    );

    // ---- glyph row -------------------------------------------------------
    // 16-row modes show each glyph row twice; mode 3's descenders rotate.
    logic [2:0] glyph_row;
    logic       row_blank;             // mode 3 rows 8/9 of a non-descender

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

    // CHACTL sits between the row counter and the character set on the way in,
    // and between the character set and the shifter on the way out.
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
        S_IDLE, S_NAME, S_NAME_D, S_DATA, S_DATA_D, S_LOADED, S_EMIT, S_DONE
    } state_t;
    state_t state;

    logic [15:0] scan_q;
    logic [7:0]  left;                 // bytes still to draw on this line

    // Emit strobes are COMBINATIONAL, not registered.  With a registered tick
    // the shifter advanced one cycle AFTER px_val was sampled, so the first
    // pixel of every byte was written twice and the whole line shifted by one.
    // Driving both from the same condition puts the line-buffer capture and the
    // shifter advance on the same clock edge.
    assign sh_tick  = (state == S_EMIT) && !exhausted;
    assign lb_wr    = (state == S_EMIT) && !exhausted;
    assign lb_color = pixel_color;


    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state     <= S_IDLE;
            scan_q    <= 16'h0000;
            left      <= 8'd0;
            char_code <= 8'h00;
            sh_load   <= 1'b0;
            sh_data   <= 8'h00;
            busy      <= 1'b0;
            done      <= 1'b0;
        end else begin
            sh_load <= 1'b0;
            done    <= 1'b0;

            case (state)
                S_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        scan_q <= scan_addr_in;
                        left   <= bytes_per_line;
                        busy   <= 1'b1;
                        // if/else rather than a ternary: assigning an enum
                        // from a conditional expression needs an explicit cast.
                        if (!is_display)  state <= S_DONE;
                        else if (is_char) state <= S_NAME;
                        else              state <= S_DATA;
                    end
                end

                // ---- character name ------------------------------------
                S_NAME:   state <= S_NAME_D;
                S_NAME_D: begin
                    char_code <= mem_data;
                    scan_q    <= {scan_q[15:12], scan_q[11:0] + 12'd1};  // 4K wrap
                    state     <= S_DATA;
                end

                // ---- graphics byte or glyph ----------------------------
                S_DATA:   state <= S_DATA_D;
                S_DATA_D: begin
                    // A blanked mode-3 row still occupies its pixels, so feed
                    // the shifter zeros rather than skipping it.
                    sh_data <= row_blank ? 8'h00 : glyph_data_ctl;
                    sh_load <= 1'b1;
                    if (!is_char)
                        scan_q <= {scan_q[15:12], scan_q[11:0] + 12'd1};
                    state <= S_LOADED;
                end

                // One cycle for sh_load to land.  Without it S_EMIT would
                // evaluate `exhausted` while the shifter still held the
                // PREVIOUS byte's (zero) bit count, conclude the byte was
                // already finished and skip it — which showed up as every
                // render being short by a non-integer number of pixels.
                S_LOADED: state <= S_EMIT;

                // ---- emit this byte's pixels ---------------------------
                S_EMIT: begin
                    if (exhausted) begin
                        if (left <= 8'd1) state <= S_DONE;
                        else begin
                            left <= left - 8'd1;
                            if (is_char) state <= S_NAME;
                            else         state <= S_DATA;
                        end
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

    assign scan_addr_out = scan_q;

    // The glyph fetch reads CHBASE; everything else reads the scan pointer.
    always_comb begin
        if (is_char && (state == S_DATA || state == S_NAME_D)) mem_addr = glyph_addr;
        else                                                   mem_addr = scan_q;
    end

endmodule

`default_nettype wire
