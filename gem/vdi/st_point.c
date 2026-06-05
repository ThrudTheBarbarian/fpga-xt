// vdi/st_point.c — vst_point (set text size in points).  Points convert to
// pixels at VDI_TEXT_DPI (72 -> 1 point == 1 px), then it's vst_height.

#include "vdi/vdi.h"
#include "vdi/internal.h"

static int pt_to_px(int pt) { return (pt * VDI_TEXT_DPI + 36) / 72; }
static int px_to_pt(int px) { return (px * 72 + VDI_TEXT_DPI / 2) / VDI_TEXT_DPI; }

void op_st_point(vdi_pb *pb) {
    vdi_ws *w = vdi_ws_of(pb->contrl[6]); if (!w) return;
    int px = vdi_set_text_px(w, pt_to_px(pb->intin[0]), pb->ptsout);
    pb->intout[0] = (int16_t)(px ? px_to_pt(px) : 0);   // selected point size
}

int vst_point(int handle, int points, int *cw, int *ch, int *cellw, int *cellh) {
    g_intin[0] = (int16_t)points;
    vdi_emit(VDI_ST_POINT, 0, handle, 0, 1);
    if (cw)    *cw    = g_ptsout[0];
    if (ch)    *ch    = g_ptsout[1];
    if (cellw) *cellw = g_ptsout[2];
    if (cellh) *cellh = g_ptsout[3];
    return g_intout[0];
}
