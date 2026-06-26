// sprite_line_cache.sv — per-sprite line cache for the sprite compositor.
//
// Holds one scanline of pixel data per sprite at RGBA-8888 (32 bpp).  The
// fetcher writes the next scanline's data on clk_fetch via port A; the
// compositor reads the current scanline on clk_pix via port B.  Dual-port
// inference target: RAMB36E1 in TDP mode, one BRAM per sprite at
// 1024-entry × 32-bit organisation (parity bits unused).
//
// Read pipeline (2 cycles): the read path is two cascaded flops at the
// same clock — Vivado packs them into the RAMB36E1's internal clock-out
// FF + optional output register (DOB_REG/OREG), giving near-zero
// clock-to-Q on the external rd_data.  Synthesis specifically flagged
// the missing OREG with `Synth 8-7052` when the cache→compositor tree
// was the critical path; this absorbs that hint.
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
    input  wire                       wr_bank,      // ping-pong bank to FILL (next line)
    input  wire [N_SPRITES-1:0]       wr_en,        // one-hot
    input  wire [ADDR_W-1:0]          wr_addr,
    input  wire [PIXEL_W-1:0]         wr_data,

    // ---- Port B: reader (clk_pix) ------------------------------------------
    // 2-cycle read latency: rd_addr at cycle N → rd_data at cycle N+2.
    input  wire                       clk_b,
    input  wire                       rd_bank,      // ping-pong bank to READ (current line)
    input  wire [ADDR_W-1:0]          rd_addr [0:N_SPRITES-1],
    output logic [PIXEL_W-1:0]        rd_data [0:N_SPRITES-1]
);

    // DOUBLE-BUFFERED (ping-pong): two line banks per sprite.  The fetcher fills
    // bank wr_bank (the next scanline) while the compositor reads bank rd_bank
    // (the current scanline); the engine flips rd_bank every line_start and keeps
    // wr_bank = ~rd_bank.  A single shared buffer aliased the fetch-write against
    // the read, so the compositor saw a mix of two scanlines — invisible on a
    // uniform sprite but flickering garbage on detailed/transparent ones.
    genvar gs;
    generate
        for (gs = 0; gs < N_SPRITES; gs = gs + 1) begin : g_sprite
            (* ram_style = "block" *) logic [PIXEL_W-1:0] mem [0:2*LINE_WIDTH-1];
            logic [PIXEL_W-1:0] rd_data_int;

            // Port A: synchronous write, no read.  Bank-prefixed address.
            always_ff @(posedge clk_a) begin
                if (wr_en[gs])
                    mem[{wr_bank, wr_addr}] <= wr_data;
            end

            // Port B: two cascaded flops — Vivado absorbs both into the
            // BRAM block (clock-out FF + DOB_REG / OREG).
            always_ff @(posedge clk_b) begin
                rd_data_int <= mem[{rd_bank, rd_addr[gs]}];
                rd_data[gs] <= rd_data_int;
            end
        end
    endgenerate

endmodule

`default_nettype wire
