`default_nettype none
//
// antic_expander — line buffer -> RGBA32 -> DDR.
//
// docs/ANTIC-rewrite.md.  ANTIC/GTIA resolve one Atari colour byte per pixel as
// the beam sweeps, into antic_line_buf.  Once a line is complete this walks it,
// turns each byte into RGBA32 through the palette, and hands it to
// axi_line_writer for the DMA.
//
// Structure: an address counter, a palette lookup, and a handshake.  Per the
// complexity smell test that is all it should be — and note this module is
// PLUMBING, not ANTIC behaviour.  The real chip had no line buffer and no DDR;
// it fed GTIA straight into a CRT.  So the smell test's transistor reasoning
// does not argue against this existing, only against it growing.
//
// Colour is NOT resolved here.  The line buffer already holds the resolved
// Atari colour, decided where the beam was, so a mid-line COLPF/COLBK write is
// already baked in.  All that remains is a quasi-static palette lookup, which is
// exactly the kind of thing that IS safe to do late.
//
// CLOCK BUDGET:
//   one pixel per clock, plus a 2-clock read pipeline (line buffer -> palette).
//   A 456-pixel line therefore costs ~460 clocks.  At 100 MHz there are ~6,300
//   clocks in a 1.79 MHz scanline, so this uses ~7% of the line and is never
//   the constraint.  It deliberately does NOT try to move more than one pixel
//   per clock: there is no need, and the wide datapath would cost area we do
//   not have on the 7020.
//
`timescale 1ns/1ps

module antic_expander #(
    parameter int PIXELS = 456          // pixels per line (line-buffer depth)
) (
    input  wire        clk,
    input  wire        rst,

    // ---- trigger --------------------------------------------------------
    input  wire        line_done,       // 1-clk: a line is complete, expand it
    input  wire [11:0] line_no,         // which scanline (for the DDR address)

    // ---- line buffer read port -----------------------------------------
    output logic [9:0] lb_addr,
    input  wire [7:0]  lb_color,        // 1-clock latency

    // ---- palette --------------------------------------------------------
    output logic [7:0] pal_addr,
    input  wire [23:0] pal_rgb,         // 1-clock latency, {R,G,B}

    // ---- axi_line_writer producer port ----------------------------------
    output logic        wr_en,
    output logic [11:0] wr_col,
    output logic [31:0] wr_pixel,       // RGBA8888
    output logic        flush,
    output logic [31:0] flush_base,
    output logic [11:0] flush_w,
    input  wire         writer_busy,

    // ---- geometry -------------------------------------------------------
    input  wire [31:0] fb_base,         // DDR byte address of row 0
    input  wire [15:0] fb_stride,       // bytes per row

    output logic       busy
);

    typedef enum logic [1:0] { S_IDLE, S_WALK, S_DRAIN, S_FLUSH } state_t;
    state_t state;

    logic [9:0] rd_ptr;    // where the read pipeline is fetching
    logic [1:0] fill;      // pipeline occupancy, 0..2
    logic [9:0] wr_ptr;    // where the emitted pixel lands

    // The line buffer and the palette each add a clock, so a colour byte read
    // at rd_ptr emerges from the palette two clocks later.  Rather than track
    // tags, the walk just runs PIXELS+2 steps and only emits once the pipe has
    // filled — the cheapest correct thing.
    assign lb_addr  = rd_ptr;
    assign pal_addr = lb_color;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state      <= S_IDLE;
            rd_ptr     <= '0;
            wr_ptr     <= '0;
            fill       <= 2'd0;
            wr_en      <= 1'b0;
            wr_col     <= '0;
            wr_pixel   <= '0;
            flush      <= 1'b0;
            flush_base <= '0;
            flush_w    <= '0;
            busy       <= 1'b0;
        end else begin
            wr_en <= 1'b0;
            flush <= 1'b0;

            case (state)
                S_IDLE: begin
                    busy <= 1'b0;
                    if (line_done && !writer_busy) begin
                        rd_ptr     <= '0;
                        wr_ptr     <= '0;
                        fill       <= 2'd0;
                        flush_base <= fb_base + (32'(line_no) * 32'(fb_stride));
                        busy       <= 1'b1;
                        state      <= S_WALK;
                    end
                end

                // Advance the read pointer and, once the two-stage pipe is
                // full, emit the pixel that has fallen out of it.
                S_WALK: begin
                    if (rd_ptr != 10'(PIXELS-1)) rd_ptr <= rd_ptr + 10'd1;
                    else                         state  <= S_DRAIN;

                    if (fill == 2'd2) begin
                        wr_en    <= 1'b1;
                        wr_col   <= 12'(wr_ptr);
                        wr_pixel <= {8'hFF, pal_rgb};   // alpha opaque
                        wr_ptr   <= wr_ptr + 10'd1;
                    end else begin
                        fill <= fill + 2'd1;
                    end
                end

                // The last two pixels are still in the pipe when rd_ptr stops.
                S_DRAIN: begin
                    wr_en    <= 1'b1;
                    wr_col   <= 12'(wr_ptr);
                    wr_pixel <= {8'hFF, pal_rgb};
                    wr_ptr   <= wr_ptr + 10'd1;
                    if (wr_ptr == 10'(PIXELS-1)) state <= S_FLUSH;
                end

                S_FLUSH: begin
                    flush   <= 1'b1;
                    flush_w <= 12'(PIXELS);
                    state   <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
