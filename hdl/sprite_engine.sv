// sprite_engine.sv — hardware sprite compositor for the 1080p scan-out path.
//
// Scaffold stub (commit-1): passthrough out_pixel = fb_pixel.  All
// internal submodules (descriptor regs, line cache, fetcher, compositor)
// land in subsequent commits.  The port surface here matches the eventual
// shape so fpga_xt_top wiring is done once and untouched as the internals
// fill in.
//
// Spec: docs/Progress/sprite-engine.md.  Deviations from spec applied at
// design time, captured in the per-commit messages:
//   * Pixel format: RGBA-8888 internal (was 16-bit RGBA-5:5:5:1 in the
//     spec).  Source data still supports the 16-bit format per sprite
//     via a per-sprite control bit — fetcher upconverts at line-cache
//     write time.
//   * Register layout: $D4Ax per-sprite control bytes + $D4Dx indexed
//     descriptor / cross-product collision / global ctrl (was a single
//     contiguous $D4A0-$D4BF span that collided with the blitter at
//     $D4B0-$D4BF).
//   * clk_bus = 150 MHz (was 162 MHz in the spec).  Per-scanline AXI HP2
//     budget recomputed to ~12.4 KB.

`default_nettype none

module sprite_engine #(
    parameter int unsigned ARENA_BASE = 32'h2000_0000,
    parameter int unsigned N_SPRITES  = 16
) (
    // ---- Clocks & reset ----------------------------------------------------
    input  wire        clk_fetch,           // AXI HP2 + fetcher clock (150 MHz / clk_sys)
    input  wire        clk_pix,             // Pixel-scan clock (148.4375 MHz)
    input  wire        rst,                 // Active-high, synchronous to clk_pix

    // ---- vbeam taps (clk_pix domain, from fb_scanout) ----------------------
    input  wire [11:0] h_count,
    input  wire [11:0] v_count,
    input  wire        line_start,          // 1-cycle pulse, start of new scanline
    input  wire        frame_start,         // 1-cycle pulse, start of frame

    // ---- Register interface (SALLY hwreg bus, clk_fetch domain) ------------
    input  wire        reg_we,
    input  wire [7:0]  reg_addr,            // low 8 bits of D4xx address
    input  wire [7:0]  reg_wdata,
    output wire [7:0]  reg_rdata,

    // ---- Framebuffer pixel input (from fb_scanout, clk_pix) ----------------
    input  wire [15:0] fb_pixel,            // {R[4:0], G[5:0], B[4:0]} RGB565
    input  wire        fb_de,

    // ---- Composited pixel output (drives SOM RGB pins, clk_pix) ------------
    output wire [4:0]  rgb_r,
    output wire [5:0]  rgb_g,
    output wire [4:0]  rgb_b,
    output wire        rgb_de,

    // ---- AXI4 burst-read master (dedicated PS HP2 port, clk_fetch) ---------
    output wire [31:0] m_axi_araddr,
    output wire [7:0]  m_axi_arlen,
    output wire [2:0]  m_axi_arsize,
    output wire [1:0]  m_axi_arburst,
    output wire        m_axi_arvalid,
    input  wire        m_axi_arready,
    input  wire [63:0] m_axi_rdata,
    input  wire        m_axi_rvalid,
    input  wire        m_axi_rlast,
    output wire        m_axi_rready
);

    // ====================================================================
    // STUB: passthrough.  No descriptor regs, no fetcher, no compositor —
    // those submodules land in subsequent commits.  This lets fpga_xt_top
    // wire the sprite_engine in once and we replace internals piecewise
    // without touching the top-level instantiation.
    // ====================================================================
    assign rgb_r = fb_pixel[15:11];
    assign rgb_g = fb_pixel[10:5];
    assign rgb_b = fb_pixel[4:0];
    assign rgb_de = fb_de;

    // Register interface tied off (descriptor regs in next commit).
    assign reg_rdata = 8'h00;

    // AXI HP2 master tied off (no transactions until line fetcher lands).
    assign m_axi_araddr  = 32'd0;
    assign m_axi_arlen   = 8'd0;
    assign m_axi_arsize  = 3'd0;
    assign m_axi_arburst = 2'd0;
    assign m_axi_arvalid = 1'b0;
    assign m_axi_rready  = 1'b1;

    // Unused inputs — quiet Vivado about them until the real implementation
    // lands.  All of these become live consumers in later commits.
    /* verilator lint_off UNUSED */
    wire _unused = &{1'b0,
                     clk_fetch, clk_pix, rst,
                     h_count, v_count, line_start, frame_start,
                     reg_we, reg_addr, reg_wdata,
                     m_axi_arready, m_axi_rdata, m_axi_rvalid, m_axi_rlast,
                     1'b0};
    /* verilator lint_on UNUSED */

endmodule

`default_nettype wire
