// plane_compositor.sv — multi-plane display compositor core (phase 1).
//
// docs/video/video-architecture.md section 4.  Composites N depth-ordered
// planes, each with an integer scale, an origin,
// and a clip rect.  For every output pixel it picks the front-most (highest
// depth) plane whose clip rect covers it, back-maps to that plane's source
// coordinate (nearest-neighbour, divider-free accumulator), and emits the
// source pixel; uncovered pixels emit the background colour.
//
// This core is BRAM-free.  Each plane has a source read interface:
//   the compositor drives {src_row_o[i], src_col_o[i]}; the source returns
//   src_pixel_i[i] (RGBA8888) registered 1 clk_pix later.
// In the unit test the source is a small frame store; in the real system
// (phase 1b) it is a per-plane line buffer kept current by an AXI fetch unit
// (src_row_o tells the fetch unit which DDR3 row to load; src_col_o reads
// within the loaded line).  The 1-cycle source latency is matched by a
// 1-stage pipeline on the coverage/winner decision.
//
// Coverage is rectangle + priority (NOT a depth bitmap) — see the spec for
// why that suffices here and the upgrade path.  clip rect = the visible
// client area (≤ window rect); for v1 it equals the window rect.
//
// Config buses are flattened {plane}*{width} so N_PLANES stays a parameter.

`default_nettype none

module plane_compositor #(
    parameter int N_PLANES = 2,
    parameter int H_ACTIVE = 1920,
    parameter int V_ACTIVE = 1080
) (
    // ---- 1080p raster (clk_pix), from vbeam ------------------------------
    input  wire        clk_pix,
    input  wire        rst_pix,
    input  wire [11:0] h_count,
    input  wire [11:0] v_count,
    input  wire        de,
    input  wire        hsync,
    input  wire        vsync,
    input  wire        line_start,

    // ---- Per-plane config (flattened, clk_pix-stable) --------------------
    input  wire [N_PLANES-1:0]      pl_enable,
    input  wire [N_PLANES-1:0]      pl_alpha_en,   // 1 = alpha-blend this plane over the one behind
                                                   // (0 = opaque: emit RGB, ignore stored alpha)
    input  wire [N_PLANES*12-1:0]   pl_origin_x,   // screen x where src col 0 lands
    input  wire [N_PLANES*12-1:0]   pl_origin_y,   // screen y where src row 0 lands
    input  wire [N_PLANES*3-1:0]    pl_scale,      // integer 1..7 (0 -> treated as 1)
    input  wire [N_PLANES*4-1:0]    pl_depth,      // higher = nearer front (unique)
    input  wire [N_PLANES*12-1:0]   pl_clip_x0,    // visible client rect (x1/y1 exclusive)
    input  wire [N_PLANES*12-1:0]   pl_clip_y0,
    input  wire [N_PLANES*12-1:0]   pl_clip_x1,
    input  wire [N_PLANES*12-1:0]   pl_clip_y1,
    input  wire [23:0]              bg_color,      // {R,G,B} where nothing covers

    // ---- Per-plane source interface (frame store or line-buf+fetch) ------
    output wire [N_PLANES*12-1:0]   src_col_o,
    output wire [N_PLANES*12-1:0]   src_row_o,     // source row for THIS scanline
    output wire [N_PLANES*12-1:0]   src_row_next_o, // source row for the NEXT scanline (prefetch)
    input  wire [N_PLANES*32-1:0]   src_pixel_i,   // RGBA8888, registered 1 clk after addr

    // ---- RGB565 output (clk_pix), pipeline-aligned -----------------------
    output reg  [4:0]  rgb_r,
    output reg  [5:0]  rgb_g,
    output reg  [4:0]  rgb_b,
    output reg         de_o,
    output reg         hsync_o,
    output reg         vsync_o
);

    // Convenience slices.
    function automatic [11:0] f12(input [N_PLANES*12-1:0] bus, input int i);
        f12 = bus[i*12 +: 12];
    endfunction

    // ---- Per-plane back-map accumulators ---------------------------------
    // src_col advances every `scale` covered pixels along the line; src_row
    // every `scale` covered scanlines.  Divider-free, any integer scale.
    genvar gi;
    logic [11:0] src_col [0:N_PLANES-1];
    logic [11:0] src_row [0:N_PLANES-1];

    generate
        for (gi = 0; gi < N_PLANES; gi = gi + 1) begin : g_accum
            wire [2:0]  scale   = pl_scale[gi*3 +: 3];
            wire [2:0]  scale_m1 = (scale == 3'd0) ? 3'd0 : (scale - 3'd1);
            wire [11:0] cx0 = f12(pl_clip_x0, gi);
            wire [11:0] cx1 = f12(pl_clip_x1, gi);
            wire [11:0] cy0 = f12(pl_clip_y0, gi);
            wire [11:0] cy1 = f12(pl_clip_y1, gi);

            wire h_in_clip = (h_count >= cx0) && (h_count < cx1);
            wire v_in_clip = (v_count >= cy0) && (v_count < cy1);

            logic [2:0] hsub, vsub;

            // Horizontal: reset each line; advance inside the clip span.
            always_ff @(posedge clk_pix or posedge rst_pix) begin
                if (rst_pix) begin
                    src_col[gi] <= 12'd0;
                    hsub        <= 3'd0;
                end else if (line_start) begin
                    src_col[gi] <= 12'd0;
                    hsub        <= 3'd0;
                end else if (h_in_clip) begin
                    if (hsub == scale_m1) begin
                        hsub        <= 3'd0;
                        src_col[gi] <= src_col[gi] + 12'd1;
                    end else begin
                        hsub <= hsub + 3'd1;
                    end
                end
            end

            // Vertical: reset at the window's top line; advance per `scale`
            // covered scanlines.  Updated once per line at line_start (when
            // v_count already holds the line that is about to display).
            always_ff @(posedge clk_pix or posedge rst_pix) begin
                if (rst_pix) begin
                    src_row[gi] <= 12'd0;
                    vsub        <= 3'd0;
                end else if (line_start) begin
                    if (v_count == cy0) begin
                        src_row[gi] <= 12'd0;
                        vsub        <= 3'd0;
                    end else if (v_in_clip) begin
                        if (vsub == scale_m1) begin
                            vsub        <= 3'd0;
                            src_row[gi] <= src_row[gi] + 12'd1;
                        end else begin
                            vsub <= vsub + 3'd1;
                        end
                    end
                end
            end

            assign src_col_o[gi*12 +: 12] = src_col[gi];
            assign src_row_o[gi*12 +: 12] = src_row[gi];

            // Source row for the NEXT scanline — the per-plane fetch unit
            // prefetches this during the current line (see plane_fetch's
            // contract).  Divider-free: derived combinationally from the
            // CURRENT registered accumulator state (src_row/vsub), NOT a
            // `(y-origin)/scale` divide (which is a long carry chain off
            // v_count and blows the clk_pix path).  It is exactly the value
            // src_row[gi] will take at the next line_start, so it tracks the
            // §4.2 accumulator with zero extra divide.
            wire [11:0] v_next       = v_count + 12'd1;
            wire        next_in_clip = (v_next >= cy0) && (v_next < cy1);
            assign src_row_next_o[gi*12 +: 12] =
                  (v_next == cy0)  ? 12'd0
                : next_in_clip     ? ((vsub == scale_m1) ? (src_row[gi] + 12'd1)
                                                         : src_row[gi])
                : 12'd0;
        end
    endgenerate

    // ---- Coverage + priority: top-2 covered planes by depth --------------
    // winner = front-most covered plane; runner = the next one down — the plane
    // an alpha-enabled winner blends OVER.  Depths are unique (spec).
    localparam int WB = $clog2(N_PLANES>1?N_PLANES:2);
    logic                       any_c, has_runner_c;
    logic [WB-1:0]              winner, runner;
    logic [3:0]                 best_depth, second_depth;
    integer pi;
    always_comb begin
        any_c        = 1'b0;
        has_runner_c = 1'b0;
        winner       = '0;
        runner       = '0;
        best_depth   = 4'd0;
        second_depth = 4'd0;
        for (pi = 0; pi < N_PLANES; pi = pi + 1) begin
            if (pl_enable[pi]
                && de
                && (h_count >= f12(pl_clip_x0, pi)) && (h_count < f12(pl_clip_x1, pi))
                && (v_count >= f12(pl_clip_y0, pi)) && (v_count < f12(pl_clip_y1, pi))) begin
                if (!any_c || (pl_depth[pi*4 +: 4] > best_depth)) begin
                    has_runner_c = any_c;                 // old winner drops to runner
                    runner       = winner;
                    second_depth = best_depth;
                    any_c        = 1'b1;
                    winner       = pi[WB-1:0];
                    best_depth   = pl_depth[pi*4 +: 4];
                end else if (!has_runner_c || (pl_depth[pi*4 +: 4] > second_depth)) begin
                    has_runner_c = 1'b1;
                    runner       = pi[WB-1:0];
                    second_depth = pl_depth[pi*4 +: 4];
                end
            end
        end
    end

    // ---- Stage 1: register the decision (aligns with the 1-clk source read).
    logic                       any_q, has_runner_q, blend_q;
    logic [WB-1:0]              winner_q, runner_q;
    logic                       de_q, hs_q, vs_q;
    always_ff @(posedge clk_pix or posedge rst_pix) begin
        if (rst_pix) begin
            any_q <= 1'b0; has_runner_q <= 1'b0; blend_q <= 1'b0;
            winner_q <= '0; runner_q <= '0;
            de_q  <= 1'b0; hs_q <= 1'b0; vs_q <= 1'b0;
        end else begin
            any_q        <= any_c;
            has_runner_q <= has_runner_c;
            blend_q      <= any_c && pl_alpha_en[winner];   // winner wants blending
            winner_q     <= winner;
            runner_q     <= runner;
            de_q  <= de;    hs_q <= hsync; vs_q <= vsync;
        end
    end

    // Winning + behind source pixels (now valid, 1 clk after their addr).
    wire [31:0] win_px = src_pixel_i[winner_q*32 +: 32];
    wire [31:0] beh_px = src_pixel_i[runner_q*32 +: 32];

    // ---- Stage 2: latch fg/bg channels + alpha (isolates the multiply) ----
    logic [7:0] s2_a, s2_wr, s2_wg, s2_wb, s2_br, s2_bg, s2_bb;
    logic       s2_any, s2_blend, de_q2, hs_q2, vs_q2;
    always_ff @(posedge clk_pix or posedge rst_pix) begin
        if (rst_pix) begin
            s2_a <= 8'd0; s2_wr <= 8'd0; s2_wg <= 8'd0; s2_wb <= 8'd0;
            s2_br <= 8'd0; s2_bg <= 8'd0; s2_bb <= 8'd0;
            s2_any <= 1'b0; s2_blend <= 1'b0; de_q2 <= 1'b0; hs_q2 <= 1'b0; vs_q2 <= 1'b0;
        end else begin
            s2_wr <= win_px[31:24]; s2_wg <= win_px[23:16];
            s2_wb <= win_px[15:8];  s2_a  <= win_px[7:0];
            // blend OVER the runner plane's RGB, or the background if there is none.
            if (has_runner_q) begin
                s2_br <= beh_px[31:24]; s2_bg <= beh_px[23:16]; s2_bb <= beh_px[15:8];
            end else begin
                s2_br <= bg_color[23:16]; s2_bg <= bg_color[15:8]; s2_bb <= bg_color[7:0];
            end
            s2_any   <= any_q;
            s2_blend <= blend_q;
            de_q2 <= de_q; hs_q2 <= hs_q; vs_q2 <= vs_q;
        end
    end

    // 8-bit alpha lerp: out = bg + a*(fg-bg)/256, with a==0/255 exact endpoints.
    function automatic [7:0] lerp8(input [7:0] a, input [7:0] fg, input [7:0] bg);
        logic signed [10:0] diff;
        logic signed [19:0] prod;
        logic signed [11:0] res;
        if (a == 8'h00)      lerp8 = bg;
        else if (a == 8'hFF) lerp8 = fg;
        else begin
            diff  = $signed({3'b000, fg}) - $signed({3'b000, bg});
            prod  = $signed({1'b0, a}) * diff;
            res   = $signed({4'b0000, bg}) + (prod >>> 8);
            lerp8 = res[7:0];
        end
    endfunction

    // Blended (alpha-enabled winner) or opaque (everyone else) winner channels.
    wire [7:0] out_r = s2_blend ? lerp8(s2_a, s2_wr, s2_br) : s2_wr;
    wire [7:0] out_g = s2_blend ? lerp8(s2_a, s2_wg, s2_bg) : s2_wg;
    wire [7:0] out_b = s2_blend ? lerp8(s2_a, s2_wb, s2_bb) : s2_wb;

    // ---- Stage 3: covered -> winner (blended/opaque) -> 565; else bg ------
    always_ff @(posedge clk_pix or posedge rst_pix) begin
        if (rst_pix) begin
            rgb_r <= 5'd0; rgb_g <= 6'd0; rgb_b <= 5'd0;
            de_o  <= 1'b0; hsync_o <= 1'b0; vsync_o <= 1'b0;
        end else begin
            if (!de_q2) begin
                rgb_r <= 5'd0; rgb_g <= 6'd0; rgb_b <= 5'd0;
            end else if (s2_any) begin
                rgb_r <= out_r[7:3];
                rgb_g <= out_g[7:2];
                rgb_b <= out_b[7:3];
            end else begin
                rgb_r <= bg_color[23:19];
                rgb_g <= bg_color[15:10];
                rgb_b <= bg_color[7:3];
            end
            de_o    <= de_q2;
            hsync_o <= hs_q2;
            vsync_o <= vs_q2;
        end
    end

endmodule

`default_nettype wire
