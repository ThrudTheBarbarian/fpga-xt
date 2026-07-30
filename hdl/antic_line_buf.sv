`default_nettype none
//
// antic_line_buf — the scanline the beam is drawing.
//
// docs/ANTIC-rewrite.md.  ANTIC/GTIA resolve one pixel per colour clock as the
// beam sweeps; this holds that line so the expander can turn it into RGBA32 in
// DDR on a line cadence.
//
// ONE BYTE PER PIXEL, holding the RESOLVED Atari colour (hue[7:4], luma[3:1]).
// Colour must be resolved as the beam passes, not later: if this held indices
// and the expander coloured them, a mid-line COLPF/COLBK write would be lost —
// which is exactly the bug the rewrite exists to remove.  The palette is
// quasi-static, so hue:luma -> RGB is safe to do downstream, and a byte per
// pixel costs a quarter of what RGBA32 would.
//
// PING-PONG.  ANTIC writes the line the beam is on while the expander reads the
// line behind it.  `swap` flips them at the line boundary.
//
// Structure: a BRAM and a write counter.  Per the complexity smell test in the
// plan, that is all this should ever be — ANTIC had no line buffer at all (it
// fed GTIA straight into a CRT), so this exists for our framebuffer target, but
// it earns its place only by staying trivial.
//
// CLOCK BUDGET (the plan requires every module to state one):
//   write side — 1 clock per pixel emitted, i.e. 2 of the ~56 fabric clocks in
//                a machine cycle at hi-res.  Nothing is shared or contended.
//   read side  — 1 clock per pixel consumed, registered output (1 clock
//                latency).  The expander has ~6,300 clocks per line to move
//                ~456 pixels, so it is never the constraint.
//
`timescale 1ns/1ps

module antic_line_buf #(
    // 228 colour clocks per scanline, 2 hi-res pixels each.  Covers the widest
    // playfield (192 cc = 384 px) plus the full border either side.
    parameter int PIXELS = 456
) (
    input  wire        clk,
    input  wire        rst,

    // ---- write side: the beam ------------------------------------------
    input  wire        line_start,   // 1-clk: rewind the write pointer
    input  wire        wr_stb,       // 1-clk: emit one pixel at the write ptr
    input  wire [7:0]  wr_color,     // resolved Atari colour
    output wire [9:0]  wr_index,     // where the next pixel lands (debug/test)

    // ---- read side: the expander ---------------------------------------
    input  wire [9:0]  rd_addr,
    output logic [7:0] rd_color,     // 1-clock read latency

    // ---- bank control ---------------------------------------------------
    input  wire        swap          // 1-clk: writer and reader change places
);

    localparam int AW = $clog2(PIXELS);

    // One memory, twice the depth; the bank bit is the top address bit.  Two
    // separate arrays would need a mux on the read path for no benefit.
    (* ram_style = "block" *)
    logic [7:0] mem [0:(2*PIXELS)-1];

    logic          wr_bank;          // which half the beam is writing
    logic [AW-1:0] wr_ptr;

    assign wr_index = {{(10-AW){1'b0}}, wr_ptr};

    // Reads come from the OTHER bank — that is the whole point of the swap.
    wire [AW-1:0] rd_ptr = rd_addr[AW-1:0];

    always_ff @(posedge clk) begin
        if (rst) begin
            wr_bank <= 1'b0;
            wr_ptr  <= '0;
        end else begin
            if (swap)       wr_bank <= ~wr_bank;
            // line_start and swap both rewind; ordering matters only if they
            // coincide, and rewinding twice is harmless.
            if (line_start || swap) wr_ptr <= '0;
            else if (wr_stb && wr_ptr != AW'(PIXELS-1))
                wr_ptr <= wr_ptr + AW'(1);
        end
    end

    // Write and read in one clocked block so the tool infers a true dual-port
    // BRAM rather than distributed RAM.
    always_ff @(posedge clk) begin
        if (wr_stb) mem[{wr_bank, wr_ptr}] <= wr_color;
        rd_color <= mem[{~wr_bank, rd_ptr}];
    end

endmodule

`default_nettype wire
