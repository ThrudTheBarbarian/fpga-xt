/*
 * xt_blitter.c — PS-side driver implementation.  See xt_blitter.h for
 * the register map and API summary.
 */

#include "xt_blitter.h"

#include "xil_io.h"
#include "sleep.h"

void xt_blitter_write8(uint32_t offset, uint8_t v)
{
    Xil_Out8(XT_BLITTER_BASE + offset, v);
}

uint8_t xt_blitter_read8(uint32_t offset)
{
    return Xil_In8(XT_BLITTER_BASE + offset);
}

uint8_t xt_blitter_status(void)
{
    return xt_blitter_read8(XT_BL_STATUS);
}

uint16_t xt_blitter_seq_counter(void)
{
    /* SEQ_LO must be read before SEQ_HI: the blitter latches SEQ_HI
     * on SEQ_LO read so the pair is consistent across an in-flight
     * counter bump (see xt_blitter.sv:145). */
    uint8_t lo = xt_blitter_read8(XT_BL_SEQ_LO);
    uint8_t hi = xt_blitter_read8(XT_BL_SEQ_HI);
    return (uint16_t)((hi << 8) | lo);
}

int xt_blitter_wait_idle(uint32_t timeout_us)
{
    /* Coarse poll loop — usleep(100) gives us roughly 100us granularity
     * which is well below typical fill latencies (~ms range).  Replace
     * with an IRQ-driven wait when the blitter exposes a completion
     * interrupt. */
    while (xt_blitter_busy()) {
        if (timeout_us == 0) {
            return -1;
        }
        if (timeout_us < 100) {
            usleep(timeout_us);
            timeout_us = 0;
        } else {
            usleep(100);
            timeout_us -= 100;
        }
    }
    return 0;
}

void xt_blitter_set_dst(int16_t x, int16_t y, uint16_t w, uint16_t h)
{
    xt_blitter_write8(XT_BL_DST_X_LO, (uint8_t)(x & 0xFF));
    xt_blitter_write8(XT_BL_DST_X_HI, (uint8_t)((x >> 8) & 0xFF));
    xt_blitter_write8(XT_BL_DST_Y_LO, (uint8_t)(y & 0xFF));
    xt_blitter_write8(XT_BL_DST_Y_HI, (uint8_t)((y >> 8) & 0xFF));
    xt_blitter_write8(XT_BL_DST_W_LO, (uint8_t)(w & 0xFF));
    xt_blitter_write8(XT_BL_DST_W_HI, (uint8_t)((w >> 8) & 0xFF));
    xt_blitter_write8(XT_BL_DST_H_LO, (uint8_t)(h & 0xFF));
    xt_blitter_write8(XT_BL_DST_H_HI, (uint8_t)((h >> 8) & 0xFF));
}

void xt_blitter_set_src(int16_t x, int16_t y, uint16_t w, uint16_t h)
{
    xt_blitter_write8(XT_BL_SRC_X_LO, (uint8_t)(x & 0xFF));
    xt_blitter_write8(XT_BL_SRC_X_HI, (uint8_t)((x >> 8) & 0xFF));
    xt_blitter_write8(XT_BL_SRC_Y_LO, (uint8_t)(y & 0xFF));
    xt_blitter_write8(XT_BL_SRC_Y_HI, (uint8_t)((y >> 8) & 0xFF));
    xt_blitter_write8(XT_BL_SRC_W_LO, (uint8_t)(w & 0xFF));
    xt_blitter_write8(XT_BL_SRC_W_HI, (uint8_t)((w >> 8) & 0xFF));
    xt_blitter_write8(XT_BL_SRC_H_LO, (uint8_t)(h & 0xFF));
    xt_blitter_write8(XT_BL_SRC_H_HI, (uint8_t)((h >> 8) & 0xFF));
}

void xt_blitter_set_pat_phase(uint8_t px, uint8_t py)
{
    xt_blitter_write8(XT_BL_PAT_PHASE_X, px & 0x1F);
    xt_blitter_write8(XT_BL_PAT_PHASE_Y, py & 0x1F);
}

void xt_blitter_set_pat_log(uint8_t log_w, uint8_t log_h)
{
    xt_blitter_write8(XT_BL_PAT_LOG_W, log_w & 0x1F);
    xt_blitter_write8(XT_BL_PAT_LOG_H, log_h & 0x1F);
}

void xt_blitter_write_pat(const uint8_t *bytes, uint32_t n)
{
    for (uint32_t i = 0; i < n; i++) {
        xt_blitter_write8(XT_BL_PAT_DATA, bytes[i]);
    }
}

void xt_blitter_set_flags(uint8_t flags)
{
    xt_blitter_write8(XT_BL_FLAGS, flags);
}

void xt_blitter_set_raster_op(uint8_t op)
{
    xt_blitter_write8(XT_BL_RASTER_OP, op & 0x0F);
}

void xt_blitter_fire(uint8_t cmd)
{
    xt_blitter_write8(XT_BL_CMD, cmd);
}

/* --- SRC_BLIT (CMD 0x08) DDR surface descriptors + helper -------------- */

void xt_blitter_set_src_surface(uint32_t base, uint16_t stride)
{
    xt_blitter_write8(XT_BL_SRC_BASE_0,   (uint8_t)(base & 0xFF));
    xt_blitter_write8(XT_BL_SRC_BASE_1,   (uint8_t)((base >> 8)  & 0xFF));
    xt_blitter_write8(XT_BL_SRC_BASE_2,   (uint8_t)((base >> 16) & 0xFF));
    xt_blitter_write8(XT_BL_SRC_BASE_3,   (uint8_t)((base >> 24) & 0xFF));
    xt_blitter_write8(XT_BL_SRC_STRIDE_LO,(uint8_t)(stride & 0xFF));
    xt_blitter_write8(XT_BL_SRC_STRIDE_HI,(uint8_t)((stride >> 8) & 0xFF));
}

void xt_blitter_set_dst_surface(uint32_t base, uint16_t stride)
{
    xt_blitter_write8(XT_BL_DST_BASE_0,   (uint8_t)(base & 0xFF));
    xt_blitter_write8(XT_BL_DST_BASE_1,   (uint8_t)((base >> 8)  & 0xFF));
    xt_blitter_write8(XT_BL_DST_BASE_2,   (uint8_t)((base >> 16) & 0xFF));
    xt_blitter_write8(XT_BL_DST_BASE_3,   (uint8_t)((base >> 24) & 0xFF));
    xt_blitter_write8(XT_BL_DST_STRIDE_LO,(uint8_t)(stride & 0xFF));
    xt_blitter_write8(XT_BL_DST_STRIDE_HI,(uint8_t)((stride >> 8) & 0xFF));
}

/* Enqueue one SRC_BLIT: source rect (sx,sy,w,h) -> dest (dx,dy).  Caller has
 * already set FLAGS (mode), the SRC/DST surfaces, and (for SRC_COV) the 1x1
 * pattern colour.  Pushes one command into the blitter queue; does NOT wait. */
void xt_blitter_src_blit(int16_t sx, int16_t sy, uint16_t w, uint16_t h,
                         int16_t dx, int16_t dy)
{
    xt_blitter_set_src(sx, sy, w, h);
    xt_blitter_set_dst(dx, dy, w, h);
    xt_blitter_fire(XT_BL_CMD_SRC_BLIT);
}
