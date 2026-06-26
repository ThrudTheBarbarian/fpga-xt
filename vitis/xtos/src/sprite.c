/*
 * sprite.c — A9-side hardware sprite-engine driver.  See sprite.h.
 */
#include "sprite.h"
#include <stddef.h>         /* size_t */
#include "xt_blitter.h"     /* XT_BLITTER_BASE (the GP0 bridge window) */
#include "xil_io.h"
#include "xil_cache.h"

/* GP0 bridge offsets that carry a sprite-engine register write. */
#define SPR_GP0_IDX   (XT_BLITTER_BASE + 0x22u)   /* reg index ($D4Ax/$D4Dx low byte) */
#define SPR_GP0_DAT   (XT_BLITTER_BASE + 0x23u)   /* reg data + write strobe          */

/* Sprite-engine register indices (reg_addr[7:0]). */
#define R_SEL         0xD0u   /* descriptor: select target slot       */
#define R_PRIO        0xD1u   /* descriptor shadow: priority [4:0]    */
#define R_LOG2SZ      0xD2u   /* descriptor shadow: log2 size [3:0]   */
#define R_ARENA_YLO   0xD3u   /* arena_y[7:0]                          */
#define R_ARENA_HI    0xD4u   /* {arena_x[11:8], arena_y[11:8]}        */
#define R_ARENA_XLO   0xD5u   /* arena_x[7:0]                          */
#define R_SCREEN_YLO  0xD6u   /* screen_y[7:0]                         */
#define R_SCREEN_HI   0xD7u   /* {screen_x[11:8], screen_y[11:8]}      */
#define R_COMMIT      0xD8u   /* commit; data = screen_x[7:0]          */
#define R_CTRL0       0xA0u   /* per-sprite control, slot 0 (+slot)   */
#define R_GLOBAL      0xDFu   /* global enable [0]                     */

static inline void spr_reg(uint8_t idx, uint8_t val)
{
    Xil_Out8(SPR_GP0_IDX, idx);   /* latch the index   */
    Xil_Out8(SPR_GP0_DAT, val);   /* data + reg_we pulse */
}

void sprite_set(int slot, int prio, int log2sz,
                int arena_x, int arena_y, int screen_x, int screen_y)
{
    spr_reg(R_SEL,        (uint8_t)(slot & 0x0F));
    spr_reg(R_PRIO,       (uint8_t)(prio & 0x1F));
    spr_reg(R_LOG2SZ,     (uint8_t)(log2sz & 0x0F));
    spr_reg(R_ARENA_YLO,  (uint8_t)(arena_y & 0xFF));
    spr_reg(R_ARENA_HI,   (uint8_t)((((arena_x >> 8) & 0x0F) << 4) | ((arena_y >> 8) & 0x0F)));
    spr_reg(R_ARENA_XLO,  (uint8_t)(arena_x & 0xFF));
    spr_reg(R_SCREEN_YLO, (uint8_t)(screen_y & 0xFF));
    spr_reg(R_SCREEN_HI,  (uint8_t)((((screen_x >> 8) & 0x0F) << 4) | ((screen_y >> 8) & 0x0F)));
    spr_reg(R_COMMIT,     (uint8_t)(screen_x & 0xFF));   /* commit (carries screen_x[7:0]) */
}

void sprite_enable(int slot, int format)
{
    /* bit0 = enable, bit5 = format (1 = 32-bit RGBA-8888) */
    spr_reg((uint8_t)(R_CTRL0 + (slot & 0x0F)),
            (uint8_t)(0x01u | (format ? 0x20u : 0x00u)));
}

void sprite_global_enable(int en)
{
    spr_reg(R_GLOBAL, en ? 0x01u : 0x00u);
}

void sprite_load_rgba(int arena_x, int arena_y, int w, int h, const uint32_t *img)
{
    /* Format-1 arena layout: each row at (arena_y+r)<<14, pixels at (arena_x+c)<<2.
     * Flush each row (the fetcher reads the arena over HP2, bypassing the cache). */
    for (int r = 0; r < h; r++) {
        volatile uint32_t *p = (volatile uint32_t *)(uintptr_t)
            (SPR_ARENA_BASE + ((uint32_t)(arena_y + r) << 14) + ((uint32_t)arena_x << 2));
        for (int c = 0; c < w; c++)
            p[c] = img[(size_t)r * w + c];
        Xil_DCacheFlushRange((INTPTR)p, (size_t)w * sizeof(uint32_t));
    }
}

void sprite_test(void)
{
    /* 32x32 opaque white into the arena, format-1 layout: each row at
     * row<<14, pixels at col<<2; low byte (alpha) = 0xFF so it composites. */
    for (int row = 0; row < 32; row++) {
        volatile uint32_t *p =
            (volatile uint32_t *)(uintptr_t)(SPR_ARENA_BASE + ((uint32_t)row << 14));
        for (int col = 0; col < 32; col++)
            p[col] = 0xFFFFFFFFu;
        /* the fetcher reads the arena over HP2 (bypasses the A9 D-cache) */
        Xil_DCacheFlushRange((INTPTR)p, 32 * sizeof(uint32_t));
    }

    sprite_set(/*slot*/0, /*prio*/0, /*log2sz*/5,        /* 1<<5 = 32 px */
               /*arena_x*/0, /*arena_y*/0, /*screen_x*/100, /*screen_y*/100);
    sprite_enable(/*slot*/0, /*format*/1);               /* 32-bit RGBA */
    sprite_global_enable(1);
}
