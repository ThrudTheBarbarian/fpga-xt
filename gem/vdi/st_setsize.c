// vdi/st_setsize.c — anisotropic text width.  vst_setsize (252) / vst_setsize32
// (252, 32-bit) set the character *width* in points independent of the height
// (condensed / expanded text); vst_width (231) sets it in pixels.  Width 0
// restores a square cell.  The raster cache keys on (width,height), so this is
// real anisotropic rendering, not a stretch.  72 dpi => 1pt = 1px.

#include "vdi/vdi.h"
#include "vdi/internal.h"

static void apply_width(vdi_ws *w, int wpx, int16_t *ptsout) {
    w->text_wpx = wpx < 1 ? 0 : wpx;                    // 0 = back to square
    font *f = vdi_ws_font(w);
    if (f && ptsout) {
        ptsout[0] = (int16_t)font_max_advance(f); ptsout[1] = (int16_t)font_ascent(f);
        ptsout[2] = (int16_t)font_max_advance(f); ptsout[3] = (int16_t)font_height(f);
    }
}

void op_st_setsize(vdi_pb *pb) {
    vdi_ws *w = vdi_ws_of(pb->contrl[6]); if (!w) return;
    int wpx;
    if (pb->contrl[5] == 1) {                           // vst_setsize32: 16.16 points
        long fx = (unsigned short)pb->intin[0] | ((long)pb->intin[1] << 16);
        wpx = (int)((fx + 0x8000) >> 16);
    } else wpx = pb->intin[0];
    apply_width(w, wpx, pb->ptsout);
    pb->intout[0] = (int16_t)w->text_wpx;
}

void op_st_width(vdi_pb *pb) {
    vdi_ws *w = vdi_ws_of(pb->contrl[6]); if (!w) return;
    apply_width(w, pb->intin[0], pb->ptsout);
    pb->intout[0] = (int16_t)w->text_wpx;
}

int vst_setsize(int handle, int width_pts, int *wc, int *hc, int *wcell, int *hcell) {
    g_intin[0] = (int16_t)width_pts;
    vdi_emit(VDI_ST_SETSIZE, 0, handle, 0, 1);
    if (wc) *wc = g_ptsout[0]; if (hc) *hc = g_ptsout[1];
    if (wcell) *wcell = g_ptsout[2]; if (hcell) *hcell = g_ptsout[3];
    return g_intout[0];
}
int vst_setsize32(int handle, long width_16_16, int *wc, int *hc, int *wcell, int *hcell) {
    g_intin[0] = (int16_t)(width_16_16 & 0xFFFF);
    g_intin[1] = (int16_t)((width_16_16 >> 16) & 0xFFFF);
    vdi_emit(VDI_ST_SETSIZE, 1, handle, 0, 2);
    if (wc) *wc = g_ptsout[0]; if (hc) *hc = g_ptsout[1];
    if (wcell) *wcell = g_ptsout[2]; if (hcell) *hcell = g_ptsout[3];
    return g_intout[0];
}
int vst_width(int handle, int width_px, int *wc, int *hc, int *wcell, int *hcell) {
    g_intin[0] = (int16_t)width_px;
    vdi_emit(VDI_ST_WIDTH, 0, handle, 0, 1);
    if (wc) *wc = g_ptsout[0]; if (hc) *hc = g_ptsout[1];
    if (wcell) *wcell = g_ptsout[2]; if (hcell) *hcell = g_ptsout[3];
    return g_intout[0];
}
