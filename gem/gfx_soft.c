// gfx_soft.c — software implementation of the gfx.h primitives.
//
// The host (SDL) backend.  These are the reference behaviours the A9 hardware
// blitter backend must match; kept deliberately simple and clip-correct.

#include "gfx.h"
#include <stdlib.h>
#include <string.h>

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

// Clip [v, v+n) to [0, lim); returns clipped n (>=0) and advances *v / *off.
static int clip_span(int *v, int *off, int n, int lim) {
    if (n <= 0) return 0;
    if (*v < 0) { int d = -*v; n -= d; *off += d; *v = 0; }
    if (*v + n > lim) n = lim - *v;
    return n < 0 ? 0 : n;
}

void gfx_fill_rect(gfx_surface *s, int x, int y, int w, int h, uint32_t rgba) {
    if (!s) return;
    int ox = 0, oy = 0;
    w = clip_span(&x, &ox, w, s->w);
    h = clip_span(&y, &oy, h, s->h);
    for (int row = 0; row < h; row++) {
        uint32_t *p = s->px + (size_t)(y + row) * s->stride + x;
        for (int col = 0; col < w; col++) p[col] = rgba;
    }
}

void gfx_blit(gfx_surface *dst, int dx, int dy,
              const gfx_surface *src, int sx, int sy, int w, int h) {
    if (!dst || !src) return;
    // Clip against the source first, then the destination (keep them aligned).
    int sox = 0, soy = 0;
    w = clip_span(&sx, &sox, w, src->w);
    h = clip_span(&sy, &soy, h, src->h);
    dx += sox; dy += soy;                       // source-side clip shifts dst too
    int dox = 0, doy = 0;
    w = clip_span(&dx, &dox, w, dst->w);
    h = clip_span(&dy, &doy, h, dst->h);
    sx += dox; sy += doy;                        // dst-side clip shifts src too
    for (int row = 0; row < h; row++) {
        const uint32_t *sp = src->px + (size_t)(sy + row) * src->stride + sx;
        uint32_t       *dp = dst->px + (size_t)(dy + row) * dst->stride + dx;
        memcpy(dp, sp, (size_t)w * sizeof(uint32_t));
    }
}

static void put_px(gfx_surface *s, int x, int y, uint32_t rgba) {
    if ((unsigned)x < (unsigned)s->w && (unsigned)y < (unsigned)s->h)
        s->px[(size_t)y * s->stride + x] = rgba;
}

void gfx_line(gfx_surface *s, int x0, int y0, int x1, int y1, uint32_t rgba) {
    if (!s) return;
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
