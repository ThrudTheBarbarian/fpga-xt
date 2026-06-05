// vdi/st_arbpt.c — vst_arbpt (op 246): select an arbitrary text size in points.
// Like vst_point, but the "arbitrary" entry that NVDI apps use to request any
// size without snapping to a bitmap-font table — which is a no-op distinction
// for a scalable (FreeType) device: every size is native.  72 dpi => 1pt = 1px.
// Reports char/cell metrics in ptsout and returns the size used.

#include "vdi/vdi.h"
#include "vdi/internal.h"

void op_st_arbpt(vdi_pb *pb) {
    vdi_ws *w = vdi_ws_of(pb->contrl[6]); if (!w) return;
    int px;
    if (pb->contrl[5] == 1) {                           // vst_arbpt32: 16.16 points
        long fx = (unsigned short)pb->intin[0] | ((long)pb->intin[1] << 16);
        px = (int)((fx + 0x8000) >> 16);                // raster cache is integer-px
    } else px = pb->intin[0];
    pb->intout[0] = (int16_t)vdi_set_text_px(w, px, pb->ptsout);
}

int vst_arbpt(int handle, int point, int *wchar, int *hchar, int *wcell, int *hcell) {
    g_intin[0] = (int16_t)point;
    vdi_emit(VDI_ST_ARBPT, 0, handle, 0, 1);
    if (wchar) *wchar = g_ptsout[0];
    if (hchar) *hchar = g_ptsout[1];
    if (wcell) *wcell = g_ptsout[2];
    if (hcell) *hcell = g_ptsout[3];
    return g_intout[0];
}
// Arbitrary size from a 16.16 fixed-point point value (rounded to whole px for
// the raster; fractional *metrics* come from vqt_f_extent / vqt_advance).
int vst_arbpt32(int handle, long point_16_16, int *wchar, int *hchar, int *wcell, int *hcell) {
    g_intin[0] = (int16_t)(point_16_16 & 0xFFFF);
    g_intin[1] = (int16_t)((point_16_16 >> 16) & 0xFFFF);
    vdi_emit(VDI_ST_ARBPT, 1, handle, 0, 2);
    if (wchar) *wchar = g_ptsout[0];
    if (hchar) *hchar = g_ptsout[1];
    if (wcell) *wcell = g_ptsout[2];
    if (hcell) *hcell = g_ptsout[3];
    return g_intout[0];
}
