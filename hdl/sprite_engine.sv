// sprite_engine.sv — hardware sprite compositor for the 1080p scan-out path.
//
// Commit-2: descriptor register file.  Adds the SALLY-visible register
// surface ($D4Ax per-sprite control bytes + $D4Dx indexed descriptor
// page).  Compositor / fetcher / line cache still stubbed — the RGB
// path remains a passthrough until those submodules land.
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
//     both 12-bit signed.  Spec implied 13-bit + 13-bit + 12-bit which
//     does not pack cleanly into the 8-byte descriptor; 12-bit each
//     preserves the spec's 64 MB arena footprint at 32 bpp (4096×4096)
//     and a ±2048 screen window which covers 1920×1080 with off-screen
//     scroll headroom.
//   * clk_bus = 150 MHz (was 162 MHz in the spec).  Per-scanline AXI HP2
//     budget recomputed to ~12.4 KB.
//
// Register map (decoded from low 8 bits of D4xx):
//
//   $D4A0..$D4AF — Per-sprite status (one byte per sprite N at $D4A0+N)
//     bit 0: en        — sprite enabled
//     bit 1: h_flip    — horizontal mirror (future)
//     bit 2: v_flip    — vertical mirror   (future)
//     bit 3: 2x_w      — 2× width          (future)
//     bit 4: 2x_h      — 2× height         (future)
//     bit 5: format    — 0=RGBA-5:5:5:1 source, 1=RGBA-8888 source
//     bit 6: reserved
//     bit 7: any_col   — R: sticky any-collision; W: 1 clears (W1C)
//
//   $D4D0  SPRITE_SEL   — W: sprite index (0..15) for descriptor R/W
//   $D4D1  SPRITE_B0    — R/W: priority[4:0]
//   $D4D2  SPRITE_B1    — R/W: log2_size[3:0]
//   $D4D3  SPRITE_B2    — R/W: arena_y[7:0]
//   $D4D4  SPRITE_B3    — R/W: {arena_x[11:8], arena_y[11:8]}
//   $D4D5  SPRITE_B4    — R/W: arena_x[7:0]
//   $D4D6  SPRITE_B5    — R/W: screen_y[7:0]
//   $D4D7  SPRITE_B6    — R/W: {screen_x[11:8], screen_y[11:8]}
//   $D4D8  SPRITE_B7    — R/W: screen_x[7:0]  (write commits descriptor)
//   $D4D9  COL_SEL      — W: collision row select (0..15)
//   $D4DA  COL_LO       — R / W1C: collision row [7:0]   for COL_SEL
//   $D4DB  COL_HI       — R / W1C: collision row [15:8]  for COL_SEL
//   $D4DC..$D4DE        — reserved
//   $D4DF  SPRITE_CTRL  — R/W: bit 0 = GLOBAL_ENABLE

`default_nettype none

module sprite_engine #(
    parameter int unsigned ARENA_BASE = 32'h2000_0000,
    parameter int unsigned N_SPRITES  = 16
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
    // Reads of $D4D1..$D4D8 reconstruct the descriptor bytes from these fields
    // for the sprite addressed by sprite_sel.
    // ========================================================================
    logic [4:0]         desc_prio    [0:N_SPRITES-1];
    logic [3:0]         desc_log2sz  [0:N_SPRITES-1];
    logic [11:0]        desc_arena_x [0:N_SPRITES-1];
    logic [11:0]        desc_arena_y [0:N_SPRITES-1];
    logic signed [11:0] desc_screen_x[0:N_SPRITES-1];
    logic signed [11:0] desc_screen_y[0:N_SPRITES-1];

    // ========================================================================
    // Shadow descriptor bytes B0..B6 — accumulate on writes to $D4D1..$D4D7.
    // Writing $D4D8 commits {B0..B6, this byte} into the descriptor file at
    // index sprite_sel.  B7 (screen_x[7:0]) is taken from reg_wdata on the
    // commit cycle, not stored in the shadow.
    // ========================================================================
    logic [7:0]         shadow_b [0:6];

    // Indexed-access registers and global control ----------------------------
    logic [3:0]         sprite_sel;     // $D4D0
    logic [3:0]         col_sel;        // $D4D9
    logic               global_enable;  // $D4DF[0]

    // ========================================================================
    // Cross-product collision matrix — one N_SPRITES-bit row per sprite.
    // Bit collision[a][b] = 1 means sprite a's pixels overlapped sprite b's
    // since the last clear.  Compositor (later commit) drives collision_set;
    // CPU clears bits via W1C through $D4DA/$D4DB at row col_sel.
    // ========================================================================
    logic [N_SPRITES-1:0] collision     [0:N_SPRITES-1];
    logic [N_SPRITES-1:0] collision_set [0:N_SPRITES-1];

    // No compositor yet — drive the set side to zero.  Later commit replaces
    // these with per-pixel overlap signals from the priority resolver.
    genvar gi;
    generate
        for (gi = 0; gi < N_SPRITES; gi = gi + 1) begin : g_collision_set_tieoff
            assign collision_set[gi] = '0;
        end
    endgenerate

    // ========================================================================
    // Address decode
    // ========================================================================
    wire is_d4ax = (reg_addr[7:4] == 4'hA);
    wire is_d4dx = (reg_addr[7:4] == 4'hD);
    wire [3:0] d4ax_idx  = reg_addr[3:0];
    wire [3:0] d4dx_idx  = reg_addr[3:0];

    wire is_d4ax_write = reg_we && is_d4ax;
    wire is_d4dx_write = reg_we && is_d4dx;

    // Per-row collision clear mask (combinational pre-flop) ------------------
    logic [N_SPRITES-1:0] col_clear_mask;
    always_comb begin
        col_clear_mask = '0;
        if (is_d4dx_write && (d4dx_idx == 4'hA))
            col_clear_mask[7:0]  = reg_wdata;
        if (is_d4dx_write && (d4dx_idx == 4'hB))
            col_clear_mask[15:8] = reg_wdata;
    end

    // ========================================================================
    // Write FSM (clk_fetch domain) — register storage + descriptor commit.
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
            // ---- $D4Ax per-sprite control byte write -----------------------
            if (is_d4ax_write) begin
                sprite_en    [d4ax_idx] <= reg_wdata[0];
                sprite_h_flip[d4ax_idx] <= reg_wdata[1];
                sprite_v_flip[d4ax_idx] <= reg_wdata[2];
                sprite_2x_w  [d4ax_idx] <= reg_wdata[3];
                sprite_2x_h  [d4ax_idx] <= reg_wdata[4];
                sprite_format[d4ax_idx] <= reg_wdata[5];
                // bit 6 reserved
                // bit 7: W1C — handled in the any_col loop below
            end

            // ---- $D4Dx indexed descriptor / collision / ctrl writes --------
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
                        // Commit: latch {B0..B6, reg_wdata} into descriptor file.
                        desc_prio    [sprite_sel] <= shadow_b[0][4:0];
                        desc_log2sz  [sprite_sel] <= shadow_b[1][3:0];
                        desc_arena_y [sprite_sel] <= {shadow_b[3][3:0], shadow_b[2]};
                        desc_arena_x [sprite_sel] <= {shadow_b[3][7:4], shadow_b[4]};
                        desc_screen_y[sprite_sel] <= $signed({shadow_b[6][3:0], shadow_b[5]});
                        desc_screen_x[sprite_sel] <= $signed({shadow_b[6][7:4], reg_wdata});
                    end
                    4'h9: col_sel <= reg_wdata[3:0];
                    // 4'hA / 4'hB: handled by collision loop below (W1C).
                    4'hF: global_enable <= reg_wdata[0];
                    default: ; // reserved — drop
                endcase
            end

            // ---- any_col sticky bit (per sprite) ---------------------------
            // Sets when compositor reports any collision for that sprite,
            // clears on $D4Ax write with bit 7 = 1.  Clear takes precedence
            // over set on the same cycle.
            for (si = 0; si < N_SPRITES; si = si + 1) begin
                if (is_d4ax_write && (d4ax_idx == si[3:0]) && reg_wdata[7])
                    sprite_any_col[si] <= 1'b0;
                else if (|collision_set[si])
                    sprite_any_col[si] <= 1'b1;
            end

            // ---- Collision matrix (sticky-OR with set, W1C from CPU) -------
            for (si = 0; si < N_SPRITES; si = si + 1) begin
                if (col_sel == si[3:0])
                    collision[si] <= (collision[si] & ~col_clear_mask) | collision_set[si];
                else
                    collision[si] <= collision[si] | collision_set[si];
            end
        end
    end

    // ========================================================================
    // Read-back path — combinational mux on reg_addr.
    // ========================================================================
    logic [7:0] rdata_d4ax;
    always_comb begin
        rdata_d4ax = {sprite_any_col[d4ax_idx],   // bit 7
                      1'b0,                        // bit 6 reserved
                      sprite_format[d4ax_idx],     // bit 5
                      sprite_2x_h[d4ax_idx],       // bit 4
                      sprite_2x_w[d4ax_idx],       // bit 3
                      sprite_v_flip[d4ax_idx],     // bit 2
                      sprite_h_flip[d4ax_idx],     // bit 1
                      sprite_en[d4ax_idx]};        // bit 0
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
    // STUB: RGB passthrough.  Compositor lands in a later commit and consumes
    // the descriptor file + per-sprite control flags declared above.
    // ========================================================================
    assign rgb_r = fb_pixel[15:11];
    assign rgb_g = fb_pixel[10:5];
    assign rgb_b = fb_pixel[4:0];
    assign rgb_de = fb_de;

    // AXI HP2 master tied off (no transactions until line fetcher lands).
    assign m_axi_araddr  = 32'd0;
    assign m_axi_arlen   = 8'd0;
    assign m_axi_arsize  = 3'd0;
    assign m_axi_arburst = 2'd0;
    assign m_axi_arvalid = 1'b0;
    assign m_axi_rready  = 1'b1;

    // Unused inputs — quiet Vivado about them until the real compositor
    // and fetcher land in later commits.
    /* verilator lint_off UNUSED */
    wire _unused = &{1'b0,
                     clk_pix, rst,
                     h_count, v_count, line_start, frame_start,
                     m_axi_arready, m_axi_rdata, m_axi_rvalid, m_axi_rlast,
                     1'b0};
    /* verilator lint_on UNUSED */

endmodule

`default_nettype wire
