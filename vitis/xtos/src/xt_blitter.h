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

/* --- Command opcodes (write to XT_BL_CMD) ---------------------------- */

#define XT_BL_CMD_RECT_FILL      0x01
#define XT_BL_CMD_LINE_DRAW      0x02
#define XT_BL_CMD_BLOCK_BLIT     0x03
#define XT_BL_CMD_SCALED_BLIT    0x04
#define XT_BL_CMD_FONT_BLIT      0x06
#define XT_BL_CMD_SYNC           0x07

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

/* Spin-poll STATUS.busy until it clears or we hit timeout_us.
 * Returns 0 on idle, -1 on timeout. */
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

/* Low-level byte poke for any other register access pattern not
 * covered above. */
void xt_blitter_write8 (uint32_t offset, uint8_t  v);
uint8_t  xt_blitter_read8 (uint32_t offset);

#endif /* XT_BLITTER_H_ */
