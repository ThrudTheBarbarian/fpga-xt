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
// tools/gen_regmap.py, which also renders hdl/regmap/xt_gp0_map.h and
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
//   0x5xx  XL-CONTROL  XL compositor-plane window placement (A9-positioned)
//
//   0x6xx  MATH (A9-only) — math-coprocessor mailbox (see hdl/math_cop.sv)
//     R 0x00         MATH_EVT   {valid[8], chunk[7:0]} — read consumes one event
//     W 0x04         MATH_DONE  {count[23:16], first-line[15:8], chunk[7:0]}
//     R 0x08         MATH_STAT  engine busy / resident chunk / evt FIFO fill
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
    input  wire [31:0] diag8_word,      // TEMP: ROM-window upload diag (AXI/rom_we counts)
    input  wire [31:0] diag9_word,      // TEMP: ROM-window upload diag (last addr/data)
    // ---- hardware entropy (clk_sys) — read in the 0x7xx block --------------
    input  wire [31:0] trng_word,
    input  wire [31:0] trng_stat_word,   // {23'd0, fresh, 2'd0, bits_avail}
    output reg         trng_rd_pop,      // 1-clk: TRNG_RND was read — consume

    // ---- SALLY speed/clock_mult read-back (clk_sys) ------------------------
    input  wire [7:0]  clock_mult,

    // ---- PL control register (clk_sys) -------------------------------------
    // [0]=HDMI bars, [3:1]=XL scale, [4]=DMACTL-blank.  Resets to 0 (boot to the
    // live compositor; bars are a debug option only).
    output reg  [7:0]  gp0_ctrl,

    // ---- Compositor plane arrangement (clk_sys; CDC'd to clk_pix in top) ----
    // depth [3:0]=desktop [7:4]=overlay [11:8]=XL; alpha_en [16]=desktop
    // [17]=overlay [18]=XL.  Reset 0x210 = the shipping arrangement (XL on top
    // opaque, desktop at the back).  Route-A flip is a single PS word write.
    output reg  [31:0] cmpcfg,

    // ---- SALLY reset hold (clk_sys; CDC'd to clk_sally in top) -------------
    // [0]=1 holds the 6502 core + its clock gen in reset (cold-boot-per-launch:
    // hold, rewrite OS/RAM through the ROM-loader window, release = coldstart).
    // Reset 0 = running, so a bitstream load boots exactly as before.
    output reg  [7:0]  sallyrst,

    // ---- ANTIC-rewrite timing tune (clk_sys, straight to antic_gtia) -------
    // Signed nibble offsets on the cycle numbers ACID bisects; 0 = RTL default.
    output reg  [15:0] rw_tune,

    // ---- Keypad->joystick override (clk_sys; routed to antic_top) ----------
    // [31]=enable, [7:0]=PORTA pin value (active-low STICK0/1), [8]=TRIG0 fire
    // (active-low). antic_top muxes this into pia_regs PORTA + GTIA TRIG0 when
    // [31]=1, replacing the absent PCAL9722 joystick. Reset 0 = joy_bridge
    // drives as normal (override off).
    output reg  [31:0] joy_ovr,
    output reg  [7:0]  consol_keys,   // CONSOL ($D01F) value the 6502 reads (active-low console keys)

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
    output reg         xl_win_ovs,         // SCALE bit 3: overscan capture (320x240)
    output reg         xl_win_en,
    output reg         xl_win_we,          // 1-cycle commit strobe (on XL_WIN_EN write)

    // ---- Math-coprocessor mailbox (clk_sys, wired to math_cop) --------------
    input  wire [8:0]  math_evt_data,      // {valid, chunk} — event FIFO head
    output reg         math_evt_pop,       // 1-cycle strobe on a MATH_EVT read
    output reg  [23:0] math_done_word,     // {count, first-line, chunk}
    output reg         math_done_we,       // 1-cycle strobe on a MATH_DONE write
    input  wire [31:0] math_stat_word,     // MATH_STAT readback

    // ---- SIO mailbox data window (clk_sys, wired to xt_sio_mbox) ------------
    // The doorbell/completion legs stay on the MATH block above (so IRQ_F2P[1]
    // and the worker task are untouched); only the payload window lives here.
    output reg  [8:0]  sio_ptr,            // SIO_PTR: byte pointer into the mailbox
    output reg         sio_ptr_we,         // 1-cycle strobe on a SIO_PTR write
    output reg  [31:0] sio_wdata,          // SIO_DAT write data
    output reg         sio_we,             // 1-cycle strobe on a SIO_DAT write
    output reg         sio_rd,             // 1-cycle strobe on a SIO_DAT read (auto-increment)
    input  wire [31:0] sio_rdata,          // SIO_DAT readback

    // ---- DEBUG block (in-fabric 6502 debugger, xt6502_debug @ clk_sally) ------
    // Control OUT (clk_sys): command toggles flip on each write; levels are values.
    output reg         dbg_halt_tog,
    output reg         dbg_go_tog,
    output reg         dbg_step_tog,
    output reg         dbg_commit_tog,
    output reg  [1:0]  dbg_cfg,            // [0]=bkpt_en [1]=halt_at_reset
    output reg  [15:0] dbg_bkpt_addr,
    output reg  [15:0] dbg_step_count,
    output reg  [15:0] dbg_wpc,
    output reg  [31:0] dbg_waxys,
    output reg  [11:0] dbg_wpsh,
    output reg  [15:0] dbg_wp_addr,        // data watchpoint address
    output reg  [2:0]  dbg_wp_cfg,         // [0]=en [1]=on_write [2]=on_read
    // Status IN (from clk_sally; coherent when halted — a halted core is static).
    input  wire [3:0]  dbg_stat,           // [3]run [2]step [1]bkpt_hit [0]halted
    input  wire [31:0] dbg_diag,           // DBG_DIAG self-observability (coherent when halted)
    input  wire [15:0] dbg_snap_pc,
    input  wire [31:0] dbg_snap_axys,
    input  wire [11:0] dbg_snap_psh,
    input  wire [31:0] dbg_icnt,
    input  wire [31:0] dbg_beam,          // beam at the halt boundary
    output reg  [15:0] dbg_beampc,        // PC to beam-stamp (no halt)
    input  wire [31:0] dbg_beam2,         // beam at that PC
    // trace ring: control out (levels), status/data in
    output reg  [1:0]  dbg_trc_ctrl,      // [0]=enable [1]=break_on_full
    output reg  [11:0] dbg_trc_idx,       // read index
    input  wire [31:0] dbg_trc_wptr,      // [11:0]=wptr [16]=wrapped [17]=broke
    input  wire [15:0] dbg_trc_pc,
    input  wire [31:0] dbg_trc_axys,
    input  wire [11:0] dbg_trc_p,
    // FID streaming trace (0x60..0x74)
    output reg  [1:0]  dbg_strm_ctrl,     // [0]=strm_en [1]=drain_done
    output reg  [11:0] dbg_strm_raddr,    // ring read address
    input  wire        dbg_strm_flush,    // ring full + core halted
    input  wire [12:0] dbg_strm_wptr,     // valid entry count
    input  wire [63:0] dbg_strm_rd,       // ring[raddr]

    // ---- ANTIC timebase debug probe (DBG_TB_*, @ antic_top clk_bus) ----------
    // Config OUT (clk_sys); 2-FF synced into the ANTIC domain inside antic_top.
    output reg  [28:0] dbg_tb_cfg,        // {[28:26]=wsync_shape,[25]=circular,[24]=clear,[19:16]=read_idx,[11:4]=match_addr,[2:0]=mode}
    // Status/capture IN (from clk_bus); 2-FF synced here (stable/slow words).
    input  wire [31:0] dbg_tb_stat,       // {[25]=armed,[24]=full,[20:16]=wr_idx,[15:0]=trig_count}
    input  wire [24:0] dbg_tb_cap         // ring[read_idx] = {scanline[8:0],phi2[7:0],data[7:0]}
);

    // Block selectors (addr[11:8]) and register offsets (addr[7:0]) come from
    // the generated package — see the header comment / hdl/regmap/xt_gp0.json.
    import xt_gp0_pkg::*;

    // 2-FF sync for the debugger status nibble (clk_sally -> clk_sys). The halted
    // flag drives the poll loop in /bin/6502, so it must be metastability-clean;
    // the wider snapshots are read only once halted (static) and need no sync.
    (* ASYNC_REG = "TRUE" *) reg [3:0] dbg_stat_s1, dbg_stat_s;
    always_ff @(posedge clk) begin
        dbg_stat_s1 <= dbg_stat;
        dbg_stat_s  <= dbg_stat_s1;
    end

    // 2-FF sync for the ANTIC timebase probe read-out (clk_bus -> clk_sys).
    // Both words are written at most once per captured event and are stable
    // whenever the A9 reads them, so a plain multi-bit 2-FF sync is safe.
    (* ASYNC_REG = "TRUE" *) reg [31:0] dbg_tb_stat_s1, dbg_tb_stat_s;
    (* ASYNC_REG = "TRUE" *) reg [24:0] dbg_tb_cap_s1,  dbg_tb_cap_s;
    always_ff @(posedge clk) begin
        dbg_tb_stat_s1 <= dbg_tb_stat;
        dbg_tb_stat_s  <= dbg_tb_stat_s1;
        dbg_tb_cap_s1  <= dbg_tb_cap;
        dbg_tb_cap_s   <= dbg_tb_cap_s1;
    end

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
            cmpcfg         <= 32'h0000_0210;  // depth desktop0/overlay1/XL2, all opaque = shipping
            sallyrst       <= 8'h06;          // power-on: bit1 = FIDELITY core, bit2 = ANTIC TIMING-MACHINE AUTHORITY.
            rw_tune        <= 16'd0;          // the RTL's own cycle numbers
                                             // bit0=0 = realm running.  Turbo is a PS opt-in (bit1=0); the
                                             // legacy ANTIC timing path is a PS opt-out (bit2=0).
                                             // Authority became the default once it measured 33/57 against
                                             // the legacy path's 31 with no regressions (run 2026-07-27-2).
            joy_ovr        <= 32'h0000_0000;  // override off: joy_bridge drives PORTA/TRIG0
            consol_keys    <= 8'h07;           // no console keys pressed (BASIC on) until the kernel sets it
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
            xl_win_ovs     <= 1'b0;
            xl_win_we      <= 1'b0;
            spr_reg_addr   <= 8'h00;
            spr_reg_data   <= 8'h00;
            spr_reg_we     <= 1'b0;
            math_done_word <= 24'd0;
            math_done_we   <= 1'b0;
            sio_ptr        <= 9'd0;
            sio_ptr_we     <= 1'b0;
            sio_wdata      <= 32'd0;
            sio_we         <= 1'b0;
            dbg_halt_tog   <= 1'b0;
            dbg_go_tog     <= 1'b0;
            dbg_step_tog   <= 1'b0;
            dbg_commit_tog <= 1'b0;
            dbg_cfg        <= 2'b00;
            dbg_bkpt_addr  <= 16'd0;
            dbg_beampc     <= 16'd0;
            dbg_wp_addr    <= 16'd0;
            dbg_wp_cfg     <= 3'b000;
            dbg_step_count <= 16'd1;
            dbg_wpc        <= 16'd0;
            dbg_waxys      <= 32'd0;
            dbg_wpsh       <= 12'd0;
            dbg_trc_ctrl   <= 2'b00;
            dbg_trc_idx    <= 12'd0;
            dbg_strm_ctrl  <= 2'b00;
            dbg_strm_raddr <= 12'd0;
            dbg_tb_cfg     <= 29'd0;
        end else begin
            s_axi_awready <= 1'b0;
            s_axi_wready  <= 1'b0;
            bl_we         <= 1'b0;
            xt_unlock_we  <= 1'b0;
            spr_reg_we    <= 1'b0;
            xl_win_we     <= 1'b0;
            math_done_we  <= 1'b0;
            sio_ptr_we    <= 1'b0;
            sio_we        <= 1'b0;

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
                                    CTRL_GP0:   gp0_ctrl <= w_byte;            // [0]bars/compositor [3:1]XL-scale [4]DMACTL-blank [5]video-sleep
                                    CTRL_CMPCFG: cmpcfg  <= w_data;            // per-plane depth + alpha_en (whole word)
                                    CTRL_SALLYRST: sallyrst <= w_byte;         // [0] = hold the 6502 realm in reset
                                    CTRL_RWTUNE:   rw_tune  <= w_data[15:0];
                                    CTRL_JOY_OVR:  joy_ovr  <= w_data;         // keypad->joystick override (whole word)
                                    CTRL_CONSOL:   consol_keys <= w_byte;       // CONSOL keys (kernel holds OPTION=$03 to keep BASIC off for games)
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
                                    // bit 3 rides the SCALE word: overscan
                                    // capture (the writeback grabs scanlines
                                    // 8..247 instead of the 40x24 playfield).
                                    XL_WIN_SCALE: begin
                                                      xl_win_scale <= w_data[2:0];
                                                      xl_win_ovs   <= w_data[3];
                                                  end
                                    XL_WIN_EN:    begin
                                                      xl_win_en <= w_data[0];
                                                      xl_win_we <= 1'b1;   // commit the rect
                                                  end
                                    default: ;
                                endcase
                            end
                            // ---- 0x6xx MATH (whole words) -------------------
                            BLK_MATH: begin
                                if (aw_off == MATH_DONE) begin
                                    math_done_word <= w_data[23:0];
                                    math_done_we   <= 1'b1;
                                end
                            end
                            // ---- 0xAxx SIO (mailbox data window) ------------
                            BLK_SIO: begin
                                unique case (aw_off)
                                    SIO_PTR: begin sio_ptr    <= w_data[8:0];
                                                   sio_ptr_we <= 1'b1; end
                                    SIO_DAT: begin sio_wdata  <= w_data;
                                                   sio_we     <= 1'b1; end
                                    default: ;
                                endcase
                            end
                            // ---- 0x8xx DEBUG (6502 debugger) ----------------
                            // Command regs toggle a bit (edge-detected in clk_sally);
                            // value regs latch. DBG_STEP carries the count + a pulse.
                            BLK_DEBUG: begin
                                unique case (aw_off)
                                    DBG_HALT:   dbg_halt_tog   <= ~dbg_halt_tog;
                                    DBG_GO:     dbg_go_tog     <= ~dbg_go_tog;
                                    DBG_STEP:   begin dbg_step_count <= w_data[15:0];
                                                      dbg_step_tog   <= ~dbg_step_tog; end
                                    DBG_CFG:    dbg_cfg        <= w_data[1:0];
                                    DBG_BKPT:   dbg_bkpt_addr  <= w_data[15:0];
                                    DBG_BEAMPC: dbg_beampc     <= w_data[15:0];
                                    DBG_WP:     dbg_wp_addr    <= w_data[15:0];
                                    DBG_WPCFG:  dbg_wp_cfg     <= w_data[2:0];
                                    DBG_COMMIT: dbg_commit_tog <= ~dbg_commit_tog;
                                    DBG_WPC:    dbg_wpc        <= w_data[15:0];
                                    DBG_WAXYS:  dbg_waxys      <= w_data;
                                    DBG_WPSH:   dbg_wpsh       <= w_data[11:0];
                                    DBG_TRC_CTRL: dbg_trc_ctrl <= w_data[1:0];
                                    DBG_TRC_IDX:  dbg_trc_idx  <= w_data[11:0];
                                    DBG_STRM_CTRL:  dbg_strm_ctrl  <= w_data[1:0];
                                    DBG_STRM_RADDR: dbg_strm_raddr <= w_data[11:0];
                                    DBG_TB_CFG:     dbg_tb_cfg     <= w_data[28:0];
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
            math_evt_pop  <= 1'b0;
            trng_rd_pop   <= 1'b0;
            sio_rd        <= 1'b0;
        end else begin
            s_axi_arready <= 1'b0;
            math_evt_pop  <= 1'b0;
            trng_rd_pop   <= 1'b0;
            sio_rd        <= 1'b0;

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
                                else if (ar_off == CTRL_CMPCFG) s_axi_rdata <= cmpcfg;
                                else if (ar_off == CTRL_SALLYRST) s_axi_rdata <= {24'd0, sallyrst};
                            BLK_DIAG:
                                unique case (ar_off)
                                    DIAG0: s_axi_rdata <= diag_word;
                                    DIAG2: s_axi_rdata <= diag2_word;
                                    DIAG3: s_axi_rdata <= diag3_word;
                                    DIAG4: s_axi_rdata <= diag4_word;
                                    DIAG5: s_axi_rdata <= diag5_word;
                                    DIAG6: s_axi_rdata <= diag6_word;
                                    DIAG7: s_axi_rdata <= diag7_word;
                                    DIAG8: s_axi_rdata <= diag8_word;
                                    DIAG9: s_axi_rdata <= diag9_word;
                                    default: ;
                                endcase
                            BLK_MATH:
                                if (ar_off == MATH_EVT) begin
                                    // read-to-pop: this read consumes the head event
                                    s_axi_rdata  <= {23'd0, math_evt_data};
                                    math_evt_pop <= 1'b1;
                                end
                                else if (ar_off == MATH_STAT) s_axi_rdata <= math_stat_word;
                            // ---- 0xAxx SIO (mailbox data window) ------------
                            // Like MATH_EVT this is a read WITH a side effect: the
                            // pointer auto-increments, so a run of words is one seek
                            // plus N reads rather than a seek per word.
                            BLK_SIO:
                                if (ar_off == SIO_DAT) begin
                                    s_axi_rdata <= sio_rdata;
                                    sio_rd      <= 1'b1;
                                end
                            BLK_TRNG:
                                // read-to-consume, same shape as MATH_EVT: the
                                // read restarts the freshness count so the next
                                // `fresh` genuinely means 32 NEW debiased bits.
                                if (ar_off == TRNG_RND) begin
                                    s_axi_rdata <= trng_word;
                                    trng_rd_pop <= 1'b1;
                                end
                                else if (ar_off == TRNG_STAT)
                                    s_axi_rdata <= trng_stat_word;
                            // ---- 0x8xx DEBUG (6502 debugger read-back) ------
                            // Snapshots are coherent only when halted (static core);
                            // the halted flag itself is 2-FF synced (dbg_stat_s).
                            BLK_DEBUG:
                                unique case (ar_off)
                                    DBG_CFG:   s_axi_rdata <= {30'd0, dbg_cfg};
                                    DBG_BKPT:  s_axi_rdata <= {16'd0, dbg_bkpt_addr};
                                    DBG_WP:    s_axi_rdata <= {16'd0, dbg_wp_addr};
                                    DBG_WPCFG: s_axi_rdata <= {29'd0, dbg_wp_cfg};
                                    DBG_DIAG:  s_axi_rdata <= dbg_diag;
                                    DBG_WPC:   s_axi_rdata <= {16'd0, dbg_wpc};
                                    DBG_WAXYS: s_axi_rdata <= dbg_waxys;
                                    DBG_WPSH:  s_axi_rdata <= {20'd0, dbg_wpsh};
                                    DBG_STAT:  s_axi_rdata <= {28'd0, dbg_stat_s};
                                    DBG_PC:    s_axi_rdata <= {16'd0, dbg_snap_pc};
                                    DBG_AXYS:  s_axi_rdata <= dbg_snap_axys;
                                    DBG_PSH:   s_axi_rdata <= {20'd0, dbg_snap_psh};
                                    DBG_ICNT:  s_axi_rdata <= dbg_icnt;
                                    DBG_BEAM:  s_axi_rdata <= dbg_beam;
                                    DBG_BEAM2: s_axi_rdata <= dbg_beam2;
                                    DBG_TRC_CTRL: s_axi_rdata <= {30'd0, dbg_trc_ctrl};
                                    DBG_TRC_WPTR: s_axi_rdata <= dbg_trc_wptr;
                                    DBG_TRC_PC:   s_axi_rdata <= {16'd0, dbg_trc_pc};
                                    DBG_TRC_AXYS: s_axi_rdata <= dbg_trc_axys;
                                    DBG_TRC_P:    s_axi_rdata <= {20'd0, dbg_trc_p};
                                    DBG_STRM_STAT:  s_axi_rdata <= {31'd0, dbg_strm_flush};
                                    DBG_STRM_WPTR:  s_axi_rdata <= {19'd0, dbg_strm_wptr};
                                    DBG_STRM_RDLO:  s_axi_rdata <= dbg_strm_rd[31:0];
                                    DBG_STRM_RDHI:  s_axi_rdata <= dbg_strm_rd[63:32];
                                    DBG_TB_CFG:     s_axi_rdata <= {3'd0, dbg_tb_cfg};
                                    DBG_TB_STAT:    s_axi_rdata <= dbg_tb_stat_s;
                                    DBG_TB_CAP:     s_axi_rdata <= {7'd0, dbg_tb_cap_s};
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
