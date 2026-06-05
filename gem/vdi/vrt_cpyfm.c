// vdi/vrt_cpyfm.c — vrt_cpyfm: copy a 1-bit-per-pixel source to the (colour)
// destination, painting set bits with the foreground pen and clear bits with
// the background pen.  This is how GEM colours monochrome icons/glyphs.  The
// source MFDB is mono: addr is packed bits, MSB = leftmost pixel, and its
// `stride` is the number of 16-bit words per row.  Honours the writing mode.

#include "vdi/vdi.h"
#include "vdi/internal.h"
#include <stddef.h>

void op_vrt_cpyfm(vdi_pb *pb) {
    vdi_ws *w = vdi_ws_of(pb->contrl[6]); if (!w || !g_cpyfm_src || !g_cpyfm_src->addr) return;
    const uint16_t *bits = (const uint16_t *)g_cpyfm_src->addr;
    int swords = g_cpyfm_src->stride;
    gfx_surface dst = vdi_mfdb_surf(g_cpyfm_dst, w);

    int sx1 = pb->ptsin[0], sy1 = pb->ptsin[1], sx2 = pb->ptsin[2], sy2 = pb->ptsin[3];
    int dx1 = pb->ptsin[4], dy1 = pb->ptsin[5];
    if (sx1 > sx2) { int t = sx1; sx1 = sx2; sx2 = t; }
    if (sy1 > sy2) { int t = sy1; sy1 = sy2; sy2 = t; }
    int bw = sx2 - sx1 + 1, bh = sy2 - sy1 + 1;

    int cx0 = 0, cy0 = 0, cx1 = dst.w - 1, cy1 = dst.h - 1;   // clip to the ws rect on-screen
    if (!g_cpyfm_dst || !g_cpyfm_dst->addr) {
        int wx0, wy0, wx1, wy1; vdi_ws_clip(w, &wx0, &wy0, &wx1, &wy1);
        if (wx0 > cx0) cx0 = wx0; if (wy0 > cy0) cy0 = wy0;
        if (wx1 < cx1) cx1 = wx1; if (wy1 < cy1) cy1 = wy1;
    }
    uint32_t fg = vdi_pen_rgba(pb->intin[0]), bg = vdi_pen_rgba(pb->intin[1]);
    int mode = pb->contrl[5] ? pb->contrl[5] : VDI_MD_REPLACE;

    for (int j = 0; j < bh; j++) {
        int sy = sy1 + j, dy = dy1 + j;
        if (dy < cy0 || dy > cy1 || sy < 0 || sy >= g_cpyfm_src->h) continue;
        const uint16_t *srow = bits + (size_t)sy * swords;
        uint32_t *drow = dst.px + (size_t)dy * dst.stride;
        for (int i = 0; i < bw; i++) {
            int sx = sx1 + i, dx = dx1 + i;
            if (dx < cx0 || dx > cx1) continue;
            int bit = (srow[sx >> 4] >> (15 - (sx & 15))) & 1;
            switch (mode) {
                case VDI_MD_TRANS: if (bit)  drow[dx] = fg;                          break;
                case VDI_MD_XOR:   if (bit)  drow[dx] ^= (fg & 0xFFFFFF00u);         break;
                case VDI_MD_ERASE: if (!bit) drow[dx] = fg;                          break;
                default:                     drow[dx] = bit ? fg : bg;               break;
            }
        }
    }
}

void vrt_cpyfm(int handle, int mode, const int16_t *pxy,
               const MFDB *src, const MFDB *dst, const int16_t *col) {
    g_cpyfm_src = src; g_cpyfm_dst = dst;
    for (int i = 0; i < 8; i++) g_ptsin[i] = pxy[i];
    g_intin[0] = col[0]; g_intin[1] = col[1];
    vdi_emit(VDI_VRT_CPYFM, mode, handle, 4, 2);
    g_cpyfm_src = g_cpyfm_dst = NULL;
}
