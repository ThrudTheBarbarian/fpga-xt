// sprite_engine.sv — hardware sprite compositor for the 1080p scan-out path.
//
// Commit-3: AXI HP2 line fetcher + line cache.  Adds the per-scanline
// burst-read FSM that pulls sprite pixel data from the arena in PS DDR3
// and writes it into the dual-port line cache.  Compositor still
// stubbed — the RGB path remains a passthrough until the pixel pipeline
// commit lands.
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
//   * Coordinate widths: arena_x/arena_y both 12-bit, screen_x/screen_y
//     both 12-bit signed — see commit-2 message for the rationale.
//   * clk_bus = 150 MHz (was 162 MHz in the spec).  Per-scanline AXI HP2
//     budget recomputed to ~12.4 KB.
//
// Arena layout (per-sprite, depends on format bit):
//   format=0 (16-bit RGBA-5:5:5:1):
//     row stride = 4096 columns × 2 B = 8 KB  (1 << 13)
//     pixel addr = ARENA_BASE + (arena_row << 13) + (arena_col << 1)
//   format=1 (32-bit RGBA-8888):
//     row stride = 4096 columns × 4 B = 16 KB (1 << 14)
//     pixel addr = ARENA_BASE + (arena_row << 14) + (arena_col << 2)
//   Sprites of different formats must live in non-overlapping arena
//   regions; software chooses the base offsets per format pool.
//
// AXI burst plan:
//   arsize  = 3'b011 (8 bytes per beat, 64-bit data bus)
//   arburst = 2'b01  (INCR)
//   arlen   = 8'd7   (8 beats per burst = 64 bytes)
//   Bursts are 8-byte aligned at issue time.  Pixel-precise scrolling is
//   supported by skipping the first 0..3 (16-bit) or 0..1 (32-bit) pixels
//   of the first beat — the fetcher tracks a 2-bit skip_pixels counter
//   that suppresses cache writes until aligned with the visible region.

`default_nettype none

module sprite_engine #(
    parameter int unsigned ARENA_BASE = 32'h2000_0000,
    parameter int unsigned N_SPRITES  = 16,
    parameter int unsigned LINE_WIDTH = 1024,        // max sprite width in cache
    parameter int unsigned SCREEN_W   = 1920,
    parameter int unsigned FETCH_BUDGET_BURSTS = 200 // ≈ 12.8 KB per scanline
) (
    // ---- Clocks & reset ----------------------------------------------------
    input  wire        clk_fetch,           // AXI HP2 + fetcher clock (150 MHz / clk_sys)
    input  wire        clk_pix,             // Pixel-scan clock (148.4375 MHz)
    input  wire        rst,                 // Active-high

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
    input  wire        fb_hsync,
    input  wire        fb_vsync,

    // ---- Composited pixel output (drives SOM RGB pins, clk_pix) ------------
    // 3-cycle pipeline delay through the compositor: hsync / vsync / de are
    // pipelined alongside the pixel data so all timing signals exit aligned.
    output wire [4:0]  rgb_r,
    output wire [5:0]  rgb_g,
    output wire [4:0]  rgb_b,
    output wire        rgb_de,
    output wire        rgb_hsync,
    output wire        rgb_vsync,

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

    // ========================================================================
    // Per-sprite control flags ($D4Ax) — one bit-vector per field, indexed by
    // sprite ID.  Storage is one flop per sprite per flag.
    // ========================================================================
    logic [N_SPRITES-1:0] sprite_en;
    logic [N_SPRITES-1:0] sprite_h_flip;
    logic [N_SPRITES-1:0] sprite_v_flip;
    logic [N_SPRITES-1:0] sprite_2x_w;
    logic [N_SPRITES-1:0] sprite_2x_h;
    logic [N_SPRITES-1:0] sprite_format;
    logic [N_SPRITES-1:0] sprite_any_col;   // Sticky; set by compositor (later commit), W1C from CPU.

    // ========================================================================
    // Per-sprite descriptor file — latched on write to $D4D8 (SPRITE_B7).
    // ========================================================================
    logic [4:0]         desc_prio    [0:N_SPRITES-1];
    logic [3:0]         desc_log2sz  [0:N_SPRITES-1];
    logic [11:0]        desc_arena_x [0:N_SPRITES-1];
    logic [11:0]        desc_arena_y [0:N_SPRITES-1];
    logic signed [11:0] desc_screen_x[0:N_SPRITES-1];
    logic signed [11:0] desc_screen_y[0:N_SPRITES-1];

    // Shadow descriptor bytes B0..B6 + global ctrl --------------------------
    logic [7:0]         shadow_b [0:6];
    logic [3:0]         sprite_sel;
    logic [3:0]         col_sel;
    logic               global_enable;

    // Cross-product collision matrix ----------------------------------------
    logic [N_SPRITES-1:0] collision     [0:N_SPRITES-1];
    logic [N_SPRITES-1:0] collision_set [0:N_SPRITES-1];

    // No compositor yet — drive the set side to zero.
    genvar gi;
    generate
        for (gi = 0; gi < N_SPRITES; gi = gi + 1) begin : g_collision_set_tieoff
            assign collision_set[gi] = '0;
        end
    endgenerate

    // ========================================================================
    // Register address decode
    // ========================================================================
    wire is_d4ax = (reg_addr[7:4] == 4'hA);
    wire is_d4dx = (reg_addr[7:4] == 4'hD);
    wire [3:0] d4ax_idx  = reg_addr[3:0];
    wire [3:0] d4dx_idx  = reg_addr[3:0];

    wire is_d4ax_write = reg_we && is_d4ax;
    wire is_d4dx_write = reg_we && is_d4dx;

    logic [N_SPRITES-1:0] col_clear_mask;
    always_comb begin
        col_clear_mask = '0;
        if (is_d4dx_write && (d4dx_idx == 4'hA))
            col_clear_mask[7:0]  = reg_wdata;
        if (is_d4dx_write && (d4dx_idx == 4'hB))
            col_clear_mask[15:8] = reg_wdata;
    end

    // ========================================================================
    // Register write FSM (clk_fetch domain)
    // ========================================================================
    integer si;
    always_ff @(posedge clk_fetch) begin
        if (rst) begin
            sprite_en      <= '0;
            sprite_h_flip  <= '0;
            sprite_v_flip  <= '0;
            sprite_2x_w    <= '0;
            sprite_2x_h    <= '0;
            sprite_format  <= '0;
            sprite_any_col <= '0;
            sprite_sel     <= 4'd0;
            col_sel        <= 4'd0;
            global_enable  <= 1'b0;
            for (si = 0; si < 7; si = si + 1)
                shadow_b[si] <= 8'h00;
            for (si = 0; si < N_SPRITES; si = si + 1) begin
                desc_prio[si]     <= 5'd0;
                desc_log2sz[si]   <= 4'd0;
                desc_arena_x[si]  <= 12'd0;
                desc_arena_y[si]  <= 12'd0;
                desc_screen_x[si] <= 12'sd0;
                desc_screen_y[si] <= 12'sd0;
                collision[si]     <= '0;
            end
        end else begin
            if (is_d4ax_write) begin
                sprite_en    [d4ax_idx] <= reg_wdata[0];
                sprite_h_flip[d4ax_idx] <= reg_wdata[1];
                sprite_v_flip[d4ax_idx] <= reg_wdata[2];
                sprite_2x_w  [d4ax_idx] <= reg_wdata[3];
                sprite_2x_h  [d4ax_idx] <= reg_wdata[4];
                sprite_format[d4ax_idx] <= reg_wdata[5];
            end

            if (is_d4dx_write) begin
                case (d4dx_idx)
                    4'h0: sprite_sel <= reg_wdata[3:0];
                    4'h1: shadow_b[0] <= reg_wdata;
                    4'h2: shadow_b[1] <= reg_wdata;
                    4'h3: shadow_b[2] <= reg_wdata;
                    4'h4: shadow_b[3] <= reg_wdata;
                    4'h5: shadow_b[4] <= reg_wdata;
                    4'h6: shadow_b[5] <= reg_wdata;
                    4'h7: shadow_b[6] <= reg_wdata;
                    4'h8: begin
                        desc_prio    [sprite_sel] <= shadow_b[0][4:0];
                        desc_log2sz  [sprite_sel] <= shadow_b[1][3:0];
                        desc_arena_y [sprite_sel] <= {shadow_b[3][3:0], shadow_b[2]};
                        desc_arena_x [sprite_sel] <= {shadow_b[3][7:4], shadow_b[4]};
                        desc_screen_y[sprite_sel] <= $signed({shadow_b[6][3:0], shadow_b[5]});
                        desc_screen_x[sprite_sel] <= $signed({shadow_b[6][7:4], reg_wdata});
                    end
                    4'h9: col_sel <= reg_wdata[3:0];
                    4'hF: global_enable <= reg_wdata[0];
                    default: ;
                endcase
            end

            for (si = 0; si < N_SPRITES; si = si + 1) begin
                if (is_d4ax_write && (d4ax_idx == si[3:0]) && reg_wdata[7])
                    sprite_any_col[si] <= 1'b0;
                else if (|collision_set[si])
                    sprite_any_col[si] <= 1'b1;
            end

            for (si = 0; si < N_SPRITES; si = si + 1) begin
                if (col_sel == si[3:0])
                    collision[si] <= (collision[si] & ~col_clear_mask) | collision_set[si];
                else
                    collision[si] <= collision[si] | collision_set[si];
            end
        end
    end

    // ========================================================================
    // Register read-back path
    // ========================================================================
    logic [7:0] rdata_d4ax;
    always_comb begin
        rdata_d4ax = {sprite_any_col[d4ax_idx],
                      1'b0,
                      sprite_format[d4ax_idx],
                      sprite_2x_h[d4ax_idx],
                      sprite_2x_w[d4ax_idx],
                      sprite_v_flip[d4ax_idx],
                      sprite_h_flip[d4ax_idx],
                      sprite_en[d4ax_idx]};
    end

    logic [7:0] rdata_d4dx;
    always_comb begin
        rdata_d4dx = 8'h00;
        case (d4dx_idx)
            4'h0: rdata_d4dx = {4'h0, sprite_sel};
            4'h1: rdata_d4dx = {3'b000, desc_prio[sprite_sel]};
            4'h2: rdata_d4dx = {4'h0, desc_log2sz[sprite_sel]};
            4'h3: rdata_d4dx = desc_arena_y[sprite_sel][7:0];
            4'h4: rdata_d4dx = {desc_arena_x[sprite_sel][11:8], desc_arena_y[sprite_sel][11:8]};
            4'h5: rdata_d4dx = desc_arena_x[sprite_sel][7:0];
            4'h6: rdata_d4dx = desc_screen_y[sprite_sel][7:0];
            4'h7: rdata_d4dx = {desc_screen_x[sprite_sel][11:8], desc_screen_y[sprite_sel][11:8]};
            4'h8: rdata_d4dx = desc_screen_x[sprite_sel][7:0];
            4'h9: rdata_d4dx = {4'h0, col_sel};
            4'hA: rdata_d4dx = collision[col_sel][7:0];
            4'hB: rdata_d4dx = collision[col_sel][15:8];
            4'hF: rdata_d4dx = {7'h00, global_enable};
            default: rdata_d4dx = 8'h00;
        endcase
    end

    assign reg_rdata = is_d4ax ? rdata_d4ax :
                       is_d4dx ? rdata_d4dx :
                       8'h00;

    // ========================================================================
    // CDC: vbeam taps from clk_pix → clk_fetch
    //
    // Source: line_start is a 1-cycle clk_pix pulse.  We convert it to a
    // toggle on clk_pix, sync the toggle into clk_fetch, and re-extract a
    // 1-cycle pulse by edge-detect.  The next-line vcount is latched in
    // clk_pix at line_start and synced as a stable bus — by the time the
    // toggle pulse appears in clk_fetch, the synced vcount has settled.
    // ========================================================================
    logic        pix_line_toggle;
    logic [11:0] pix_next_vcount;
    always_ff @(posedge clk_pix) begin
        if (rst) begin
            pix_line_toggle <= 1'b0;
            pix_next_vcount <= 12'd0;
        end else if (line_start) begin
            pix_line_toggle <= ~pix_line_toggle;
            pix_next_vcount <= v_count + 12'd1;
        end
    end

    wire        fetch_line_toggle;
    wire [11:0] fetch_next_vcount;
    cdc_sync_bit #(.WIDTH(1))  u_sync_line_tog (
        .dst_clk (clk_fetch),
        .src_sig (pix_line_toggle),
        .dst_sig (fetch_line_toggle)
    );
    cdc_sync_bit #(.WIDTH(12)) u_sync_vcount (
        .dst_clk (clk_fetch),
        .src_sig (pix_next_vcount),
        .dst_sig (fetch_next_vcount)
    );

    logic fetch_line_toggle_q;
    always_ff @(posedge clk_fetch) begin
        if (rst) fetch_line_toggle_q <= 1'b0;
        else     fetch_line_toggle_q <= fetch_line_toggle;
    end
    wire fetch_line_start = fetch_line_toggle ^ fetch_line_toggle_q;

    // ========================================================================
    // Sprite line fetcher FSM (clk_fetch domain)
    // ========================================================================
    // The eval phase is split into 3 cycles to break the long combinational
    // chain (sprite_idx mux → CARRY4 chain for visibility/clip → FSM next
    // state) that otherwise pushes WNS to ≈ -3.6 ns at 150 MHz clk_sys:
    //
    //   F_EVAL_LATCH — latch desc[sprite_idx] fields into eval_*_q.
    //   F_EVAL_VIS   — compute visibility + clip from eval_*_q; register
    //                  vis_*_q and decide eval_visible_q.
    //   F_EVAL_ADDR  — compute byte_addr/byte_len/skip from vis_*_q + format;
    //                  transition to F_ISSUE_AR or advance sprite_idx.
    //
    // Per-sprite cost rises from 1 cycle to 3 cycles in the skip path, but
    // 16 × 3 = 48 cycles is negligible against a 2200-cycle scanline.
    typedef enum logic [3:0] {
        F_IDLE,
        F_EVAL_LATCH,    // mux desc[sprite_idx] → ev_*_q
        F_EVAL_VIS_A,    // compute vis_right + vis_width_full + arena_row/col
        F_EVAL_VIS_B,    // compute vis_width (clamp to LINE_WIDTH) + decision
        F_EVAL_ADDR,     // byte_addr math, transition to F_ISSUE_AR
        F_ISSUE_AR,
        F_DRAIN,
        F_NEXT
    } fetch_state_t;

    fetch_state_t fstate;

    logic [3:0]  sprite_idx;             // 0..15
    logic [11:0] next_vcount_q;          // latched at line start
    logic [12:0] visible_width_q;        // 0..1920 pixels to write
    logic        format_q;
    logic [11:0] cache_wr_x_q;
    logic [31:0] byte_addr_burst_q;      // 8-byte aligned address of current burst
    logic [13:0] bytes_remaining_q;      // pixel bytes still to write for this sprite
    logic [1:0]  skip_pixels_q;          // 0..3 (16-bit) / 0..1 (32-bit) skip at start
    logic [7:0]  budget_bursts_q;        // bursts remaining for this scanline

    // ---- Pipelined eval-stage registers (clk_fetch) -----------------------
    // Populated in F_EVAL_LATCH from desc[sprite_idx].
    logic signed [11:0] ev_screen_x_q;
    logic signed [11:0] ev_screen_y_q;
    logic [11:0]        ev_arena_x_q;
    logic [11:0]        ev_arena_y_q;
    logic [3:0]         ev_log2sz_q;
    logic               ev_format_q;
    logic               ev_en_q;
    logic [13:0]        ev_size_q;       // 1 << log2sz
    logic signed [12:0] ev_local_y_q;    // next_vcount - screen_y
    logic               ev_y_in_range_q;
    logic signed [12:0] ev_vis_left_q;
    logic signed [13:0] ev_vis_right_edge_q;
    // Populated in F_EVAL_VIS from the _q values above.
    logic signed [13:0] ev_vis_right_q;
    logic signed [13:0] ev_vis_width_full_q;     // populated in F_EVAL_VIS_A
    logic signed [13:0] ev_vis_width_q;
    logic               ev_visible_q;
    logic [11:0]        ev_clip_left_q;
    logic [11:0]        ev_arena_row_q;
    logic [11:0]        ev_arena_col_first_q;

    // Per-beat draining state -----------------------------------------------
    logic [63:0] beat_buffer_q;
    logic [3:0]  beat_drain_q;           // pixels left to emit from beat_buffer_q
    logic [3:0]  beats_left_q;           // beats still to come AFTER the one in buffer

    // AXI master outputs — combinational on FSM state to avoid handshake
    // races (NBA-deferred arvalid would otherwise miss arready in the same
    // cycle that the master transitions into F_ISSUE_AR).
    assign m_axi_araddr  = byte_addr_burst_q;
    assign m_axi_arlen   = 8'd7;
    assign m_axi_arsize  = 3'b011;
    assign m_axi_arburst = 2'b01;
    assign m_axi_arvalid = (fstate == F_ISSUE_AR);
    assign m_axi_rready  = (fstate == F_DRAIN) && (beat_drain_q == 4'd0);

    // Cache write port (drives sprite_line_cache port A) --------------------
    logic [N_SPRITES-1:0] cache_wr_en;
    logic [9:0]           cache_wr_addr;
    logic [31:0]          cache_wr_data;

    // ------------------------------------------------------------------------
    // Eval stage 1 (F_EVAL_LATCH) — combinational inputs sourced from
    // desc[sprite_idx].  Registered into ev_*_q at the F_EVAL_LATCH posedge.
    // ------------------------------------------------------------------------
    wire signed [12:0] latch_screen_x_se = $signed({desc_screen_x[sprite_idx][11], desc_screen_x[sprite_idx]});
    wire signed [12:0] latch_screen_y_se = $signed({desc_screen_y[sprite_idx][11], desc_screen_y[sprite_idx]});
    wire signed [12:0] latch_vc          = $signed({1'b0, next_vcount_q});
    wire [13:0]        latch_size        = 14'd1 << desc_log2sz[sprite_idx];
    wire signed [12:0] latch_local_y     = latch_vc - latch_screen_y_se;
    wire               latch_y_in_range  = (latch_local_y >= 0) &&
                                            ($signed({1'b0, latch_local_y}) < $signed({1'b0, latch_size}));
    wire signed [13:0] latch_right_edge  = $signed({latch_screen_x_se[12], latch_screen_x_se})
                                              + $signed({1'b0, latch_size});
    wire signed [12:0] latch_vis_left    = (latch_screen_x_se < 0) ? 13'sd0 : latch_screen_x_se;

    // ------------------------------------------------------------------------
    // Eval stage 2A (F_EVAL_VIS_A) — combinational from ev_*_q populated by
    // F_EVAL_LATCH.  Computes vis_right (clamp) and vis_width_full
    // (subtract).  Registered at the F_EVAL_VIS_A posedge.
    // ------------------------------------------------------------------------
    wire signed [13:0] vis_right_w     = (ev_vis_right_edge_q > $signed(14'(SCREEN_W)))
                                            ? $signed(14'(SCREEN_W)) : ev_vis_right_edge_q;
    wire signed [13:0] vis_width_full_w = vis_right_w - $signed({1'b0, ev_vis_left_q});
    wire signed [12:0] vis_clip_left_w = ev_vis_left_q - ev_screen_x_q;
    wire [11:0]        vis_arena_row_w = ev_arena_y_q + ev_local_y_q[11:0];
    wire [11:0]        vis_arena_col_first_w = ev_arena_x_q + vis_clip_left_w[11:0];

    // ------------------------------------------------------------------------
    // Eval stage 2B (F_EVAL_VIS_B) — combinational from registered
    // ev_vis_width_full_q.  Computes vis_width clamp + visible decision.
    // ------------------------------------------------------------------------
    wire signed [13:0] vis_width_w     = (ev_vis_width_full_q > $signed(14'(LINE_WIDTH)))
                                            ? $signed(14'(LINE_WIDTH)) : ev_vis_width_full_q;
    wire               vis_visible_w   = ev_en_q && global_enable && ev_y_in_range_q && (vis_width_w > 0);

    // ------------------------------------------------------------------------
    // Eval stage 3 (F_EVAL_ADDR) — byte-address math from vis_*_q.  Uses
    // ev_format_q to choose 16-bit vs 32-bit arena stride.
    // ------------------------------------------------------------------------
    wire [5:0]  addr_pix_shift    = ev_format_q ? 6'd2 : 6'd1;
    wire [5:0]  addr_stride_shift = ev_format_q ? 6'd14 : 6'd13;
    wire [31:0] addr_pix_w        = ARENA_BASE
                                  + ({20'd0, ev_arena_row_q} << addr_stride_shift)
                                  + ({20'd0, ev_arena_col_first_q} << addr_pix_shift);
    wire [31:0] addr_aligned_w    = addr_pix_w & 32'hFFFF_FFF8;
    wire [2:0]  addr_skip_bytes_w = addr_pix_w[2:0];
    wire [1:0]  addr_skip_pixels_w = ev_format_q ? {1'b0, addr_skip_bytes_w[2]} : addr_skip_bytes_w[2:1];
    wire [13:0] addr_byte_len_pix_w = (ev_vis_width_q[11:0] << addr_pix_shift);
    wire [14:0] addr_total_bytes_w  = {1'b0, addr_byte_len_pix_w} + {12'd0, addr_skip_bytes_w};

    // ------------------------------------------------------------------------
    // Pixel demux from beat_buffer_q.
    //   16-bit format: low 16 bits = next pixel.
    //   32-bit format: low 32 bits = next pixel.
    // After emitting one pixel we right-shift the buffer by pixel width.
    // ------------------------------------------------------------------------
    function automatic logic [31:0] expand_5551(input logic [15:0] p);
        logic [4:0] r5, g5, b5;
        logic       a1;
        r5 = p[15:11];
        g5 = p[10:6];
        b5 = p[5:1];
        a1 = p[0];
        return {{r5, r5[4:2]}, {g5, g5[4:2]}, {b5, b5[4:2]}, {8{a1}}};
    endfunction

    wire [31:0] next_pixel_internal = format_q
        ? beat_buffer_q[31:0]
        : expand_5551(beat_buffer_q[15:0]);

    // ------------------------------------------------------------------------
    // Main fetcher state machine.
    // ------------------------------------------------------------------------
    integer ci;
    always_ff @(posedge clk_fetch) begin
        if (rst) begin
            fstate            <= F_IDLE;
            sprite_idx        <= 4'd0;
            next_vcount_q     <= 12'd0;
            visible_width_q   <= 13'd0;
            format_q          <= 1'b0;
            cache_wr_x_q      <= 12'd0;
            byte_addr_burst_q <= 32'd0;
            bytes_remaining_q <= 14'd0;
            skip_pixels_q     <= 2'd0;
            budget_bursts_q   <= 8'(FETCH_BUDGET_BURSTS);
            beat_buffer_q     <= 64'd0;
            beat_drain_q      <= 4'd0;
            beats_left_q      <= 4'd0;
            for (ci = 0; ci < N_SPRITES; ci = ci + 1)
                cache_wr_en[ci] <= 1'b0;
            cache_wr_addr     <= 10'd0;
            cache_wr_data     <= 32'd0;
            ev_screen_x_q        <= 12'sd0;
            ev_screen_y_q        <= 12'sd0;
            ev_arena_x_q         <= 12'd0;
            ev_arena_y_q         <= 12'd0;
            ev_log2sz_q          <= 4'd0;
            ev_format_q          <= 1'b0;
            ev_en_q              <= 1'b0;
            ev_size_q            <= 14'd0;
            ev_local_y_q         <= 13'sd0;
            ev_y_in_range_q      <= 1'b0;
            ev_vis_left_q        <= 13'sd0;
            ev_vis_right_edge_q  <= 14'sd0;
            ev_vis_right_q       <= 14'sd0;
            ev_vis_width_full_q  <= 14'sd0;
            ev_vis_width_q       <= 14'sd0;
            ev_visible_q         <= 1'b0;
            ev_clip_left_q       <= 12'd0;
            ev_arena_row_q       <= 12'd0;
            ev_arena_col_first_q <= 12'd0;
        end else begin
            // Default: drop one-shots
            for (ci = 0; ci < N_SPRITES; ci = ci + 1)
                cache_wr_en[ci] <= 1'b0;

            case (fstate)
                // ------------------------------------------------------------
                F_IDLE: begin
                    if (fetch_line_start && global_enable) begin
                        next_vcount_q   <= fetch_next_vcount;
                        sprite_idx      <= 4'd0;
                        budget_bursts_q <= 8'(FETCH_BUDGET_BURSTS);
                        fstate          <= F_EVAL_LATCH;
                    end
                end

                // ------------------------------------------------------------
                F_EVAL_LATCH: begin
                    // Cycle 1: latch desc[sprite_idx] + compute size, local_y.
                    ev_screen_x_q       <= desc_screen_x[sprite_idx];
                    ev_screen_y_q       <= desc_screen_y[sprite_idx];
                    ev_arena_x_q        <= desc_arena_x[sprite_idx];
                    ev_arena_y_q        <= desc_arena_y[sprite_idx];
                    ev_log2sz_q         <= desc_log2sz[sprite_idx];
                    ev_format_q         <= sprite_format[sprite_idx];
                    ev_en_q             <= sprite_en[sprite_idx];
                    ev_size_q           <= latch_size;
                    ev_local_y_q        <= latch_local_y;
                    ev_y_in_range_q     <= latch_y_in_range;
                    ev_vis_left_q       <= latch_vis_left;
                    ev_vis_right_edge_q <= latch_right_edge;
                    fstate              <= F_EVAL_VIS_A;
                end

                // ------------------------------------------------------------
                F_EVAL_VIS_A: begin
                    // Cycle 2: clamp vis_right, subtract vis_width_full,
                    // pre-compute arena_row/col + clip_left.  No decision
                    // — that happens in F_EVAL_VIS_B against a registered
                    // vis_width_full so the CARRY4 chain doesn't gate the
                    // sprite_idx CE in a single cycle.
                    ev_vis_right_q       <= vis_right_w;
                    ev_vis_width_full_q  <= vis_width_full_w;
                    ev_clip_left_q       <= vis_clip_left_w[11:0];
                    ev_arena_row_q       <= vis_arena_row_w;
                    ev_arena_col_first_q <= vis_arena_col_first_w;
                    fstate               <= F_EVAL_VIS_B;
                end

                // ------------------------------------------------------------
                F_EVAL_VIS_B: begin
                    // Cycle 3: clamp vis_width to LINE_WIDTH + decide.
                    ev_vis_width_q <= vis_width_w;
                    ev_visible_q   <= vis_visible_w;
                    if (vis_visible_w && (budget_bursts_q > 0)) begin
                        fstate <= F_EVAL_ADDR;
                    end else if (sprite_idx == N_SPRITES - 1) begin
                        fstate <= F_IDLE;
                    end else begin
                        sprite_idx <= sprite_idx + 4'd1;
                        fstate     <= F_EVAL_LATCH;
                    end
                end

                // ------------------------------------------------------------
                F_EVAL_ADDR: begin
                    // Cycle 3: byte_addr math, latch burst-walk state,
                    // advance to F_ISSUE_AR.
                    visible_width_q   <= ev_vis_width_q[12:0];
                    format_q          <= ev_format_q;
                    cache_wr_x_q      <= ev_clip_left_q;
                    byte_addr_burst_q <= addr_aligned_w;
                    bytes_remaining_q <= addr_total_bytes_w[13:0];
                    skip_pixels_q     <= addr_skip_pixels_w;
                    fstate            <= F_ISSUE_AR;
                end

                // ------------------------------------------------------------
                F_ISSUE_AR: begin
                    // arvalid is combinational on (fstate == F_ISSUE_AR).
                    // Wait for arready, then capture the burst.
                    if (m_axi_arready) begin
                        beats_left_q   <= 4'd8;
                        beat_drain_q   <= 4'd0;
                        if (budget_bursts_q != 0)
                            budget_bursts_q <= budget_bursts_q - 8'd1;
                        fstate <= F_DRAIN;
                    end
                end

                // ------------------------------------------------------------
                F_DRAIN: begin
                    // 1) If beat_drain_q == 0, accept the next AXI beat.
                    //    rready is automatic via (fstate == F_DRAIN) && (beat_drain_q == 0).
                    if ((beat_drain_q == 4'd0) && m_axi_rvalid) begin
                        beat_buffer_q <= m_axi_rdata;
                        beat_drain_q  <= format_q ? 4'd2 : 4'd4;
                        beats_left_q  <= beats_left_q - 4'd1;
                    end

                    // 2) Emit one pixel per cycle from the beat buffer.
                    if (beat_drain_q != 0) begin
                        if (skip_pixels_q != 0) begin
                            skip_pixels_q <= skip_pixels_q - 2'd1;
                        end else if (visible_width_q != 0) begin
                            cache_wr_en[sprite_idx] <= 1'b1;
                            cache_wr_addr           <= cache_wr_x_q[9:0];
                            cache_wr_data           <= next_pixel_internal;
                            cache_wr_x_q            <= cache_wr_x_q + 12'd1;
                            visible_width_q         <= visible_width_q - 13'd1;
                        end
                        // Shift the beat buffer down by one pixel.
                        beat_buffer_q <= format_q ? {32'd0, beat_buffer_q[63:32]}
                                                  : {16'd0, beat_buffer_q[63:16]};
                        beat_drain_q  <= beat_drain_q - 4'd1;
                        // Last beat fully consumed?
                        if ((beat_drain_q == 4'd1) && (beats_left_q == 4'd0)) begin
                            // Burst done.  rready already gated to 0 since beats_left_q reached 0.
                            byte_addr_burst_q <= byte_addr_burst_q + 32'd64;
                            bytes_remaining_q <= (bytes_remaining_q > 14'd64)
                                                ? bytes_remaining_q - 14'd64
                                                : 14'd0;
                            if ((bytes_remaining_q > 14'd64) && (visible_width_q > 13'd1))
                                fstate <= F_ISSUE_AR;
                            else
                                fstate <= F_NEXT;
                        end
                    end
                end

                // ------------------------------------------------------------
                F_NEXT: begin
                    if (sprite_idx == N_SPRITES - 1)
                        fstate <= F_IDLE;
                    else begin
                        sprite_idx <= sprite_idx + 4'd1;
                        fstate     <= F_EVAL_LATCH;
                    end
                end

                default: fstate <= F_IDLE;
            endcase
        end
    end

    // ========================================================================
    // Pixel compositor (clk_pix domain)
    //
    // Pipeline (3 cycles, input → output):
    //   Stage 1 (combinational at cycle N):
    //     Per-sprite hit check (in_box) + cache rd_addr drive.
    //   Pipeline FF1 (latched at posedge N+1):
    //     s2_hit_q, s2_fb_*_q.  BRAM port B also registers rd_data at this
    //     edge based on cycle-N rd_addr.
    //   Stage 3 (combinational at cycle N+1):
    //     Alpha test + priority resolve.
    //   Pipeline FF2 (latched at posedge N+2):
    //     s4_winner_*_q, s4_fb_*_q.
    //   Stage 4 (combinational at cycle N+2):
    //     Alpha blend with framebuffer.
    //   Pipeline FF3 (latched at posedge N+3):
    //     Final rgb_*_q output.
    //
    // CDC note: desc_* / sprite_* fields live in clk_fetch.  We read them
    // directly from clk_pix without a synchroniser — the values change at
    // SALLY's ~1 MHz cadence, so a 1-pixel-period glitch during transition
    // is invisible at 1080p60.  XDC max_delay constraints on these paths
    // (or false_path during CDC review) keep timing closure clean.
    // ========================================================================

    // Per-sprite local coordinate + hit check ---------------------------------
    logic [N_SPRITES-1:0] s1_hit;
    logic [9:0]           s1_rd_addr [0:N_SPRITES-1];

    genvar gc;
    generate
        for (gc = 0; gc < N_SPRITES; gc = gc + 1) begin : g_hit
            wire signed [13:0] cx = $signed({2'b00, h_count});
            wire signed [13:0] cy = $signed({2'b00, v_count});
            wire signed [13:0] sx = $signed({{2{desc_screen_x[gc][11]}}, desc_screen_x[gc]});
            wire signed [13:0] sy = $signed({{2{desc_screen_y[gc][11]}}, desc_screen_y[gc]});
            wire signed [13:0] sz = $signed({1'b0, (13'd1 << desc_log2sz[gc])});
            wire signed [13:0] cap = $signed(14'(LINE_WIDTH));
            wire signed [13:0] lx = cx - sx;
            wire signed [13:0] ly = cy - sy;
            wire in_x = (lx >= 0) && (lx < cap) && (lx < sz);
            wire in_y = (ly >= 0) && (ly < sz);
            assign s1_hit[gc]     = sprite_en[gc] && global_enable && in_x && in_y;
            assign s1_rd_addr[gc] = lx[9:0];
        end
    endgenerate

    // ========================================================================
    // Sprite line cache — fetcher writes on clk_fetch; compositor reads on
    // clk_pix.  Per-sprite rd_addr enables parallel reads at distinct
    // local_x values (each sprite has its own screen_x).
    // ========================================================================
    logic [31:0] cache_rd_data [0:N_SPRITES-1];

    sprite_line_cache #(
        .N_SPRITES  (N_SPRITES),
        .LINE_WIDTH (LINE_WIDTH),
        .PIXEL_W    (32),
        .ADDR_W     (10)
    ) u_cache (
        .clk_a    (clk_fetch),
        .wr_en    (cache_wr_en),
        .wr_addr  (cache_wr_addr),
        .wr_data  (cache_wr_data),
        .clk_b    (clk_pix),
        .rd_addr  (s1_rd_addr),
        .rd_data  (cache_rd_data)
    );

    // Pipeline FF1 + FF1b ----------------------------------------------------
    // The cache now has 2-cycle read latency (BRAM clock-out FF + OREG).
    // s2_*_q is the first stage; s2b_*_q delays everything one more cycle
    // so hit / fb / prio align with cache_rd_data when has_color and the
    // tree run downstream.  Pipeline depth from this restructure: +1 cycle
    // (6 total) but the cache→tree path picks up the OREG's near-zero
    // clock-to-Q in return.
    logic [N_SPRITES-1:0] s2_hit_q,        s2b_hit_q;
    logic [15:0]          s2_fb_pixel_q,   s2b_fb_pixel_q;
    logic                 s2_fb_de_q,      s2b_fb_de_q;
    logic                 s2_fb_hsync_q,   s2b_fb_hsync_q;
    logic                 s2_fb_vsync_q,   s2b_fb_vsync_q;
    // Pipeline desc_prio twice so the priority resolver doesn't see a
    // freshly-written prio for a sprite whose hit was computed earlier.
    logic [4:0]           s2_prio_q  [0:N_SPRITES-1];
    logic [4:0]           s2b_prio_q [0:N_SPRITES-1];

    integer pi;
    always_ff @(posedge clk_pix) begin
        if (rst) begin
            s2_hit_q       <= '0;
            s2_fb_pixel_q  <= 16'h0000;
            s2_fb_de_q     <= 1'b0;
            s2_fb_hsync_q  <= 1'b0;
            s2_fb_vsync_q  <= 1'b0;
            s2b_hit_q      <= '0;
            s2b_fb_pixel_q <= 16'h0000;
            s2b_fb_de_q    <= 1'b0;
            s2b_fb_hsync_q <= 1'b0;
            s2b_fb_vsync_q <= 1'b0;
            for (pi = 0; pi < N_SPRITES; pi = pi + 1) begin
                s2_prio_q[pi]  <= 5'd0;
                s2b_prio_q[pi] <= 5'd0;
            end
        end else begin
            // Stage 1 → s2 (cycle N → N+1)
            s2_hit_q       <= s1_hit;
            s2_fb_pixel_q  <= fb_pixel;
            s2_fb_de_q     <= fb_de;
            s2_fb_hsync_q  <= fb_hsync;
            s2_fb_vsync_q  <= fb_vsync;
            for (pi = 0; pi < N_SPRITES; pi = pi + 1) s2_prio_q[pi] <= desc_prio[pi];
            // s2 → s2b (cycle N+1 → N+2) — aligns with BRAM OREG output
            s2b_hit_q      <= s2_hit_q;
            s2b_fb_pixel_q <= s2_fb_pixel_q;
            s2b_fb_de_q    <= s2_fb_de_q;
            s2b_fb_hsync_q <= s2_fb_hsync_q;
            s2b_fb_vsync_q <= s2_fb_vsync_q;
            for (pi = 0; pi < N_SPRITES; pi = pi + 1) s2b_prio_q[pi] <= s2_prio_q[pi];
        end
    end

    // Stage 3: alpha test + priority resolve ---------------------------------
    //
    // Tree-reduce priority resolve over 16 candidates, split across two
    // clk_pix cycles to keep logic depth per cycle under the 6.7 ns budget:
    //   Cycle A: leaves → l1 → l2 (16 → 8 → 4 candidates), register into
    //            mid_cand_q[0:3] at the next posedge.
    //   Cycle B: mid_cand_q → l3 → l4 (4 → 2 → 1 winner), feeds the alpha
    //            blend.
    // Each merge picks the higher-priority candidate, carrying its pixel
    // data alongside the priority field so no separate "mux by winner
    // index" step is needed.  Ties resolve to the higher sprite index
    // (b-side wins on equal prio).
    logic [N_SPRITES-1:0] s3_has_color;
    genvar ga;
    generate
        for (ga = 0; ga < N_SPRITES; ga = ga + 1) begin : g_alpha
            assign s3_has_color[ga] = s2b_hit_q[ga] && (|cache_rd_data[ga][7:0]);
        end
    endgenerate

    // Level 1: 16 leaves → 8 pairs ------------------------------------------
    logic        l1_valid [0:7];
    logic [4:0]  l1_prio  [0:7];
    logic [31:0] l1_pixel [0:7];

    // Level 2: 8 → 4 ---------------------------------------------------------
    logic        l2_valid [0:3];
    logic [4:0]  l2_prio  [0:3];
    logic [31:0] l2_pixel [0:3];

    // Level 3: 4 → 2 ---------------------------------------------------------
    logic        l3_valid [0:1];
    logic [4:0]  l3_prio  [0:1];
    logic [31:0] l3_pixel [0:1];

    // Level 4: 2 → 1 (final winner) -----------------------------------------
    logic        l4_valid;
    logic [4:0]  l4_prio;
    logic [31:0] l4_pixel;

    genvar gtr;
    generate
        for (gtr = 0; gtr < 8; gtr = gtr + 1) begin : g_l1
            wire        a_v = s3_has_color[gtr*2];
            wire        b_v = s3_has_color[gtr*2 + 1];
            wire [4:0]  a_p = s2b_prio_q[gtr*2];
            wire [4:0]  b_p = s2b_prio_q[gtr*2 + 1];
            wire        b_wins = b_v && (!a_v || (b_p >= a_p));
            assign l1_valid[gtr] = a_v || b_v;
            assign l1_prio[gtr]  = b_wins ? b_p : a_p;
            assign l1_pixel[gtr] = b_wins ? cache_rd_data[gtr*2 + 1]
                                          : cache_rd_data[gtr*2];
        end

        for (gtr = 0; gtr < 4; gtr = gtr + 1) begin : g_l2
            wire b_wins = l1_valid[gtr*2 + 1]
                           && (!l1_valid[gtr*2] || (l1_prio[gtr*2 + 1] >= l1_prio[gtr*2]));
            assign l2_valid[gtr] = l1_valid[gtr*2] || l1_valid[gtr*2 + 1];
            assign l2_prio[gtr]  = b_wins ? l1_prio[gtr*2 + 1]  : l1_prio[gtr*2];
            assign l2_pixel[gtr] = b_wins ? l1_pixel[gtr*2 + 1] : l1_pixel[gtr*2];
        end

    endgenerate

    // Pipeline register between l2 and l3 ------------------------------------
    logic        mid_valid_q [0:3];
    logic [4:0]  mid_prio_q  [0:3];
    logic [31:0] mid_pixel_q [0:3];
    // Pipeline fb_pixel chain by one extra cycle to align with the deeper
    // compositor pipeline (was 3 stages, now 4 stages).
    logic [15:0] mid_fb_pixel_q;
    logic        mid_fb_de_q;
    logic        mid_fb_hsync_q;
    logic        mid_fb_vsync_q;

    integer mi;
    always_ff @(posedge clk_pix) begin
        if (rst) begin
            for (mi = 0; mi < 4; mi = mi + 1) begin
                mid_valid_q[mi] <= 1'b0;
                mid_prio_q[mi]  <= 5'd0;
                mid_pixel_q[mi] <= 32'd0;
            end
            mid_fb_pixel_q <= 16'h0000;
            mid_fb_de_q    <= 1'b0;
            mid_fb_hsync_q <= 1'b0;
            mid_fb_vsync_q <= 1'b0;
        end else begin
            for (mi = 0; mi < 4; mi = mi + 1) begin
                mid_valid_q[mi] <= l2_valid[mi];
                mid_prio_q[mi]  <= l2_prio[mi];
                mid_pixel_q[mi] <= l2_pixel[mi];
            end
            mid_fb_pixel_q <= s2b_fb_pixel_q;
            mid_fb_de_q    <= s2b_fb_de_q;
            mid_fb_hsync_q <= s2b_fb_hsync_q;
            mid_fb_vsync_q <= s2b_fb_vsync_q;
        end
    end

    // Cycle B: 4 candidates → 1 winner --------------------------------------
    generate
        for (gtr = 0; gtr < 2; gtr = gtr + 1) begin : g_l3
            wire b_wins = mid_valid_q[gtr*2 + 1]
                           && (!mid_valid_q[gtr*2]
                               || (mid_prio_q[gtr*2 + 1] >= mid_prio_q[gtr*2]));
            assign l3_valid[gtr] = mid_valid_q[gtr*2] || mid_valid_q[gtr*2 + 1];
            assign l3_prio[gtr]  = b_wins ? mid_prio_q[gtr*2 + 1]  : mid_prio_q[gtr*2];
            assign l3_pixel[gtr] = b_wins ? mid_pixel_q[gtr*2 + 1] : mid_pixel_q[gtr*2];
        end
    endgenerate

    wire l4_b_wins = l3_valid[1] && (!l3_valid[0] || (l3_prio[1] >= l3_prio[0]));
    assign l4_valid = l3_valid[0] || l3_valid[1];
    assign l4_prio  = l4_b_wins ? l3_prio[1]  : l3_prio[0];
    assign l4_pixel = l4_b_wins ? l3_pixel[1] : l3_pixel[0];

    wire        s3_winner_valid = l4_valid;
    wire [31:0] s3_winner_pixel = l4_pixel;
    /* verilator lint_off UNUSED */
    wire [4:0]  s3_winner_prio_unused = l4_prio;
    /* verilator lint_on UNUSED */

    // Pipeline FF2 -----------------------------------------------------------
    logic [31:0] s4_winner_pixel_q;
    logic        s4_winner_valid_q;
    logic [15:0] s4_fb_pixel_q;
    logic        s4_fb_de_q;
    logic        s4_fb_hsync_q;
    logic        s4_fb_vsync_q;

    always_ff @(posedge clk_pix) begin
        if (rst) begin
            s4_winner_pixel_q <= 32'd0;
            s4_winner_valid_q <= 1'b0;
            s4_fb_pixel_q     <= 16'd0;
            s4_fb_de_q        <= 1'b0;
            s4_fb_hsync_q     <= 1'b0;
            s4_fb_vsync_q     <= 1'b0;
        end else begin
            s4_winner_pixel_q <= s3_winner_pixel;
            s4_winner_valid_q <= s3_winner_valid;
            s4_fb_pixel_q     <= mid_fb_pixel_q;
            s4_fb_de_q        <= mid_fb_de_q;
            s4_fb_hsync_q     <= mid_fb_hsync_q;
            s4_fb_vsync_q     <= mid_fb_vsync_q;
        end
    end

    // Stage 4a: multiplier inputs (combinational from s4_winner_pixel_q).
    // Pipeline FF_mul absorbs the multiplier output into the DSP48 M
    // register so the add + truncate + final mux all fit in one cycle.
    // Expand fb_pixel RGB565 → RGB888 (replicate top bits into the LSBs).
    wire [7:0] fb_r8 = {s4_fb_pixel_q[15:11], s4_fb_pixel_q[15:13]};
    wire [7:0] fb_g8 = {s4_fb_pixel_q[10:5],  s4_fb_pixel_q[10:9]};
    wire [7:0] fb_b8 = {s4_fb_pixel_q[4:0],   s4_fb_pixel_q[4:2]};

    wire [7:0] sp_r8 = s4_winner_pixel_q[31:24];
    wire [7:0] sp_g8 = s4_winner_pixel_q[23:16];
    wire [7:0] sp_b8 = s4_winner_pixel_q[15:8];
    wire [7:0] alpha = s4_winner_pixel_q[7:0];
    wire [7:0] inv_a = 8'hFF - alpha;

    // Pipeline FF_mul — registered multiplier outputs + fb pixeled forward.
    // 3 × 2 = 6 × 8x8 unsigned mults map to 6 DSP48s on Zynq-7020.  Output
    // registers get absorbed into the DSP M register for sub-ns delay.
    logic [15:0] r_mul_sp_q, r_mul_fb_q;
    logic [15:0] g_mul_sp_q, g_mul_fb_q;
    logic [15:0] b_mul_sp_q, b_mul_fb_q;
    logic        s5_winner_valid_q;
    logic [15:0] s5_fb_pixel_q;
    logic        s5_fb_de_q;
    logic        s5_fb_hsync_q;
    logic        s5_fb_vsync_q;

    always_ff @(posedge clk_pix) begin
        if (rst) begin
            r_mul_sp_q <= 16'd0;
            r_mul_fb_q <= 16'd0;
            g_mul_sp_q <= 16'd0;
            g_mul_fb_q <= 16'd0;
            b_mul_sp_q <= 16'd0;
            b_mul_fb_q <= 16'd0;
            s5_winner_valid_q <= 1'b0;
            s5_fb_pixel_q     <= 16'h0000;
            s5_fb_de_q        <= 1'b0;
            s5_fb_hsync_q     <= 1'b0;
            s5_fb_vsync_q     <= 1'b0;
        end else begin
            r_mul_sp_q <= sp_r8 * alpha;
            r_mul_fb_q <= fb_r8 * inv_a;
            g_mul_sp_q <= sp_g8 * alpha;
            g_mul_fb_q <= fb_g8 * inv_a;
            b_mul_sp_q <= sp_b8 * alpha;
            b_mul_fb_q <= fb_b8 * inv_a;
            s5_winner_valid_q <= s4_winner_valid_q;
            s5_fb_pixel_q     <= s4_fb_pixel_q;
            s5_fb_de_q        <= s4_fb_de_q;
            s5_fb_hsync_q     <= s4_fb_hsync_q;
            s5_fb_vsync_q     <= s4_fb_vsync_q;
        end
    end

    // Stage 4b (comb): add the products + 128 round bias and truncate.
    //   out = (sp*a + fb*(255-a) + 128) >> 8.
    wire [16:0] r_sum    = {1'b0, r_mul_sp_q} + {1'b0, r_mul_fb_q} + 17'd128;
    wire [7:0]  blend_r8 = r_sum[15:8];
    wire [16:0] g_sum    = {1'b0, g_mul_sp_q} + {1'b0, g_mul_fb_q} + 17'd128;
    wire [7:0]  blend_g8 = g_sum[15:8];
    wire [16:0] b_sum    = {1'b0, b_mul_sp_q} + {1'b0, b_mul_fb_q} + 17'd128;
    wire [7:0]  blend_b8 = b_sum[15:8];

    // Truncate back to RGB565 for the SOM output.
    wire [4:0] out_r5 = s5_winner_valid_q ? blend_r8[7:3] : s5_fb_pixel_q[15:11];
    wire [5:0] out_g6 = s5_winner_valid_q ? blend_g8[7:2] : s5_fb_pixel_q[10:5];
    wire [4:0] out_b5 = s5_winner_valid_q ? blend_b8[7:3] : s5_fb_pixel_q[4:0];

    // Pipeline FF_out — final output register --------------------------------
    logic [4:0] rgb_r_q;
    logic [5:0] rgb_g_q;
    logic [4:0] rgb_b_q;
    logic       rgb_de_q;
    logic       rgb_hsync_q;
    logic       rgb_vsync_q;

    always_ff @(posedge clk_pix) begin
        if (rst) begin
            rgb_r_q     <= 5'd0;
            rgb_g_q     <= 6'd0;
            rgb_b_q     <= 5'd0;
            rgb_de_q    <= 1'b0;
            rgb_hsync_q <= 1'b0;
            rgb_vsync_q <= 1'b0;
        end else begin
            rgb_r_q     <= out_r5;
            rgb_g_q     <= out_g6;
            rgb_b_q     <= out_b5;
            rgb_de_q    <= s5_fb_de_q;
            rgb_hsync_q <= s5_fb_hsync_q;
            rgb_vsync_q <= s5_fb_vsync_q;
        end
    end

    assign rgb_r     = rgb_r_q;
    assign rgb_g     = rgb_g_q;
    assign rgb_b     = rgb_b_q;
    assign rgb_de    = rgb_de_q;
    assign rgb_hsync = rgb_hsync_q;
    assign rgb_vsync = rgb_vsync_q;

    // Unused inputs — frame_start is consumed by the fetcher elsewhere
    // (per-line) so this module observes but doesn't use it; the cache's
    // 16-element rd_data is fully consumed inside the compositor genvar
    // loop above but Verilator still flags the array reference.
    /* verilator lint_off UNUSED */
    wire _unused = &{1'b0,
                     frame_start,
                     1'b0};
    /* verilator lint_on UNUSED */

endmodule

`default_nettype wire
