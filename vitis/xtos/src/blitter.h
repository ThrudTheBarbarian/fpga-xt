/*
 * blitter.h — PS-side driver for the fpga-xt blitter (GP0 BLITTER block).
 *
 * Register writes go to XT_BLK_BLITTER + offset, where the offset is the
 * blitter's native bl_addr ($D4Bx/$D4Cx/$D4Ex, reconstructed in the PL).  See
 * hdl/xt_blitter.sv for the register spec and xt_gp0_map.h for the block map.
 */
#ifndef BLITTER_H_
#define BLITTER_H_

#include <stdint.h>
#include <stdbool.h>
#include "xt_gp0_map.h"

/* --- Blitter register offsets (within the BLITTER block) ------------------ */
/* $D4Bx page */
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
#define XT_BL_PAT_LOG_H          0x0E
#define XT_BL_RASTER_OP          0x0F
/* $D4Cx page */
#define XT_BL_SRC_X_LO           0x10
#define XT_BL_SRC_X_HI           0x11
#define XT_BL_SRC_Y_LO           0x12
#define XT_BL_SRC_Y_HI           0x13
#define XT_BL_SRC_W_LO           0x14
#define XT_BL_SRC_W_HI           0x15
#define XT_BL_SRC_H_LO           0x16
#define XT_BL_SRC_H_HI           0x17
#define XT_BL_FLAGS              0x18
/* $D4Ex page — SRC_BLIT / off-plane DDR surface descriptors */
#define XT_BL_SRC_BASE_0         0x30
#define XT_BL_SRC_BASE_1         0x31
#define XT_BL_SRC_BASE_2         0x32
#define XT_BL_SRC_BASE_3         0x33
#define XT_BL_SRC_STRIDE_LO      0x34
#define XT_BL_SRC_STRIDE_HI      0x35
#define XT_BL_DST_BASE_0         0x36
#define XT_BL_DST_BASE_1         0x37
#define XT_BL_DST_BASE_2         0x38
#define XT_BL_DST_BASE_3         0x39
#define XT_BL_DST_STRIDE_LO      0x3A
#define XT_BL_DST_STRIDE_HI      0x3B

/* --- FLAGS register bits (XT_BL_FLAGS) ------------------------------------ */
#define XT_BL_FLAG_BLEND         (1u << 0)
#define XT_BL_FLAG_BILINEAR      (1u << 1)
#define XT_BL_FLAG_SRC_DDR       (1u << 2)
#define XT_BL_FLAG_SRC_COV       (1u << 3)
#define XT_BL_FLAG_SRC_AOVER     (1u << 4)
#define XT_BL_FLAG_DST_DDR       (1u << 5)

/* --- Command opcodes (write to XT_BL_CMD) --------------------------------- */
#define XT_BL_CMD_RECT_FILL      0x01
#define XT_BL_CMD_LINE_DRAW      0x02
#define XT_BL_CMD_BLOCK_BLIT     0x03
#define XT_BL_CMD_SCALED_BLIT    0x04
#define XT_BL_CMD_SYNC           0x07
#define XT_BL_CMD_SRC_BLIT       0x08

/* --- STATUS register bits ------------------------------------------------- */
#define XT_BL_STATUS_BUSY        (1u << 0)
#define XT_BL_STATUS_QFULL       (1u << 1)
#define XT_BL_STATUS_PAT_BLOCKED (1u << 2)

/* --- GEM raster ops (XT_BL_RASTER_OP[3:0]) -------------------------------- */
#define XT_BL_RASTER_ZERO        0x0
#define XT_BL_RASTER_S_AND_D     0x1
#define XT_BL_RASTER_S_AND_NOTD  0x2
#define XT_BL_RASTER_S           0x3
#define XT_BL_RASTER_NOTS_AND_D  0x4
#define XT_BL_RASTER_D           0x5
#define XT_BL_RASTER_S_XOR_D     0x6
#define XT_BL_RASTER_S_OR_D      0x7
#define XT_BL_RASTER_NOT_SOR_D   0x8
#define XT_BL_RASTER_NOT_SXOR_D  0x9
#define XT_BL_RASTER_NOT_D       0xA
#define XT_BL_RASTER_S_OR_NOTD   0xB
#define XT_BL_RASTER_NOT_S       0xC
#define XT_BL_RASTER_NOTS_OR_D   0xD
#define XT_BL_RASTER_NOT_SAND_D  0xE
#define XT_BL_RASTER_ONE         0xF

/* --- API ------------------------------------------------------------------ */
uint8_t  xt_blitter_status(void);

static inline bool xt_blitter_busy(void)
{
    return (xt_blitter_status() & XT_BL_STATUS_BUSY) != 0;
}

int  xt_blitter_irq_init(void);
int  xt_blitter_wait_idle(uint32_t timeout_us);
uint16_t xt_blitter_seq_counter(void);

void xt_blitter_set_dst(int16_t x, int16_t y, uint16_t w, uint16_t h);
void xt_blitter_set_src(int16_t x, int16_t y, uint16_t w, uint16_t h);
void xt_blitter_set_pat_phase(uint8_t px, uint8_t py);
void xt_blitter_set_pat_log(uint8_t log_w, uint8_t log_h);
void xt_blitter_write_pat(const uint8_t *bytes, uint32_t n);
void xt_blitter_set_flags(uint8_t flags);
void xt_blitter_set_raster_op(uint8_t op);
void xt_blitter_fire(uint8_t cmd);

void xt_blitter_set_src_surface(uint32_t base, uint16_t stride, uint8_t bpp);
void xt_blitter_set_dst_surface(uint32_t base, uint16_t stride);
void xt_blitter_src_blit(int16_t sx, int16_t sy, uint16_t w, uint16_t h,
                         int16_t dx, int16_t dy);
void xt_blitter_dst_ddr_rect(uint32_t base, uint16_t stride, int16_t x0, int16_t y0);
void xt_blitter_src_ddr_rect(uint32_t base, uint16_t stride, int16_t x0, int16_t y0);

/* Low-level register poke within the BLITTER block (offset == bl_addr). */
void    xt_blitter_write8(uint32_t offset, uint8_t v);
uint8_t xt_blitter_read8 (uint32_t offset);

#endif /* BLITTER_H_ */
