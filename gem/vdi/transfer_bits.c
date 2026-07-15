// vdi/transfer_bits.c — vr_transfer_bits (170): copy a source rectangle onto a
// destination rectangle of a possibly different size (nearest-neighbour scaling)
// with a raster operation.  Both MFDBs are device format (chunky RGBA-8888);
// dst NULL = the workstation's target surface (clipped to its clip rect).
// Modes 0-15 are the BitBlt logic ops applied to the RGB bits (alpha kept
// opaque); 16-19 are the extended blends using the hilite/min/max/weight colours.

#include "vdi/vdi.h"
#include "vdi/internal.h"
#include <stddef.h>

static uint32_t logic_op(int mode, uint32_t s, uint32_t d) {
    uint32_t r;
    switch (mode & 15) {
        case 0:  r = 0;          break;   case 1:  r = s & d;      break;
        case 2:  r = s & ~d;     break;   case 3:  r = s;          break;   // copy
        case 4:  r = ~s & d;     break;   case 5:  r = d;          break;
        case 6:  r = s ^ d;      break;   case 7:  r = s | d;      break;
        case 8:  r = ~(s | d);   break;   case 9:  r = ~(s ^ d);   break;
        case 10: r = ~d;         break;   case 11: r = s | ~d;     break;
        case 12: r = ~s;         break;   case 13: r = ~s | d;     break;
        case 14: r = ~(s & d);   break;   default: r = ~0u;        break;   // 15
    }
    return (r & 0xFFFFFF00u) | 0xFF;      // keep the surface opaque
}

#define CH(v,sh) (int)(((v) >> (sh)) & 0xFF)
static int clampi(int v, int lo, int hi) { return v < lo ? lo : v > hi ? hi : v; }

static uint32_t blend_op(int mode, uint32_t s, uint32_t d) {
    uint32_t hi = vdi_pen_rgba(g_hilite_color), mn = vdi_pen_rgba(g_min_color),
             mx = vdi_pen_rgba(g_max_color), wt = vdi_pen_rgba(g_weight_color);
    if (mode == VR_HILITE) return (s & 0xFFFFFF00u) ? ((hi & 0xFFFFFF00u) | 0xFF) : d;
    if (mode == VR_OVER) {                // src-over using the source's own alpha
        int a = (int)(s & 0xFF);
        if (a == 0) return d;             // fully transparent: keep dst
        if (a == 255) return (s & 0xFFFFFF00u) | 0xFF;
        int r = (CH(s,24)*a + CH(d,24)*(255-a)) / 255;
        int g = (CH(s,16)*a + CH(d,16)*(255-a)) / 255;
        int b = (CH(s,8) *a + CH(d,8) *(255-a)) / 255;
        return GFX_RGB(r, g, b);
    }
    int r, g, b;
    if (mode == VR_MAX) {                 // additive, ceilinged by max_colour
        r = clampi(CH(s,24)+CH(d,24), 0, CH(mx,24));
        g = clampi(CH(s,16)+CH(d,16), 0, CH(mx,16));
        b = clampi(CH(s,8) +CH(d,8),  0, CH(mx,8));
    } else if (mode == VR_MIN) {          // subtractive, floored by min_colour
        r = clampi(CH(d,24)-CH(s,24), CH(mn,24), 255);
        g = clampi(CH(d,16)-CH(s,16), CH(mn,16), 255);
        b = clampi(CH(d,8) -CH(s,8),  CH(mn,8),  255);
    } else {                              // VR_BLEND: per-channel weight from weight_colour
        int wr = CH(wt,24), wg = CH(wt,16), wb = CH(wt,8);
        r = (CH(s,24)*wr + CH(d,24)*(255-wr)) / 255;
        g = (CH(s,16)*wg + CH(d,16)*(255-wg)) / 255;
        b = (CH(s,8) *wb + CH(d,8) *(255-wb)) / 255;
    }
    return GFX_RGB(r, g, b);
}

void op_transfer_bits(vdi_pb *pb) {
    const MFDB *sm = g_cpyfm_src, *dm = g_cpyfm_dst;
    vdi_ws *w = vdi_ws_of(pb->contrl[6]); if (!w || !sm || !sm->addr) return;
    gfx_surface src = vdi_mfdb_surf(sm, w);
    gfx_surface dst = (dm && dm->addr) ? vdi_mfdb_surf(dm, w) : *w->target;
    int mode = pb->intin[0];

    int sx1 = pb->ptsin[0], sy1 = pb->ptsin[1], sx2 = pb->ptsin[2], sy2 = pb->ptsin[3];
    int dx1 = pb->ptsin[4], dy1 = pb->ptsin[5], dx2 = pb->ptsin[6], dy2 = pb->ptsin[7];
    if (dx2 < dx1) { int t = dx1; dx1 = dx2; dx2 = t; t = sx1; sx1 = sx2; sx2 = t; }
    if (dy2 < dy1) { int t = dy1; dy1 = dy2; dy2 = t; t = sy1; sy1 = sy2; sy2 = t; }
    int dw = dx2 - dx1 + 1, dh = dy2 - dy1 + 1, sw = sx2 - sx1 + 1, sh = sy2 - sy1 + 1;
    if (dw < 1 || dh < 1) return;

    int cx0 = 0, cy0 = 0, cx1 = dst.w - 1, cy1 = dst.h - 1;
    if (!(dm && dm->addr)) vdi_ws_clip(w, &cx0, &cy0, &cx1, &cy1);   // screen: honour the clip

    /* Intersect the destination rect with the clip (and the surface) ONCE, then walk
     * only that span — rather than iterating every pixel of the sprite and testing
     * each one against the clip.  This is load-bearing for damage-rect redraws:
     * wind_redraw_area re-renders the WHOLE desktop clipped to the damage rect, so
     * without an early reject every icon/sprite on screen was walked pixel-by-pixel
     * (testing, discarding, drawing nothing) just to paint one icon's worth of
     * damage.  A sprite wholly outside the damage rect now costs O(1) instead of
     * O(w*h), and a partly-visible one only touches its visible pixels.  cpyfm.c
     * already clamped this way; this blitter (the alpha-blended icon/theme path)
     * never did.  The source mapping still divides by the ORIGINAL dst rect
     * (dx1/dw, dy1/dh), so scaling is unchanged — we just skip pixels that the
     * per-pixel test would have thrown away anyway.  Output is bit-identical. */
    if (cx0 < 0) cx0 = 0;   if (cx1 > dst.w - 1) cx1 = dst.w - 1;
    if (cy0 < 0) cy0 = 0;   if (cy1 > dst.h - 1) cy1 = dst.h - 1;
    int gx0 = dx1 > cx0 ? dx1 : cx0, gx1 = dx2 < cx1 ? dx2 : cx1;
    int gy0 = dy1 > cy0 ? dy1 : cy0, gy1 = dy2 < cy1 ? dy2 : cy1;
    if (gx0 > gx1 || gy0 > gy1) return;                              // wholly clipped -> nothing to do

    long long gp_t0 = gem_prof_now();                                // TEMP profiler

    /* COPY (3) and VR_OVER take dedicated loops, scaled or not; the generic per-pixel
     * dispatch below is for everything else.  This matters at desktop scale, twice over
     * and both board-measured: a 1920x1080 wallpaper pass through the generic loop was
     * 1.3s for ONE full-screen render (2M function calls, blend_op re-deriving the four
     * blend pen colours per pixel), and the CHROME — 9-slice edges and title bars, which
     * STRETCH and so miss any unscaled-only path — was 550ns/px of gemd's composite,
     * saturating the server during a live resize.  All specialized loops are
     * bit-identical to what the generic loop produces (same sx/sy rounding math). */
    if (mode == 3 || mode == VR_OVER) {
        int unscaled = (sw == dw && sh == dh);
        for (int dy = gy0; dy <= gy1; dy++) {
            int sy = unscaled ? sy1 + (dy - dy1) : sy1 + (dy - dy1) * sh / dh;
            if (sy < 0 || sy >= src.h) continue;
            uint32_t       *drow = dst.px + (size_t)dy * dst.stride;
            const uint32_t *srow = src.px + (size_t)sy * src.stride;
            if (mode == 3) {
                for (int dx = gx0; dx <= gx1; dx++) {                // copy, alpha forced opaque
                    int sx = unscaled ? sx1 + (dx - dx1) : sx1 + (dx - dx1) * sw / dw;
                    if (sx < 0 || sx >= src.w) continue;
                    drow[dx] = (srow[sx] & 0xFFFFFF00u) | 0xFF;
                }
            } else {
                for (int dx = gx0; dx <= gx1; dx++) {                // src-over, source alpha
                    int sx = unscaled ? sx1 + (dx - dx1) : sx1 + (dx - dx1) * sw / dw;
                    if (sx < 0 || sx >= src.w) continue;
                    uint32_t s = srow[sx];
                    unsigned a = s & 0xFF;
                    if (a == 0) continue;
                    if (a == 255) { drow[dx] = (s & 0xFFFFFF00u) | 0xFF; continue; }
                    uint32_t d = drow[dx];
                    int r = (CH(s,24)*(int)a + CH(d,24)*(255-(int)a)) / 255;
                    int g = (CH(s,16)*(int)a + CH(d,16)*(255-(int)a)) / 255;
                    int b = (CH(s,8) *(int)a + CH(d,8) *(255-(int)a)) / 255;
                    drow[dx] = GFX_RGB(r, g, b);
                }
            }
        }
    } else {
        for (int dy = gy0; dy <= gy1; dy++) {
            int sy = sy1 + (dy - dy1) * sh / dh;
            if (sy < 0 || sy >= src.h) continue;
            uint32_t *drow = dst.px + (size_t)dy * dst.stride;
            const uint32_t *srow = src.px + (size_t)sy * src.stride;
            for (int dx = gx0; dx <= gx1; dx++) {
                int sx = sx1 + (dx - dx1) * sw / dw;
                if (sx < 0 || sx >= src.w) continue;
                uint32_t s = srow[sx], d = drow[dx];
                drow[dx] = (mode < 16) ? logic_op(mode, s, d) : blend_op(mode, s, d);
            }
        }
    }
    gem_prof_add(GEM_PROF_BLIT, gem_prof_now() - gp_t0,              // TEMP profiler
                 (long)(gx1 - gx0 + 1) * (gy1 - gy0 + 1));
}

// pxy = src x1,y1,x2,y2, dst x1,y1,x2,y2 (different sizes => scaled).
void vr_transfer_bits(int handle, const MFDB *src, const MFDB *dst,
                      const int16_t *pxy, int mode) {
    g_cpyfm_src = src; g_cpyfm_dst = dst;
    for (int i = 0; i < 8; i++) g_ptsin[i] = pxy[i];
    g_intin[0] = (int16_t)mode;
    vdi_emit(VDI_TRANSFER_BITS, 0, handle, 4, 1);
    g_cpyfm_src = g_cpyfm_dst = 0;
}
