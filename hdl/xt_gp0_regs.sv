// xt_gp0_regs.sv — AXI4-Lite control-register file for the PL, from PS GP0.
//
// Replaces axi_blitter_bridge.sv.  Same job — terminate AXI-Lite writes/reads
// from the ARM cores (PS GP0) and fan them out to the PL devices — but with a
// SPACIOUS, self-documenting per-device address map instead of the old crammed
// 64-byte window where blitter / sprite / overlay / control / keyboard / seven
// diagnostic words all fought over offsets 0x00..0x3F with read and write
// meaning different things on the same address.
//
// Runs on clk_sys — same domain as the blitter, so no CDC for the register bus.
//
// The block selectors and register offsets below are NOT hand-written here: they
// come from xt_gp0_pkg (generated from hdl/regmap/xt_gp0.json by
// tools/gen_regmap.py, which also renders vitis/xtos/src/xt_gp0_map.h and
// docs/Design/gp0-register-map.md).  Edit the JSON spec, never these constants.
//
// ====================================================================
// ADDRESS MAP (byte offset from the GP0 base 0x43C0_0000).  Block = addr[11:8];
// the slave claims 0x000..0xFFF (addr[15:12]==0).  ROM-loader lives at 0x1000+.
// All multi-byte registers are 32-bit WORD-ALIGNED — software uses Xil_In/Out32,
// no byte-lane replication.  Reads and writes never share an offset.
//
//   0x0xx  BLITTER   (dual-access: 6502 $D4Bx/$D4Cx/$D4Ex under UNLK_BLIT)
//     W 0x00..0x18   blitter registers DST/PAT/CMD/SRC/FLAGS (bl_addr = offset)
//     W 0x30..0x3B   SRC/DST DDR-surface descriptors (bl_addr = offset)
//     R 0x40         STATUS  {pat_blocked[2], queue_full[1], busy[0]}
//     R 0x44         SEQ     seq_counter[15:0]
//
//   0x1xx  SPRITE    (dual-access: 6502 $D4Ax/$D4Dx under UNLK_SPRITE)
//     W 0x00         SPR_IDX   latch sprite reg index
//     W 0x04         SPR_DATA  sprite reg data + strobe (writes idx/data to engine)
//
//   0x2xx  COMPOSITOR (A9-only) — drag overlay, written as whole words
//     W 0x00         OVL_EN    [0]=enable; also toggles the commit flag
//     W 0x04         OVL_BASE  DDR byte address (32-bit)
//     W 0x08         OVL_X     on-screen X (12-bit)
//     W 0x0C         OVL_Y     on-screen Y (12-bit)
//     W 0x10         OVL_W     width px (12-bit; stride = w<<2)
//     W 0x14         OVL_H     height px (12-bit)
//
//   0x3xx  CONTROL
//     W 0x00 / R 0x00  GP0_CTRL  [0]=bars, [3:1]=XL scale, [4]=DMACTL-blank (A9-only)
//     W 0x04 / R 0x04  SPEED     SALLY clock_mult (dual: 6502 $D4CA); read = effective
//     W 0x08 / R 0x08  UNLOCK    XT register-unlock (dual: 6502 $D1DF); read = effective
//     W 0x0C           KBD_INJECT  KBCODE + POKEY IRQ   (A9-only; emits $D4CF)
//     W 0x10           KBD_RELEASE all-keys-up          (A9-only; emits $D4CD)
//     W 0x14           KBD_BREAK   Atari BREAK          (A9-only; emits $D4CB)
//
//   0x4xx  DIAGNOSTICS (A9-only, read-only, word-aligned)
//     R 0x00 diag_word   R 0x04 diag2   R 0x08 diag3   R 0x0C diag4
//     R 0x10 diag5       R 0x14 diag6   R 0x18 diag7
//
//   0x5xx  XL-CONTROL  reserved (XL scale/blank still ride in GP0_CTRL for now)
//
// The blitter registers, keyboard inject and clock_mult all leave on the SAME
// bl_addr/bl_data/bl_we bus (reconstructed to $D4xx in fpga_xt_top and merged
// with the 6502 path there) — that is why this is one register file, not per-
// device sub-modules: they share one output bus.  Only the A9-side ADDRESS
// decode changed; the device-side signals and the fpga_xt_top fan-out muxes are
// identical to before, so the binding clk_sys paths are untouched.
// ====================================================================

`default_nettype none

module xt_gp0_regs (
    input  wire        clk,                  // clk_sys
    input  wire        rst,                  // active-high, clk domain

    // ---- AXI4-Lite slave (GP0 from PS) -------------------------------------
    input  wire [31:0] s_axi_awaddr,
    input  wire        s_axi_awvalid,
    output reg         s_axi_awready,
    input  wire [31:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output reg         s_axi_wready,
    output reg  [1:0]  s_axi_bresp,
    output reg         s_axi_bvalid,
    input  wire        s_axi_bready,

    input  wire [31:0] s_axi_araddr,
    input  wire        s_axi_arvalid,
    output reg         s_axi_arready,
    output reg  [31:0] s_axi_rdata,
    output reg  [1:0]  s_axi_rresp,
    output reg         s_axi_rvalid,
    input  wire        s_axi_rready,

    // ---- Blitter register bus output (clk_sys) — also carries kbd + clock_mult
    // bl_addr is the blitter's native 6-bit register address ($D4Bx/$D4Cx/$D4Ex,
    // page = bl_addr[5:4]); fpga_xt_top reconstructs the 16-bit bus address and
    // merges with the 6502 path.
    output reg  [5:0]  bl_addr,
    output reg  [7:0]  bl_data,
    output reg         bl_we,              // 1-cycle write strobe

    // ---- Sprite-engine reg bus output (A9-driven, clk_sys) -----------------
    output reg  [7:0]  spr_reg_addr,
    output reg  [7:0]  spr_reg_data,
    output reg         spr_reg_we,         // 1-cycle write strobe
    input  wire [15:0] spr_coll_data,      // collision[col_sel] readback (SPR_COLL)

    // ---- Blitter status (clk_sys) ------------------------------------------
    input  wire        bl_busy,
    input  wire        bl_queue_full,
    input  wire        bl_pat_blocked,
    input  wire [15:0] bl_seq_counter,

    // ---- PL diagnostic words (clk_sys) — read in the 0x4xx block -----------
    input  wire [31:0] diag_word,
    input  wire [31:0] diag2_word,
    input  wire [31:0] diag3_word,
    input  wire [31:0] diag4_word,
    input  wire [31:0] diag5_word,
    input  wire [31:0] diag6_word,
    input  wire [31:0] diag7_word,

    // ---- SALLY speed/clock_mult read-back (clk_sys) ------------------------
    input  wire [7:0]  clock_mult,

    // ---- PL control register (clk_sys) -------------------------------------
    // [0]=HDMI bars, [3:1]=XL scale, [4]=DMACTL-blank.  Resets to 0 (boot to the
    // live compositor; bars are a debug option only).
    output reg  [7:0]  gp0_ctrl,

    // ---- XT register-unlock control (clk_sys) ------------------------------
    output reg         xt_unlock_we,       // 1-cycle strobe (byte on bl_data)
    input  wire [7:0]  xt_unlock_state,    // effective unlock, for read-back

    // ---- Drag-overlay config (clk_sys) -------------------------------------
    output reg  [31:0] overlay_base,
    output reg  [11:0] overlay_x,
    output reg  [11:0] overlay_y,
    output reg  [11:0] overlay_w,
    output reg  [11:0] overlay_h,
    output reg         overlay_en,
    output reg         overlay_commit,     // toggles on each OVL_EN write

    // ---- XL compositor-plane window placement (clk_sys) --------------------
    // A9 positions the live XL emulation plane at an arbitrary rect (the GEM
    // emulation window's content rect).  xl_win_en=0 -> fpga_xt_top keeps the
    // legacy gp0_ctrl-scale centred placement.
    output reg  [11:0] xl_win_x,
    output reg  [11:0] xl_win_y,
    output reg  [11:0] xl_win_w,
    output reg  [11:0] xl_win_h,
    output reg  [2:0]  xl_win_scale,
    output reg         xl_win_en,
    output reg         xl_win_we           // 1-cycle commit strobe (on XL_WIN_EN write)
);

    // Block selectors (addr[11:8]) and register offsets (addr[7:0]) come from
    // the generated package — see the header comment / hdl/regmap/xt_gp0.json.
    import xt_gp0_pkg::*;

    // ====================================================================
    // AXI4-Lite write transaction FSM.
    //
    // AW and W are accepted INDEPENDENTLY (not coupled): the PS GP0 master may
    // assert AWVALID and wait for AWREADY before driving WVALID; a slave that
    // only accepts both together deadlocks.  Capture AW when it addresses our
    // window, capture W once we own that AW (the W beat is shared with the
    // ROM-loader slave), then respond once both halves are in.
    // ====================================================================
    localparam WST_IDLE = 1'b0,
               WST_RESP = 1'b1;

    reg        wstate;
    reg        aw_have, w_have;
    reg [3:0]  aw_blk;                 // latched block  = awaddr[11:8]
    reg [7:0]  aw_off;                 // latched offset = awaddr[7:0]
    reg [31:0] w_data;                 // full 32-bit write word (for word regs)
    reg [7:0]  w_byte;                 // first active byte  (for byte/blitter regs)

    // Claim 0x000..0xFFF; ROM-loader OR-muxes on the same bus at 0x1000+.
    wire       aw_mine = s_axi_awvalid && (s_axi_awaddr[15:12] == 4'h0);

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            wstate         <= WST_IDLE;
            s_axi_awready  <= 1'b0;
            s_axi_wready   <= 1'b0;
            s_axi_bresp    <= 2'b00;
            s_axi_bvalid   <= 1'b0;
            bl_addr        <= 6'd0;
            bl_data        <= 8'd0;
            bl_we          <= 1'b0;
            aw_have        <= 1'b0;
            w_have         <= 1'b0;
            aw_blk         <= 4'd0;
            aw_off         <= 8'd0;
            w_data         <= 32'd0;
            w_byte         <= 8'd0;
            gp0_ctrl       <= 8'h00;   // boot to the compositor; bars are debug-only
            xt_unlock_we   <= 1'b0;
            overlay_base   <= 32'd0;
            overlay_x      <= 12'd0;
            overlay_y      <= 12'd0;
            overlay_w      <= 12'd0;
            overlay_h      <= 12'd0;
            overlay_en     <= 1'b0;
            overlay_commit <= 1'b0;
            xl_win_x       <= 12'd0;
            xl_win_y       <= 12'd0;
            xl_win_w       <= 12'd0;
            xl_win_h       <= 12'd0;
            xl_win_scale   <= 3'd1;
            xl_win_en      <= 1'b0;
            xl_win_we      <= 1'b0;
            spr_reg_addr   <= 8'h00;
            spr_reg_data   <= 8'h00;
            spr_reg_we     <= 1'b0;
        end else begin
            s_axi_awready <= 1'b0;
            s_axi_wready  <= 1'b0;
            bl_we         <= 1'b0;
            xt_unlock_we  <= 1'b0;
            spr_reg_we    <= 1'b0;
            xl_win_we     <= 1'b0;

            unique case (wstate)
                WST_IDLE: begin
                    // Accept AW (once) if it addresses our window.
                    if (aw_mine && !aw_have) begin
                        s_axi_awready <= 1'b1;
                        aw_have       <= 1'b1;
                        aw_blk        <= s_axi_awaddr[11:8];
                        aw_off        <= s_axi_awaddr[7:0];
                    end

                    // Accept W only once we own the AW (this cycle or earlier).
                    if (s_axi_wvalid && !w_have && (aw_have || aw_mine)) begin
                        s_axi_wready <= 1'b1;
                        w_have       <= 1'b1;
                        w_data       <= s_axi_wdata;
                        if (s_axi_wstrb[0])      w_byte <= s_axi_wdata[7:0];
                        else if (s_axi_wstrb[1]) w_byte <= s_axi_wdata[15:8];
                        else if (s_axi_wstrb[2]) w_byte <= s_axi_wdata[23:16];
                        else                     w_byte <= s_axi_wdata[31:24];
                    end

                    // Both halves captured -> commit + respond.
                    if (aw_have && w_have) begin
                        bl_data <= w_byte;            // default data for the blitter bus
                        unique case (aw_blk)
                            // ---- 0x0xx BLITTER ------------------------------
                            // Genuine blitter registers map 1:1 to bl_addr.
                            BLK_BLITTER: begin
                                if ((aw_off <= BLT_REG_HI) ||
                                    (aw_off >= BLT_DESC_LO && aw_off <= BLT_DESC_HI)) begin
                                    bl_addr <= aw_off[5:0];
                                    bl_we   <= 1'b1;
                                end
                            end
                            // ---- 0x1xx SPRITE -------------------------------
                            BLK_SPRITE: begin
                                if      (aw_off == SPR_IDX) spr_reg_addr <= w_byte;
                                else if (aw_off == SPR_DATA) begin
                                    spr_reg_data <= w_byte;
                                    spr_reg_we   <= 1'b1;
                                end
                            end
                            // ---- 0x2xx COMPOSITOR (overlay, whole words) ----
                            BLK_COMP: begin
                                unique case (aw_off)
                                    OVL_EN: begin
                                               overlay_en     <= w_data[0];
                                               overlay_commit <= ~overlay_commit;
                                           end
                                    OVL_BASE: overlay_base <= w_data;
                                    OVL_X:    overlay_x    <= w_data[11:0];
                                    OVL_Y:    overlay_y    <= w_data[11:0];
                                    OVL_W:    overlay_w    <= w_data[11:0];
                                    OVL_H:    overlay_h    <= w_data[11:0];
                                    default: ;
                                endcase
                            end
                            // ---- 0x3xx CONTROL ------------------------------
                            BLK_CTRL: begin
                                unique case (aw_off)
                                    CTRL_GP0:   gp0_ctrl <= w_byte;            // [0]bars/compositor [3:1]XL-scale [4]DMACTL-blank [5]drag-overlay alpha-blend
                                    CTRL_SPEED: begin bl_addr <= 6'h1A; bl_we <= 1'b1; end // clock_mult -> $D4CA
                                    CTRL_UNLOCK: xt_unlock_we <= 1'b1;         // unlock (data on bl_data)
                                    CTRL_KBD_INJECT:  begin bl_addr <= 6'h1F; bl_we <= 1'b1; end // -> $D4CF
                                    CTRL_KBD_RELEASE: begin bl_addr <= 6'h1D; bl_we <= 1'b1; end // -> $D4CD
                                    CTRL_KBD_BREAK:   begin bl_addr <= 6'h1B; bl_we <= 1'b1; end // -> $D4CB
                                    default: ;
                                endcase
                            end
                            // ---- 0x5xx XL-CONTROL (whole words) -------------
                            BLK_XLCTL: begin
                                unique case (aw_off)
                                    XL_WIN_X:     xl_win_x     <= w_data[11:0];
                                    XL_WIN_Y:     xl_win_y     <= w_data[11:0];
                                    XL_WIN_W:     xl_win_w     <= w_data[11:0];
                                    XL_WIN_H:     xl_win_h     <= w_data[11:0];
                                    XL_WIN_SCALE: xl_win_scale <= w_data[2:0];
                                    XL_WIN_EN:    begin
                                                      xl_win_en <= w_data[0];
                                                      xl_win_we <= 1'b1;   // commit the rect
                                                  end
                                    default: ;
                                endcase
                            end
                            default: ; // 0x4xx diag is read-only; others no-op
                        endcase
                        s_axi_bresp  <= 2'b00;
                        s_axi_bvalid <= 1'b1;
                        aw_have      <= 1'b0;
                        w_have       <= 1'b0;
                        wstate       <= WST_RESP;
                    end
                end

                WST_RESP: begin
                    s_axi_bvalid <= 1'b1;            // hold until the PS accepts
                    if (s_axi_bready) begin
                        s_axi_bvalid <= 1'b0;
                        wstate       <= WST_IDLE;
                    end
                end
            endcase
        end
    end

    // ====================================================================
    // AXI4-Lite read transaction FSM — word-aligned, per-block, no replication.
    // ====================================================================
    localparam RST_IDLE = 1'b0,
               RST_READ = 1'b1;

    reg        rstate;
    wire [3:0] ar_blk = s_axi_araddr[11:8];
    wire [7:0] ar_off = s_axi_araddr[7:0];

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            rstate        <= RST_IDLE;
            s_axi_arready <= 1'b0;
            s_axi_rdata   <= 32'd0;
            s_axi_rresp   <= 2'b00;
            s_axi_rvalid  <= 1'b0;
        end else begin
            s_axi_arready <= 1'b0;

            unique case (rstate)
                RST_IDLE: begin
                    if (s_axi_arvalid && (s_axi_araddr[15:12] == 4'h0)) begin
                        s_axi_arready <= 1'b1;
                        s_axi_rdata   <= 32'd0;
                        unique case (ar_blk)
                            BLK_BLITTER:
                                if      (ar_off == BLT_STATUS)
                                    s_axi_rdata <= {29'd0, bl_pat_blocked, bl_queue_full, bl_busy};
                                else if (ar_off == BLT_SEQ)
                                    s_axi_rdata <= {16'd0, bl_seq_counter};
                            BLK_SPRITE:
                                if      (ar_off == SPR_COLL)
                                    s_axi_rdata <= {16'd0, spr_coll_data};
                            BLK_CTRL:
                                if      (ar_off == CTRL_GP0)    s_axi_rdata <= {24'd0, gp0_ctrl};
                                else if (ar_off == CTRL_SPEED)  s_axi_rdata <= {24'd0, clock_mult};
                                else if (ar_off == CTRL_UNLOCK) s_axi_rdata <= {24'd0, xt_unlock_state};
                            BLK_DIAG:
                                unique case (ar_off)
                                    DIAG0: s_axi_rdata <= diag_word;
                                    DIAG2: s_axi_rdata <= diag2_word;
                                    DIAG3: s_axi_rdata <= diag3_word;
                                    DIAG4: s_axi_rdata <= diag4_word;
                                    DIAG5: s_axi_rdata <= diag5_word;
                                    DIAG6: s_axi_rdata <= diag6_word;
                                    DIAG7: s_axi_rdata <= diag7_word;
                                    default: ;
                                endcase
                            default: ;
                        endcase
                        s_axi_rresp  <= 2'b00;
                        s_axi_rvalid <= 1'b1;
                        rstate       <= RST_READ;
                    end
                end

                RST_READ: begin
                    if (s_axi_rready) begin
                        s_axi_rvalid <= 1'b0;
                        rstate       <= RST_IDLE;
                    end
                end
            endcase
        end
    end

endmodule

`default_nettype wire
