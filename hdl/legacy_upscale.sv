// legacy_upscale.sv — 1080p pillarbox upscaler for the legacy ANTIC display.
//
// Boot-to-BASIC gap 4(b) (prompts/task-0006).  Output is always 1080p60; the
// legacy Atari image is integer-scaled and centred inside the 1920x1080
// active raster, with black bars (pillarbox left/right, letterbox top/bottom)
// filling the remainder.
//
// Architecture: this is a PEER of sprite_engine — it consumes fb_scanout's
// 1080p raster (h_count / v_count / de / hsync / vsync, all clk_pix) and
// produces RGB565 for the same raster.  So its output is inherently a valid
// 1080p60 signal; the display-source mux in fpga_xt_top selects it for
// legacy mode.  The native ANTIC hdmi_out/scan_out chain is bypassed for the
// HDMI output — only ANTIC's rendered pixels (palette indices) need to land
// in this module's frame store.
//
//   frame store (ATARI_W x ATARI_H palette indices, dual-clock BRAM):
//     written by the ANTIC capture path on wr_clk (clk_bus side),
//     read in the clk_pix raster.
//   palette_lut: 256-entry index -> RGB888, written (CDC'd) to mirror the
//     ANTIC palette.
//
// Scale is power-of-two (shift) so the back-map needs no divider.  The
// defaults (384x240 image, 4x4 -> 1536x960 centred in 1920x1080) leave
// 192 px pillarbox bars and 60 px letterbox bars.  Tune H_SHIFT/V_SHIFT for
// the final aspect once on hardware.
//
// Pipeline (clk_pix), 2 stages to cover the BRAM + palette read latency:
//   s0 (comb): from h_count/v_count compute in-window + (atari_row, atari_col)
//              + frame-store read address.
//   s1 (reg):  fs_index  = frame_store[addr];   timing/in-window piped 1.
//   s2 (reg):  pal_rgb   = palette[fs_index];    timing/in-window piped 2.
//   out:       rgb = in_window ? pal_rgb565 : black; sync follows the pipe.

`default_nettype none

module legacy_upscale #(
    parameter int H_ACTIVE = 1920,
    parameter int V_ACTIVE = 1080,
    parameter int ATARI_W  = 384,
    parameter int ATARI_H  = 240,
    parameter int H_SHIFT  = 2,     // horizontal scale = 2**H_SHIFT
    parameter int V_SHIFT  = 2      // vertical   scale = 2**V_SHIFT
) (
    // ---- 1080p raster (clk_pix), from fb_scanout ------------------------
    input  wire        clk_pix,
    input  wire        rst_pix,
    input  wire [11:0] h_count,     // 0..H_TOTAL-1 (active when < H_ACTIVE)
    input  wire [11:0] v_count,     // 0..V_TOTAL-1 (active when < V_ACTIVE)
    input  wire        de,          // raster data-enable (active video)
    input  wire        hsync,
    input  wire        vsync,

    // ---- Frame-store write (ANTIC capture, wr_clk = clk_bus) ------------
    input  wire        wr_clk,
    input  wire        wr_en,
    input  wire [8:0]  wr_row,      // 0..ATARI_H-1
    input  wire [8:0]  wr_col,      // 0..ATARI_W-1
    input  wire [7:0]  wr_index,    // Atari colour index for this pixel

    // ---- Palette write (clk_pix; CDC'd from antic_regs) -----------------
    input  wire        pal_we,
    input  wire [7:0]  pal_waddr,
    input  wire [23:0] pal_wdata,   // {R[7:0], G[7:0], B[7:0]}

    // ---- RGB565 output (clk_pix), pipeline-aligned ----------------------
    output reg  [4:0]  rgb_r,
    output reg  [5:0]  rgb_g,
    output reg  [4:0]  rgb_b,
    output reg         de_o,
    output reg         hsync_o,
    output reg         vsync_o
);

    // ---- Derived geometry -------------------------------------------------
    localparam int SCALED_W = ATARI_W << H_SHIFT;
    localparam int SCALED_H = ATARI_H << V_SHIFT;
    localparam int H_OFF    = (H_ACTIVE - SCALED_W) / 2;   // left pillarbox width
    localparam int V_OFF    = (V_ACTIVE - SCALED_H) / 2;   // top letterbox height
    localparam int FS_DEPTH = ATARI_W * ATARI_H;
    localparam int FS_AW    = $clog2(FS_DEPTH);

    // ---- Frame store (dual-clock true-dual-port BRAM) --------------------
    (* ram_style = "block" *)
    logic [7:0] frame_store [0:FS_DEPTH-1];

    wire [FS_AW-1:0] wr_addr = FS_AW'(wr_row * ATARI_W + wr_col);
    always_ff @(posedge wr_clk) begin
        if (wr_en) frame_store[wr_addr] <= wr_index;
    end

    // ---- s0: back-map the 1080p pixel to an Atari pixel ------------------
    wire h_in = (h_count >= H_OFF) && (h_count < H_OFF + SCALED_W);
    wire v_in = (v_count >= V_OFF) && (v_count < V_OFF + SCALED_H);
    wire in_window = de && h_in && v_in;

    wire [11:0] h_rel = h_count - H_OFF[11:0];
    wire [11:0] v_rel = v_count - V_OFF[11:0];
    wire [8:0]  atari_col = h_rel[H_SHIFT +: 9];   // (h_count-H_OFF) >> H_SHIFT
    wire [8:0]  atari_row = v_rel[V_SHIFT +: 9];   // (v_count-V_OFF) >> V_SHIFT

    // Clamp the read address to 0 outside the window so an off-image pixel
    // can never index past the store (output is forced black anyway).
    wire [FS_AW-1:0] fs_raddr = in_window ? FS_AW'(atari_row * ATARI_W + atari_col)
                                          : '0;

    // ---- s1: frame-store read + 1-stage timing pipe ----------------------
    logic [7:0] fs_index_q;
    logic       in_win_s1, de_s1, hs_s1, vs_s1;
    always_ff @(posedge clk_pix) begin
        fs_index_q <= frame_store[fs_raddr];
        in_win_s1  <= in_window;
        de_s1      <= de;
        hs_s1      <= hsync;
        vs_s1      <= vsync;
    end

    // ---- palette: index -> RGB888 (1-clock read) ------------------------
    wire [23:0] pal_rgb;
    // Palette is written at runtime via pal_we (CDC'd from antic_regs), so
    // no compile-time init file is needed here.
    palette_lut #(.ADDR_W(8), .INIT_FILE("")) u_pal (
        .clk   (clk_pix),
        .we    (pal_we),
        .waddr (pal_waddr),
        .wdata (pal_wdata),
        .raddr (fs_index_q),
        .rdata (pal_rgb)
    );

    // ---- s2: align timing with the palette read, then drive output -------
    logic in_win_s2, de_s2, hs_s2, vs_s2;
    always_ff @(posedge clk_pix) begin
        in_win_s2 <= in_win_s1;
        de_s2     <= de_s1;
        hs_s2     <= hs_s1;
        vs_s2     <= vs_s1;
    end

    always_ff @(posedge clk_pix) begin
        if (rst_pix) begin
            rgb_r <= 5'd0; rgb_g <= 6'd0; rgb_b <= 5'd0;
            de_o  <= 1'b0; hsync_o <= 1'b0; vsync_o <= 1'b0;
        end else begin
            // Inside the Atari image: palette colour (RGB888 -> RGB565).
            // Bars (and blanking): black, but de still follows the raster.
            rgb_r   <= in_win_s2 ? pal_rgb[23:19] : 5'd0;   // R[7:3]
            rgb_g   <= in_win_s2 ? pal_rgb[15:10] : 6'd0;   // G[7:2]
            rgb_b   <= in_win_s2 ? pal_rgb[7:3]   : 5'd0;   // B[7:3]
            de_o    <= de_s2;
            hsync_o <= hs_s2;
            vsync_o <= vs_s2;
        end
    end

endmodule

`default_nettype wire
