// xt_blitter.sv — 2D GPU v0.11: rect fill + line draw + block blit +
//                     scaled blit (NN + bilinear) + alpha-blend rect fill
//                     + font raster with RGBA-8888 pattern + phase +
//                     16-beat AXI bursts + GEM raster ops for block blit.
//
// Phase 2b v0.9 adds:
//   * GEM raster ops for block blit (CMD=0x03).  RASTER_OP register at
//     $D4BF selects one of 16 GEM-vintage boolean operations on source and
//     destination bytes.  Ops needing destination data (1,2,4,6,7,8,9,10,
//     11,13,14) issue a second AXI read segment after the source read,
//     combine byte-wise, and store the result in the write burst buffer.
//     Op 12 (~SRC) inverts source bytes on the fly during BL_RWAIT.
//     Ops 0/5 cause the blit to skip entirely (treated as no-op).
//   * BL_DREAD / BL_DRWAIT states for the destination-read + combine path.
//   * bl_arlen_q register to capture segment length for destination reads.
//
// Phase 2b v0.8 adds:
//   * Scaled-blit blend: CMD=0x04 + FLAGS.BLEND, CMD=0x06 + FLAGS.BLEND.
//     Bilinear path interpolates alpha from the four tap pixels (a_blend).
//     SC_SBLEND state for dest read + blend + transition to SC_NEXT.
//
// Phase 2b v0.7 adds:
//   * Bilinear scaled blit (CMD=0x06).  2×2 tap weighted interpolation of
//     a rectangular source region to a destination region.  Reads four 4-byte
//     AXI beats per destination pixel (P00, P10, P01, P11) via compact
//     sub-pixel-counter FSM, then computes the 8-bit fractional weights
//     fx8,fy8 via an 8-cycle sequential divider and blends:
//       out = (P00*w00 + P10*w10 + P01*w01 + P11*w11) >> 8
//     where w00 = (256-fx8)*(256-fy8)>>8, etc.  No alignment constraints
//     on source X (handles even and odd via single-pixel 4-byte reads).
//
// Phase 2b v0.5 adds:
//   * Alpha-blend rect fill (CMD=0x01 + FLAGS.BLEND).  Per-pixel alpha
//     blending of the pattern colour with the existing framebuffer.
//     Reads the destination RGBA via single-beat AXI read, blends using
//     the pattern's alpha channel, and accumulates the result into the
//     write burst buffer.  Opaque (α=255) skips dest read; transparent
//     (α=0) masks via wstrb=0.
//
// Phase 2b v0.4 adds:
//   * Scaled blit (CMD=0x04).  Nearest-neighbour scaling of a rectangular
//     source region (SRC_X,SRC_Y × SRC_W×SRC_H) to a destination region
//     (DST_X,DST_Y × DST_W×DST_H).  Single-pixel AXI reads from the source
//     with Bresenham-like incremental stepping; accumulates pixels into the
//     same burst-buffer write pipeline used by rect fill.
//
// Phase 2b v0.2 adds:
//   * Bresenham line draw (CMD=0x02).  DST_W/H hold signed DX/DY;
//     pattern lookup uses offset from the line start.  Single-beat
//     AXI writes per pixel (no burst across non-contiguous addresses).
//     Shares the pattern memory + alpha masking with rect fill.
//
// Phase 2b v0.1 scope (existing):
//   * Register interface taps the SALLY hwreg bus (clk_sys after CDC) and
//     latches commands at $D4B0..$D4BF (chiplet-extension page).
//   * Pattern memory: up to 1024 entries × 32-bit RGBA-8888, row-major
//     layout.  Dimensions are 2^log_pw × 2^log_ph, each ∈ [0..5]
//     (i.e., 1×1 up to 32×32).  Software loads via byte-stream writes to
//     PAT_DATA; writing PAT_LOG_W resets the load pointer.
//   * Per-pixel lookup: pattern[(cy + phase_y) & (ph-1)][(cx + phase_x) &
//     (pw-1)].  If A == 0, mask the byte strobes for that pixel (wstrb=0).
//     Any non-zero A is treated as opaque for v0.1; proper partial-alpha
//     blending lands in v0.2 (needs read-modify-write).
//   * 16-beat AXI write bursts with wstrb masking for transparent pixels
//     within a beat.  Each 64-bit beat carries 2 RGBA-8888 pixels.
//     Burst length is 1..16 depending on fill geometry; the last burst
//     in a row may be shorter.  Bursts with all pixels transparent are
//     skipped entirely (no AW issued).
//
// Architecture:
//   Pixel loop processes 2 pixels per iteration (one beat) whenever possible.
//   If dst_x is odd, the first pixel of each row is handled as a single-pixel
//   beat (high half only).  Accumulated beats fill a 16-entry burst buffer;
//   when full or end-of-row, the buffer is drained as an AXI INCR burst.
//   The BRAM pattern memory is addressed as {pat_y_eff[4:0], pat_x_eff[4:0]}
//   (10 bits, up to 1024 entries) — row-major, with width = 2^log_pw.
//
// Register map ($D4B0..$D4BF, $D4C0..$D4CF, all little-endian byte-wise):
//
//   $D4B0   DST_X_LO     W   destination X, low byte          (rect: origin;
//   $D4B1   DST_X_HI     W   destination X, high byte          line: start;
//   $D4B2   DST_Y_LO     W   destination Y, low byte          blit/scaled: dest)
//   $D4B3   DST_Y_HI     W   destination Y, high byte
//   $D4B4   DST_W_LO     W   rect: width / line: DX (signed) / blit: width / scaled: dst_width
//   $D4B5   DST_W_HI     W   (high byte)
//   $D4B6   DST_H_LO     W   rect: height / line: DY (signed) / blit: height / scaled: dst_height
//   $D4B7   DST_H_HI     W   (high byte)
//   $D4B8   PAT_PHASE_X  W   pattern phase X (bits [4:0] used)
//   $D4B9   PAT_PHASE_Y  W   pattern phase Y (bits [4:0] used)
//   $D4BA   PAT_LOG_W    W   writing ANY value sets log2(pattern_width) [4:0]
//                            (0→1, 1→2, 2→4, 3→8, 4→16, 5→32 pixels) AND
//                            resets the PAT_DATA byte-stream pointer to 0.
//   $D4BB   PAT_DATA     W   next pattern byte (auto-advances; wraps mod
//                            4096 bytes = 1024 entries).  Pattern entries
//                            are packed R,G,B,A in that byte order — same
//                            RGBA-8888 layout used everywhere.
//   $D4BC   CMD          W   write 0x01 → rect fill (qualify with FLAGS);
//                            write 0x02 → line draw (qualify with FLAGS.BLEND
//                                          for per-pixel alpha blend);
//                            write 0x03 → block blit;
//                            (continued below; see also 0x07 for SYNC.)
//                            write 0x04 → scaled blit (qualify with FLAGS);
//                            write 0x05 → font raster (always blends);
//                            write 0x06 → bilinear scaled blit;
//                            write 0x07 → SYNC barrier (no drawing; increments
//                                          SEQ_COUNTER on pop — see $D4C9/CA.
//                                          Hardware short-cut: pushing 0x07
//                                          into an empty + idle blitter bumps
//                                          the counter the same cycle, no
//                                          queue round-trip).
//                            (snapshots DST_*, PAT_*, SRC_* registers)
//   $D4BD   STATUS       R   read: bit 0 = busy (1 = queue non-empty OR FSM
//                            active, 0 = drained and idle);
//                            bit 1 = queue_full (1 = next CMD write will be
//                            dropped; poll until 0 before pushing);
//                            bit 2 = pat_blocked (sticky: a pat/font load
//                            register was written while busy — write was
//                            dropped, retry after busy goes 0; auto-clears
//                            when busy=0);
//                            bits 7:3 reserved (read 0)
//   $D4BE   PAT_LOG_H    W   log2(pattern_height) [4:0], range 0..5
//   $D4BF   RASTER_OP    W   GEM raster op [3:0] for block blit (CMD=0x03):
//                            0=ZERO, 1=SRC&DST, 2=SRC&~DST, 3=SRC(copy),
//                            4=~SRC&DST, 5=DST(no-op), 6=SRC^DST, 7=SRC|DST,
//                            8=~(SRC|DST), 9=~(SRC^DST), 10=~DST,
//                            11=~(SRC&DST), 12=~SRC, 13=~SRC|DST,
//                            14=~(SRC&~DST), 15=SRC.  Ops 3/15 = copy (default).
//                            Combines source and destination byte-wise per
//                            GEM vro_cpyfm convention.  Ops needing dest data
//                            add one AXI read segment per block-blit segment.
//   $D4C0   SRC_X_LO     W   block-blit/scaled-blit source X, low byte
//   $D4C1   SRC_X_HI     W   block-blit/scaled-blit source X, high byte
//   $D4C2   SRC_Y_LO     W   block-blit/scaled-blit source Y, low byte
//   $D4C3   SRC_Y_HI     W   block-blit/scaled-blit source Y, high byte
//   $D4C4   SRC_W_LO     W   scaled-blit source width, low byte
//   $D4C5   SRC_W_HI     W   scaled-blit source width, high byte
//   $D4C6   SRC_H_LO     W   scaled-blit source height, low byte
//   $D4C7   SRC_H_HI     W   scaled-blit source height, high byte
//   $D4C8   FLAGS        W   option flags:
//                            bit 0 (BLEND)   — alpha-blend with destination
//                            bit 1 (BILINEAR)— bilinear filtering (vs NN)
//                            bit 2 (FONT)    — font raster (alpha from font BRAM)
//                            bits 7:3 reserved
//   $D4C9   SEQ_LO       R   low byte of 16-bit SYNC sequence counter
//                            (read-only, increments on each SYNC pop, wraps
//                             at 65536).  Software fence pattern:
//                              e = SEQ_COUNTER; write CMD=0x07;
//                              wait until SEQ_COUNTER != e.
//   $D4CA   SEQ_HI       R   high byte of 16-bit SYNC sequence counter
//   $D4CB..$D4CD _reserved
//   $D4CE   FONT_DATA    W   font coverage byte (auto-advances; 4 bytes/word)
//   $D4CF   FONT_CTRL    W   writing any value resets FONT_DATA load pointer
//
// Solid-colour fill is a 1×1 pattern: write PAT_LOG_W = 0, PAT_LOG_H = 0,
// load four bytes (R, G, B, A) to PAT_DATA, CMD = 0x01.  Pattern lookup
// then resolves to entry 0 for every pixel.
//
// Address calculation (no multipliers; FB_STRIDE_B = 1 << 13 = 8192):
//   pixel_addr = FB_BASE + ((y) << 13) + ((x) << 2)
//   For rect:   y = dst_y + cy, x = dst_x + cx
//   For line:   y = line_y,     x = line_x
//   For blit:   y = src_y + cy, x = src_x + cx  (src for read)
//               y = dst_y + cy, x = dst_x + cx  (dst for write)
//   For scaled: sx = src_x + sx_step (Bresenham), sy = src_y + sy_step
//               pixel read via single-beat AXI, accumulate same as rect
//   burst_addr = {pixel_addr[31:3], 3'b000}  (8-byte-aligned for AXI)

`default_nettype none

module xt_blitter #(
    parameter logic [31:0] FB_BASE     = 32'h3000_0000,
    parameter int          FB_STRIDE_B = 8192        // power of two: 1 << 13
) (
    // ---- Clocks & reset --------------------------------------------------
    input  wire        clk,                 // = clk_sys
    // SYNCHRONOUS reset (sampled on posedge clk, not async).  rst_sys is a
    // synchronised, post-MMCM-lock reset that is held for several clk_sys
    // cycles, so a sync reset reliably clears every FF.  Using sync reset
    // (vs `posedge clk or posedge rst`) avoids async-reset removal-timing
    // hold violations on the high-fanout rst_sys net across the die.
    input  wire        rst,                 // active-high, clk domain

    // ---- Register-write tap from SALLY (post-CDC, clk_sys) ---------------
    input  wire [15:0] bus_addr,
    input  wire [7:0]  bus_data,
    input  wire        bus_we,              // 1-cycle write strobe

    // ---- Status (clk_sys) -------------------------------------------------
    output wire        busy,
    output wire        cq_full,            // command queue cannot accept another CMD
    output wire        pat_blocked,        // sticky: pat/font load was attempted while busy
                                           //         (write was dropped to preserve queue state)
    output wire [15:0] seq_counter,        // increments on each SYNC barrier completion
                                           //         (CMD=0x07); read via $D4C9/$D4CA

    // ---- AXI4 write master (clk_sys, drives DDR3 HP slave) ---------------
    output logic [31:0] m_axi_awaddr,
    output logic [7:0]  m_axi_awlen,
    output logic [2:0]  m_axi_awsize,
    output logic [1:0]  m_axi_awburst,
    output logic        m_axi_awvalid,
    input  wire         m_axi_awready,
    output logic [63:0] m_axi_wdata,
    output logic [7:0]  m_axi_wstrb,
    output logic        m_axi_wlast,
    output logic        m_axi_wvalid,
    input  wire         m_axi_wready,
    input  wire         m_axi_bvalid,
    output wire         m_axi_bready,

    // ---- AXI4 read master (clk_sys, reads from DDR3 HP slave) ------------
    output logic [31:0] m_axi_araddr,
    output logic [7:0]  m_axi_arlen,
    output logic [2:0]  m_axi_arsize,
    output logic [1:0]  m_axi_arburst,
    output logic        m_axi_arvalid,
    input  wire         m_axi_arready,
    input  wire [63:0]  m_axi_rdata,
    input  wire         m_axi_rvalid,
    input  wire         m_axi_rlast,
    output logic        m_axi_rready
);

    // ====================================================================
    // Register decode — covers $D4B0..$D4BF and $D4C0..$D4CF
    // ====================================================================
    // $D4Bx: bus_addr[7:4] = 4'b1011
    // $D4Cx: bus_addr[7:4] = 4'b1100
    // reg_addr = {~bus_addr[5], bus_addr[3:0]} → 0-15 = $D4Bx, 16-31 = $D4Cx
    wire        is_d4bx = (bus_addr[7:4] == 4'b1011);
    wire        is_d4cx = (bus_addr[7:4] == 4'b1100);
    wire reg_we = bus_we
                && (bus_addr[15:8] == 8'hD4)
                && (is_d4bx || is_d4cx);
    wire [4:0] reg_addr = {~bus_addr[5], bus_addr[3:0]};

    // ---- Parameter registers (all written by SALLY / PS GP0) ------------
    // These hold the most-recent values written by software.  A CMD write
    // ($D4BC) snapshots them (plus the CMD code and FLAGS) into the command
    // FIFO; S_IDLE pops the oldest snapshot and copies it into the *_q
    // working registers before firing the state machine.  Software can
    // therefore reprogram these between CMD writes without affecting
    // already-queued operations.
    logic [15:0] dst_x_reg, dst_y_reg, dst_w_reg, dst_h_reg;
    logic [15:0] src_x_reg, src_y_reg;
    logic [15:0] src_w_reg, src_h_reg;      // source dimensions for scaled blit
    logic [4:0]  pat_phase_x_reg, pat_phase_y_reg;
    logic [4:0]  log_pw_reg, log_ph_reg;
    logic [7:0]  flags_reg;              // FLAGS register at $D4C8
    logic [3:0]  raster_op_reg;          // GEM raster op for block blit ($D4BF)

    // ---- Pattern memory + byte-stream load --------------------------------
    // Up to 1024 entries × 32-bit RGBA-8888 = 32 Kb (two BRAM18s or one
    // RAMB36).  Row-major, 2^log_pw entries per row.  Address = {pat_y_eff,
    // pat_x_eff} — 10-bit index.
    //
    // Byte stream order: R (byte 0), G (byte 1), B (byte 2), A (byte 3).
    // The 32-bit word is packed big-endian so the BRAM output pat_pixel_q
    // has R at bits [31:24], G at [23:16], B at [15:8], A at [7:0].
    // This matches fb_scanout's expected framebuffer layout:
    //   rd_pixel[31:24]=R, [23:16]=G, [15:8]=B, [7:0]=A.
    (* ram_style = "block" *)
    logic [31:0] pat_mem [0:1023];

    // Load pointer: byte address 0..4095.  Top 10 bits = entry index
    // (0..1023), bottom 2 bits = byte-within-entry (0=R, 1=G, 2=B, 3=A).
    logic [11:0] pat_load_ptr;

    // Shift-register accumulator for the in-flight entry.  When byte 3 (A)
    // arrives, the full 32-bit RGBA word commits to pat_mem.
    logic [23:0] pat_load_accum;
    logic [23:0] pat_load_accum_q;   // pipeline stage for BRAM hold timing

    // ---- Font coverage memory (512 × 32-bit = 16 Kb, one BRAM18) -----------
    // Stores packed AAAA coverage bytes: 4 pixels per word.
    // Address = {cy[4:0], cx[5:2]}, byte select = cx[1:0].
    (* ram_style = "block" *)
    logic [31:0] font_mem [0:511];

    // Font byte-stream load state.  Each 4-byte group packs into a word and
    // commits to font_mem.  FONT_CTRL ($D4CF) resets the pointer to 0.
    logic [10:0] font_load_ptr;        // byte offset 0..2047 (11 bits)
    logic [31:0] font_load_accum;      // word under construction
    logic [1:0]  font_load_byte_idx;   // next byte position within word (0-3)

    // ---- Register write decode --------------------------------------------
    always_ff @(posedge clk) begin  // sync reset — see note at `rst` port
        if (rst) begin
            dst_x_reg       <= 16'd0;
            dst_y_reg       <= 16'd0;
            dst_w_reg       <= 16'd0;
            dst_h_reg       <= 16'd0;
            pat_phase_x_reg <= 5'd0;
            pat_phase_y_reg <= 5'd0;
            log_pw_reg      <= 5'd0;
            log_ph_reg      <= 5'd0;
            raster_op_reg   <= 4'd3;    // default: SRC copy
            flags_reg       <= 8'd0;
            src_x_reg       <= 16'd0;
            src_y_reg       <= 16'd0;
            src_w_reg       <= 16'd0;
            src_h_reg       <= 16'd0;
            pat_load_ptr    <= 12'd0;
            pat_load_accum  <= 24'd0;
            font_load_ptr       <= 11'd0;
            font_load_accum     <= 32'd0;
            font_load_byte_idx  <= 2'd0;
        end else begin
            if (reg_we) begin
                unique case (reg_addr)
                    5'h00: dst_x_reg[7:0]   <= bus_data;
                    5'h01: dst_x_reg[15:8]  <= bus_data;
                    5'h02: dst_y_reg[7:0]   <= bus_data;
                    5'h03: dst_y_reg[15:8]  <= bus_data;
                    5'h04: dst_w_reg[7:0]   <= bus_data;
                    5'h05: dst_w_reg[15:8]  <= bus_data;
                    5'h06: dst_h_reg[7:0]   <= bus_data;
                    5'h07: dst_h_reg[15:8]  <= bus_data;
                    5'h08: pat_phase_x_reg  <= bus_data[4:0];
                    5'h09: pat_phase_y_reg  <= bus_data[4:0];
                    5'h0A: begin
                        // PAT_LOG_W: log_pw_reg is snapshotted per CMD so the
                        // write is always allowed; the byte-stream pointer
                        // reset is gated on !busy so we don't disturb the
                        // load state for queued commands.
                        log_pw_reg <= bus_data[4:0];
                        if (!busy) begin
                            pat_load_ptr   <= 12'd0;
                            pat_load_accum <= 24'd0;
                        end
                    end
                    5'h0B: if (!busy) begin
                        // Byte-stream pattern load. Bytes 0..2 accumulate;
                        // byte 3 commits the entry to BRAM and advances
                        // the entry pointer.  Gated on !busy so queued
                        // commands keep a consistent pat_mem.
                        case (pat_load_ptr[1:0])
                            2'd0: pat_load_accum[7:0]   <= bus_data;          // R
                            2'd1: pat_load_accum[15:8]  <= bus_data;          // G
                            2'd2: pat_load_accum[23:16] <= bus_data;          // B
                            2'd3: /* A — see below */;
                            default: ;
                        endcase
                        pat_load_ptr <= pat_load_ptr + 12'd1;
                    end
                    5'h0C: begin
                        // CMD write — snapshot pushed into the command FIFO
                        // below (outside this always_ff).  Mode flags are
                        // derived from the snapshot's CMD code + FLAGS byte
                        // when the entry is popped in S_IDLE.
                        //   0x01 = rect fill        (+FLAGS.BLEND → alpha blend)
                        //   0x02 = line draw        (+FLAGS.BLEND → alpha blend)
                        //   0x03 = block blit       (uses RASTER_OP)
                        //   0x04 = scaled blit      (FLAGS.BILINEAR / FLAGS.BLEND)
                        //   0x05 = font raster      (always blends, uses font BRAM)
                        //   0x06 = bilinear scaled blit (legacy alias for 0x04+BILINEAR)
                    end
                    5'h0E: log_ph_reg  <= bus_data[4:0];   // PAT_LOG_H
                    // $D4BF — RASTER_OP (GEM raster op for block blit)
                    5'h0F: raster_op_reg <= bus_data[3:0];
                    // $D4C0-$D4C3 — block-blit/scaled-blit source coordinates
                    5'h10: src_x_reg[7:0]  <= bus_data;
                    5'h11: src_x_reg[15:8] <= bus_data;
                    5'h12: src_y_reg[7:0]  <= bus_data;
                    5'h13: src_y_reg[15:8] <= bus_data;
                    // $D4C4-$D4C7 — scaled-blit source dimensions
                    5'h14: src_w_reg[7:0]  <= bus_data;
                    5'h15: src_w_reg[15:8] <= bus_data;
                    5'h16: src_h_reg[7:0]  <= bus_data;
                    5'h17: src_h_reg[15:8] <= bus_data;
                    // $D4C8 — FLAGS (option byte)
                    5'h18: flags_reg <= bus_data;
                    // $D4CE — FONT_DATA byte-stream load (gated on !busy
                    // so queued commands keep a consistent font_mem)
                    5'h1E: if (!busy) begin
                        case (font_load_byte_idx)
                            2'd0: font_load_accum[7:0]   <= bus_data;
                            2'd1: font_load_accum[15:8]  <= bus_data;
                            2'd2: font_load_accum[23:16] <= bus_data;
                            2'd3: /* — committed below */;
                            default: ;
                        endcase
                        font_load_byte_idx <= font_load_byte_idx + 2'd1;
                        font_load_ptr <= font_load_ptr + 11'd1;
                    end
                    // $D4CF — FONT_CTRL (writing any value resets load pointer)
                    5'h1F: if (!busy) begin
                        font_load_ptr      <= 11'd0;
                        font_load_accum    <= 32'd0;
                        font_load_byte_idx <= 2'd0;
                    end
                    default: /* reserved */;
                endcase
            end
        end
    end
    // LUT2 hold-delay insertion for BRAM DI paths.
    // At clk_sys=150 MHz, direct FF→BRAM DI paths with 0 logic levels suffer
    // hold violations (WHS=-0.197 ns) because clock skew between SLICEs and
    // BRAMs within pb_blitter's two clock regions reaches 0.309 ns — more
    // than the 0.267 ns data delay + 0.155 ns BRAM hold requirement.
    // phys_opt cannot fix 0-logic-level paths (no logic to replicate/delay).
    //
    // We insert LUT2 AND buffers on every write-data bit to pat_mem and
    // font_mem.  Each LUT2 is configured as O = I0 & I1 where I1 is the
    // respective write-enable signal (pat_we / font_we).  This adds ~0.15 ns
    // of logic delay to the data path, sufficient to meet hold.  When the
    // write enable is deasserted the DI value is don't-care (BRAM captures
    // data only when WE is active), so the AND is functionally transparent.
    //
    // Critically, a LUT2 with a non-constant second input performs a real
    // logic function — unlike a LUT1 pass-through (INIT=2'b10), which
    // Vivado's opt_design removes regardless of DONT_TOUCH per UG901.
    //
    // pat_mem write data — packed as {R, G, B, A} in fb_scanout order.
    wire [31:0] pat_mem_din_pre = {pat_load_accum_q[7:0],    // R → [31:24]
                                    pat_load_accum_q[15:8],   // G → [23:16]
                                    pat_load_accum_q[23:16],  // B → [15:8]
                                    bus_data};                // A → [7:0]

    // Pattern memory write enable — gated on !busy so pat contents stay frozen
    // for in-flight commands (declared before the generate block uses it).
    wire pat_we = reg_we && (reg_addr == 5'h0B) && (pat_load_ptr[1:0] == 2'd3) && !busy;

    wire [31:0] pat_mem_din;
    generate
        genvar pb;
        for (pb = 0; pb < 32; pb++) begin : pat_di_buf
`ifdef XILINX
            (* DONT_TOUCH = "true" *)
            LUT2 #(.INIT(4'h8)) u_buf (.I0(pat_mem_din_pre[pb]), .I1(pat_we), .O(pat_mem_din[pb]));
`else
            assign pat_mem_din[pb] = pat_mem_din_pre[pb] & pat_we;
`endif
        end
    endgenerate

    // Pattern memory write port — fires when byte 3 (A) of an entry arrives.
    // Gated on !busy: if software writes a pat byte while the blitter is busy,
    // the byte-stream pointer logic (above) silently drops the write.  pat_we
    // mirrors that gate so the BRAM contents stay frozen until the queue
    // drains, preserving pat consistency for in-flight commands.
    wire [9:0] pat_entry_idx_wr = pat_load_ptr[11:2];

    always_ff @(posedge clk) pat_load_accum_q <= pat_load_accum;

    always_ff @(posedge clk) begin
        if (pat_we)
            pat_mem[pat_entry_idx_wr] <= pat_mem_din;
    end

    // ---- Font memory write port — fires when byte 3 (4th coverage byte) ----
    // Same LUT2 hold-delay treatment as pat_mem above.
    wire [31:0] font_mem_din_pre = {bus_data,               // byte3 → [31:24]
                                     font_load_accum[23:16],  // byte2 → [23:16]
                                     font_load_accum[15:8],   // byte1 → [15:8]
                                     font_load_accum[7:0]};   // byte0 → [7:0]

    // Font memory write enable — declared before the generate block uses it.
    wire font_we = reg_we && (reg_addr == 5'h1E) && (font_load_byte_idx == 2'd3) && !busy;

    wire [31:0] font_mem_din;
    generate
        genvar pb2;
        for (pb2 = 0; pb2 < 32; pb2++) begin : font_di_buf
`ifdef XILINX
            (* DONT_TOUCH = "true" *)
            LUT2 #(.INIT(4'h8)) u_buf (.I0(font_mem_din_pre[pb2]), .I1(font_we), .O(font_mem_din[pb2]));
`else
            assign font_mem_din[pb2] = font_mem_din_pre[pb2] & font_we;
`endif
        end
    endgenerate

    wire [8:0] font_entry_idx_wr = font_load_ptr[10:2];   // byte ptr → word index

    always_ff @(posedge clk) begin
        if (font_we)
            font_mem[font_entry_idx_wr] <= font_mem_din;
    end

    // ====================================================================
    // pat_blocked — sticky diagnostic flag
    // ====================================================================
    // Asserts the moment software writes any pat/font load register
    // ($D4BA pointer-reset, $D4BB byte, $D4CE font byte, $D4CF font reset)
    // while the blitter is busy.  All such writes are silently dropped by
    // the gates above, but pat_blocked tells software that it did so — so
    // SW knows it needs to drain the queue and retry the load.  Clears
    // automatically when busy goes 0 (the safe state for pat/font writes).
    wire pat_load_attempt   = reg_we && busy && (reg_addr == 5'h0B);
    wire pat_logw_attempt   = reg_we && busy && (reg_addr == 5'h0A);
    wire font_load_attempt  = reg_we && busy && (reg_addr == 5'h1E);
    wire font_ctrl_attempt  = reg_we && busy && (reg_addr == 5'h1F);
    // Note: pat_logw_attempt only flags if the side-effect (pointer reset)
    // would have applied — software writing $D4BA just to change log_pw_reg
    // for a future CMD is legitimate and not a "blocked" event per se, but
    // the pointer reset IS dropped, so we still raise the flag to keep the
    // SW model simple: any pat/font register touch while busy = flagged.
    logic pat_blocked_q;
    always_ff @(posedge clk) begin  // sync reset — see note at `rst` port
        if (rst)
            pat_blocked_q <= 1'b0;
        else if (pat_load_attempt || pat_logw_attempt
              || font_load_attempt || font_ctrl_attempt)
            pat_blocked_q <= 1'b1;
        else if (!busy)
            pat_blocked_q <= 1'b0;
    end
    assign pat_blocked = pat_blocked_q;

    // ====================================================================
    // Command queue — FIFO of register snapshots (BRAM-backed, 16-deep)
    // ====================================================================
    // Each CMD write ($D4BC) snapshots the current *_reg values, CMD code,
    // FLAGS, and RASTER_OP into a 192-bit entry and pushes it into the
    // FIFO.  S_IDLE pops the oldest entry, re-derives mode flags from the
    // snapshot's CMD + FLAGS, copies the fields into the *_q working
    // registers, and dispatches to the first state.
    //
    // Software can submit up to Q_DEPTH operations back-to-back without
    // polling STATUS between each one; the PS just programs the registers,
    // writes CMD, and moves on.  When the queue is full, STATUS.queue_full
    // (bit 1 at $D4BD) asserts and further CMD writes are silently dropped.
    //
    // Pattern memory and font memory are NOT snapshotted per entry.  The
    // byte-stream loads for pat_mem and font_mem are gated on `!busy` (see
    // further down) so all queued commands observe a consistent pat/font
    // state — software must drain the queue before reloading patterns.
    //
    // Storage: 1024 × 192 bits = 196608 bits, forced to BRAM via
    // (* ram_style = "block" *).  Vivado typically maps this as
    // 6× RAMB36E1 (3 columns of 72-bit width × 2 banks of 512 depth).
    // Read latency is 1 cycle, hidden by a small prefetch FSM:
    // cq_front_q always reflects the oldest entry when cq_front_valid = 1,
    // with a write-first bypass for the push-to-empty edge case so the
    // first command after an idle period dispatches without an extra stall.
    localparam int Q_DEPTH = 1024;
    localparam int Q_AW    = 10;            // $clog2(Q_DEPTH)

    (* ram_style = "block" *)
    logic [191:0]    cmd_fifo [0:Q_DEPTH-1];
    logic [Q_AW-1:0] cq_head;               // next write slot
    logic [Q_AW-1:0] cq_tail;               // next read slot
    logic [Q_AW:0]   cq_count;              // occupancy, 0..Q_DEPTH

    wire cq_empty_w = (cq_count == '0);
    assign cq_full  = (cq_count == Q_DEPTH);

    // Snapshot packed from current *_reg values at the moment of CMD write.
    // Layout (MSB first):
    //   [191:176] dst_x   [175:160] dst_y   [159:144] dst_w   [143:128] dst_h
    //   [127:112] src_x   [111:96]  src_y   [95:80]   src_w   [79:64]   src_h
    //   [63:56]  pat_phase_x  [55:48] pat_phase_y
    //   [47:40]  log_pw       [39:32] log_ph
    //   [31:24]  cmd          [23:16] flags
    //   [15:8]   raster_op    [7:0]   reserved
    wire [191:0] cmd_snapshot_in = {
        dst_x_reg, dst_y_reg, dst_w_reg, dst_h_reg,
        src_x_reg, src_y_reg, src_w_reg, src_h_reg,
        {3'd0, pat_phase_x_reg}, {3'd0, pat_phase_y_reg},
        {3'd0, log_pw_reg},      {3'd0, log_ph_reg},
        bus_data, flags_reg,
        {4'd0, raster_op_reg}, 8'd0
    };

    wire valid_cmd = (bus_data >= 8'h01) && (bus_data <= 8'h07);
    // SYNC short-cut: CMD=0x07 written while !busy (= queue empty AND FSM
    // idle, by the definition of busy) can bypass the queue entirely and
    // increment seq_counter_q this cycle, saving the queue push + pop
    // round-trip (~3 cycles).  Software doing "fence-after-drain" gets
    // sub-100 ns sync latency.
    wire sync_direct = reg_we && (reg_addr == 5'h0C) && (bus_data == 8'h07)
                       && !busy;
    wire cq_push     = reg_we && (reg_addr == 5'h0C) && valid_cmd
                       && !cq_full && !sync_direct;
    wire cq_pop;   // driven below (forward reference; declared as wire so it
                   // is visible to the FIFO management always_ff)

    // BRAM-friendly storage pattern: bare write + registered read with NO
    // conditional logic on the read port.  Vivado infers a BRAM at this
    // size only if the read port is "always read mem[ra] into rd_reg".
    // The push-to-empty bypass lives in a separate register below, mux'd
    // into cq_front_q combinationally.
    logic [191:0] cq_front_bram_q;     // registered output of the BRAM

    always_ff @(posedge clk) begin
        if (cq_push) cmd_fifo[cq_head] <= cmd_snapshot_in;
        cq_front_bram_q <= cmd_fifo[cq_tail];
    end

    // Bypass register — holds the snapshot from the most recent push-to-
    // empty, since the BRAM read collides with that write and returns
    // stale data the next cycle (read-first mode).  Cleared on the
    // first pop that consumes it.
    logic         cq_bypass_valid_q;
    logic [191:0] cq_bypass_data_q;
    always_ff @(posedge clk) begin  // sync reset — see note at `rst` port
        if (rst) begin
            cq_bypass_valid_q <= 1'b0;
            cq_bypass_data_q  <= '0;
        end else if (cq_push && cq_empty_w) begin
            cq_bypass_valid_q <= 1'b1;
            cq_bypass_data_q  <= cmd_snapshot_in;
        end else if (cq_pop) begin
            cq_bypass_valid_q <= 1'b0;
        end
    end

    // cq_front_q: bypass takes priority, otherwise the BRAM read.
    wire [191:0] cq_front_q = cq_bypass_valid_q ? cq_bypass_data_q
                                                : cq_front_bram_q;

    // cq_front_valid tracks whether cq_front_q reflects the entry at
    // cq_tail.  Goes low on cq_pop (tail advances → BRAM needs to
    // refetch), goes high one cycle later, OR same cycle on push-to-
    // empty (the bypass register carries the data immediately).
    logic         cq_front_valid;

    // cq_front_valid: high iff cq_front_q reflects the entry at cq_tail.
    // Goes low on cq_pop (cq_tail advances → BRAM needs to refetch from
    // the new slot).  Comes back high one cycle later in steady state,
    // OR the same cycle on push-to-empty (the bypass register carries
    // the snapshot directly into cq_front_q without waiting for BRAM).
    always_ff @(posedge clk) begin  // sync reset — see note at `rst` port
        if (rst)
            cq_front_valid <= 1'b0;
        else if (cq_pop)
            cq_front_valid <= 1'b0;
        else if (cq_push && cq_empty_w)
            cq_front_valid <= 1'b1;
        else if (!cq_empty_w)
            cq_front_valid <= 1'b1;
    end

    // Unpacked fields for use in S_IDLE (read from the registered output).
    wire [15:0] q_dst_x      = cq_front_q[191:176];
    wire [15:0] q_dst_y      = cq_front_q[175:160];
    wire [15:0] q_dst_w      = cq_front_q[159:144];
    wire [15:0] q_dst_h      = cq_front_q[143:128];
    wire [15:0] q_src_x      = cq_front_q[127:112];
    wire [15:0] q_src_y      = cq_front_q[111:96];
    wire [15:0] q_src_w      = cq_front_q[95:80];
    wire [15:0] q_src_h      = cq_front_q[79:64];
    wire [4:0]  q_phase_x    = cq_front_q[60:56];
    wire [4:0]  q_phase_y    = cq_front_q[52:48];
    wire [4:0]  q_log_pw     = cq_front_q[44:40];
    wire [4:0]  q_log_ph     = cq_front_q[36:32];
    wire [7:0]  q_cmd        = cq_front_q[31:24];
    wire [7:0]  q_flags      = cq_front_q[23:16];
    wire [3:0]  q_raster_op  = cq_front_q[11:8];

    // Mode flags re-derived from the popped snapshot.  Same logic as the
    // pre-queue CMD-write decoder used to produce, now evaluated at pop
    // time instead.
    wire q_line_mode  = (q_cmd == 8'h02);
    wire q_blk_mode   = (q_cmd == 8'h03);
    wire q_sc_mode    = (q_cmd == 8'h04) && !q_flags[1];
    wire q_bilin_mode = ((q_cmd == 8'h04) && q_flags[1]) || (q_cmd == 8'h06);
    wire q_sc_blend   = ((q_cmd == 8'h04) || (q_cmd == 8'h06)) && q_flags[0];
    wire q_blend_mode = ((q_cmd == 8'h01) || (q_cmd == 8'h02)) && q_flags[0];
    wire q_font_mode  = (q_cmd == 8'h05);
    wire q_sync_mode  = (q_cmd == 8'h07);

    // FIFO pointer/count management
    always_ff @(posedge clk) begin  // sync reset — see note at `rst` port
        if (rst) begin
            cq_head  <= '0;
            cq_tail  <= '0;
            cq_count <= '0;
        end else begin
            if (cq_push) cq_head <= cq_head + 1'd1;
            if (cq_pop)  cq_tail <= cq_tail + 1'd1;
            case ({cq_push, cq_pop})
                2'b10:   cq_count <= cq_count + 1'd1;
                2'b01:   cq_count <= cq_count - 1'd1;
                default: ;   // 2'b00 (no change) or 2'b11 (push and pop cancel)
            endcase
        end
    end

    // ====================================================================
    // Sync sequence counter (16-bit, wraps at 65536)
    // ====================================================================
    // Incremented every time a SYNC (CMD=0x07) entry is popped from the
    // queue, OR via the sync_direct short-cut when SW pushes SYNC into an
    // empty + idle queue.  Software uses this for fence semantics: read
    // SEQ_COUNTER, push SYNC, poll SEQ_COUNTER until it advances past the
    // recorded value — at which point all preceding queued operations
    // are known to have completed.  16 bits gives wrap=65536, well above
    // the 1024 queue depth so multiple in-flight syncs are unambiguous.
    logic [15:0] seq_counter_q;
    wire seq_inc = sync_direct || (cq_pop && q_sync_mode);

    always_ff @(posedge clk) begin  // sync reset — see note at `rst` port
        if (rst)             seq_counter_q <= 16'd0;
        else if (seq_inc)    seq_counter_q <= seq_counter_q + 16'd1;
    end
    assign seq_counter = seq_counter_q;

    // ====================================================================
    // Line-draw state registers
    // ====================================================================
    // Bresenham parameters computed in L_INIT, used during line walk.
    logic [15:0] line_x, line_y;         // current pixel coordinate on line
    logic [15:0] line_dx, line_dy;       // |DX|, |DY| (positive)
    logic        line_sx, line_sy;        // step direction: 0=-1, 1=+1
    logic signed [16:0] line_err;        // Bresenham error term (signed 17-bit)
    logic [15:0] line_x_end, line_y_end; // end point (dst + dx, dst + dy)
    logic [31:0] line_pix_addr;          // 8-byte-aligned pixel address for AW
    // L_STEP registers bstep_y/bstep_x here; L_STEP2 applies them.  Splits
    // the 9-CARRY4 Bresenham chain (be2→bstep→berr_delta→line_err→cx) into
    // two halves so each fits in 6.667 ns at clk_sys=150 MHz.
    logic [1:0]  line_step_q;            // {bstep_y, bstep_x} registered

    // Bresenham decision variables (combinational)
    wire signed [16:0] be2       = line_err <<< 1;
    wire        bstep_x = (be2 > -17'(line_dy));
    wire        bstep_y = (be2 <  17'(line_dx));
    // Combined delta for the error term, using the registered step flags
    // so L_STEP2 doesn't recompute the be2→bstep compare chain — keeps
    // each Bresenham critical-path half within one cycle at 150 MHz.
    wire signed [16:0] berr_delta_q = (line_step_q[0] ? -17'(line_dy) : 17'd0)
                                    + (line_step_q[1] ?  17'(line_dx) : 17'd0);

    // ====================================================================
    // Burst buffer — 16 beats of {64-bit data, 8-bit wstrb}
    // ====================================================================
    // Each beat packs two RGBA-8888 pixels: {odd_pixel, even_pixel}.
    // Even-position pixels occupy wdata[31:0] (byte lanes 3:0);
    // odd-position pixels occupy wdata[63:32] (byte lanes 7:4).
    logic [63:0] burst_data [0:15];
    logic [7:0]  burst_strb [0:15];
    logic [4:0]  burst_len;            // 0..16 beats accumulated so far
    logic [4:0]  burst_flush_idx;      // beat index during flush (0..burst_len-1)

    // Partial-beat accumulator: holds the even pixel while waiting for its
    // odd partner.  When beat_lo_filled=1 and the next pixel is odd, the
    // two are packed and committed.  If the row ends with beat_lo_filled=1,
    // the orphan pixel is committed as a half-beat (only byte lanes 3:0).
    logic [31:0] beat_lo;              // even-pixel value (RGBA-8888)
    logic [3:0]  beat_strb_lo;         // wstrb for byte lanes 3:0
    logic        beat_lo_filled;       // 1 = low half has valid data waiting

    // Track whether the current burst contains any non-transparent pixel.
    // Set when a beat with non-zero wstrb is committed.  Cleared at flush.
    logic        burst_nonzero_mask;

    // Temp variable for S_ACCUM_W: set when the current pixel commits a beat
    // (i.e., completes a 2-pixel beat or creates a single-pixel orphan).
    logic        accum_commits_beat;

    // Pipeline registers for the S_ACCUM_W → S_ACCUM_W2 split.  S_ACCUM_W
    // computes pixel data and registers intermediate results; S_ACCUM_W2 uses
    // these registered values for the state-transition decision, breaking the
    // long combinational path from pat_pixel_q → state decode → ARVALID →
    // burst_len CE.
    logic        accum_commits_q;          // registered accum_commits_beat
    logic [15:0] cx_q;                     // cx captured before increment
    logic        cx_ge_dst_w_q;            // (cx + 1 >= dst_w_q) pipelined, breaks CARRY4 chain
    logic [7:0]  ft_al_q;                  // ft_al captured after multiplier
    logic        strb_nonzero_q;           // committed beat had non-zero wstrb

    // ---- Latched parameter registers (snapshotted at S_IDLE → S_SEG) --------
    logic [15:0] dst_x_q, dst_y_q, dst_w_q, dst_h_q;
    logic [4:0]  phase_x_q, phase_y_q;
    logic [4:0]  log_pw_q, log_ph_q;
    logic        line_mode_q;              // derived from popped CMD at S_IDLE (q_line_mode)
    logic        blk_mode_q;               // derived from popped CMD at S_IDLE (q_blk_mode)
    logic        sc_mode_q;                // derived from popped CMD + FLAGS at S_IDLE
    logic        blend_mode_q;             // derived from popped CMD + FLAGS at S_IDLE
    logic        bilin_mode_q;             // derived from popped CMD + FLAGS at S_IDLE
    logic        font_mode_q;              // derived from popped CMD at S_IDLE
    logic        sc_blend_q;               // derived from popped CMD + FLAGS at S_IDLE
    logic [3:0]  raster_op_q;             // captured from raster_op_reg at S_IDLE
    // bl_need_dst: true when the raster op needs to read destination data
    // (ops 1,2,4,6,7,8,9,10,11,13,14 combine src+dst).  Ops 0/3/5/12/15 use
    // source-only transforms or skip entirely.  Only meaningful when blk_mode_q.
    wire         bl_need_dst = blk_mode_q
                    && ((raster_op_q == 4'd1) || (raster_op_q == 4'd2)
                    || (raster_op_q == 4'd4) || (raster_op_q == 4'd6)
                    || (raster_op_q == 4'd7) || (raster_op_q == 4'd8)
                    || (raster_op_q == 4'd9) || (raster_op_q == 4'd10)
                    || (raster_op_q == 4'd11) || (raster_op_q == 4'd13)
                    || (raster_op_q == 4'd14));
    logic [7:0]  bl_arlen_q;              // captured ARLEN from BL_READ for dest read
    logic [15:0] src_x_q, src_y_q;         // latched source coordinates for block blit
    logic [15:0] src_w_q, src_h_q;         // latched source dimensions for scaled blit

    // ---- Sweep counters (cx across columns, cy across rows) ---------------
    logic [15:0] cx, cy;

    // ====================================================================
    // Segment address snapshot
    // ====================================================================
    // The burst AW address is computed from the pixel coordinates of the
    // first pixel in the burst.  We capture (seg_cx, seg_cy) at segment
    // start because cx/cy advance during accumulation.
    logic [15:0] seg_cx;
    logic [15:0] seg_cy;
    wire [15:0]  seg_pix_x = dst_x_q + seg_cx;
    wire [15:0]  seg_pix_y = dst_y_q + seg_cy;

    // Full 32-bit address of the first pixel in this segment.
    wire [31:0]  seg_raw_addr = FB_BASE
                              + (32'(seg_pix_y) << 13)
                              + (32'(seg_pix_x) << 2);

    // Source address for block-blit read bursts (uses src_x_q/src_y_q).
    wire [31:0]  bl_src_raw_addr = FB_BASE
                                  + (32'(src_y_q + seg_cy) << 13)
                                  + (32'(src_x_q + seg_cx) << 2);

    // ====================================================================
    // Scaled-blit state
    // ====================================================================
    // Bresenham-like stepping for nearest-neighbour source coordinate:
    //   sx_accum accumulates src_w_q per destination pixel; when it reaches
    //   dst_w_q, sx_step increments and sx_accum wraps by subtracting dst_w_q.
    // Same approach for sy (per destination row).
    logic [15:0] sx_step_q;             // current source X offset (sx - src_x_q)
    logic [15:0] sy_cur_q;              // current source Y for this row
    logic [15:0] sx_accum_q;            // Bresenham X accumulator
    logic [15:0] sy_accum_q;            // Bresenham Y accumulator (per row)
    logic        sc_pixel_valid_q;      // cached pixel is valid
    logic [31:0] sc_pixel_q;            // cached source pixel (RGBA-8888)
    logic [31:0] sc_pixel_addr_q;       // address of cached source pixel
    logic [31:0] sc_raddr_q;            // address of current AXI read request
    logic        sc_need_flush_q;       // flush needed after sx advance completes

    // ====================================================================
    // Alpha-blend state
    // ====================================================================
    logic [31:0] bl_src_pixel_q;        // source RGBA held during destination AXI read
    logic        bl_px_low_q;           // px_in_low_half latched at S_ACCUM_W for BL_RACC

    // ====================================================================
    // Bilinear scaled-blit state
    // ====================================================================
    // Four tap pixels from the 2×2 source neighbourhood.
    logic [31:0] p00_q, p10_q;          // top row: (sx_int, sy_int) and (sx_int+1, sy_int)
    logic [31:0] p01_q, p11_q;          // bottom row: (sx_int, sy_int+1) and (sx_int+1, sy_int+1)
    // Fractional weights (8-bit, 0..255)
    logic [7:0]  bl_fx8_q;              // fractional X from sx_accum_q / dst_w_q
    logic [7:0]  bl_fy8_q;              // fractional Y from sy_accum_q / dst_h_q
    // Sequential divider state
    logic [23:0] bl_rem_x_q;            // 24-bit remainder for fx8 divider (shift register)
    logic [23:0] bl_rem_y_q;            // 24-bit remainder for fy8 divider
    logic [3:0]  bl_div_cycle_q;        // 0..7 divider cycle counter
    logic [1:0]  bl_sub_q;              // 0=P00,1=P10,2=P01,3=P11 (read sub-pixel index)

    // Pipeline register for bilinear blend output (1-cycle delay to break
    // the 20-level combinatorial path from bl_fx8_q → burst_data CE).
    // The full split is: SC_BL_ACC computes weights → bl_w??_q,
    // then SC_BL_BLEND computes the weighted blend → bl_pixel_q,
    // then SC_BL_ACC2 writes into the burst buffer.
    logic [8:0]  bl_w00_q, bl_w10_q, bl_w01_q, bl_w11_q;
    logic [31:0] bl_pixel_q;

    // Pipeline register for alpha-blend fill (BL_RACC / SC_SBLEND).
    // Splits the critical path from bl_src_pixel_q → blend multipliers →
    // CARRY4s → burst_data into two cycles: cycle 1 computes and registers
    // bl_blend_q, cycle 2 uses bl_blend_q for the burst-buffer write.
    logic [31:0] bl_blend_q;
    logic        bl_blend_valid_q;

    // Pipeline register for destination pixel in alpha-blend (BL_RACC / SC_SBLEND).
    // Latching m_axi_rdata into bl_dst_q lets us split the blend multiply-accumulate
    // across two cycles: cycle 1 registers dst, cycle 2 computes the weighted sum.
    logic [31:0] bl_dst_q;

    // Pipeline registers for alpha-blend multiply-accumulate intermediate products.
    // Each holds 4 channels × 16-bit product (src*sa or dst*inv_a) computed in
    // BL_RACC_BLEND / SC_SBLEND_BLEND.  The combine step in BL_RACC_BLEND2 /
    // SC_SBLEND_BLEND2 sums the products and shifts to produce bl_blend_q.
    logic [63:0] bl_src_prod_q;   // {R_prod, G_prod, B_prod, A_unused}  each 16-bit
    logic [63:0] bl_dst_prod_q;   // {R_prod, G_prod, B_prod, A_unused}

    // ====================================================================
    // Line-draw blend support
    // ====================================================================
    // bl_read_high_half_q: registered at AR-issue time for blend reads, used
    // in BL_RACC / SC_SBLEND to select the correct half of the 8-byte AXI3
    // read beat.  araddr[2]=1 means the 4-byte pixel sits on rdata[63:32];
    // araddr[2]=0 means rdata[31:0].  Without this, blend reads of odd-X
    // destinations would latch the wrong pixel.
    logic        bl_read_high_half_q;
    // line_use_blend_q: set in BL_RACC_BLEND2 when returning from the line-
    // draw blend detour.  L_PLOT consumes it to issue the AXI write with
    // bl_blend_q instead of pat_pixel_q (and to skip the alpha re-check that
    // would otherwise route back into the blend pipeline forever).
    logic        line_use_blend_q;

    // ====================================================================
    // DMA fill mode — solid-colour rect fill without per-pixel FSM
    //
    // When the pattern is 1×1 (solid colour, no blend/font/raster-op), the
    // blitter bypasses the pixel-loop states and firehoses AXI write bursts
    // directly.  This drops a full-screen clear from ~54 ms to ~12 ms at
    // 100 MHz clk_sys — well within one 60 Hz frame.
    //
    // Registers used (only valid when dma_mode_q is asserted):
    // ====================================================================
    logic        dma_mode_q;              // 1 = DMA fill active
    logic [31:0] dma_next_q;              // byte address of next burst (8-byte aligned)
    logic [15:0] dma_rem_rows_q;          // rows remaining
    logic [15:0] dma_rem_row_px_q;        // pixels remaining in current row (excl. head pad)
    logic [5:0]  dma_burst_px_q;          // remaining useful pixels in current burst (0..32)
    logic [4:0]  dma_burst_beats_q;       // beats in current burst (1..16)
    logic [3:0]  dma_beat_cnt_q;          // current beat index within burst
    logic        dma_head_q;              // 1 = first burst of row (needs head wstrb)
    logic        dma_head_pad_q;          // 1 = dst_x odd, first beat wstrb = 8'hF0

    // ====================================================================
    // Pattern read — combinational address from cx, synchronous output
    // ====================================================================
    // Mask derived from pattern size: (1 << log_pw) - 1, up to 5'd31.
    wire [4:0] pat_mask_x = (5'd1 << log_pw_q) - 5'd1;
    wire [4:0] pat_mask_y = (5'd1 << log_ph_q) - 5'd1;
    wire [4:0] pat_x_eff  = (cx[4:0] + phase_x_q) & pat_mask_x;
    wire [4:0] pat_y_eff  = (cy[4:0] + phase_y_q) & pat_mask_y;
    wire [9:0] pat_addr_rd = {pat_y_eff, pat_x_eff};

    // Registered BRAM output.  1-cycle latency: address sampled at posedge
    // t0, data valid at posedge t1.
    logic [31:0] pat_pixel_q;
    (* keep = "true" *) logic [31:0] pat_pixel_q2;
    always_ff @(posedge clk) begin
        pat_pixel_q  <= pat_mem[pat_addr_rd];
        pat_pixel_q2 <= pat_pixel_q;
    end

    // ---- Alpha check -------------------------------------------------------
    // Pixel format is RGBA-8888 with R in bits [31:24], G in [23:16],
    // B in [15:8], A in [7:0] (big-endian packed, matching fb_scanout).
    // Any non-zero alpha means the 4 byte lanes for that half are valid.
    // Use pat_pixel_q2 (external FF, not BRAB-absorbed) for timing-critical
    // alpha-dependent paths.
    wire        px_alpha_nz   = (pat_pixel_q[7:0] != 8'd0);   // A at [7:0]
    wire [3:0]  px_strb       = px_alpha_nz ? 4'hF : 4'h0;

    // which half of the 64-bit beat does this pixel go into?
    wire        px_in_low_half = (dst_x_q[0] == cx[0]);  // parity match → even global X

    // ---- Font memory read port (synchronous, 1-cycle latency) ---------------
    // Address: {cy[4:0], cx[6:2]} = 5 bits row + 5 bits column-word = 9-bit
    // index [8:0] into 512-entry BRAM (max 32 rows × 64 pixels).
    // Byte select within word: cx[1:0] selects which of four coverage bytes.
    wire [8:0] font_addr_rd = {cy[4:0], cx[6:2]};
    logic [31:0] font_pixel_q;
    (* keep = "true" *) logic [31:0] font_pixel_q2;

    always_ff @(posedge clk) begin
        font_pixel_q  <= font_mem[font_addr_rd];
        font_pixel_q2 <= font_pixel_q;
    end

    // Extract coverage byte for the current pixel (combinational mux).
    wire [7:0] font_coverage2 =
        (cx[1:0] == 2'd0) ? font_pixel_q2[7:0]   :
        (cx[1:0] == 2'd1) ? font_pixel_q2[15:8]  :
        (cx[1:0] == 2'd2) ? font_pixel_q2[23:16] :
                            font_pixel_q2[31:24];
    wire [7:0] font_coverage =
        (cx[1:0] == 2'd0) ? font_pixel_q[7:0]   :
        (cx[1:0] == 2'd1) ? font_pixel_q[15:8]  :
        (cx[1:0] == 2'd2) ? font_pixel_q[23:16] :
                            font_pixel_q[31:24];

    // ====================================================================
    // FSM
    // ====================================================================
    typedef enum logic [5:0] {
        S_IDLE   = 6'd0,
        // Rect fill states
        S_SEG    = 6'd1,   // start new segment, snapshot seg_cx/cy
        S_ACCUM  = 6'd2,   // present pattern address (pat_addr_rd → BRAM)
        S_ACCUM_W= 6'd3,   // pat_pixel_q valid; process pixel
        S_ACCUM_FW=6'd32,  // font wait cycle 1 (font_pixel_q2 pipeline)
        S_ACCUM_FW2=6'd33, // font wait cycle 2 (font_pixel_q2 pipeline)
        S_ACCUM_W2=6'd34,  // state-transition decision using registered values
        S_ACCUM_WAIT=6'd35,// wait cycle so pat_pixel_q2 is valid
        S_PEND   = 6'd4,   // commit pending beat_lo; then decide AW/skip
        S_AW     = 6'd5,   // issue AW for accumulated burst
        S_W      = 6'd6,   // stream W beats
        S_B      = 6'd7,   // wait for B response
        S_ADV    = 6'd8,   // advance to next segment/row
        S_DONE   = 6'd9,
        // Line draw states
        L_INIT   = 6'd10,  // compute Bresenham parameters
        L_ACCUM  = 6'd11,  // present pattern address for pixel at (line_x,line_y)
        L_PLOT   = 6'd12,  // pat_pixel_q valid; issue single-beat AXI write
	        L_PLOT_W = 6'd31,  // hold AXI write signals one cycle for slave to sample
        L_STEP   = 6'd13,  // Bresenham step; check termination
        // Block blit states
        BL_READ  = 6'd14,  // issue AR for source segment
        BL_RWAIT = 6'd15,  // receive R beats, fill burst buffer
        // Scaled blit states
        SC_ROW   = 6'd16,  // start new destination row, compute source Y
        SC_ROW2  = 6'd17,  // finish sy advance (may loop for downscale)
        SC_CALC  = 6'd18,  // compute source address, check cache, issue AR
        SC_READ  = 6'd19,  // wait for AXI R data
        SC_ACCUM = 6'd20,  // accumulate pixel into burst buffer
        SC_NEXT  = 6'd21,  // update sx_accum for next pixel
        SC_NEXT2 = 6'd22,  // finish sx advance (may loop for downscale)
        // Alpha-blend states
        BL_RACC  = 6'd23,  // wait for destination read, blend, accumulate
        // Bilinear scaled-blit states (compact: sub-pixel index in bl_sub_q)
        SC_BL_RD  = 6'd24, // issue AR for one of P00/P10/P01/P11 (bl_sub_q selects)
        SC_BL_W   = 6'd25, // wait for R data, latch into correct pixel register
        SC_BL_WT  = 6'd26, // compute 8-bit fractional weights (sequential divider)
        SC_BL_ACC = 6'd27, // cycle 1: bilinear blend — compute weighted pixel
        SC_BL_BLEND = 6'd42, // cycle 1.5: bilinear blend — weighted pixel from registered weights
        SC_BL_ACC2= 6'd36, // cycle 2: bilinear blend — accumulate into burst buffer
        SC_SBLEND = 6'd28, // scaled-blit blend: wait for dest read, blend, accumulate, goto SC_NEXT
        // Block-blit raster-op states
        BL_DREAD  = 6'd29, // issue AR for destination segment
        BL_DRWAIT = 6'd30, // receive destination beats, combine byte-wise with source
        // DMA rect fill — solid colour, no per-pixel FSM
        S_DMA_AW  = 6'd37, // issue AW for next burst
        S_DMA_W   = 6'd38, // stream W beats (wdata = {colour, colour})
        S_DMA_B   = 6'd39, // wait for B, advance counters
        // Pipeline stages for alpha-blend (break critical path)
        BL_RACC2  = 6'd40, // cycle 2 of BL_RACC: accumulate blended pixel
        SC_SBLEND2= 6'd41, // cycle 2 of SC_SBLEND: accumulate blended pixel
        BL_RACC_BLEND = 6'd43, // cycle 1.5: compute src*sa and dst*inv_a products
        SC_SBLEND_BLEND = 6'd44, // cycle 1.5: compute src*sa and dst*inv_a products
        BL_RACC_BLEND2 = 6'd45, // cycle 1.75: combine products → bl_blend_q
        SC_SBLEND_BLEND2 = 6'd46, // cycle 1.75: combine products → bl_blend_q
        L_STEP2  = 6'd47   // line-draw: apply registered step flags
    } state_t;
    state_t state;

    // ---- AXI output --------------------------------------------------------
    assign m_axi_bready  = 1'b1;
    // awsize/awburst are set procedurally in S_AW (rect) and L_PLOT (line).
    // busy = FSM not idle OR work still queued — software polls this to
    // know when a batch of CMDs has fully drained.
    assign busy          = (state != S_IDLE) || !cq_empty_w;
    // cq_pop fires when S_IDLE sees a non-empty queue AND the prefetched
    // entry is valid.  cq_front_valid hides the BRAM 1-cycle read latency
    // and the push-to-empty bypass takes care of the first-CMD case.
    assign cq_pop        = (state == S_IDLE) && !cq_empty_w && cq_front_valid;

    // ====================================================================
    always_ff @(posedge clk) begin  // sync reset — see note at `rst` port
        if (rst) begin
            state             <= S_IDLE;
            cx                <= 16'd0;
            cy                <= 16'd0;
            seg_cx            <= 16'd0;
            seg_cy            <= 16'd0;
            dst_x_q           <= 16'd0;
            dst_y_q           <= 16'd0;
            dst_w_q           <= 16'd0;
            dst_h_q           <= 16'd0;
            phase_x_q         <= 5'd0;
            phase_y_q         <= 5'd0;
            log_pw_q          <= 5'd0;
            log_ph_q          <= 5'd0;
            burst_len         <= 5'd0;
            burst_flush_idx   <= 5'd0;
            beat_lo           <= 32'd0;
            beat_strb_lo      <= 4'd0;
            beat_lo_filled    <= 1'b0;
            burst_nonzero_mask <= 1'b0;
            line_mode_q       <= 1'b0;
            blk_mode_q        <= 1'b0;
            sc_mode_q         <= 1'b0;
            blend_mode_q      <= 1'b0;
            bl_src_pixel_q    <= 32'd0;
            bl_px_low_q       <= 1'b0;
            src_x_q           <= 16'd0;
            src_y_q           <= 16'd0;
            src_w_q           <= 16'd0;
            src_h_q           <= 16'd0;
            sx_step_q         <= 16'd0;
            sy_cur_q          <= 16'd0;
            sx_accum_q        <= 16'd0;
            sy_accum_q        <= 16'd0;
            sc_pixel_valid_q  <= 1'b0;
            sc_pixel_q        <= 32'd0;
            sc_pixel_addr_q   <= 32'd0;
            sc_raddr_q        <= 32'd0;
            sc_need_flush_q   <= 1'b0;
            bilin_mode_q      <= 1'b0;
            font_mode_q       <= 1'b0;
            sc_blend_q        <= 1'b0;
            raster_op_q       <= 4'd3;
            bl_arlen_q        <= 8'd0;
            p00_q             <= 32'd0;
            p10_q             <= 32'd0;
            p01_q             <= 32'd0;
            p11_q             <= 32'd0;
            bl_fx8_q          <= 8'd0;
            bl_fy8_q          <= 8'd0;
            bl_w00_q          <= 9'd0;
            bl_w10_q          <= 9'd0;
            bl_w01_q          <= 9'd0;
            bl_w11_q          <= 9'd0;
            bl_rem_x_q        <= 24'd0;
            bl_rem_y_q        <= 24'd0;
            bl_div_cycle_q    <= 4'd0;
            bl_sub_q          <= 2'd0;
            m_axi_awaddr      <= 32'd0;
            m_axi_awlen       <= 8'd0;
            m_axi_awvalid     <= 1'b0;
            m_axi_wdata       <= 64'd0;
            m_axi_wstrb       <= 8'h00;
            m_axi_wlast       <= 1'b0;
            m_axi_wvalid      <= 1'b0;
            m_axi_araddr      <= 32'd0;
            m_axi_arlen       <= 8'd0;
            m_axi_arvalid     <= 1'b0;
            dma_mode_q        <= 1'b0;
            dma_next_q        <= 32'd0;
            dma_rem_rows_q    <= 16'd0;
            dma_rem_row_px_q  <= 16'd0;
            dma_burst_px_q    <= 6'd0;
            dma_burst_beats_q <= 5'd0;
            dma_beat_cnt_q    <= 4'd0;
            dma_head_q        <= 1'b0;
            dma_head_pad_q    <= 1'b0;
            m_axi_rready      <= 1'b0;
            bl_blend_q        <= 32'd0;
            bl_blend_valid_q  <= 1'b0;
            bl_dst_q          <= 32'd0;
            bl_src_prod_q     <= 64'd0;
            bl_dst_prod_q     <= 64'd0;
            line_step_q       <= 2'd0;
            bl_read_high_half_q <= 1'b0;
            line_use_blend_q  <= 1'b0;
        end else begin
            // one-shot strobes default off
            m_axi_awvalid <= 1'b0;
            m_axi_wvalid  <= 1'b0;
            m_axi_wlast   <= 1'b0;
            m_axi_arvalid <= 1'b0;
            m_axi_rready  <= 1'b0;

            unique case (state)

                // ============================================================
                // S_IDLE — pop the next command off the FIFO and dispatch.
                //
                // cq_pop = (state == S_IDLE) && !cq_empty_w && cq_front_valid
                // is computed outside the case and consumed by the FIFO-
                // management always_ff to advance cq_tail.  Here we just
                // snapshot the popped fields (q_*) into the working
                // registers and pick the first state based on the popped
                // CMD.  cq_front_valid gates on BRAM read latency — if the
                // prefetch hasn't settled yet we just wait another cycle.
                // ============================================================
                S_IDLE: begin
                    if (!cq_empty_w && cq_front_valid && q_sync_mode) begin
                        // SYNC barrier — pop the entry and stay in S_IDLE.
                        // seq_counter_q is bumped by its own always_ff via
                        // the (cq_pop && q_sync_mode) qualifier.  No drawing
                        // state to enter, no working registers to load.
                    end else if (!cq_empty_w && cq_front_valid) begin
                        dst_x_q   <= q_dst_x;
                        dst_y_q   <= q_dst_y;
                        dst_w_q   <= q_dst_w;
                        dst_h_q   <= q_dst_h;
                        phase_x_q <= q_phase_x;
                        phase_y_q <= q_phase_y;
                        log_pw_q  <= q_log_pw;
                        log_ph_q  <= q_log_ph;
                        line_mode_q  <= q_line_mode;
                        blk_mode_q   <= q_blk_mode;
                        sc_mode_q    <= q_sc_mode;
                        blend_mode_q <= q_blend_mode;
                        bilin_mode_q <= q_bilin_mode;
                        font_mode_q  <= q_font_mode;
                        sc_blend_q   <= q_sc_blend;
                        raster_op_q  <= q_raster_op;
                        src_x_q     <= q_src_x;
                        src_y_q     <= q_src_y;
                        src_w_q     <= q_src_w;
                        src_h_q     <= q_src_h;
                        cx        <= 16'd0;
                        cy        <= 16'd0;
                        burst_len         <= 5'd0;
                        beat_lo_filled    <= 1'b0;
                        burst_nonzero_mask <= 1'b0;
                        sc_pixel_valid_q  <= 1'b0;

                        // Default: clear DMA mode.  Set below only for
                        // eligible solid-colour fills.
                        dma_mode_q <= 1'b0;

                        if (q_line_mode) begin
                            // Line draw — skip rect init
                            if (q_dst_w == 16'd0 && q_dst_h == 16'd0)
                                state <= S_DONE;
                            else
                                state <= L_INIT;
                        end else if (q_blk_mode) begin
                            // Block blit
                            if (q_dst_w == 16'd0 || q_dst_h == 16'd0 || q_raster_op == 4'd0 || q_raster_op == 4'd5)
                                state <= S_DONE;
                            else
                                state <= BL_READ;
                        end else if (q_sc_mode) begin
                            // Scaled blit
                            if (q_dst_w == 16'd0 || q_dst_h == 16'd0
                                || q_src_w == 16'd0 || q_src_h == 16'd0)
                                state <= S_DONE;
                            else
                                state <= SC_ROW;
                        end else if (q_blend_mode) begin
                            // Alpha-blend rect fill
                            if (q_dst_w == 16'd0 || q_dst_h == 16'd0 || q_raster_op == 4'd0 || q_raster_op == 4'd5)
                                state <= S_DONE;
                            else
                                state <= S_SEG;
                        end else if (q_font_mode) begin
                            // Font raster
                            if (q_dst_w == 16'd0 || q_dst_h == 16'd0 || q_raster_op == 4'd0 || q_raster_op == 4'd5)
                                state <= S_DONE;
                            else
                                state <= S_SEG;
                        end else if (q_bilin_mode) begin
                            // Bilinear scaled blit
                            if (q_dst_w == 16'd0 || q_dst_h == 16'd0
                                || q_src_w == 16'd0 || q_src_h == 16'd0)
                                state <= S_DONE;
                            else
                                state <= SC_ROW;
                        end else begin
                            // Rect fill
                            if (q_dst_w == 16'd0 || q_dst_h == 16'd0 || q_raster_op == 4'd0 || q_raster_op == 4'd5) begin
                                state <= S_DONE;
                            end else if (q_log_pw == 5'd0 && q_log_ph == 5'd0 && !q_blend_mode && !q_font_mode && !q_bilin_mode
                                         && (q_raster_op == 4'd3 || q_raster_op == 4'd15)) begin
                                // DMA fill mode: 1×1 pattern (solid colour), no blend/font,
                                // raster op = COPY.  Bypasses per-pixel FSM entirely.
                                dma_mode_q      <= 1'b1;
                                dma_next_q      <= FB_BASE + (32'(q_dst_y) << 13) + (32'(q_dst_x) << 2);
                                dma_rem_rows_q  <= q_dst_h;
                                dma_rem_row_px_q<= q_dst_w;
                                dma_head_q      <= 1'b1;
                                dma_head_pad_q  <= q_dst_x[0];
                                state <= S_ACCUM;   // warm up BRAM (pat_mem[0] → pat_pixel_q2)
                            end else begin
                                dma_mode_q <= 1'b0;
                                state <= S_SEG;
                            end
                        end
                    end
                end

                // ============================================================
                // S_SEG — start a new burst segment
                //
                // Snapshots seg_cx/seg_cy for the AW address.  Transitions
                // to S_ACCUM to begin reading pixels from the pattern BRAM.
                // ============================================================
                S_SEG: begin
                    seg_cx <= cx;
                    seg_cy <= cy;

                    if (cx >= dst_w_q) begin
                        state <= S_ADV;
                    end else begin
                        state <= S_ACCUM;
                    end
                end

                // ============================================================
                // S_ACCUM — present pattern address for pixel at (cx, cy)
                //
                // pat_addr_rd is combinational from cx/cy.  BRAM captures
                // this address on the posedge; data appears in pat_pixel_q
                // one cycle later.
                // ============================================================
                S_ACCUM: begin
                    if (font_mode_q)
                        state <= S_ACCUM_FW;
                    else
                        state <= S_ACCUM_WAIT;
                end

                // ============================================================
                // S_ACCUM_FW — font BRAM pipeline wait cycle 1
                // ============================================================
                S_ACCUM_FW: begin
                    state <= S_ACCUM_FW2;
                end

                // ============================================================
                // S_ACCUM_FW2 — font BRAM pipeline wait cycle 2
                // ============================================================
                S_ACCUM_FW2: begin
                    state <= S_ACCUM_WAIT;
                end

                // ============================================================
                // S_ACCUM_WAIT — pat_pixel_q2 copy cycle
                //
                // One-cycle wait so pat_pixel_q2 gets the data from pat_pixel_q
                // (which was captured in S_ACCUM).  In the following S_ACCUM_W,
                // pat_pixel_q2 has the correct pixel data while presenting only
                // a short FF clock-to-output delay instead of the BRAM's 2.125 ns.
                // ============================================================
                S_ACCUM_WAIT: begin
                    if (font_mode_q) begin
                        logic [7:0]  ft_a;
                        logic [15:0] ft_mod;
                        ft_a   = pat_pixel_q2[7:0];
                        ft_mod = font_coverage2 * ft_a;
                        ft_al_q <= ft_mod[15:8];
                    end
                    if (dma_mode_q) begin
                        // Pattern alpha check: if fully transparent, skip fill.
                        // DMA mode doesn't have per-pixel wstrb masking, so
                        // early-exit here rather than issuing zero-opacity bursts.
                        if (pat_pixel_q2[7:0] == 8'd0)
                            state <= S_DONE;
                        else
                            state <= S_DMA_AW;  // enter DMA loop
                    end else begin
                        state <= S_ACCUM_W;
                    end
                end

                // ============================================================
                // S_ACCUM_W — pixel-data processing (second pipeline stage)
                //
                // The 8×8 multiplier (coverage × pattern.A) was already
                // computed in S_ACCUM_WAIT; ft_al_q holds the modulated alpha.
                // Here we compare ft_al_q against 0/255, set strb_nonzero_q,
                // and route to S_ACCUM_W2 (normal) or BL_RACC (blend).
                //
                // For non-font blend paths, pat_pixel_q2[7:0] is checked
                // directly (no multiply needed — already the per-pixel alpha).
                //
                // For non-blend paths, results are registered and we go to
                // S_ACCUM_W2 which uses the registered values for the state-
                // transition decision (burst_len/cx compare, ARVALID decode,
                // next state).  This splits the long combinational path
                // pat_pixel_q → state decode → CARRY4 → ARVALID → burst_len
                // into two halves, each fitting in 6.667 ns at 150 MHz.
                //
                // flush-when conditions use the VALUE AFTER increment:
                //   cx_next   = cx + 1
                //   bl_next   = burst_len + (accum_commits_beat ? 1 : 0)
                // flush if (bl_next == 16) || (cx_next >= dst_w_q)
                // ============================================================
                S_ACCUM_W: begin
                    accum_commits_beat = 1'b0;

                    if (font_mode_q) begin
                        // --- Font raster path ---
                        // ft_al_q was pre-computed in S_ACCUM_WAIT
                        // (coverage × pattern.A ÷ 256) using the 8×8
                        // multiplier, removing it from this critical
                        // path.  Here we only compare and decode state,
                        // keeping the combinational depth short enough
                        // for 150 MHz.

                        if (ft_al_q == 8'd0) begin
                            // Fully transparent — mask via wstrb, advance
                            if (px_in_low_half) begin
                                beat_lo        <= 32'd0;
                                beat_strb_lo   <= 4'h0;
                                beat_lo_filled <= 1'b1;
                            end else if (beat_lo_filled) begin
                                burst_data[burst_len] <= {32'd0, beat_lo};
                                burst_strb[burst_len] <= {4'h0, beat_strb_lo};
                                beat_lo_filled <= 1'b0;
                                accum_commits_beat = 1'b1;
                            end else begin
                                burst_data[burst_len] <= {32'd0, 32'd0};
                                burst_strb[burst_len] <= {4'h0, 4'h0};
                                accum_commits_beat = 1'b1;
                            end
                            cx <= cx + 16'd1;
                            strb_nonzero_q <= 1'b0;
                            accum_commits_q <= accum_commits_beat;
                            cx_q           <= cx;
                            cx_ge_dst_w_q  <= (cx + 16'd1 >= dst_w_q);
                            state <= S_ACCUM_W2;
                        end else if (ft_al_q == 8'd255) begin
                            // Fully opaque — use pattern RGB with A=255
                            logic [31:0] ft_px;
                            ft_px = {pat_pixel_q2[31:8], 8'd255};
                            if (px_in_low_half) begin
                                beat_lo        <= ft_px;
                                beat_strb_lo   <= 4'hF;
                                beat_lo_filled <= 1'b1;
                            end else if (beat_lo_filled) begin
                                burst_data[burst_len] <= {ft_px, beat_lo};
                                burst_strb[burst_len] <= {4'hF, beat_strb_lo};
                                beat_lo_filled <= 1'b0;
                                accum_commits_beat = 1'b1;
                            end else begin
                                burst_data[burst_len] <= {ft_px, 32'd0};
                                burst_strb[burst_len] <= {4'hF, 4'h0};
                                accum_commits_beat = 1'b1;
                            end
                            cx <= cx + 16'd1;
                            strb_nonzero_q <= 1'b1;
                            accum_commits_q <= accum_commits_beat;
                            cx_q           <= cx;
                            cx_ge_dst_w_q  <= (cx + 16'd1 >= dst_w_q);
                            state <= S_ACCUM_W2;
                        end else begin
                            // Partially transparent — blend with destination
                            // Use pattern RGB with computed alpha as source.
                            bl_src_pixel_q <= {pat_pixel_q2[31:8], ft_al_q};
                            bl_px_low_q    <= px_in_low_half;
                            m_axi_araddr  <= FB_BASE
                                           + (32'(dst_y_q + cy) << 13)
                                           + (32'(dst_x_q + cx) << 2);
                            m_axi_arlen   <= 8'd0;
                            m_axi_arsize  <= 3'b010;
                            m_axi_arburst <= 2'b01;
                            m_axi_arvalid <= 1'b1;
                            bl_read_high_half_q <= ~px_in_low_half;
                            cx <= cx + 16'd1;
                            state <= BL_RACC;
                        end

                    end else if (blend_mode_q && (pat_pixel_q2[7:0] != 8'd0) && pat_pixel_q2[7:0] != 8'd255) begin
                        // --- Alpha blend path (0 < alpha < 255) ---
                        // Latch source pixel and half-position for BL_RACC.
                        bl_src_pixel_q <= pat_pixel_q2;
                        bl_px_low_q    <= px_in_low_half;

                        m_axi_araddr  <= FB_BASE
                                       + (32'(dst_y_q + cy) << 13)
                                       + (32'(dst_x_q + cx) << 2);
                        m_axi_arlen   <= 8'd0;
                        m_axi_arsize  <= 3'b010;   // 4 bytes
                        m_axi_arburst <= 2'b01;
                        m_axi_arvalid <= 1'b1;
                        bl_read_high_half_q <= ~px_in_low_half;

                        cx <= cx + 16'd1;
                        state <= BL_RACC;

                    end else begin
                        // --- Normal (accumulate) or opaque/transparent shortcut ---
                        // For blend_mode_q with alpha==255: use source as-is.
                        // For blend_mode_q with alpha==0: wstrb will be 0 (px_strb).
                        // For normal rect fill: unchanged behaviour.

                        if (px_in_low_half) begin
                            // Pixel goes in low half (byte lanes 3:0).
                            beat_lo        <= pat_pixel_q2;
                            beat_strb_lo   <= px_strb;
                            beat_lo_filled <= 1'b1;
                        end else begin
                            if (beat_lo_filled) begin
                                // Partner exists — commit the full beat.
                                burst_data[burst_len] <= {pat_pixel_q2, beat_lo};
                                burst_strb[burst_len] <= {px_strb, beat_strb_lo};
                                strb_nonzero_q <= (beat_strb_lo != 4'd0 || px_strb != 4'd0);
                                beat_lo_filled <= 1'b0;
                                accum_commits_beat = 1'b1;
                            end else begin
                                // Orphaned odd pixel (started on odd X).
                                burst_data[burst_len] <= {pat_pixel_q2, 32'd0};
                                burst_strb[burst_len] <= {px_strb, 4'h0};
                                strb_nonzero_q <= (px_strb != 4'd0);
                                accum_commits_beat = 1'b1;
                            end
                        end

                        cx <= cx + 16'd1;
                        accum_commits_q <= accum_commits_beat;
                        cx_q           <= cx;
                        cx_ge_dst_w_q  <= (cx + 16'd1 >= dst_w_q);
                        state <= S_ACCUM_W2;
                    end
                end

                // ============================================================
                // S_ACCUM_W2 — state-transition decision (second half)
                //
                // Uses registered values from S_ACCUM_W:
                //   accum_commits_q, cx_ge_dst_w_q (pipelined CARRY4 compare),
                //   strb_nonzero_q
                // to determine burst_len increment and next FSM state.
                // cx_ge_dst_w_q was computed in S_ACCUM_W as (cx+1 >= dst_w_q)
                // and registered, breaking the 6-CARRY4 chain out of the
                // path to state_reg — critical for 150 MHz timing closure.
                // ============================================================
                S_ACCUM_W2: begin
                    // Apply registered strb-nonzero flag to the sticky mask.
                    if (accum_commits_q && strb_nonzero_q)
                        burst_nonzero_mask <= 1'b1;

                    if (font_mode_q) begin
                        // --- Font raster: use registered ft_al_q ---
                        if (accum_commits_q) begin
                            if (burst_len == 5'd15) begin
                                burst_len <= 5'd16;
                                state <= S_PEND;
                            end else if (cx_ge_dst_w_q) begin
                                burst_len <= burst_len + 5'd1;
                                state <= S_PEND;
                            end else begin
                                burst_len <= burst_len + 5'd1;
                                state <= S_ACCUM_FW;
                            end
                        end else begin
                            if (cx_ge_dst_w_q) begin
                                state <= S_PEND;
                            end else begin
                                state <= S_ACCUM_FW;
                            end
                        end

                    end else begin
                        // --- Normal fill: use registered accum_commits_q ---
                        if (accum_commits_q) begin
                            if (burst_len == 5'd15) begin
                                burst_len <= 5'd16;
                                state <= S_PEND;
                            end else if (cx_ge_dst_w_q) begin
                                burst_len <= burst_len + 5'd1;
                                state <= S_PEND;
                            end else begin
                                burst_len <= burst_len + 5'd1;
                                state <= S_ACCUM;
                            end
                        end else begin
                            if (cx_ge_dst_w_q) begin
                                state <= S_PEND;
                            end else begin
                                state <= S_ACCUM;
                            end
                        end
                    end
                end

                // ============================================================
                // S_PEND — commit any pending beat_lo, then flush or skip
                // ============================================================
                S_PEND: begin
                    if (beat_lo_filled) begin
                        // Even pixel waiting with no partner (odd-width row).
                        burst_data[burst_len] <= {32'd0, beat_lo};
                        burst_strb[burst_len] <= {4'h0, beat_strb_lo};
                        if (beat_strb_lo != 4'd0)
                            burst_nonzero_mask <= 1'b1;
                        burst_len      <= burst_len + 5'd1;
                        beat_lo_filled <= 1'b0;
                        // Stay in S_PEND next cycle (re-evaluate with
                        // beat_lo_filled now 0).
                    end else if (burst_len == 5'd0 || !burst_nonzero_mask) begin
                        // Nothing useful to write — skip to advance.
                        burst_len         <= 5'd0;
                        burst_nonzero_mask <= 1'b0;
                        if (sc_mode_q) begin
                            // Scaled blit: go directly to row/next-pixel check
                            if (cx >= dst_w_q) begin
                                if (cy >= dst_h_q - 16'd1 || dst_h_q == 16'd0)
                                    state <= S_DONE;
                                else begin
                                    cy <= cy + 16'd1;
                                    state <= SC_ROW;
                                end
                            end else begin
                                state <= SC_CALC;
                            end
                        end else if (bilin_mode_q) begin
                            // Bilinear scaled blit: same row advance as scaled
                            if (cx >= dst_w_q) begin
                                if (cy >= dst_h_q - 16'd1 || dst_h_q == 16'd0)
                                    state <= S_DONE;
                                else begin
                                    cy <= cy + 16'd1;
                                    state <= SC_ROW;
                                end
                            end else begin
                                state <= SC_BL_RD;
                            end
                        end else begin
                            state <= S_ADV;
                        end
                    end else begin
                        state <= S_AW;
                    end
                end

                // ============================================================
                // S_AW — issue AW for the accumulated burst
                //
                // The burst base address is seg_raw_addr aligned down to
                // the nearest 8-byte boundary: {seg_raw_addr[31:3], 3'b000}.
                // This is the address of the 64-bit beat that contains
                // the first pixel of the segment.
                // ============================================================
                S_AW: begin
                    m_axi_awaddr  <= {seg_raw_addr[31:3], 3'b000};
                    m_axi_awlen   <= burst_len[3:0] - 8'd1;
                    m_axi_awsize  <= 3'b011;       // 8 bytes/beat
                    m_axi_awburst <= 2'b01;        // INCR
                    m_axi_awvalid <= 1'b1;
                    burst_flush_idx    <= 5'd0;
                    burst_nonzero_mask <= 1'b0;
                    state         <= S_W;
                end

                // ============================================================
                // S_W — stream W beats of the burst
                // ============================================================
                S_W: begin
                    m_axi_wdata  <= burst_data[burst_flush_idx];
                    m_axi_wstrb  <= burst_strb[burst_flush_idx];
                    m_axi_wlast  <= (burst_flush_idx == burst_len - 5'd1);
                    m_axi_wvalid <= 1'b1;

                    if (m_axi_wready) begin
                        if (burst_flush_idx == burst_len - 5'd1) begin
                            state <= S_B;
                        end else begin
                            burst_flush_idx <= burst_flush_idx + 5'd1;
                        end
                    end
                end

                // ============================================================
                // S_B — wait for B response
                //
                // For block blit, advance cx/cy for the next segment before
                // returning to BL_READ.  Each beat = 2 pixels, so cx advances
                // by burst_len × 2.  If row complete, wrap to next row.
                // ============================================================
                S_B: begin
                    if (m_axi_bvalid) begin
                        if (sc_mode_q) begin
                            // cx was advanced per-pixel during accumulation;
                            // check if row is complete or continue.
                            burst_len <= 5'd0;   // reset after flush
                            if (cx >= dst_w_q) begin
                                if (cy >= dst_h_q - 16'd1 || dst_h_q == 16'd0)
                                    state <= S_DONE;
                                else begin
                                    cy <= cy + 16'd1;
                                    state <= SC_ROW;
                                end
                            end else begin
                                state <= SC_CALC;
                            end
                        end else if (bilin_mode_q) begin
                            // Bilinear scaled blit: same row/pixel check
                            burst_len <= 5'd0;   // reset after flush
                            if (cx >= dst_w_q) begin
                                if (cy >= dst_h_q - 16'd1 || dst_h_q == 16'd0)
                                    state <= S_DONE;
                                else begin
                                    cy <= cy + 16'd1;
                                    state <= SC_ROW;
                                end
                            end else begin
                                state <= SC_BL_RD;
                            end
                        end else if (line_mode_q) begin
                            state <= L_STEP;
                        end else if (blk_mode_q) begin
                            // Advance past the segment we just wrote.
                            // {burst_len, 1'b0} = burst_len * 2 pixels.
                            if (cx + {burst_len, 1'b0} >= dst_w_q) begin
                                // Row complete
                                if (cy >= dst_h_q - 16'd1) begin
                                    state <= S_DONE;
                                end else begin
                                    cy <= cy + 16'd1;
                                    cx <= 16'd0;
                                    state <= BL_READ;
                                end
                            end else begin
                                cx <= cx + {burst_len, 1'b0};
                                state <= BL_READ;
                            end
                        end else begin
                            state <= S_ADV;
                        end
                    end
                end

                // ============================================================
                // S_ADV — advance cx/cy past flushed segment
                // ============================================================
                S_ADV: begin
                    burst_len         <= 5'd0;
                    beat_lo_filled    <= 1'b0;
                    burst_nonzero_mask <= 1'b0;

                    if (cx >= dst_w_q) begin
                        if (cy == dst_h_q - 16'd1) begin
                            state <= S_DONE;
                        end else begin
                            cy <= cy + 16'd1;
                            cx <= 16'd0;
                            state <= S_SEG;
                        end
                    end else begin
                        state <= S_SEG;
                    end
                end

                // ============================================================
                S_DONE: begin
                    line_mode_q <= 1'b0;
                    blk_mode_q  <= 1'b0;
                    dma_mode_q  <= 1'b0;
                    state <= S_IDLE;
                end

                // ============================================================
                // DMA fill — solid-colour rect fill (bypass per-pixel FSM)
                //
                // S_DMA_AW — compute burst geometry and issue AW
                // S_DMA_W  — stream W beats with head/tail wstrb handling
                // S_DMA_B  — wait for BVALID, advance counters
                //
                // Each 64-bit beat carries two 32-bit RGBA pixels.  Head-padding
                // handles odd dst_x (first pixel in high half, wstrb = 8'hF0).
                // Tail-padding handles odd remaining pixels (wstrb = 8'h0F).
                // ============================================================

                // ============================================================
                // S_DMA_AW — issue AW for next burst
                //
                // Computes burst size from remaining row pixels, handles head
                // padding for odd dst_x, and issues a single AXI INCR write.
                // Max burst = 16 beats (31 useful pixels, or 32 slots including
                // head padding).  Sets dma_beat_cnt_q = 0 for S_DMA_W.
                // ============================================================
                S_DMA_AW: begin
                    logic [5:0]  head_pad;       // 0 or 1
                    logic [5:0]  rem_px;         // useful pixels this burst (capped)
                    logic [5:0]  total_slots;    // rem_px + head_pad (pixel slots)
                    logic [5:0]  beats;          // AXI beats = ceil(total_slots / 2)
                    logic [31:0] burst_addr;     // 8-byte-aligned AXI address

                    head_pad = dma_head_q && dma_head_pad_q ? 6'd1 : 6'd0;

                    // Cap burst at 32 pixel slots = 16 beats max.
                    // With head_pad, first beat only carries 1 useful pixel
                    // so max useful = 31.  Without head_pad, max = 32.
                    rem_px = 6'(dma_rem_row_px_q);
                    if (rem_px > (32 - head_pad))
                        rem_px = 32 - head_pad;

                    total_slots = rem_px + head_pad;   // 1..32
                    beats = (total_slots + 1) >> 1;    // ceil division, 1..16

                    // Store parameters for S_DMA_W
                    dma_burst_px_q   <= rem_px;
                    dma_burst_beats_q <= beats[4:0];
                    dma_beat_cnt_q   <= 4'd0;

                    // 8-byte-aligned AXI address
                    if (head_pad != 6'd0)
                        burst_addr = (dma_next_q - 4) & 32'hFFFFFFF8;
                    else
                        burst_addr = dma_next_q & 32'hFFFFFFF8;

                    if (total_slots == 6'd0) begin
                        // Degenerate: no pixels (should not happen)
                        state <= S_DMA_B;
                    end else begin
                        // Issue AW
                        m_axi_awaddr  <= burst_addr;
                        m_axi_awlen   <= beats - 6'd1;
                        m_axi_awsize  <= 3'b011;    // 8 bytes/beat
                        m_axi_awburst <= 2'b01;     // INCR
                        m_axi_awvalid <= 1'b1;
                        state <= S_DMA_W;
                    end

                    // Advance tracking (unconditional: even degenerate case
                    // consumed 0 useful pixels, so subtract 0).
                    dma_rem_row_px_q <= dma_rem_row_px_q - rem_px;
                    dma_next_q <= dma_next_q + {24'd0, rem_px, 2'd0};

                    // NOTE: dma_head_q is NOT cleared here.  S_DMA_W needs it
                    // to recognise the first beat for head-pad wstrb.  It will
                    // be cleared after the first beat's wready in S_DMA_W.
                end

                // ============================================================
                // S_DMA_W — stream W beats for the current burst
                //
                // Each beat carries pat_pixel_q2 (the solid colour) in both
                // halves.  wstrb is adjusted per-beat:
                //   - First beat with head_pad: 8'hF0 (high half only)
                //   - Last beat with odd remaining: 8'h0F (low half only)
                //   - Full beats: 8'hFF
                //
                // dma_burst_px_q tracks useful pixels remaining.  dma_beat_cnt_q
                // tracks the AXI beat index for wlast generation.
                // ============================================================
                S_DMA_W: begin
                    logic [7:0] dw_wstrb;

                    // ---- compute wstrb for this beat ----
                    dw_wstrb = 8'hFF;   // default: both halves valid
                    if (dma_beat_cnt_q == 4'd0 && dma_head_q && dma_head_pad_q) begin
                        // Head-padded first beat: 1 useful pixel in high half
                        dw_wstrb = 8'hF0;
                    end else if (dma_burst_px_q == 6'd1) begin
                        // Last useful pixel only → low half
                        dw_wstrb = 8'h0F;
                    end

                    // ---- drive AXI W channel ----
                    m_axi_wdata  <= {pat_pixel_q2, pat_pixel_q2};
                    m_axi_wstrb  <= dw_wstrb;
                    m_axi_wlast  <= (dma_beat_cnt_q == dma_burst_beats_q - 5'd1);
                    m_axi_wvalid <= 1'b1;

                    // ---- update tracking on W ready ----
                    if (m_axi_wready) begin
                        // Decrement remaining useful pixels
                        if (dma_beat_cnt_q == 4'd0 && dma_head_q && dma_head_pad_q) begin
                            dma_burst_px_q <= dma_burst_px_q - 6'd1;
                            dma_head_q <= 1'b0;   // head pad consumed for this row
                        end else if (dma_burst_px_q >= 6'd2) begin
                            dma_burst_px_q <= dma_burst_px_q - 6'd2;
                        end else begin
                            dma_burst_px_q <= 6'd0;
                        end

                        if (dma_beat_cnt_q == dma_burst_beats_q - 5'd1) begin
                            state <= S_DMA_B;
                        end else begin
                            dma_beat_cnt_q <= dma_beat_cnt_q + 4'd1;
                        end
                    end
                end

                // ============================================================
                // S_DMA_B — wait for BVALID (write response)
                //
                // On completion, either advance to next row (S_DMA_AW with
                // dma_head_q=1) or finish (S_DONE).  dma_rem_row_px_q was
                // decremented in S_DMA_AW; when ==0 the row is complete.
                // ============================================================
                S_DMA_B: begin
                    if (m_axi_bvalid) begin
                        if (dma_rem_row_px_q == 16'd0) begin
                            // Row complete
                            if (dma_rem_rows_q <= 16'd1) begin
                                dma_rem_rows_q <= 16'd0;
                                state <= S_DONE;
                            end else begin
                                dma_rem_rows_q   <= dma_rem_rows_q - 16'd1;
                                dma_rem_row_px_q <= dst_w_q;
                                dma_head_q       <= 1'b1;
                                dma_next_q       <= dma_next_q
                                                   + 32'd8192
                                                   - {14'd0, dst_w_q, 2'd0};
                                state <= S_DMA_AW;
                            end
                        end else begin
                            // More pixels in this row
                            state <= S_DMA_AW;
                        end
                    end
                end

                // ============================================================
                // L_INIT — compute Bresenham parameters from latched registers
                //
                //   dx = |dst_w_q|, dy = |dst_h_q|
                //   sx = sign(dst_w_q), sy = sign(dst_h_q)
                //   err = dx - dy
                //   line_x/y = start point, x/y_end = start + delta
                // ============================================================
                L_INIT: begin
                    // Absolute values and sign bits (sx/sy: 1 = positive)
                    line_dx    <= (dst_w_q[15]) ? ~dst_w_q + 16'd1 : dst_w_q;
                    line_dy    <= (dst_h_q[15]) ? ~dst_h_q + 16'd1 : dst_h_q;
                    line_sx    <= ~dst_w_q[15];
                    line_sy    <= ~dst_h_q[15];
                    line_x     <= dst_x_q;
                    line_y     <= dst_y_q;
                    line_x_end <= dst_x_q + dst_w_q;
                    line_y_end <= dst_y_q + dst_h_q;
                    line_err   <= 17'(dst_w_q[15] ? ~dst_w_q + 16'd1 : dst_w_q)
                                - 17'(dst_h_q[15] ? ~dst_h_q + 16'd1 : dst_h_q);

                    burst_len         <= 5'd0;
                    beat_lo_filled    <= 1'b0;
                    burst_nonzero_mask <= 1'b0;

                    state <= L_ACCUM;
                end

                // ============================================================
                // L_ACCUM — BRAM read latency slot
                //
                // cx/cy were already set by L_INIT (first pixel) or L_STEP
                // (subsequent pixels).  The BRAM captures pat_addr_rd at this
                // posedge; pat_pixel_q will be valid one cycle later for L_PLOT.
                // Also pre-compute the 8-byte-aligned AXI write address.
                // ============================================================
                L_ACCUM: begin
                    line_pix_addr <= FB_BASE
                                   + (32'(line_y) << 13)
                                   + (32'(line_x) << 2);
                    state <= L_PLOT;
                end

                // ============================================================
                // L_PLOT — pat_pixel_q valid (BRAM read from L_ACCUM cycle)
                //
                // Three paths:
                //   (a) blend_mode_q && 0 < pat alpha < 255 && !line_use_blend_q:
                //       issue an AXI read for the destination pixel and detour
                //       through BL_RACC* (4-stage blend pipeline shared with
                //       rect-fill).  BL_RACC_BLEND2 sets line_use_blend_q and
                //       returns to L_PLOT.
                //   (b) line_use_blend_q: write bl_blend_q (always full strb).
                //   (c) opaque / transparent / no-blend: write pat_pixel_q with
                //       px_strb (alpha-derived).
                //
                // For (b) and (c): single-beat AXI write (awlen=0), awaddr
                // 8-byte aligned, pixel in low half if line_pix_addr[2]==0.
                // Go to S_B via L_PLOT_W to wait for B response.
                // ============================================================
                L_PLOT: begin
                    if (blend_mode_q && !line_use_blend_q
                        && pat_pixel_q[7:0] != 8'd0
                        && pat_pixel_q[7:0] != 8'd255) begin
                        // (a) partial-alpha: read dest, blend, come back here
                        bl_src_pixel_q <= pat_pixel_q;
                        m_axi_araddr   <= line_pix_addr;
                        m_axi_arlen    <= 8'd0;
                        m_axi_arsize   <= 3'b010;
                        m_axi_arburst  <= 2'b01;
                        m_axi_arvalid  <= 1'b1;
                        bl_read_high_half_q <= line_pix_addr[2];
                        state <= BL_RACC;
                    end else begin
                        // (b)/(c) write path
                        logic [31:0] px;
                        logic [3:0]  st;
                        px = line_use_blend_q ? bl_blend_q : pat_pixel_q;
                        st = line_use_blend_q ? 4'hF       : px_strb;

                        m_axi_awaddr  <= {line_pix_addr[31:3], 3'b000};
                        m_axi_awlen   <= 8'd0;
                        m_axi_awsize  <= 3'b011;
                        m_axi_awburst <= 2'b01;
                        m_axi_awvalid <= 1'b1;

                        if (line_pix_addr[2] == 1'b0) begin
                            m_axi_wdata <= {32'd0, px};
                            m_axi_wstrb <= {4'h0, st};
                        end else begin
                            m_axi_wdata <= {px, 32'd0};
                            m_axi_wstrb <= {st, 4'h0};
                        end
                        m_axi_wlast  <= 1'b1;
                        m_axi_wvalid <= 1'b1;

                        line_use_blend_q <= 1'b0;
                        state <= L_PLOT_W;
                    end
                end

                // ============================================================
                // L_PLOT_W — hold AXI write signals one cycle
                //
                // The one-shot defaults at the top of this always_ff block
                // cleared awvalid/wvalid/wlast to 0.  Re-assert them so the
                // slave can sample the transaction on this cycle.  wdata/wstrb
                // are untouched by the defaults so they persist from L_PLOT.
                // ============================================================
                L_PLOT_W: begin
                    m_axi_awvalid <= 1'b1;
                    m_axi_wvalid  <= 1'b1;
                    m_axi_wlast   <= 1'b1;
                    state <= S_B;
                end

                // ============================================================
                // L_STEP — Bresenham step, cycle 1: register step flags.
                //
                // Runs AFTER the AXI write for the current pixel has completed
                // (we arrive here from S_B via line_mode_q routing).
                //
                // Bresenham:
                //   e2 = 2 * err
                //   step_x if e2 > -dy    → err -= dy,  x += sx
                //   step_y if e2 <  dx    → err += dx,  y += sy
                //
                // Split into two cycles (v0.17) to fit clk_sys=150 MHz:
                //   L_STEP : capture {bstep_y,bstep_x} from line_err into
                //            line_step_q (~4 CARRY4s of be2→bstep compares).
                //   L_STEP2: apply the registered flags to update
                //            line_err/line_x/line_y/cx/cy (~5 CARRY4s).
                // ============================================================
                L_STEP: begin
                    if (line_x == line_x_end && line_y == line_y_end) begin
                        state <= S_DONE;
                    end else begin
                        line_step_q <= {bstep_y, bstep_x};
                        state <= L_STEP2;
                    end
                end

                // ============================================================
                // L_STEP2 — Bresenham step, cycle 2: apply registered flags.
                //
                // line_step_q[0] = bstep_x, line_step_q[1] = bstep_y.
                // berr_delta_q reuses the registered flags so the be2→bstep
                // compare chain stays in L_STEP and L_STEP2 sees only the
                // shorter line_err+delta and cx subtract paths.
                // ============================================================
                L_STEP2: begin
                    line_err <= line_err + berr_delta_q;

                    if (line_step_q[0]) begin
                        if (line_sx) line_x <= line_x + 16'd1;
                        else         line_x <= line_x - 16'd1;
                    end
                    if (line_step_q[1]) begin
                        if (line_sy) line_y <= line_y + 16'd1;
                        else         line_y <= line_y - 16'd1;
                    end

                    cx <= (line_x + (line_step_q[0] ? (line_sx ? 16'd1 : -16'd1) : 16'd0))
                        - dst_x_q;
                    cy <= (line_y + (line_step_q[1] ? (line_sy ? 16'd1 : -16'd1) : 16'd0))
                        - dst_y_q;

                    state <= L_ACCUM;
                end

                // ============================================================
                // Block blit
                // ============================================================

                // ============================================================
                // BL_READ — issue AR for source segment
                //
                // Compute segment size: up to 32 pixels (= 16 beats).  The
                // source address is 8-byte-aligned from (src_x_q + cx).
                // arsize=3 (8 bytes/beat), arburst=INCR.
                // Clear burst_len for the incoming R beats.
                // ============================================================
                BL_READ: begin
                    seg_cx <= cx;
                    seg_cy <= cy;
                    burst_len <= 5'd0;

                    if (cx < dst_w_q) begin
                        if (cx + 32 <= dst_w_q) begin
                            // Full segment: 32 pixels = 16 beats
                            m_axi_araddr  <= {bl_src_raw_addr[31:3], 3'b000};
                            m_axi_arlen   <= 8'd15;
                            bl_arlen_q    <= 8'd15;
                        end else begin
                            // Last (partial) segment.  Even width means
                            // remaining = 2,4,6..30 pixels -> beats = 1..15.
                            m_axi_araddr  <= {bl_src_raw_addr[31:3], 3'b000};
                            m_axi_arlen   <= ((dst_w_q - cx) >> 1) - 8'd1;
                            bl_arlen_q    <= ((dst_w_q - cx) >> 1) - 8'd1;
                        end
                        m_axi_arsize  <= 3'b011;
                        m_axi_arburst <= 2'b01;
                        m_axi_arvalid <= 1'b1;
                        state <= BL_RWAIT;
                    end else begin
                        // Row already complete - should not happen (S_B
                        // checks before transitioning here).
                        state <= S_DONE;
                    end
                end

                // ============================================================
                // BL_RWAIT - receive R beats into burst buffer
                //
                // Each R beat is one 64-bit value = 2 RGBA-8888 pixels.
                // Store in burst_data with wstrb=8'hFF (all bytes valid).
                // For raster op 12 (~SRC), invert all 8 bytes on the fly.
                // When rlast arrives, either go to BL_DREAD (if destination
                // data is needed for combine) or to S_PEND to flush writes.
                // ============================================================
                BL_RWAIT: begin
                    m_axi_rready <= 1'b1;

                    if (m_axi_rvalid) begin
                        // Source transform: op 12 = ~SRC (invert all bytes)
                        if (raster_op_q == 4'd12) begin
                            burst_data[burst_len] <= ~m_axi_rdata;
                        end else begin
                            burst_data[burst_len] <= m_axi_rdata;
                        end
                        burst_strb[burst_len] <= 8'hFF;
                        burst_nonzero_mask <= 1'b1;

                        if (m_axi_rlast) begin
                            burst_len <= burst_len + 5'd1;
                            if (bl_need_dst) begin
                                // Need destination data for combine
                                state <= BL_DREAD;
                            end else begin
                                // Source-only op (3,12,15) — flush writes
                                state <= S_PEND;
                            end
                        end else begin
                            burst_len <= burst_len + 5'd1;
                        end
                    end
                end

                // ============================================================
                // BL_DREAD — issue AR for destination segment
                //
                // Reads the destination segment that corresponds to the same
                // (seg_cx, seg_cy) position as the source.  Uses the same
                // segment size (bl_arlen_q) as the source read.  Burst_len
                // is reset to 0 so BL_DRWAIT can reuse it as the beat index.
                // ============================================================
                BL_DREAD: begin
                    m_axi_araddr  <= {seg_raw_addr[31:3], 3'b000};
                    m_axi_arlen   <= bl_arlen_q;
                    m_axi_arsize  <= 3'b011;       // 8 bytes/beat
                    m_axi_arburst <= 2'b01;         // INCR
                    m_axi_arvalid <= 1'b1;
                    burst_len     <= 5'd0;          // reuse for dest beat index
                    state <= BL_DRWAIT;
                end

                // ============================================================
                // BL_DRWAIT — receive destination beats, combine with source
                //
                // For each destination R beat, combines the source byte
                // (already in burst_data[burst_len]) with the destination
                // byte (from m_axi_rdata) using raster_op_q, and stores the
                // result back in burst_data[burst_len].  The raster op is
                // applied byte-wise to all 8 byte lanes of the 64-bit beat.
                // On rlast, transition to S_PEND for the write burst.
                // ============================================================
                BL_DRWAIT: begin
                    m_axi_rready <= 1'b1;

                    if (m_axi_rvalid) begin
                        // Byte-wise raster-op combine across all 8 lanes.
                        // Plain case (not unique) to avoid synthesis warnings.
                        for (int bi = 0; bi < 8; bi++) begin
                            case (raster_op_q)
                                4'd0:  burst_data[burst_len][bi*8+:8] <= 8'd0;
                                4'd1:  burst_data[burst_len][bi*8+:8] <= burst_data[burst_len][bi*8+:8] & m_axi_rdata[bi*8+:8];
                                4'd2:  burst_data[burst_len][bi*8+:8] <= burst_data[burst_len][bi*8+:8] & ~m_axi_rdata[bi*8+:8];
                                4'd3:  ; // SRC — already in burst_data
                                4'd4:  burst_data[burst_len][bi*8+:8] <= ~burst_data[burst_len][bi*8+:8] & m_axi_rdata[bi*8+:8];
                                4'd5:  burst_data[burst_len][bi*8+:8] <= m_axi_rdata[bi*8+:8]; // DST
                                4'd6:  burst_data[burst_len][bi*8+:8] <= burst_data[burst_len][bi*8+:8] ^ m_axi_rdata[bi*8+:8];
                                4'd7:  burst_data[burst_len][bi*8+:8] <= burst_data[burst_len][bi*8+:8] | m_axi_rdata[bi*8+:8];
                                4'd8:  burst_data[burst_len][bi*8+:8] <= ~(burst_data[burst_len][bi*8+:8] | m_axi_rdata[bi*8+:8]);
                                4'd9:  burst_data[burst_len][bi*8+:8] <= ~(burst_data[burst_len][bi*8+:8] ^ m_axi_rdata[bi*8+:8]);
                                4'd10: burst_data[burst_len][bi*8+:8] <= ~m_axi_rdata[bi*8+:8];
                                4'd11: burst_data[burst_len][bi*8+:8] <= ~(burst_data[burst_len][bi*8+:8] & m_axi_rdata[bi*8+:8]);
                                4'd12: burst_data[burst_len][bi*8+:8] <= ~burst_data[burst_len][bi*8+:8]; // ~SRC
                                4'd13: burst_data[burst_len][bi*8+:8] <= ~burst_data[burst_len][bi*8+:8] | m_axi_rdata[bi*8+:8];
                                4'd14: burst_data[burst_len][bi*8+:8] <= ~(burst_data[burst_len][bi*8+:8] & ~m_axi_rdata[bi*8+:8]);
                                4'd15: ; // SRC — already in burst_data
                                default: ;
                            endcase
                        end
                        burst_strb[burst_len] <= 8'hFF;  // all bytes valid after combine

                        if (m_axi_rlast) begin
                            burst_len <= burst_len + 5'd1;
                            state <= S_PEND;
                        end else begin
                            burst_len <= burst_len + 5'd1;
                        end
                    end
                end

                // ============================================================
                // Scaled blit — nearest-neighbour
                // ============================================================

                // ============================================================
                // SC_ROW — start new destination row, compute source Y
                //
                // Reset column state and compute sy for this destination row
                // using Bresenham-like Y-stepping.  The first row (cy==0)
                // maps directly to src_y_q.  Subsequent rows add src_h_q to
                // sy_accum and advance sy_cur when sy_accum >= dst_h_q.
                // ============================================================
                SC_ROW: begin
                    cx <= 16'd0;
                    sx_step_q   <= 16'd0;
                    sx_accum_q  <= 16'd0;
                    sc_pixel_valid_q <= 1'b0;
                    beat_lo_filled   <= 1'b0;
                    burst_len         <= 5'd0;
                    burst_nonzero_mask <= 1'b0;

                    if (cy == 16'd0) begin
                        // First row: source Y = src_y_q
                        sy_cur_q  <= src_y_q;
                        sy_accum_q <= 16'd0;
                        if (bilin_mode_q)
                            state <= SC_BL_RD;
                        else
                            state <= SC_CALC;
                    end else begin
                        sy_accum_q <= sy_accum_q + src_h_q;
                        state <= SC_ROW2;
                    end
                end

                // ============================================================
                // SC_ROW2 — finish sy advance (may loop for downscale)
                // ============================================================
                SC_ROW2: begin
                    if (sy_accum_q >= dst_h_q) begin
                        sy_cur_q   <= sy_cur_q + 16'd1;
                        sy_accum_q <= sy_accum_q - dst_h_q;
                        // Stay in SC_ROW2 to check again
                    end else begin
                        if (bilin_mode_q)
                            state <= SC_BL_RD;
                        else
                            state <= SC_CALC;
                    end
                end

                // ============================================================
                // SC_CALC — compute source address, check cache, issue AR
                //
                // Compute the source pixel address from (src_x_q + sx_step_q,
                // sy_cur_q).  If the cached pixel covers this address, go
                // directly to SC_ACCUM.  Otherwise issue a single-beat AXI
                // read (arsize=3'b010, 4 bytes — one RGBA-8888 pixel).
                // ============================================================
                SC_CALC: begin
                    if (cx >= dst_w_q) begin
                        // Row complete — flush any pending pixels
                        state <= S_PEND;
                    end else begin
                        // Source address for this destination pixel
                        sc_raddr_q <= FB_BASE
                                    + (32'(sy_cur_q) << 13)
                                    + (32'(src_x_q + sx_step_q) << 2);

                        if (sc_pixel_valid_q && sc_pixel_addr_q == sc_raddr_q) begin
                            // Cache hit — pixel already in sc_pixel_q
                            state <= SC_ACCUM;
                        end else begin
                            // Cache miss — issue single-beat AXI read (4 bytes)
                            m_axi_araddr  <= sc_raddr_q;
                            m_axi_arlen   <= 8'd0;
                            m_axi_arsize  <= 3'b010;   // 4 bytes
                            m_axi_arburst <= 2'b01;    // INCR
                            m_axi_arvalid <= 1'b1;
                            state <= SC_READ;
                        end
                    end
                end

                // ============================================================
                // SC_READ — wait for AXI R data
                // ============================================================
                SC_READ: begin
                    m_axi_rready <= 1'b1;

                    if (m_axi_rvalid) begin
                        // 4-byte read returns pixel in lower 32 bits
                        sc_pixel_q <= m_axi_rdata[31:0];

                        sc_pixel_addr_q  <= sc_raddr_q;
                        sc_pixel_valid_q <= 1'b1;
                        state <= SC_ACCUM;
                    end
                end

                // ============================================================
                // SC_ACCUM — accumulate pixel into burst buffer
                //
                // Places sc_pixel_q into the correct half of a 64-bit beat.
                // When sc_blend_q is set, checks the source pixel's alpha:
                //   α=0   → skip (wstrb=0, preserves burst-buffer consistency)
                //   α=255 → write opaque (current fast path)
                //   0<α<255 → save pixel, issue dest read, go to SC_SBLEND
                // After accumulation or skip, transitions to SC_NEXT.
                // ============================================================
                SC_ACCUM: begin
                    // Helper: byte-strobe is 0 when sc_blend_q and source alpha
                    // is 0 (transparent pixel); otherwise 4'hF (opaque).
                    // Declared as automatic logic to avoid wire-in-block issues.
                    logic [3:0] sc_strb;
                    sc_strb = (sc_blend_q && sc_pixel_q[7:0] == 8'd0) ? 4'h0 : 4'hF;

                    if (sc_blend_q && sc_pixel_q[7:0] != 8'd0
                                  && sc_pixel_q[7:0] != 8'd255) begin
                        // ---- Partial-alpha: dest read + blend ------------------
                        bl_src_pixel_q <= sc_pixel_q;
                        bl_px_low_q    <= (dst_x_q[0] == cx[0]);
                        m_axi_araddr   <= FB_BASE
                                        + (32'(dst_y_q + cy) << 13)
                                        + (32'(dst_x_q + cx) << 2);
                        m_axi_arlen    <= 8'd0;
                        m_axi_arsize   <= 3'b010;
                        m_axi_arburst  <= 2'b01;
                        m_axi_arvalid  <= 1'b1;
                        bl_read_high_half_q <= ~(dst_x_q[0] == cx[0]);
                        state <= SC_SBLEND;
                        // Note: cx NOT incremented here — SC_SBLEND handles cx
                        // advance after the blend/accumulate.

                    end else if ((dst_x_q[0] == cx[0])) begin
                        // ---- Even global X → low half (byte lanes 3:0) --------
                        beat_lo        <= sc_pixel_q;
                        beat_strb_lo   <= sc_strb;
                        beat_lo_filled <= 1'b1;
                        if (cx + 16'd1 >= dst_w_q)
                            sc_need_flush_q <= 1'b1;
                        else
                            sc_need_flush_q <= 1'b0;
                        cx <= cx + 16'd1;
                        state <= SC_NEXT;

                    end else if (beat_lo_filled) begin
                        // ---- Odd X with partner — commit full beat -------------
                        burst_data[burst_len] <= {sc_pixel_q, beat_lo};
                        burst_strb[burst_len] <= {sc_strb, beat_strb_lo};
                        if (sc_strb != 4'h0 || beat_strb_lo != 4'h0)
                            burst_nonzero_mask <= 1'b1;
                        beat_lo_filled      <= 1'b0;
                        if (burst_len == 5'd15) begin
                            burst_len <= 5'd16;
                            sc_need_flush_q <= 1'b1;
                        end else if (cx + 16'd1 >= dst_w_q) begin
                            burst_len <= burst_len + 5'd1;
                            sc_need_flush_q <= 1'b1;
                        end else begin
                            burst_len <= burst_len + 5'd1;
                            sc_need_flush_q <= 1'b0;
                        end
                        cx <= cx + 16'd1;
                        state <= SC_NEXT;

                    end else begin
                        // ---- Orphaned odd pixel (started on odd X) -------------
                        burst_data[burst_len] <= {sc_pixel_q, 32'd0};
                        burst_strb[burst_len] <= {sc_strb, 4'h0};
                        if (sc_strb != 4'h0)
                            burst_nonzero_mask <= 1'b1;
                        if (burst_len == 5'd15) begin
                            burst_len <= 5'd16;
                            sc_need_flush_q <= 1'b1;
                        end else if (cx + 16'd1 >= dst_w_q) begin
                            burst_len <= burst_len + 5'd1;
                            sc_need_flush_q <= 1'b1;
                        end else begin
                            burst_len <= burst_len + 5'd1;
                            sc_need_flush_q <= 1'b0;
                        end
                        cx <= cx + 16'd1;
                        state <= SC_NEXT;
                    end
                end

                // ============================================================
                // SC_NEXT — update sx_accum for next pixel
                //
                // Add src_w_q to the Bresenham X accumulator.  If the result
                // is >= dst_w_q, advance sx_step and wrap around.
                // ============================================================
                SC_NEXT: begin
                    sx_accum_q <= sx_accum_q + src_w_q;
                    state <= SC_NEXT2;
                end

                // ============================================================
                // SC_NEXT2 — finish sx advance (may loop for downscale)
                //
                // Check if the new sx_accum >= dst_w_q; if so, step sx_step
                // and subtract dst_w_q (repeat until sx_accum < dst_w_q).
                // When done, either flush (if buffer is full or row end) or
                // return to SC_CALC for the next pixel.
                // ============================================================
                SC_NEXT2: begin
                    if (sx_accum_q >= dst_w_q) begin
                        sx_step_q  <= sx_step_q + 16'd1;
                        sx_accum_q <= sx_accum_q - dst_w_q;
                        // Stay in SC_NEXT2 to check again
                    end else begin
                        // SX advance complete — decide next state
                        if (sc_need_flush_q) begin
                            sc_need_flush_q <= 1'b0;
                            state <= S_PEND;
                        end else begin
                            if (bilin_mode_q)
                                state <= SC_BL_RD;
                            else
                                state <= SC_CALC;
                        end
                    end
                end

                // ============================================================
                // Bilinear scaled blit
                // ============================================================

                // ============================================================
                // SC_BL_RD — issue single-beat AR for one sub-pixel
                //
                // bl_sub_q selects which of the four 2×2 tap pixels to fetch:
                //   0 → P00 (sx_int,     sy_int)
                //   1 → P10 (sx_int + 1, sy_int)
                //   2 → P01 (sx_int,     sy_int + 1)
                //   3 → P11 (sx_int + 1, sy_int + 1)
                // where sx_int = src_x_q + sx_step_q, sy_int = sy_cur_q.
                // Each read is a single 4-byte beat (arsize=3'b010).
                // ============================================================
                SC_BL_RD: begin
                    if (cx >= dst_w_q) begin
                        // Row complete — flush any pending pixels
                        state <= S_PEND;
                    end else begin
                        unique case (bl_sub_q)
                            2'd0: m_axi_araddr <= FB_BASE
                                                 + (32'(sy_cur_q) << 13)
                                                 + (32'(src_x_q + sx_step_q) << 2);
                            2'd1: m_axi_araddr <= FB_BASE
                                                 + (32'(sy_cur_q) << 13)
                                                 + (32'(src_x_q + sx_step_q + 16'd1) << 2);
                            2'd2: m_axi_araddr <= FB_BASE
                                                 + (32'(sy_cur_q + 16'd1) << 13)
                                                 + (32'(src_x_q + sx_step_q) << 2);
                            2'd3: m_axi_araddr <= FB_BASE
                                                 + (32'(sy_cur_q + 16'd1) << 13)
                                                 + (32'(src_x_q + sx_step_q + 16'd1) << 2);
                        endcase
                        m_axi_arlen   <= 8'd0;
                        m_axi_arsize  <= 3'b010;   // 4 bytes
                        m_axi_arburst <= 2'b01;    // INCR
                        m_axi_arvalid <= 1'b1;
                        state <= SC_BL_W;
                    end
                end

                // ============================================================
                // SC_BL_W — wait for R data, latch into correct pixel register
                //
                // When data arrives, store it in p00_q/p10_q/p01_q/p11_q
                // according to bl_sub_q.  If this was the last of the four
                // reads (bl_sub_q==3), transition to weight computation.
                // Otherwise increment bl_sub_q and go back to SC_BL_RD.
                // ============================================================
                SC_BL_W: begin
                    m_axi_rready <= 1'b1;

                    if (m_axi_rvalid) begin
                        unique case (bl_sub_q)
                            2'd0: p00_q <= m_axi_rdata[31:0];
                            2'd1: p10_q <= m_axi_rdata[31:0];
                            2'd2: p01_q <= m_axi_rdata[31:0];
                            2'd3: p11_q <= m_axi_rdata[31:0];
                        endcase

                        if (bl_sub_q == 2'd3) begin
                            // All four tap pixels received
                            bl_sub_q <= 2'd0;
                            state <= SC_BL_WT;
                        end else begin
                            bl_sub_q <= bl_sub_q + 2'd1;
                            state <= SC_BL_RD;
                        end
                    end
                end

                // ============================================================
                // SC_BL_WT — compute 8-bit fractional weights via sequential
                //            divider (8 cycles)
                //
                // Implements restoring division for:
                //   fx8 = (sx_accum_q << 8) / dst_w_q  (8-bit fraction)
                //   fy8 = (sy_accum_q << 8) / dst_h_q
                //
                // Each cycle: shift remainder left, compare with divisor,
                // set quotient bit if remainder >= divisor, subtract.
                // Parallel computation of fx8 and fy8 (same hardware cost).
                // ============================================================
                SC_BL_WT: begin
                    if (bl_div_cycle_q == 4'd0) begin
                        // Cycle 0: initialize remainder = dividend
                        bl_rem_x_q[15:0] <= sx_accum_q;
                        bl_rem_y_q[15:0] <= sy_accum_q;
                        bl_fx8_q   <= 8'd0;
                        bl_fy8_q   <= 8'd0;
                        bl_div_cycle_q <= 4'd1;
                    end else if (bl_div_cycle_q <= 4'd8) begin
                        // Cycles 1..8: shift-and-compare iteration
                        logic [16:0] rem_x_sh;
                        logic [16:0] rem_y_sh;
                        logic        bit_x;
                        logic        bit_y;
                        rem_x_sh = {bl_rem_x_q[15:0], 1'b0};
                        rem_y_sh = {bl_rem_y_q[15:0], 1'b0};
                        bit_x    = (rem_x_sh >= {1'b0, dst_w_q});
                        bit_y    = (rem_y_sh >= {1'b0, dst_h_q});

                        bl_rem_x_q[15:0] <= bit_x ? (rem_x_sh[15:0] - dst_w_q) : rem_x_sh[15:0];
                        bl_rem_y_q[15:0] <= bit_y ? (rem_y_sh[15:0] - dst_h_q) : rem_y_sh[15:0];
                        bl_fx8_q <= {bl_fx8_q[6:0], bit_x};
                        bl_fy8_q <= {bl_fy8_q[6:0], bit_y};
                        bl_div_cycle_q <= bl_div_cycle_q + 4'd1;
                    end else begin
                        // Cycle 9: divider done — proceed to blend + accumulate
                        bl_div_cycle_q <= 4'd0;
                        state <= SC_BL_ACC;
                    end
                end

                // ============================================================
                // SC_BL_ACC — bilinear blend / pipeline stage 1 (weight compute)
                //
                // Compute the four 8-bit bilinear weights (w00..w11) from
                // the fractional pixel positions fx8/fy8 and register them.
                // The actual blend multiply-accumulate is deferred to
                // SC_BL_BLEND (stage 2) so neither path exceeds ~7 logic levels
                // at 150 MHz.
                //
                //   w00 = (256-fx8)*(256-fy8) >> 8    (top-left contribution)
                //   w10 = (fx8)*(256-fy8) >> 8        (top-right)
                //   w01 = (256-fx8)*(fy8) >> 8        (bottom-left)
                //   w11 = (fx8)*(fy8) >> 8            (bottom-right)
                //
                // Source pixels p00..p11 were loaded in SC_BL_W and remain
                // stable through SC_BL_ACC → SC_BL_BLEND → SC_BL_ACC2.
                // ============================================================
                SC_BL_ACC: begin
                    // Combinational temps for bilinear weight calc.
                    // Inlined rather than declared with `automatic`/
                    // `static` to stay portable across both Vivado
                    // synth (which demands an explicit lifetime on
                    // initialised case-item-local logic — Synth
                    // 8-10180) and iverilog 13.0 (which doesn't yet
                    // support overriding default variable lifetime).
                    bl_w00_q <= ((9'd256 - {1'b0, bl_fx8_q})
                                 * (9'd256 - {1'b0, bl_fy8_q})) >> 8;
                    bl_w10_q <= ({1'b0, bl_fx8_q}
                                 * (9'd256 - {1'b0, bl_fy8_q})) >> 8;
                    bl_w01_q <= ((9'd256 - {1'b0, bl_fx8_q})
                                 * {1'b0, bl_fy8_q}) >> 8;
                    bl_w11_q <= ({1'b0, bl_fx8_q}
                                 * {1'b0, bl_fy8_q}) >> 8;

                    state <= SC_BL_BLEND;
                end

                // ============================================================
                // SC_BL_BLEND — bilinear blend / pipeline stage 2 (blend)
                //
                // 2×2 weighted blend of p00/p10/p01/p11 using the registered
                // weights from SC_BL_ACC.  Result registered in bl_pixel_q;
                // SC_BL_ACC2 handles burst-buffer write / dest-read dispatch.
                //
                // Separating weight computation (SC_BL_ACC) from blend
                // multiply-accumulate (SC_BL_BLEND) breaks the critical path
                // bl_fx8_q → 8× CARRY4 + 6× LUT → bl_pixel_q that exceeded
                // 6.667 ns at 150 MHz with the full PS BD clock tree.
                // ============================================================
                SC_BL_BLEND: begin
                    logic [15:0] r_blend;
                    logic [15:0] g_blend;
                    logic [15:0] b_blend;
                    logic [15:0] a_blend;
                    r_blend = p00_q[31:24] * bl_w00_q + p10_q[31:24] * bl_w10_q
                            + p01_q[31:24] * bl_w01_q + p11_q[31:24] * bl_w11_q;
                    g_blend = p00_q[23:16] * bl_w00_q + p10_q[23:16] * bl_w10_q
                            + p01_q[23:16] * bl_w01_q + p11_q[23:16] * bl_w11_q;
                    b_blend = p00_q[15:8]  * bl_w00_q + p10_q[15:8]  * bl_w10_q
                            + p01_q[15:8]  * bl_w01_q + p11_q[15:8]  * bl_w11_q;
                    a_blend = p00_q[7:0]   * bl_w00_q + p10_q[7:0]   * bl_w10_q
                            + p01_q[7:0]   * bl_w01_q + p11_q[7:0]   * bl_w11_q;

                    bl_pixel_q[31:24] <= r_blend[15:8];
                    bl_pixel_q[23:16] <= g_blend[15:8];
                    bl_pixel_q[15:8]  <= b_blend[15:8];
                    bl_pixel_q[7:0]   <= a_blend[15:8];

                    state <= SC_BL_ACC2;
                end

                // ============================================================
                // SC_BL_ACC2 — bilinear blend / pipeline stage 3 (burst write)
                //
                // Uses bl_pixel_q (registered in SC_BL_BLEND) to write into
                // the burst buffer or dispatch a destination read for
                // partial-alpha blending.  All control signals (cx,
                // beat_lo_filled, etc.) are already registered from prior
                // states so no additional pipeline delay is incurred.
                // ============================================================
                SC_BL_ACC2: begin
                    logic [7:0]  bl_pixel_a;
                    logic [31:0] bl_pixel;
                    bl_pixel_a = bl_pixel_q[7:0];
                    bl_pixel   = bl_pixel_q;

                    // ---- Alpha-aware dispatch (when sc_blend_q is set) ---------
                    if (sc_blend_q && bl_pixel_a != 8'd0 && bl_pixel_a != 8'd255) begin
                        // Partial alpha: read destination, blend, accumulate
                        bl_src_pixel_q <= bl_pixel;
                        bl_px_low_q    <= (dst_x_q[0] == cx[0]);
                        m_axi_araddr   <= FB_BASE
                                        + (32'(dst_y_q + cy) << 13)
                                        + (32'(dst_x_q + cx) << 2);
                        m_axi_arlen    <= 8'd0;
                        m_axi_arsize   <= 3'b010;
                        m_axi_arburst  <= 2'b01;
                        m_axi_arvalid  <= 1'b1;
                        bl_read_high_half_q <= ~(dst_x_q[0] == cx[0]);
                        state <= SC_SBLEND;
                        // cx NOT incremented — SC_SBLEND handles that after blend

                    end else begin
                        // Opaque (α=255), transparent (α=0), or no blend flag
                        logic [3:0] bl_strb;
                        bl_strb = (sc_blend_q && bl_pixel_a == 8'd0) ? 4'h0 : 4'hF;

                        if ((dst_x_q[0] == cx[0])) begin
                            // Even global X → low half
                            beat_lo        <= bl_pixel;
                            beat_strb_lo   <= bl_strb;
                            beat_lo_filled <= 1'b1;
                            if (cx + 16'd1 >= dst_w_q)
                                sc_need_flush_q <= 1'b1;
                            else
                                sc_need_flush_q <= 1'b0;
                            cx <= cx + 16'd1;
                            state <= SC_NEXT;

                        end else if (beat_lo_filled) begin
                            // Odd X with partner — commit full beat
                            burst_data[burst_len] <= {bl_pixel, beat_lo};
                            burst_strb[burst_len] <= {bl_strb, beat_strb_lo};
                            if (bl_strb != 4'h0 || beat_strb_lo != 4'h0)
                                burst_nonzero_mask <= 1'b1;
                            beat_lo_filled      <= 1'b0;
                            if (burst_len == 5'd15) begin
                                burst_len <= 5'd16;
                                sc_need_flush_q <= 1'b1;
                            end else if (cx + 16'd1 >= dst_w_q) begin
                                burst_len <= burst_len + 5'd1;
                                sc_need_flush_q <= 1'b1;
                            end else begin
                                burst_len <= burst_len + 5'd1;
                                sc_need_flush_q <= 1'b0;
                            end
                            cx <= cx + 16'd1;
                            state <= SC_NEXT;

                        end else begin
                            // Orphaned odd pixel
                            burst_data[burst_len] <= {bl_pixel, 32'd0};
                            burst_strb[burst_len] <= {bl_strb, 4'h0};
                            if (bl_strb != 4'h0)
                                burst_nonzero_mask <= 1'b1;
                            if (burst_len == 5'd15) begin
                                burst_len <= 5'd16;
                                sc_need_flush_q <= 1'b1;
                            end else if (cx + 16'd1 >= dst_w_q) begin
                                burst_len <= burst_len + 5'd1;
                                sc_need_flush_q <= 1'b1;
                            end else begin
                                burst_len <= burst_len + 5'd1;
                                sc_need_flush_q <= 1'b0;
                            end
                            cx <= cx + 16'd1;
                            state <= SC_NEXT;
                        end
                    end
                end

                // ============================================================
                // SC_SBLEND — scaled-blit blend: dest read, register dst
                //
                // Entered from SC_ACCUM or SC_BL_ACC2 when 0 < source alpha < 255
                // (and sc_blend_q is set).  Bl_src_pixel_q holds the source pixel,
                // bl_px_low_q holds the half-position latch.  We register
                // m_axi_rdata into bl_dst_q so the blend multiply-accumulate
                // can be computed in SC_SBLEND_BLEND from registered operands.
                //
                // Pipeline: BL_RACC (reg dst) → BL_RACC_BLEND (products) →
                //           BL_RACC_BLEND2 (combine) → BL_RACC2 (accumulate).
                // SC_SBLEND path follows the same 4-stage structure.
                // ============================================================
                SC_SBLEND: begin
                    m_axi_rready <= 1'b1;

                    if (m_axi_rvalid) begin
                        bl_dst_q <= bl_read_high_half_q ? m_axi_rdata[63:32]
                                                        : m_axi_rdata[31:0];
                        state <= SC_SBLEND_BLEND;
                    end
                end

                // ============================================================
                // SC_SBLEND_BLEND — compute src*sa and dst*inv_a products
                //
                // Same arithmetic as BL_RACC_BLEND — pipeline stage 1 of 2.
                // ============================================================
                SC_SBLEND_BLEND: begin
                    logic [7:0]  sa;
                    logic [7:0]  inv_a;
                    logic [31:0] dst;
                    sa    = bl_src_pixel_q[7:0];
                    inv_a = 8'd255 - sa;
                    dst   = bl_dst_q;

                    bl_src_prod_q[63:48] <= bl_src_pixel_q[31:24] * sa;
                    bl_src_prod_q[47:32] <= bl_src_pixel_q[23:16] * sa;
                    bl_src_prod_q[31:16] <= bl_src_pixel_q[15:8]  * sa;
                    bl_src_prod_q[15:0]  <= 16'd0;

                    bl_dst_prod_q[63:48] <= dst[31:24] * inv_a;
                    bl_dst_prod_q[47:32] <= dst[23:16] * inv_a;
                    bl_dst_prod_q[31:16] <= dst[15:8]  * inv_a;
                    bl_dst_prod_q[15:0]  <= 16'd0;

                    state <= SC_SBLEND_BLEND2;
                end

                // ============================================================
                // SC_SBLEND_BLEND2 — combine products into blended pixel
                //
                // Same arithmetic as BL_RACC_BLEND2 — pipeline stage 2 of 2.
                // ============================================================
                SC_SBLEND_BLEND2: begin
                    bl_blend_q[31:24] <= (bl_src_prod_q[63:48]
                                        + bl_dst_prod_q[63:48] + 16'd128) >> 8;
                    bl_blend_q[23:16] <= (bl_src_prod_q[47:32]
                                        + bl_dst_prod_q[47:32] + 16'd128) >> 8;
                    bl_blend_q[15:8]  <= (bl_src_prod_q[31:16]
                                        + bl_dst_prod_q[31:16] + 16'd128) >> 8;
                    bl_blend_q[7:0]   <= bl_src_pixel_q[7:0];   // preserve source alpha
                    bl_blend_valid_q  <= 1'b1;
                    state <= SC_SBLEND2;
                end

                // ============================================================
                // SC_SBLEND2 — scaled-blit blend: accumulate (cycle 2)
                //
                // Cycle 2: bl_blend_q holds the blended pixel from SC_SBLEND.
                // Accumulate into burst buffer, then transition to SC_NEXT.
                // ============================================================
                SC_SBLEND2: begin
                    bl_blend_valid_q <= 1'b0;

                    // ---- Accumulate (SC_ACCUM-style via bl_px_low_q) ---------
                    if (bl_px_low_q) begin
                        // Low half
                        beat_lo        <= bl_blend_q;
                        beat_strb_lo   <= 4'hF;
                        beat_lo_filled <= 1'b1;
                        if (cx + 16'd1 >= dst_w_q)
                            sc_need_flush_q <= 1'b1;
                        else
                            sc_need_flush_q <= 1'b0;
                    end else if (beat_lo_filled) begin
                        // Odd X with partner
                        burst_data[burst_len] <= {bl_blend_q, beat_lo};
                        burst_strb[burst_len] <= {4'hF, beat_strb_lo};
                        burst_nonzero_mask <= 1'b1;
                        beat_lo_filled      <= 1'b0;
                        if (burst_len == 5'd15) begin
                            burst_len <= 5'd16;
                            sc_need_flush_q <= 1'b1;
                        end else if (cx + 16'd1 >= dst_w_q) begin
                            burst_len <= burst_len + 5'd1;
                            sc_need_flush_q <= 1'b1;
                        end else begin
                            burst_len <= burst_len + 5'd1;
                            sc_need_flush_q <= 1'b0;
                        end
                    end else begin
                        // Orphaned odd pixel
                        burst_data[burst_len] <= {bl_blend_q, 32'd0};
                        burst_strb[burst_len] <= {4'hF, 4'h0};
                        burst_nonzero_mask <= 1'b1;
                        if (burst_len == 5'd15) begin
                            burst_len <= 5'd16;
                            sc_need_flush_q <= 1'b1;
                        end else if (cx + 16'd1 >= dst_w_q) begin
                            burst_len <= burst_len + 5'd1;
                            sc_need_flush_q <= 1'b1;
                        end else begin
                            burst_len <= burst_len + 5'd1;
                            sc_need_flush_q <= 1'b0;
                        end
                    end

                    cx <= cx + 16'd1;
                    state <= SC_NEXT;
                end

                // ============================================================
                // BL_RACC — wait for destination read data, register dst
                //
                // Destination pixel arrives on the 4-byte AXI3 read beat in
                // either m_axi_rdata[31:0] (low half, araddr[2]=0) or
                // m_axi_rdata[63:32] (high half, araddr[2]=1).  We register
                // it in bl_dst_q so the blend multiply-accumulate can be
                // pipelined across two more stages without the AXI read-
                // data distribution delay.
                //
                // Pipeline: BL_RACC (reg dst) → BL_RACC_BLEND (products) →
                //           BL_RACC_BLEND2 (combine) → BL_RACC2 (accumulate
                //           into burst buffer) or → L_PLOT (line-draw write).
                // ============================================================
                BL_RACC: begin
                    m_axi_rready <= 1'b1;

                    if (m_axi_rvalid) begin
                        bl_dst_q <= bl_read_high_half_q ? m_axi_rdata[63:32]
                                                        : m_axi_rdata[31:0];
                        state <= BL_RACC_BLEND;
                    end
                end

                // ============================================================
                // BL_RACC_BLEND — compute src*sa and dst*inv_a products
                //
                // bl_src_pixel_q (registered in S_ACCUM_W) and bl_dst_q
                // (registered in BL_RACC) are both stable.  We compute the
                // 8×8→16 products for each colour channel and register them.
                //
                // Per-channel products:  src_ch * alpha,  dst_ch * (255-alpha)
                //
                // Pipeline stage 1 of 2 (stage 2 = BL_RACC_BLEND2 combines).
                // ============================================================
                BL_RACC_BLEND: begin
                    logic [7:0]  sa;
                    logic [7:0]  inv_a;
                    logic [31:0] dst;
                    sa    = bl_src_pixel_q[7:0];   // source alpha
                    inv_a = 8'd255 - sa;
                    dst   = bl_dst_q;              // registered dest

                    bl_src_prod_q[63:48] <= bl_src_pixel_q[31:24] * sa;
                    bl_src_prod_q[47:32] <= bl_src_pixel_q[23:16] * sa;
                    bl_src_prod_q[31:16] <= bl_src_pixel_q[15:8]  * sa;
                    bl_src_prod_q[15:0]  <= 16'd0;

                    bl_dst_prod_q[63:48] <= dst[31:24] * inv_a;
                    bl_dst_prod_q[47:32] <= dst[23:16] * inv_a;
                    bl_dst_prod_q[31:16] <= dst[15:8]  * inv_a;
                    bl_dst_prod_q[15:0]  <= 16'd0;

                    state <= BL_RACC_BLEND2;
                end

                // ============================================================
                // BL_RACC_BLEND2 — combine products into blended pixel
                //
                // Pipeline stage 2 of 2: add the two 16-bit products for each
                // channel, add 128 (rounding), and right-shift by 8.
                //
                // Per-channel: (src_prod + dst_prod + 128) >> 8
                // Alpha is preserved as source alpha.
                //
                // A single 16-bit add + constant + shift per channel (~4 CARRY4
                // levels) is well within the 6.667 ns budget.
                // ============================================================
                BL_RACC_BLEND2: begin
                    bl_blend_q[31:24] <= (bl_src_prod_q[63:48]
                                        + bl_dst_prod_q[63:48] + 16'd128) >> 8;
                    bl_blend_q[23:16] <= (bl_src_prod_q[47:32]
                                        + bl_dst_prod_q[47:32] + 16'd128) >> 8;
                    bl_blend_q[15:8]  <= (bl_src_prod_q[31:16]
                                        + bl_dst_prod_q[31:16] + 16'd128) >> 8;
                    bl_blend_q[7:0]   <= bl_src_pixel_q[7:0];   // preserve source alpha
                    bl_blend_valid_q  <= 1'b1;
                    // Line-draw blend returns to L_PLOT to issue the AXI write
                    // for this pixel; rect-fill goes to BL_RACC2 to accumulate
                    // into the burst buffer.
                    if (line_mode_q) begin
                        line_use_blend_q <= 1'b1;
                        state <= L_PLOT;
                    end else begin
                        state <= BL_RACC2;
                    end
                end

                // ============================================================
                // BL_RACC2 — accumulate blended pixel into burst buffer
                //
                // Cycle 2: bl_blend_q holds the result from BL_RACC.
                // Uses the same half-beat accumulation logic as S_ACCUM_W.
                // ============================================================
                BL_RACC2: begin
                    bl_blend_valid_q <= 1'b0;

                    // ---- Accumulate into burst buffer --------------------------
                    // Mirrors the S_ACCUM_W accumulation logic using blended pixel.
                    // Use bl_px_low_q (latched before cx increment) for half
                    // positioning.
                    accum_commits_beat = 1'b0;

                    if (bl_px_low_q) begin
                        beat_lo        <= bl_blend_q;
                        beat_strb_lo   <= 4'hF;   // always opaque after blend
                        beat_lo_filled <= 1'b1;
                    end else begin
                        if (beat_lo_filled) begin
                            burst_data[burst_len] <= {bl_blend_q, beat_lo};
                            burst_strb[burst_len] <= {4'hF, beat_strb_lo};
                            burst_nonzero_mask <= 1'b1;
                            beat_lo_filled <= 1'b0;
                            accum_commits_beat = 1'b1;
                        end else begin
                            burst_data[burst_len] <= {bl_blend_q, 32'd0};
                            burst_strb[burst_len] <= {4'hF, 4'h0};
                            burst_nonzero_mask <= 1'b1;
                            accum_commits_beat = 1'b1;
                        end
                    end

                    // ---- Advance and flush check -------------------------------
                    // cx was already incremented in S_ACCUM_W before entering
                    // BL_RACC, so the current cx points to the NEXT pixel.
                    // We use cx (post-increment) for row-end detection.
                    if (accum_commits_beat) begin
                        if (burst_len == 5'd15) begin
                            burst_len <= 5'd16;
                            state <= S_PEND;
                        end else if (cx >= dst_w_q) begin
                            burst_len <= burst_len + 5'd1;
                            state <= S_PEND;
                        end else begin
                            burst_len <= burst_len + 5'd1;
                            state <= S_ACCUM;
                        end
                    end else begin
                        if (cx >= dst_w_q) begin
                            state <= S_PEND;
                        end else begin
                            state <= S_ACCUM;
                        end
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
