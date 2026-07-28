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
    if (w > 0 && h > 0) gem_prof_add(GEM_PROF_FILL, 0, (long)w * h);   // TEMP profiler
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
    if (w > 0 && h > 0) gem_prof_add(GEM_PROF_BLIT, 0, (long)w * h);   // TEMP profiler
    for (int row = 0; row < h; row++) {
        const uint32_t *sp = src->px + (size_t)(sy + row) * src->stride + sx;
        uint32_t       *dp = dst->px + (size_t)(dy + row) * dst->stride + dx;
        memcpy(dp, sp, (size_t)w * sizeof(uint32_t));
    }
}

void gfx_blit_over(gfx_surface *dst, int dx, int dy,
                   const gfx_surface *src, int sx, int sy, int w, int h) {
    if (!dst || !src) return;
    int sox = 0, soy = 0;
    w = clip_span(&sx, &sox, w, src->w);
    h = clip_span(&sy, &soy, h, src->h);
    dx += sox; dy += soy;
    int dox = 0, doy = 0;
    w = clip_span(&dx, &dox, w, dst->w);
    h = clip_span(&dy, &doy, h, dst->h);
    sx += dox; sy += doy;
    for (int row = 0; row < h; row++) {
        const uint32_t *sp = src->px + (size_t)(sy + row) * src->stride + sx;
        uint32_t       *dp = dst->px + (size_t)(dy + row) * dst->stride + dx;
        for (int col = 0; col < w; col++) {
            uint32_t s = sp[col]; unsigned a = s & 0xFF;
            if (a == 0) continue;                       // transparent: keep dst
            if (a == 255) { dp[col] = (s & 0xFFFFFF00u) | 0xFF; continue; }
            uint32_t d = dp[col];
            unsigned r = (((s>>24)&0xFF)*a + ((d>>24)&0xFF)*(255-a)) / 255;
            unsigned g = (((s>>16)&0xFF)*a + ((d>>16)&0xFF)*(255-a)) / 255;
            unsigned b = (((s>>8) &0xFF)*a + ((d>>8) &0xFF)*(255-a)) / 255;
            dp[col] = (r<<24)|(g<<16)|(b<<8)|0xFF;
        }
    }
}

static void put_px(gfx_surface *s, int x, int y, uint32_t rgba) {
    if ((unsigned)x < (unsigned)s->w && (unsigned)y < (unsigned)s->h)
        s->px[(size_t)y * s->stride + x] = rgba;
}

void gfx_blit_coverage(gfx_surface *dst, int dx, int dy,
                       const uint8_t *cov, int cov_stride,
                       int sx, int sy, int w, int h, uint32_t rgba) {
    if (!dst || !cov || w <= 0 || h <= 0) return;
    unsigned sr = (rgba>>24)&0xFF, sg = (rgba>>16)&0xFF, sb = (rgba>>8)&0xFF;
    for (int row = 0; row < h; row++) {
        const uint8_t *cr = cov + (size_t)(sy + row) * cov_stride + sx;
        uint32_t      *dr = dst->px + (size_t)(dy + row) * dst->stride + dx;
        for (int col = 0; col < w; col++) {
            unsigned c = cr[col];
            if (c == 0) continue;
            if (c == 255) { dr[col] = (rgba & 0xFFFFFF00u) | 0xFF; continue; }
            uint32_t d = dr[col];
            unsigned ic = 255 - c;
            unsigned r = (sr*c + ((d>>24)&0xFF)*ic) / 255;
            unsigned g = (sg*c + ((d>>16)&0xFF)*ic) / 255;
            unsigned b = (sb*c + ((d>>8) &0xFF)*ic) / 255;
            dr[col] = (r<<24) | (g<<16) | (b<<8) | 0xFF;
        }
    }
}

void gfx_text_flush(void) { }   // host backend draws synchronously — nothing to drain

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

// ---- draw profiler (see gfx.h) — compiled only under -DINSTRUMENTATION ------
#ifdef INSTRUMENTATION
#include <stdio.h>
#ifdef GEM_XTOS
#include "usys.h"
#else
#include <sys/time.h>
#endif

static struct { long long us; long units; int n; } g_gp[GEM_PROF_NSLOTS];

long long gem_prof_now(void)
{
// GEM_HOST: the XTOS stack built against the POSIX shim (hostgem).  GEM_XTOS is still on there — it
// IS the XTOS client/server stack — but the raw trap below is not available to every binary in that
// build: a CLIENT reaches __syscall through the dylib, where libSystem's real __syscall(2) resolves
// first and traps SIGSYS on an XTOS call number.  (The server links the shim directly, so its own
// wins — which is why only the client died, and only with -DINSTRUMENTATION.)  Use POSIX time there.
#if defined(GEM_XTOS) && !defined(GEM_HOST)
    // FOUR words, not three: XTOS returns {sec,?,usec} in 12 bytes; sized for the larger layout so a
    // host-side caller of the shim's gettimeofday cannot overrun it.
    unsigned tv[4] = {0,0,0,0};
    __syscall(SYS_gettimeofday, (long)tv, 0, 0);
    return (long long)tv[0] * 1000000ll + tv[2];
#else
    struct timeval tv; gettimeofday(&tv, NULL);
    return (long long)tv.tv_sec * 1000000ll + tv.tv_usec;
#endif
}

void gem_prof_add(int slot, long long us, long units)
{
    if ((unsigned)slot >= GEM_PROF_NSLOTS) return;
    g_gp[slot].us += us; g_gp[slot].units += units; g_gp[slot].n++;
}

void gem_prof_dump(const char *tag)
{
    static long long last;
    long long now = gem_prof_now();
    if (!last) { last = now; return; }
    if (now - last < 1000000ll) return;
    if (g_gp[GEM_PROF_RENDER].n || g_gp[GEM_PROF_DAMAGE].n) {
        char b[256];
        int n = snprintf(b, sizeof b,
            "[gemprof %s] 1s: render %d/%dms (layout %d/%dms text %d/%dms %ld gl) "
            "alloc %d/%dms blit %d/%dms/%ldkpx fill %d/%ldkpx dmg %d/%ldkpx\n",
            tag,
            g_gp[GEM_PROF_RENDER].n, (int)(g_gp[GEM_PROF_RENDER].us / 1000),
            g_gp[GEM_PROF_LAYOUT].n, (int)(g_gp[GEM_PROF_LAYOUT].us / 1000),
            g_gp[GEM_PROF_TEXT].n,   (int)(g_gp[GEM_PROF_TEXT].us   / 1000),
            g_gp[GEM_PROF_TEXT].units,
            g_gp[GEM_PROF_ALLOC].n,  (int)(g_gp[GEM_PROF_ALLOC].us  / 1000),
            g_gp[GEM_PROF_BLIT].n,   (int)(g_gp[GEM_PROF_BLIT].us   / 1000),
            g_gp[GEM_PROF_BLIT].units / 1000,
            g_gp[GEM_PROF_FILL].n,   g_gp[GEM_PROF_FILL].units / 1000,
            g_gp[GEM_PROF_DAMAGE].n, g_gp[GEM_PROF_DAMAGE].units / 1000);
#ifdef GEM_XTOS
        sys_klog(b, (unsigned)n);
#else
        fputs(b, stderr); (void)n;
#endif
    }
    memset(g_gp, 0, sizeof g_gp);
    last = now;
}
#endif // INSTRUMENTATION
