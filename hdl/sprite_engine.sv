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
    typedef enum logic [2:0] {
        F_IDLE,
        F_EVAL,
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
    // Combinational visibility / clip computation for sprite_idx.
    // ------------------------------------------------------------------------
    wire signed [12:0] eval_screen_x = $signed({desc_screen_x[sprite_idx][11], desc_screen_x[sprite_idx]});
    wire signed [12:0] eval_screen_y = $signed({desc_screen_y[sprite_idx][11], desc_screen_y[sprite_idx]});
    wire signed [12:0] eval_vc       = $signed({1'b0, next_vcount_q});
    wire signed [12:0] eval_size     = $signed({1'b0, 12'd1 << desc_log2sz[sprite_idx]});
    wire signed [12:0] eval_local_y  = eval_vc - eval_screen_y;

    wire eval_y_in_range = (eval_local_y >= 0) && (eval_local_y < eval_size);
    wire signed [13:0] eval_right_edge = eval_screen_x + eval_size;

    wire signed [12:0] eval_vis_left  = (eval_screen_x  < 0)                  ? 13'sd0 : eval_screen_x;
    wire signed [13:0] eval_vis_right = (eval_right_edge > $signed(14'(SCREEN_W))) ?
                                            $signed(14'(SCREEN_W)) : eval_right_edge;
    wire signed [13:0] eval_vis_width_full = eval_vis_right - eval_vis_left;
    // Clamp to LINE_WIDTH so we never exceed cache geometry.
    wire signed [13:0] eval_vis_width = (eval_vis_width_full > $signed(14'(LINE_WIDTH))) ?
                                            $signed(14'(LINE_WIDTH)) : eval_vis_width_full;
    wire eval_visible = sprite_en[sprite_idx]
                        && global_enable
                        && eval_y_in_range
                        && (eval_vis_width > 0);

    wire signed [12:0] eval_clip_left = eval_vis_left - eval_screen_x;       // sprite-local x of first emitted pixel
    wire [11:0]        eval_arena_row = desc_arena_y[sprite_idx] + eval_local_y[11:0];
    wire [11:0]        eval_arena_col_first = desc_arena_x[sprite_idx] + eval_clip_left[11:0];

    wire eval_format        = sprite_format[sprite_idx];
    wire [5:0]  eval_pix_shift    = eval_format ? 6'd2 : 6'd1;
    wire [5:0]  eval_stride_shift = eval_format ? 6'd14 : 6'd13;

    // Byte-precise start address (pre-alignment)
    wire [31:0] eval_addr_pix = ARENA_BASE
                              + ({20'd0, eval_arena_row} << eval_stride_shift)
                              + ({20'd0, eval_arena_col_first} << eval_pix_shift);
    wire [31:0] eval_addr_aligned = eval_addr_pix & 32'hFFFF_FFF8;
    wire [2:0]  eval_skip_bytes = eval_addr_pix[2:0];
    wire [1:0]  eval_skip_pixels = eval_format ? {1'b0, eval_skip_bytes[2]} : eval_skip_bytes[2:1];

    wire [13:0] eval_byte_len_pix = (eval_vis_width[11:0] << eval_pix_shift); // up to 4096
    wire [14:0] eval_total_bytes = {1'b0, eval_byte_len_pix} + {12'd0, eval_skip_bytes};

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
                        fstate          <= F_EVAL;
                    end
                end

                // ------------------------------------------------------------
                F_EVAL: begin
                    if (eval_visible && (budget_bursts_q > 0)) begin
                        visible_width_q   <= eval_vis_width[12:0];
                        format_q          <= eval_format;
                        cache_wr_x_q      <= eval_clip_left[11:0];
                        byte_addr_burst_q <= eval_addr_aligned;
                        bytes_remaining_q <= eval_total_bytes[13:0];
                        skip_pixels_q     <= eval_skip_pixels;
                        fstate            <= F_ISSUE_AR;
                    end else begin
                        // Skip this sprite (not visible or budget exhausted).
                        if (sprite_idx == N_SPRITES - 1)
                            fstate <= F_IDLE;
                        else
                            sprite_idx <= sprite_idx + 4'd1;
                    end
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
                        fstate     <= F_EVAL;
                    end
                end

                default: fstate <= F_IDLE;
            endcase
        end
    end

    // ========================================================================
    // Sprite line cache — fetcher writes on clk_fetch; compositor (later
    // commit) reads on clk_pix.  Read side is dangled for now.
    // ========================================================================
    logic [9:0]                   cache_rd_addr_pix;
    logic [31:0]                  cache_rd_data [0:N_SPRITES-1];

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
        .rd_addr  (cache_rd_addr_pix),
        .rd_data  (cache_rd_data)
    );

    // Tie off read port until compositor lands.
    assign cache_rd_addr_pix = 10'd0;

    // ========================================================================
    // STUB: RGB passthrough.  Compositor lands in a later commit and consumes
    // the descriptor file + per-sprite control flags + cache_rd_data above.
    // ========================================================================
    assign rgb_r  = fb_pixel[15:11];
    assign rgb_g  = fb_pixel[10:5];
    assign rgb_b  = fb_pixel[4:0];
    assign rgb_de = fb_de;

    // Unused inputs — quiet Vivado until the compositor lands.
    /* verilator lint_off UNUSED */
    wire _unused = &{1'b0,
                     h_count, frame_start,
                     cache_rd_data[0],
                     1'b0};
    /* verilator lint_on UNUSED */

endmodule

`default_nettype wire
