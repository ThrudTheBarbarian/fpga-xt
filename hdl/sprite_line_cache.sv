// sprite_line_cache.sv — per-sprite line cache for the sprite compositor.
//
// Holds one scanline of pixel data per sprite at RGBA-8888 (32 bpp).  The
// fetcher writes the next scanline's data on clk_fetch via port A; the
// compositor reads the current scanline on clk_pix via port B.  Dual-port
// inference target: RAMB36E1 in TDP mode, one BRAM per sprite at
// 1024-entry × 32-bit organisation (parity bits unused).
//
// Address space:
//   wr_addr is shared across all sprites — the fetcher iterates sprites
//   sequentially and asserts a one-hot wr_en bit at any given moment.
//   rd_addr is PER-sprite: each sprite has its own screen_x, so the
//   compositor computes a distinct local_x for every sprite at every
//   pixel.  Reads run in parallel across all 16 BRAMs.
//
// Reset semantics: BRAM contents come up undefined.  Compositor's own
// hit / alpha gating ensures only valid pixels reach the output.

`default_nettype none

module sprite_line_cache #(
    parameter int unsigned N_SPRITES  = 16,
    parameter int unsigned LINE_WIDTH = 1024,
    parameter int unsigned PIXEL_W    = 32,
    parameter int unsigned ADDR_W     = 10        // $clog2(LINE_WIDTH)
) (
    // ---- Port A: writer (clk_fetch) ----------------------------------------
    input  wire                       clk_a,
    input  wire [N_SPRITES-1:0]       wr_en,        // one-hot
    input  wire [ADDR_W-1:0]          wr_addr,
    input  wire [PIXEL_W-1:0]         wr_data,

    // ---- Port B: reader (clk_pix) ------------------------------------------
    input  wire                       clk_b,
    input  wire [ADDR_W-1:0]          rd_addr [0:N_SPRITES-1],  // per-sprite
    output logic [PIXEL_W-1:0]        rd_data [0:N_SPRITES-1]
);

    genvar gs;
    generate
        for (gs = 0; gs < N_SPRITES; gs = gs + 1) begin : g_sprite
            (* ram_style = "block" *) logic [PIXEL_W-1:0] mem [0:LINE_WIDTH-1];

            // Port A: synchronous write, no read.
            always_ff @(posedge clk_a) begin
                if (wr_en[gs])
                    mem[wr_addr] <= wr_data;
            end

            // Port B: registered read.  One-cycle BRAM read latency matches
            // the compositor pipeline's stage-1 FF.
            always_ff @(posedge clk_b) begin
                rd_data[gs] <= mem[rd_addr[gs]];
            end
        end
    endgenerate

endmodule

`default_nettype wire
