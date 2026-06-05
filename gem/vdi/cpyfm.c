// vdi/cpyfm.c — vro_cpyfm (opaque raster copy, VRO_COPY).  MFDB pointers travel
// out-of-band via g_cpyfm_src/dst (not packed in the WORD arrays).

#include "vdi/vdi.h"
#include "vdi/internal.h"
#include <string.h>

void op_cpyfm(vdi_pb *pb) {
    vdi_ws *w = vdi_ws_of(pb->contrl[6]); if (!w || !g_cpyfm_src) return;
    gfx_surface src = vdi_mfdb_surf(g_cpyfm_src, w);
    gfx_surface dst = vdi_mfdb_surf(g_cpyfm_dst, w);
    int sx1 = pb->ptsin[0], sy1 = pb->ptsin[1], sx2 = pb->ptsin[2], sy2 = pb->ptsin[3];
    int dx1 = pb->ptsin[4], dy1 = pb->ptsin[5];
    if (sx1 > sx2) { int t = sx1; sx1 = sx2; sx2 = t; }
    if (sy1 > sy2) { int t = sy1; sy1 = sy2; sy2 = t; }
    int bw = sx2 - sx1 + 1, bh = sy2 - sy1 + 1;
    // Clip the destination to the ws clip rect when copying to the screen target.
    if (!g_cpyfm_dst || !g_cpyfm_dst->addr) {
        int cx0, cy0, cx1, cy1; vdi_ws_clip(w, &cx0, &cy0, &cx1, &cy1);
        if (dx1 < cx0) { int d = cx0 - dx1; sx1 += d; bw -= d; dx1 = cx0; }
        if (dy1 < cy0) { int d = cy0 - dy1; sy1 += d; bh -= d; dy1 = cy0; }
        if (dx1 + bw - 1 > cx1) bw = cx1 - dx1 + 1;
        if (dy1 + bh - 1 > cy1) bh = cy1 - dy1 + 1;
    }
    if (bw > 0 && bh > 0) gfx_blit(&dst, dx1, dy1, &src, sx1, sy1, bw, bh);
}

void vro_cpyfm(int handle, int mode, const int16_t *pxy, const MFDB *src, const MFDB *dst) {
    g_cpyfm_src = src; g_cpyfm_dst = dst;
    memcpy(g_ptsin, pxy, 8 * sizeof(int16_t));      // src x1,y1,x2,y2 + dst x1,y1,x2,y2
    vdi_emit(VDI_CPYFM, mode, handle, 4, 0);
    g_cpyfm_src = g_cpyfm_dst = NULL;
}
