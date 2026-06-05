// vdi/st_arbpt.c — vst_arbpt (op 246): select an arbitrary text size in points.
// Like vst_point, but the "arbitrary" entry that NVDI apps use to request any
// size without snapping to a bitmap-font table — which is a no-op distinction
// for a scalable (FreeType) device: every size is native.  72 dpi => 1pt = 1px.
// Reports char/cell metrics in ptsout and returns the size used.

#include "vdi/vdi.h"
#include "vdi/internal.h"

void op_st_arbpt(vdi_pb *pb) {
    vdi_ws *w = vdi_ws_of(pb->contrl[6]); if (!w) return;
    pb->intout[0] = (int16_t)vdi_set_text_px(w, pb->intin[0], pb->ptsout);
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
