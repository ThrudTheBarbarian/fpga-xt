/* ============================================================================
 * ⚠ REFERENCE ONLY — NOT BUILT, NOT LINKED, NOT RUN. The live OS is loader/.
 *
 * ...BUT THIS FILE IS WORTH READING. It is the AUTHORITATIVE example of driving
 * the PL blitter, and the live driver (loader/test/freertos/blitter.c) was ported
 * FROM it. Three real bugs in that port were found only by diffing against this
 * file (docs/bugs/scaled-blit-ddr.md). If you are writing blitter code, read this
 * BEFORE re-deriving anything from the docs -- re-deriving is the mistake.
 * See reference/vitis-baremetal/README.md.
 * ============================================================================ */
/*
 * blitter.c — PS-side blitter driver.  See blitter.h for the register map/API.
 */

#include "blitter.h"

#include "xil_io.h"
#include "sleep.h"

/* Completion-IRQ path.  The blitter pulses IRQ_F2P[0] (GIC SPI 61) on busy 1->0;
 * the ISR gives a semaphore that wait_idle blocks on.  The IRQ is an OPTIMISATION
 * over the poll, not a hard dependency: wait_idle re-checks `busy` on a short
 * timeout, so a missed IRQ degrades to a poll.  -DXT_BLITTER_IRQ=0 compiles it out. */
#ifndef XT_BLITTER_IRQ
#define XT_BLITTER_IRQ 1
#endif

#if XT_BLITTER_IRQ
#include "FreeRTOS.h"
#include "task.h"
#include "semphr.h"
#include "xscugic.h"
#include "xparameters.h"
#endif

void xt_blitter_write8(uint32_t offset, uint8_t v)
{
    Xil_Out8(XT_BLK_BLITTER + offset, v);
}

uint8_t xt_blitter_read8(uint32_t offset)
{
    return Xil_In8(XT_BLK_BLITTER + offset);
}

uint8_t xt_blitter_status(void)
{
    return (uint8_t)(Xil_In32(XT_BLT_STATUS) & 0xFFu);   /* {pat_blocked,qfull,busy} */
}

uint16_t xt_blitter_seq_counter(void)
{
    return (uint16_t)(Xil_In32(XT_BLT_SEQ) & 0xFFFFu);   /* full 16-bit SYNC counter */
}

#if XT_BLITTER_IRQ
/* ---- Completion IRQ (PL IRQ_F2P[0] -> Zynq-7000 GIC SPI ID 61) ----------
 * Handler install + enable go through the FreeRTOS port API.  The rising-edge
 * trigger config needs a GIC instance the 2025.2 SDT port does NOT expose, so
 * use a minimal config-only XScuGic (LookupConfig, NO CfgInitialize: touches
 * only interrupt 61's ICFGR/priority).  Call xt_blitter_irq_init() ONCE from a
 * task after the scheduler is running. */
#define XT_BLIT_IRQ_ID  61u

static SemaphoreHandle_t s_blit_done;

static void xt_blitter_isr(void *unused)
{
    BaseType_t hpw = pdFALSE;
    (void)unused;
    if (s_blit_done) {
        xSemaphoreGiveFromISR(s_blit_done, &hpw);
    }
    portYIELD_FROM_ISR(hpw);
}

int xt_blitter_irq_init(void)
{
    s_blit_done = xSemaphoreCreateBinary();
    if (!s_blit_done) {
        return -1;
    }
    XScuGic_Config *cfg = XScuGic_LookupConfig(XPAR_XSCUGIC_0_BASEADDR);
    if (cfg) {
        static XScuGic gic_tt;          /* config-only: trigger-type write */
        gic_tt.Config  = cfg;
        gic_tt.IsReady = XIL_COMPONENT_IS_READY;
        XScuGic_SetPriorityTriggerType(&gic_tt, XT_BLIT_IRQ_ID, 0xA0, 0x03);
    }
    if (xPortInstallInterruptHandler(XT_BLIT_IRQ_ID,
                                     (XInterruptHandler) xt_blitter_isr,
                                     NULL) != pdPASS) {
        return -1;
    }
    vPortEnableInterrupt(XT_BLIT_IRQ_ID);
    return 0;
}
#else
int xt_blitter_irq_init(void) { return -1; }
#endif

int xt_blitter_wait_idle(uint32_t timeout_us)
{
    if (!xt_blitter_busy()) {
        return 0;
    }

#if XT_BLITTER_IRQ
    if (s_blit_done) {
        TickType_t slice = pdMS_TO_TICKS(2);
        if (slice == 0) slice = 1;
        uint32_t waited_us = 0;
        (void) xSemaphoreTake(s_blit_done, 0);    /* drain stale give */
        while (xt_blitter_busy()) {
            (void) xSemaphoreTake(s_blit_done, slice);
            if (!xt_blitter_busy()) return 0;
            waited_us += 2000u;
            if (timeout_us != 0 && waited_us >= timeout_us) return -1;
        }
        return 0;
    }
#endif

    /* Poll fallback — coarse, ~100 us granularity. */
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

/* --- SRC_BLIT (CMD 0x08) DDR surface descriptors + helper ----------------- */
static uint32_t g_sb_src_base, g_sb_dst_base;
static uint16_t g_sb_src_stride, g_sb_dst_stride;
static uint8_t  g_sb_src_bpp = 4;          /* 1 = 8-bit coverage, 4 = RGBA */

static void xt_blitter_write32(uint8_t off0, uint32_t v)
{
    xt_blitter_write8(off0,     (uint8_t)(v & 0xFF));
    xt_blitter_write8(off0 + 1, (uint8_t)((v >> 8)  & 0xFF));
    xt_blitter_write8(off0 + 2, (uint8_t)((v >> 16) & 0xFF));
    xt_blitter_write8(off0 + 3, (uint8_t)((v >> 24) & 0xFF));
}

void xt_blitter_set_src_surface(uint32_t base, uint16_t stride, uint8_t bpp)
{
    g_sb_src_base   = base;
    g_sb_src_stride = stride;
    g_sb_src_bpp    = bpp ? bpp : 4;
    xt_blitter_write8(XT_BL_SRC_STRIDE_LO,(uint8_t)(stride & 0xFF));
    xt_blitter_write8(XT_BL_SRC_STRIDE_HI,(uint8_t)((stride >> 8) & 0xFF));
}

void xt_blitter_set_dst_surface(uint32_t base, uint16_t stride)
{
    g_sb_dst_base   = base;
    g_sb_dst_stride = stride;
    xt_blitter_write8(XT_BL_DST_STRIDE_LO,(uint8_t)(stride & 0xFF));
    xt_blitter_write8(XT_BL_DST_STRIDE_HI,(uint8_t)((stride >> 8) & 0xFF));
}

void xt_blitter_src_blit(int16_t sx, int16_t sy, uint16_t w, uint16_t h,
                         int16_t dx, int16_t dy)
{
    uint32_t src_row0 = g_sb_src_base
                      + (uint32_t)((int32_t)sy * (int32_t)g_sb_src_stride)
                      + (uint32_t)((int32_t)sx * (int32_t)g_sb_src_bpp);
    uint32_t dst_row0 = g_sb_dst_base
                      + (uint32_t)((int32_t)dy * (int32_t)g_sb_dst_stride)
                      + (uint32_t)((int32_t)dx * 4);
    xt_blitter_write32(XT_BL_SRC_BASE_0, src_row0);
    xt_blitter_write32(XT_BL_DST_BASE_0, dst_row0);
    xt_blitter_set_dst(0, 0, w, h);
    xt_blitter_fire(XT_BL_CMD_SRC_BLIT);
}

void xt_blitter_dst_ddr_rect(uint32_t base, uint16_t stride, int16_t x0, int16_t y0)
{
    uint32_t row0 = base + (uint32_t)((int32_t)y0 * (int32_t)stride)
                         + (uint32_t)((int32_t)x0 * 4);
    xt_blitter_write32(XT_BL_DST_BASE_0, row0);
    xt_blitter_write8(XT_BL_DST_STRIDE_LO,(uint8_t)(stride & 0xFF));
    xt_blitter_write8(XT_BL_DST_STRIDE_HI,(uint8_t)((stride >> 8) & 0xFF));
}

void xt_blitter_src_ddr_rect(uint32_t base, uint16_t stride, int16_t x0, int16_t y0)
{
    uint32_t row0 = base + (uint32_t)((int32_t)y0 * (int32_t)stride)
                         + (uint32_t)((int32_t)x0 * 4);
    xt_blitter_write32(XT_BL_SRC_BASE_0, row0);
    xt_blitter_write8(XT_BL_SRC_STRIDE_LO,(uint8_t)(stride & 0xFF));
    xt_blitter_write8(XT_BL_SRC_STRIDE_HI,(uint8_t)((stride >> 8) & 0xFF));
}
