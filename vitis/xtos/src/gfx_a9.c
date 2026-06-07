// gfx_a9.c — A9 graphics backend for the GEM gfx.h primitives.
//
// Routes the three backend primitives (fill / blit / line) to the hardware
// blitter when the target is the live desktop plane, and falls back to the
// same software implementation as gfx_soft.c for any off-screen surface.
//
// Only the desktop plane can be hardware-accelerated: the blitter's framebuffer
// base + stride are hardwired in the RTL (FB_BASE = 0x30000000, FB_STRIDE_B =
// 8192) — it can address pixels only within that one plane.  Off-screen
// surfaces (heap-backed window backing stores, font atlases) keep the CPU path.
//
// Coherency: the blitter is an HP AXI master and writes/reads DDR directly,
// bypassing the A9 D-cache.  The plane is cacheable, so before every blitter op
// we Xil_DCacheFlushRange the rects it touches.  On Zynq that primitive does a
// clean+invalidate, which (a) pushes any dirty CPU pixels to DDR so a blit reads
// fresh source data, (b) drops the lines so the blitter's DDR writes can't be
// clobbered by a later eviction, and (c) leaves the rect uncached so the next
// CPU read (e.g. font alpha-blend over a filled background) re-fetches the
// blitter's result.  Write-only ops (fill/line) only need the flush; no
// post-op invalidate.
//
// This file is compiled in place of gfx_soft.c for the A9 build (see
// vitis/scripts/create_platform.py); gfx_soft.c remains the SDL-testbed backend.

#include "gfx.h"
#include "xt_blitter.h"
#include "xil_cache.h"
#include <stdlib.h>
#include <string.h>

#define PLANE_BASE     0x30000000u
#define PLANE_STRIDE_B 8192u          /* bytes per row — matches blitter FB_STRIDE_B */
#define PLANE_W        1920
#define PLANE_H        1080
#define BLIT_TIMEOUT   500000u        /* wait_idle budget (us-ish spin count)        */

// Below this pixel area the blitter's per-op cost (cache flush + ~9 GP0 register
// pokes + wait_idle) outweighs a straight CPU fill/copy, so stay on the CPU.
// Tunable; the blitter clearly wins on backgrounds, clears and large rects.
#define HW_MIN_PX      1024u          /* ~32x32 */

// The blitter can only touch the live desktop plane (fixed FB_BASE/stride).
static inline int is_plane(const gfx_surface *s) {
    return s && (uintptr_t)s->px == (uintptr_t)PLANE_BASE
             && s->stride == (int)(PLANE_STRIDE_B / 4u);
}

// Clean+invalidate a w×h pixel rect of the plane, row by row (the rows are not
// contiguous — only `w` pixels of each PLANE_STRIDE_B-byte row belong to us, so
// a single flat range would needlessly evict unrelated columns' dirty lines).
static void plane_flush_rect(int x, int y, int w, int h) {
    if (w <= 0 || h <= 0) return;
    for (int row = 0; row < h; row++) {
        uintptr_t a = PLANE_BASE + (uintptr_t)(y + row) * PLANE_STRIDE_B
                                 + (uintptr_t)x * 4u;
        Xil_DCacheFlushRange((INTPTR)a, (INTPTR)((uintptr_t)w * 4u));
    }
}

// ---- software fallback (identical behaviour to gfx_soft.c) ------------------

// Clip [v, v+n) to [0, lim); returns clipped n (>=0) and advances *v / *off.
static int clip_span(int *v, int *off, int n, int lim) {
    if (n <= 0) return 0;
    if (*v < 0) { int d = -*v; n -= d; *off += d; *v = 0; }
    if (*v + n > lim) n = lim - *v;
    return n < 0 ? 0 : n;
}

static void soft_fill_rect(gfx_surface *s, int x, int y, int w, int h, uint32_t rgba) {
    int ox = 0, oy = 0;
    w = clip_span(&x, &ox, w, s->w);
    h = clip_span(&y, &oy, h, s->h);
    for (int row = 0; row < h; row++) {
        uint32_t *p = s->px + (size_t)(y + row) * s->stride + x;
        for (int col = 0; col < w; col++) p[col] = rgba;
    }
}

static void put_px(gfx_surface *s, int x, int y, uint32_t rgba) {
    if ((unsigned)x < (unsigned)s->w && (unsigned)y < (unsigned)s->h)
        s->px[(size_t)y * s->stride + x] = rgba;
}

static void soft_line(gfx_surface *s, int x0, int y0, int x1, int y1, uint32_t rgba) {
    int dx =  abs(x1 - x0), sx = x0 < x1 ? 1 : -1;
    int dy = -abs(y1 - y0), sy = y0 < y1 ? 1 : -1;
    int err = dx + dy;
    for (;;) {
        put_px(s, x0, y0, rgba);
        if (x0 == x1 && y0 == y1) break;
        int e2 = 2 * err;
        if (e2 >= dy) { err += dy; x0 += sx; }
        if (e2 <= dx) { err += dx; y0 += sy; }
    }
}

// ---- surface lifecycle (always software — heap) ----------------------------

gfx_surface *gfx_surface_alloc(int w, int h) {
    if (w <= 0 || h <= 0) return NULL;
    gfx_surface *s = (gfx_surface *)calloc(1, sizeof(*s));
    if (!s) return NULL;
    s->w = w; s->h = h; s->stride = w;
    s->px = (uint32_t *)calloc((size_t)w * h, sizeof(uint32_t));
    if (!s->px) { free(s); return NULL; }
    return s;
}

void gfx_surface_free(gfx_surface *s) {
    if (!s) return;
    free(s->px);
    free(s);
}

// ---- backend primitives ----------------------------------------------------

void gfx_fill_rect(gfx_surface *s, int x, int y, int w, int h, uint32_t rgba) {
    if (!s) return;
    int ox = 0, oy = 0;
    w = clip_span(&x, &ox, w, s->w);
    h = clip_span(&y, &oy, h, s->h);
    if (w <= 0 || h <= 0) return;

    if (!is_plane(s) || (unsigned)(w * h) < HW_MIN_PX) {
        soft_fill_rect(s, x, y, w, h, rgba);
        return;
    }

    // HW: solid 1x1 pattern fill (rgba = 0xRRGGBBAA).
    uint8_t pat[4] = { (uint8_t)(rgba >> 24), (uint8_t)(rgba >> 16),
                       (uint8_t)(rgba >> 8),  (uint8_t)rgba };
    plane_flush_rect(x, y, w, h);
    xt_blitter_set_pat_log(0, 0);
    xt_blitter_set_pat_phase(0, 0);
    xt_blitter_write_pat(pat, 4);
    xt_blitter_set_raster_op(XT_BL_RASTER_S);
    xt_blitter_set_dst((int16_t)x, (int16_t)y, (uint16_t)w, (uint16_t)h);
    xt_blitter_fire(XT_BL_CMD_RECT_FILL);
    xt_blitter_wait_idle(BLIT_TIMEOUT);
}

void gfx_blit(gfx_surface *dst, int dx, int dy,
              const gfx_surface *src, int sx, int sy, int w, int h) {
    if (!dst || !src) return;
    // Clip against the source first, then the destination (keep them aligned).
    int sox = 0, soy = 0;
    w = clip_span(&sx, &sox, w, src->w);
    h = clip_span(&sy, &soy, h, src->h);
    dx += sox; dy += soy;
    int dox = 0, doy = 0;
    w = clip_span(&dx, &dox, w, dst->w);
    h = clip_span(&dy, &doy, h, dst->h);
    sx += dox; sy += doy;
    if (w <= 0 || h <= 0) return;

    // HW block blit only when BOTH surfaces are the one plane the blitter knows
    // and the copy is large enough to beat a per-row memcpy.
    if (is_plane(dst) && is_plane(src) && (unsigned)(w * h) >= HW_MIN_PX) {
        plane_flush_rect(sx, sy, w, h);            /* push source to DDR  */
        plane_flush_rect(dx, dy, w, h);            /* drop dest dirty lines */
        xt_blitter_set_raster_op(XT_BL_RASTER_S);  /* S = straight copy   */
        xt_blitter_set_src((int16_t)sx, (int16_t)sy, (uint16_t)w, (uint16_t)h);
        xt_blitter_set_dst((int16_t)dx, (int16_t)dy, (uint16_t)w, (uint16_t)h);
        xt_blitter_fire(XT_BL_CMD_BLOCK_BLIT);
        xt_blitter_wait_idle(BLIT_TIMEOUT);
        return;
    }

    // Software copy (off-screen source and/or destination).
    for (int row = 0; row < h; row++) {
        const uint32_t *sp = src->px + (size_t)(sy + row) * src->stride + sx;
        uint32_t       *dp = dst->px + (size_t)(dy + row) * dst->stride + dx;
        memcpy(dp, sp, (size_t)w * sizeof(uint32_t));
    }
}

void gfx_line(gfx_surface *s, int x0, int y0, int x1, int y1, uint32_t rgba) {
    if (!s) return;

    // HW line draw needs both endpoints inside the plane (the blitter does not
    // clip).  The VDI clips before calling us, but guard anyway and fall back to
    // the software Bresenham (which clips per-pixel) if anything is out of range.
    int in_plane = is_plane(s)
                && (unsigned)x0 < (unsigned)PLANE_W && (unsigned)y0 < (unsigned)PLANE_H
                && (unsigned)x1 < (unsigned)PLANE_W && (unsigned)y1 < (unsigned)PLANE_H;
    if (!in_plane) { soft_line(s, x0, y0, x1, y1, rgba); return; }

    // DST_W/H carry signed DX/DY; the blitter draws |D|+1 pixels inclusive.
    int dx = x1 - x0, dy = y1 - y0;
    int bx0 = x0 < x1 ? x0 : x1, by0 = y0 < y1 ? y0 : y1;
    int bw  = abs(dx) + 1,       bh  = abs(dy) + 1;
    uint8_t pat[4] = { (uint8_t)(rgba >> 24), (uint8_t)(rgba >> 16),
                       (uint8_t)(rgba >> 8),  (uint8_t)rgba };
    plane_flush_rect(bx0, by0, bw, bh);
    xt_blitter_set_pat_log(0, 0);
    xt_blitter_set_pat_phase(0, 0);
    xt_blitter_write_pat(pat, 4);
    xt_blitter_set_raster_op(XT_BL_RASTER_S);
    xt_blitter_set_dst((int16_t)x0, (int16_t)y0, (uint16_t)dx, (uint16_t)dy);
    xt_blitter_fire(XT_BL_CMD_LINE_DRAW);
    xt_blitter_wait_idle(BLIT_TIMEOUT);
}
