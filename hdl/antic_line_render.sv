`default_nettype none
//
// antic_line_render — turn the fetched line into coloured pixels.
//
// docs/ANTIC-rewrite.md.  antic_pf_fetch has already filled ANTIC's internal
// line buffer; this walks it, shifts out pixels and resolves each one to an
// Atari colour byte.  It drives antic_pixel_shift -> antic_pf_source ->
// antic_color_sel.
//
// EMISSION IS PACED BY THE BEAM.  emit_en pulses once per hi-res pixel and only
// inside the live display window, so the colour registers are sampled AS EACH
// PIXEL IS EMITTED and a mid-line COLPF write lands exactly where the beam was.
// The old compositor decided a whole row at one instant and could not express
// that — it is why roughly half the ANTIC failures were unreachable.
//
// A LINE NEED NOT FINISH.  A scrolled narrow line has 40 bytes in the buffer and
// a 32-byte window; when the window closes emission simply stops, and `start`
// restarts the walk for the next scanline.  Nothing downstream cares, because
// the scan pointer is the fetcher's business, not ours.
//
// Everything to do with WHERE the bytes came from — the scan pointer, the two
// fetches a character costs, glyph row selection, CHACTL — lives in
// antic_pf_fetch.  This module only ever sees a buffer index.
//
// CLOCK BUDGET: one clock per hi-res pixel, plus two to reload the shifter every
// 8 pixels.  At 4 pixels per machine cycle there are ~14 fabric clocks between
// pixels, so the reload has ample room and never stalls the emit.
//
`timescale 1ns/1ps

module antic_line_render (
    input  wire        clk,
    input  wire        rst,

    // ---- what to draw ----------------------------------------------------
    input  wire        start,          // 1-clk: begin this line (restarts)
    input  wire        emit_en,        // 1-clk per hi-res pixel, window-gated
    input  wire [3:0]  mode,
    input  wire [7:0]  bytes_per_line,

    // ---- colour registers, sampled as each pixel is emitted -------------
    input  wire [7:0]  colbk, colpf0, colpf1, colpf2, colpf3,

    // ---- ANTIC's internal line buffer ------------------------------------
    output logic [5:0] rd_idx,
    input  wire  [7:0] rd_data,        // glyph or graphics byte
    input  wire  [7:0] rd_code,        // character code, for the colour select

    // ---- line buffer write port ------------------------------------------
    output wire        lb_wr,
    output wire  [7:0] lb_color,
    // GTIA needs the SOURCE, not the colour: priority and collisions are
    // decided on which playfield this is, and only then coloured.
    output wire  [2:0] lb_pf_src,
    // ...and in a GTIA mode it needs the RAW value instead, because those modes
    // do not interpret it as a playfield at all.  Two bits per colour clock is
    // what ANTIC sends whatever mode it is in; see gtia_special.
    output wire  [1:0] lb_px_val,
    output wire        lb_is_hires,

    output logic       busy,
    output logic       done            // 1-clk when the last byte is emitted
);

    // ---- mode parameters -------------------------------------------------
    wire       is_char, descender_u, is_display;
    wire [1:0] bpp;
    wire [3:0] px_width;
    wire [4:0] rows_u;

    antic_mode_tbl u_tbl (
        .mode(mode), .is_char(is_char), .bpp(bpp), .px_width(px_width),
        .rows(rows_u), .descender(descender_u), .is_display(is_display)
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

    wire [2:0] pf_src;

    // rd_code is combinational from rd_idx, which holds still for the whole
    // byte, so the colour select sees the right character with no register.
    antic_pf_source u_src (
        .is_char(is_char), .bpp(bpp), .is_hires(is_hires),
        .px_val(px_val), .char_code(rd_code), .pf_src(pf_src)
    );

    wire [7:0] pixel_color;

    // Unlit hi-res (pf_src 6) DRAWS as playfield 2; only its collision differs,
    // and antic_color_sel's 6 means PM0, so map it here rather than there.
    wire [3:0] col_src = (pf_src == 3'd6) ? 4'd3 : {1'b0, pf_src};

    antic_color_sel u_col (
        .src(col_src),
        .colbk(colbk), .colpf0(colpf0), .colpf1(colpf1),
        .colpf2(colpf2), .colpf3(colpf3),
        .colpm0(8'h00), .colpm1(8'h00), .colpm2(8'h00), .colpm3(8'h00),
        .color(pixel_color)
    );

    // ---- the walk --------------------------------------------------------
    typedef enum logic [2:0] {
        S_IDLE, S_LOAD, S_LOADED, S_EMIT, S_DONE
    } state_t;
    state_t state;

    logic [7:0] left;                  // bytes still to emit

    // Emit strobes are COMBINATIONAL, not registered.  With a registered tick
    // the shifter advanced one cycle AFTER px_val was sampled, so the first
    // pixel of every byte was written twice and the whole line shifted by one.
    // Driving both from the same condition puts the line-buffer capture and the
    // shifter advance on the same clock edge.
    assign sh_tick  = (state == S_EMIT) && !exhausted && emit_en;
    assign lb_wr    = (state == S_EMIT) && !exhausted && emit_en;
    assign lb_color = pixel_color;
    assign lb_pf_src   = pf_src;
    assign lb_px_val   = px_val;
    assign lb_is_hires = is_hires;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state   <= S_IDLE;
            rd_idx  <= 6'd0;
            left    <= 8'd0;
            sh_load <= 1'b0;
            sh_data <= 8'h00;
            busy    <= 1'b0;
            done    <= 1'b0;
        end else begin
            sh_load <= 1'b0;
            done    <= 1'b0;

            if (start) begin
                rd_idx <= 6'd0;
                left   <= bytes_per_line;
                busy   <= 1'b1;
                if (!is_display || bytes_per_line == 8'd0) state <= S_DONE;
                else                                       state <= S_LOAD;
            end else
            case (state)
                S_IDLE: busy <= 1'b0;

                S_LOAD: begin
                    sh_data <= rd_data;
                    sh_load <= 1'b1;
                    state   <= S_LOADED;
                end

                // One cycle for sh_load to land.  Without it S_EMIT would
                // evaluate `exhausted` while the shifter still held the
                // PREVIOUS byte's (zero) bit count, conclude the byte was
                // already finished and skip it — which showed up as every
                // render being short by a non-integer number of pixels.
                S_LOADED: state <= S_EMIT;

                S_EMIT: begin
                    if (exhausted) begin
                        if (left <= 8'd1) begin
                            state <= S_DONE;
                        end else begin
                            left   <= left - 8'd1;
                            rd_idx <= rd_idx + 6'd1;
                            state  <= S_LOAD;
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

endmodule

`default_nettype wire
