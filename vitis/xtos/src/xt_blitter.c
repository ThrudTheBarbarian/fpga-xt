/*
 * xt_blitter.c — PS-side driver implementation.  See xt_blitter.h for
 * the register map and API summary.
 */

#include "xt_blitter.h"

#include "xil_io.h"
#include "sleep.h"

/* Completion-IRQ path.  The blitter pulses IRQ_F2P[0] (GIC SPI 61) on busy 1->0;
 * the ISR gives a semaphore that wait_idle blocks on.  The IRQ is an OPTIMISATION
 * over the poll, not a hard dependency: wait_idle re-checks `busy` (the source of
 * truth) on a short timeout, so a missed/misconfigured IRQ degrades to a poll
 * rather than stalling.  Build -DXT_BLITTER_IRQ=0 to compile it out entirely. */
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

#if XT_BLITTER_IRQ
/* ---- Completion IRQ (PL IRQ_F2P[0] -> Zynq-7000 GIC SPI ID 61) ----------
 * Handler install + enable go through the FreeRTOS port API (not usb_hid's GIC,
 * retired for the STM32).  The rising-edge trigger config needs a GIC instance,
 * which the 2025.2 SDT port does NOT expose, so use a minimal config-only
 * XScuGic (LookupConfig, NO CfgInitialize: this touches only interrupt 61's
 * ICFGR/priority, never the distributor the port already set up).  Call
 * xt_blitter_irq_init() ONCE from a task after the scheduler is running. */
#define XT_BLIT_IRQ_ID  61u            /* IRQ_F2P[0] -> GIC SPI ID 61 */

static SemaphoreHandle_t s_blit_done;  /* given by the ISR on completion */

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
    /* rising-edge (the PL drives irq high for a single clk on completion) */
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
/* IRQ path not built — wait_idle polls.  Stub keeps callers linking. */
int xt_blitter_irq_init(void) { return -1; }
#endif

int xt_blitter_wait_idle(uint32_t timeout_us)
{
    /* busy is the source of truth; the IRQ semaphore (when built) is just the
     * wakeup — otherwise we poll. */
    if (!xt_blitter_busy()) {
        return 0;
    }

#if XT_BLITTER_IRQ
    if (s_blit_done) {
        /* IRQ-assisted: block on the completion semaphore in short slices, but
         * `busy` stays the source of truth.  The ISR wakes us immediately on a
         * real completion; a missed/misconfigured IRQ just re-polls each slice,
         * so we degrade to a poll instead of stalling on the semaphore. */
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

/* --- SRC_BLIT (CMD 0x08) DDR surface descriptors + helper -------------- */
/* The blitter addresses a surface by ROW0 (the byte address of the blit's
 * (x0,y0) origin pixel) + row stride, and only accumulates (+stride/row,
 * +bpp/pixel) — no fabric multiply.  The A9 folds the origin in, so we keep the
 * per-surface {base, stride, bpp} here and recompute ROW0 per blit.  Stride is
 * written to HW once per surface; ROW0 (the descriptor "base" reg) per blit. */
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

/* Enqueue one SRC_BLIT: source rect (sx,sy,w,h) -> dest (dx,dy).  Caller has
 * already set FLAGS (mode), the SRC/DST surfaces, and (for SRC_COV) the 1x1
 * pattern colour.  Folds the origins into ROW0 and writes the descriptor bases
 * + the sweep extent (DST_W/H).  Pushes one command; does NOT wait. */
void xt_blitter_src_blit(int16_t sx, int16_t sy, uint16_t w, uint16_t h,
                         int16_t dx, int16_t dy)
{
    uint32_t src_row0 = g_sb_src_base
                      + (uint32_t)((int32_t)sy * (int32_t)g_sb_src_stride)
                      + (uint32_t)((int32_t)sx * (int32_t)g_sb_src_bpp);
    uint32_t dst_row0 = g_sb_dst_base
                      + (uint32_t)((int32_t)dy * (int32_t)g_sb_dst_stride)
                      + (uint32_t)((int32_t)dx * 4);
    xt_blitter_write32(XT_BL_SRC_BASE_0, src_row0);   /* ROW0_src */
    xt_blitter_write32(XT_BL_DST_BASE_0, dst_row0);   /* ROW0_dst */
    xt_blitter_set_dst(0, 0, w, h);                   /* DST_W/H sweep (X/Y ignored) */
    xt_blitter_fire(XT_BL_CMD_SRC_BLIT);
}

/* --- Off-plane DDR surfaces for RECT_FILL / BLOCK_BLIT / LINE ---------- */
/* These commands seed their row-base accumulator from the descriptor base reg
 * when the FLAGS DDR bit is set.  Write that base = ROW0 (origin folded in:
 * base + y0*stride + x0*4) and the row stride.  RGBA-8888 (4 B/px) only.  The
 * caller still sets DST_X/Y (DST_X carries the 8-byte half parity), W/H, the
 * DST_DDR/SRC_DDR flag, pattern/raster-op as needed, then fires. */
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

/* --- XT register-unlock (the A9 sets the stock-vs-XT personality) ------ */

void xt_unlock_set(uint8_t mask)
{
    xt_blitter_write8(XT_BL_UNLOCK, mask);
}

uint8_t xt_unlock_get(void)
{
    return xt_blitter_read8(XT_BL_UNLOCK);
}

/* ---- Drag overlay ---------------------------------------------------------
 * The write to OVL_EN is the COMMIT: the PL captures {x,y,w,h,en} atomically
 * on that write and adopts it at the next vblank (so a move never tears and a
 * half-written multi-byte position never reaches the compositor).  Always
 * write OVL_EN last. */
void xt_overlay_enable(uint32_t base, uint16_t x, uint16_t y, uint16_t w, uint16_t h)
{
    xt_blitter_write8(XT_BL_OVL_BASE_0, (uint8_t)(base & 0xFF));
    xt_blitter_write8(XT_BL_OVL_BASE_1, (uint8_t)((base >> 8)  & 0xFF));
    xt_blitter_write8(XT_BL_OVL_BASE_2, (uint8_t)((base >> 16) & 0xFF));
    xt_blitter_write8(XT_BL_OVL_BASE_3, (uint8_t)((base >> 24) & 0xFF));
    xt_blitter_write8(XT_BL_OVL_W_LO,   (uint8_t)(w & 0xFF));
    xt_blitter_write8(XT_BL_OVL_W_HI,   (uint8_t)((w >> 8) & 0x0F));
    xt_blitter_write8(XT_BL_OVL_H_LO,   (uint8_t)(h & 0xFF));
    xt_blitter_write8(XT_BL_OVL_H_HI,   (uint8_t)((h >> 8) & 0x0F));
    xt_blitter_write8(XT_BL_OVL_X_LO,   (uint8_t)(x & 0xFF));
    xt_blitter_write8(XT_BL_OVL_X_HI,   (uint8_t)((x >> 8) & 0x0F));
    xt_blitter_write8(XT_BL_OVL_Y_LO,   (uint8_t)(y & 0xFF));
    xt_blitter_write8(XT_BL_OVL_Y_HI,   (uint8_t)((y >> 8) & 0x0F));
    xt_blitter_write8(XT_BL_OVL_EN,     0x01);            /* enable + commit */
}

void xt_overlay_move(uint16_t x, uint16_t y)
{
    xt_blitter_write8(XT_BL_OVL_X_LO,   (uint8_t)(x & 0xFF));
    xt_blitter_write8(XT_BL_OVL_X_HI,   (uint8_t)((x >> 8) & 0x0F));
    xt_blitter_write8(XT_BL_OVL_Y_LO,   (uint8_t)(y & 0xFF));
    xt_blitter_write8(XT_BL_OVL_Y_HI,   (uint8_t)((y >> 8) & 0x0F));
    xt_blitter_write8(XT_BL_OVL_EN,     0x01);            /* keep enabled + commit */
}

void xt_overlay_disable(void)
{
    xt_blitter_write8(XT_BL_OVL_EN,     0x00);            /* disable + commit */
}
