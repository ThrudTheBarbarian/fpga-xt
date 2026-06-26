/*
 * xt_blitter.h — PS-side driver for the fpga-xt blitter.
 *
 * Pokes the AXI-Lite bridge (axi_blitter_bridge.sv) over the Zynq
 * GP0 port.  The bridge translates 32-bit AXI4-Lite cycles into the
 * byte-wide register bus the blitter shares with the SALLY CPU.
 *
 * Register map (PL-side $D4Bx/$D4Cx, byte offsets relative to
 * XT_BLITTER_BASE; see hdl/xt_blitter.sv:78-152 for the full spec):
 *
 *   0x00..0x07  DST_{X,Y,W,H}_{LO,HI}  — destination geometry
 *   0x08..0x09  PAT_PHASE_{X,Y}         — pattern phase (low 5 bits)
 *   0x0A        PAT_LOG_W               — write to set log2(pat_w)
 *   0x0B        PAT_DATA                — pattern byte, auto-advances
 *   0x0C        CMD                     — write triggers an operation
 *   0x0D        STATUS (read)           — {pat_blocked, q_full, busy}
 *   0x0E        PAT_LOG_H               — log2(pat_h)
 *   0x0F        RASTER_OP               — GEM raster op [3:0]
 *   0x10..0x17  SRC_{X,Y,W,H}_{LO,HI}   — source geometry
 *   0x18        FLAGS                   — option flags
 *   0x19/0x1A   SEQ_LO/SEQ_HI (read)    — SYNC sequence counter
 *   0x1E        FONT_DATA               — font coverage byte
 *   0x1F        FONT_CTRL                — write resets font pointer
 *
 * The bridge sits at 0x43C0_0000 in the PS BD address map (Vivado-
 * assigned slot for M_AXI_GP0's first PL slave; see ps_bd.bda).
 */

#ifndef XT_BLITTER_H_
#define XT_BLITTER_H_

#include <stdint.h>
#include <stdbool.h>

/* --- Address map ----------------------------------------------------- */

#ifndef XT_BLITTER_BASE
#define XT_BLITTER_BASE          0x43C00000u
#endif

/* $D4Bx page (offsets 0x00..0x0F) */
#define XT_BL_DST_X_LO           0x00
#define XT_BL_DST_X_HI           0x01
#define XT_BL_DST_Y_LO           0x02
#define XT_BL_DST_Y_HI           0x03
#define XT_BL_DST_W_LO           0x04
#define XT_BL_DST_W_HI           0x05
#define XT_BL_DST_H_LO           0x06
#define XT_BL_DST_H_HI           0x07
#define XT_BL_PAT_PHASE_X        0x08
#define XT_BL_PAT_PHASE_Y        0x09
#define XT_BL_PAT_LOG_W          0x0A
#define XT_BL_PAT_DATA           0x0B
#define XT_BL_CMD                0x0C
#define XT_BL_STATUS             0x0D     /* read-only */
#define XT_BL_PAT_LOG_H          0x0E
#define XT_BL_RASTER_OP          0x0F

/* $D4Cx page (offsets 0x10..0x1F) */
#define XT_BL_SRC_X_LO           0x10
#define XT_BL_SRC_X_HI           0x11
#define XT_BL_SRC_Y_LO           0x12
#define XT_BL_SRC_Y_HI           0x13
#define XT_BL_SRC_W_LO           0x14
#define XT_BL_SRC_W_HI           0x15
#define XT_BL_SRC_H_LO           0x16
#define XT_BL_SRC_H_HI           0x17
#define XT_BL_FLAGS              0x18
#define XT_BL_SEQ_LO             0x19     /* read-only */
#define XT_BL_SEQ_HI             0x1A     /* read-only */
#define XT_BL_FONT_DATA          0x1E
#define XT_BL_FONT_CTRL          0x1F

/* $D4Ex page (offsets 0x30..0x3F) — SRC_BLIT DDR surface descriptors.
 * On $D4Ex, NOT $D4Dx: $D4Dx is the sprite engine's per-sprite descriptor page,
 * and decoding it in the blitter collides A9 traffic with the native/6502
 * sprite traffic.  Global registers (latched while the blitter is idle); set
 * them before enqueuing the commands that use them, and don't change a surface
 * while commands referencing it are still draining (drain via SYNC if you must). */
#define XT_BL_SRC_BASE_0         0x30     /* SRC_BASE   byte 0 (LSB) */
#define XT_BL_SRC_BASE_1         0x31
#define XT_BL_SRC_BASE_2         0x32
#define XT_BL_SRC_BASE_3         0x33     /* SRC_BASE   byte 3 (MSB) */
#define XT_BL_SRC_STRIDE_LO      0x34     /* SRC_STRIDE bytes/row, low  */
#define XT_BL_SRC_STRIDE_HI      0x35
#define XT_BL_DST_BASE_0         0x36     /* DST_BASE   byte 0 (LSB) */
#define XT_BL_DST_BASE_1         0x37
#define XT_BL_DST_BASE_2         0x38
#define XT_BL_DST_BASE_3         0x39     /* DST_BASE   byte 3 (MSB) */
#define XT_BL_DST_STRIDE_LO      0x3A     /* DST_STRIDE bytes/row, low  */
#define XT_BL_DST_STRIDE_HI      0x3B

/* --- Drag overlay (GP0 offsets 0x21..0x2F, page 2 $D4Dx) -------------- */
/* A movable DDR-backed surface composited above the GEM desktop (depth 1)
 * but below the XL/ST windows (depth 2): shows a GEM window WHILE it is
 * being dragged, so moving it is a single x/y register write instead of
 * re-blitting it into the desktop plane each frame (tear-free).
 *
 * Protocol: set BASE/X/Y/W/H while disabled, then write OVL_EN=1 LAST — that
 * write also COMMITS the whole {x,y,w,h,en} set, which the PL adopts at the
 * next vblank (atomic, no tear).  Per drag step, update X/Y then re-write
 * OVL_EN (=1) to re-commit.  On drop, write OVL_EN=0 (commits the disable).
 *
 * The surface row stride is a FIXED PL constant (OVL_STRIDE_W words below): a
 * variable stride would synthesise a DSP multiply on the HP2 read-address path
 * and bust clk_sys.  So the PS must render the drag surface at this stride
 * (row r of column c at word r*OVL_STRIDE_W + c); only the first W columns are
 * fetched, so the padding costs memory but not bandwidth.
 * See hdl/fpga_xt_top.sv (u_plane_fetch_overlay) + hdl/axi_blitter_bridge.sv. */
#define OVL_STRIDE_W   2048u   /* overlay surface stride in 32-bit words (= 8192 B) */
#define XT_BL_OVL_EN             0x21   /* bit0 = enable; the write commits x/y/w/h */
#define XT_BL_OVL_BASE_0         0x24   /* surface DDR base, byte 0 (LSB) */
#define XT_BL_OVL_BASE_1         0x25
#define XT_BL_OVL_BASE_2         0x26
#define XT_BL_OVL_BASE_3         0x27   /* byte 3 (MSB) */
#define XT_BL_OVL_X_LO           0x28   /* on-screen origin X (12-bit) */
#define XT_BL_OVL_X_HI           0x29
#define XT_BL_OVL_Y_LO           0x2A   /* on-screen origin Y (12-bit) */
#define XT_BL_OVL_Y_HI           0x2B
#define XT_BL_OVL_W_LO           0x2C   /* surface width  (12-bit); stride = w*4 */
#define XT_BL_OVL_W_HI           0x2D
#define XT_BL_OVL_H_LO           0x2E   /* surface height (12-bit) */
#define XT_BL_OVL_H_HI           0x2F

/* --- XT register-unlock control (GP0 offset 0x20) -------------------- */
/* The A9 sets the machine's stock-vs-XT personality: each bit ungates the
 * NATIVE (6502/ANTIC-side) decode of one feature group.  The A9/bridge path
 * itself is never gated, so the desktop drives the blitter / injects keys /
 * pulses reset regardless of lock state.  Reset (PL) → 0x00 (fully locked /
 * stock).  See docs/Zynq/register-unlock.md.  Read back the EFFECTIVE value
 * (incl. any 6502 self-unlock via $D1DF) at the same offset. */
#define XT_BL_UNLOCK             0x20

#define XT_UNLOCK_ANTIC          (1u << 0)  /* $D480-$D49F ANTIC chiplet */
#define XT_UNLOCK_SPRITE         (1u << 1)  /* sprite engine $D4Ax/$D4Dx */
#define XT_UNLOCK_BLITTER        (1u << 2)  /* blitter native $D4Bx/$D4Cx + $D4CA turbo */
#define XT_UNLOCK_BANK           (1u << 3)  /* $D5C0/$D5C1 code/data bank select */
#define XT_UNLOCK_GEM            (1u << 4)  /* $D5D0-$D5D4 GEM doorbell (reserved) */
#define XT_UNLOCK_KBD            (1u << 5)  /* reserved (kbd inject is bridge-only) */

/* --- FLAGS register bits (XT_BL_FLAGS) ------------------------------- */
#define XT_BL_FLAG_BLEND         (1u << 0)  /* rect/line: alpha-blend with dest */
#define XT_BL_FLAG_BILINEAR      (1u << 1)  /* scaled blit: bilinear            */
#define XT_BL_FLAG_SRC_DDR       (1u << 2)  /* SRC_BLIT: source from SRC_BASE   */
#define XT_BL_FLAG_SRC_COV       (1u << 3)  /* SRC_BLIT: 8-bit coverage source  */
#define XT_BL_FLAG_SRC_AOVER     (1u << 4)  /* SRC_BLIT: RGBA alpha-over        */
#define XT_BL_FLAG_DST_DDR       (1u << 5)  /* SRC_BLIT: dest to DST_BASE       */

/* --- Command opcodes (write to XT_BL_CMD) ---------------------------- */

#define XT_BL_CMD_RECT_FILL      0x01
#define XT_BL_CMD_LINE_DRAW      0x02
#define XT_BL_CMD_BLOCK_BLIT     0x03
#define XT_BL_CMD_SCALED_BLIT    0x04
#define XT_BL_CMD_SYNC           0x07
#define XT_BL_CMD_SRC_BLIT       0x08     /* DDR→DDR blit (coverage/RGBA) */

/* --- STATUS register bits ------------------------------------------- */

#define XT_BL_STATUS_BUSY        (1u << 0)  /* queue non-empty OR FSM active */
#define XT_BL_STATUS_QFULL       (1u << 1)  /* next CMD write would be dropped */
#define XT_BL_STATUS_PAT_BLOCKED (1u << 2)  /* sticky: pat/font load dropped */

/* --- GEM raster ops (XT_BL_RASTER_OP[3:0]) -------------------------- */

#define XT_BL_RASTER_ZERO        0x0   /* 0 */
#define XT_BL_RASTER_S_AND_D     0x1   /* S & D */
#define XT_BL_RASTER_S_AND_NOTD  0x2   /* S & ~D */
#define XT_BL_RASTER_S           0x3   /* S */
#define XT_BL_RASTER_NOTS_AND_D  0x4   /* ~S & D */
#define XT_BL_RASTER_D           0x5   /* D */
#define XT_BL_RASTER_S_XOR_D     0x6   /* S ^ D */
#define XT_BL_RASTER_S_OR_D      0x7   /* S | D */
#define XT_BL_RASTER_NOT_SOR_D   0x8   /* ~(S | D) */
#define XT_BL_RASTER_NOT_SXOR_D  0x9   /* ~(S ^ D) */
#define XT_BL_RASTER_NOT_D       0xA   /* ~D */
#define XT_BL_RASTER_S_OR_NOTD   0xB   /* S | ~D */
#define XT_BL_RASTER_NOT_S       0xC   /* ~S */
#define XT_BL_RASTER_NOTS_OR_D   0xD   /* ~S | D */
#define XT_BL_RASTER_NOT_SAND_D  0xE   /* ~(S & D) */
#define XT_BL_RASTER_ONE         0xF   /* 1 */

/* --- API ------------------------------------------------------------- */

/* Read STATUS byte (busy / qfull / pat_blocked flags). */
uint8_t xt_blitter_status(void);

/* True if blitter is busy (queue non-empty OR FSM running). */
static inline bool xt_blitter_busy(void)
{
    return (xt_blitter_status() & XT_BL_STATUS_BUSY) != 0;
}

/* Register the blitter completion IRQ (PL IRQ_F2P[0] -> GIC ID 61) on the
 * FreeRTOS port GIC and create the wait semaphore.  Call ONCE from a task after
 * the scheduler is running.  Returns 0 on success, -1 on failure.  Until called,
 * xt_blitter_wait_idle() falls back to polling. */
int xt_blitter_irq_init(void);

/* Wait for the blitter to drain to idle, or until timeout_us elapses.
 * IRQ-driven (blocks on the completion semaphore) once xt_blitter_irq_init()
 * has run; otherwise polls STATUS.busy.  Returns 0 on idle, -1 on timeout. */
int xt_blitter_wait_idle(uint32_t timeout_us);

/* Read the 16-bit SYNC sequence counter. */
uint16_t xt_blitter_seq_counter(void);

/* Set destination rectangle (origin + size). */
void xt_blitter_set_dst(int16_t x, int16_t y, uint16_t w, uint16_t h);

/* Set source rectangle (origin + size; size only used by scaled blit). */
void xt_blitter_set_src(int16_t x, int16_t y, uint16_t w, uint16_t h);

/* Set pattern phase (low 5 bits of each). */
void xt_blitter_set_pat_phase(uint8_t px, uint8_t py);

/* Set log2 of pattern dimensions (each 0..5). */
void xt_blitter_set_pat_log(uint8_t log_w, uint8_t log_h);

/* Stream pattern bytes into the auto-advancing PAT_DATA window. */
void xt_blitter_write_pat(const uint8_t *bytes, uint32_t n);

/* Write the FLAGS register (mode/option bits — see hdl/xt_blitter.sv:139). */
void xt_blitter_set_flags(uint8_t flags);

/* Write the GEM raster op for block blit (CMD=0x03). */
void xt_blitter_set_raster_op(uint8_t op);

/* Fire a command opcode (XT_BL_CMD_*).  Caller must have configured the
 * relevant DST/SRC/PAT/FLAGS registers first; the blitter snapshots
 * them at CMD-write time into its queue entry. */
void xt_blitter_fire(uint8_t cmd);

/* Set the SRC_BLIT (CMD 0x08) source / destination DDR surfaces.  base = the
 * surface origin, stride = bytes/row, bpp = bytes/pixel (src only: 1 for an
 * 8-bit coverage source, 4 for RGBA; dst is always RGBA).  The stride is written
 * to HW here; the per-blit origin is folded into ROW0 by xt_blitter_src_blit().
 * Set once per run; don't change while commands using the surface are queued. */
void xt_blitter_set_src_surface(uint32_t base, uint16_t stride, uint8_t bpp);
void xt_blitter_set_dst_surface(uint32_t base, uint16_t stride);

/* Enqueue one SRC_BLIT: source rect (sx,sy,w,h) of the current SRC surface
 * blitted to (dx,dy) of the current DST surface, in the mode set by FLAGS
 * (SRC_DDR + SRC_COV/SRC_AOVER + DST_DDR).  Does not wait — push a whole run,
 * then xt_blitter_wait_idle() (or a SYNC) once at the end. */
void xt_blitter_src_blit(int16_t sx, int16_t sy, uint16_t w, uint16_t h,
                         int16_t dx, int16_t dy);

/* Point RECT_FILL / BLOCK_BLIT / LINE at an off-plane DDR surface: write the
 * dst (or src) descriptor base = ROW0 (= base + y0*stride + x0*4) + stride.
 * RGBA-8888 only.  Caller sets DST_X/Y (parity) + W/H + the DST_DDR/SRC_DDR
 * FLAGS bit + pattern/raster-op, then fires. */
void xt_blitter_dst_ddr_rect(uint32_t base, uint16_t stride, int16_t x0, int16_t y0);
void xt_blitter_src_ddr_rect(uint32_t base, uint16_t stride, int16_t x0, int16_t y0);

/* Set the XT register-unlock mask (offset 0x20).  Pass an OR of XT_UNLOCK_*
 * bits; 0 = bone-stock (the post-reset state).  The A9 is the authority — it
 * sets this before launching a guest (e.g. 0 for a stock cart, the needed
 * groups for an XT app). */
void xt_unlock_set(uint8_t mask);

/* Read back the EFFECTIVE unlock mask (includes any 6502 self-unlock at $D1DF). */
uint8_t xt_unlock_get(void);

/* ---- Drag overlay (compositor plane 1) -------------------------------------
 * A movable DDR-backed surface composited above the GEM desktop but below the
 * XL/ST windows (see XT_BL_OVL_* above).  The caller renders an RGBA-8888
 * surface at the fixed OVL_STRIDE_W row stride into DDR, FLUSHES it (HP2 read
 * is not cache-coherent), then calls xt_overlay_enable().  Moving is one call;
 * the PL adopts the new position at the next vblank (tear-free).  Disabling
 * commits the hide.  No plane writes happen during a move. */
void xt_overlay_enable(uint32_t base, uint16_t x, uint16_t y, uint16_t w, uint16_t h);
void xt_overlay_move(uint16_t x, uint16_t y);   /* re-position only (keeps enabled) */
void xt_overlay_disable(void);

/* Low-level byte poke for any other register access pattern not
 * covered above. */
void xt_blitter_write8 (uint32_t offset, uint8_t  v);
uint8_t  xt_blitter_read8 (uint32_t offset);

#endif /* XT_BLITTER_H_ */
