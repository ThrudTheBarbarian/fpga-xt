// vdi/clip.c — vs_clip (set / clear the workstation clip rectangle).

#include "vdi/vdi.h"
#include "vdi/internal.h"

void op_clip(vdi_pb *pb) {
    vdi_ws *w = vdi_ws_of(pb->contrl[6]); if (!w) return;
    w->clip_on = pb->intin[0] ? 1 : 0;
    if (w->clip_on) {
        int x0 = pb->ptsin[0], y0 = pb->ptsin[1], x1 = pb->ptsin[2], y1 = pb->ptsin[3];
        w->cx0 = x0 < x1 ? x0 : x1; w->cx1 = x0 < x1 ? x1 : x0;
        w->cy0 = y0 < y1 ? y0 : y1; w->cy1 = y0 < y1 ? y1 : y0;
    }
}

void vs_clip(int handle, int on, const int16_t *pxy) {
    g_intin[0] = (int16_t)(on ? 1 : 0);
    g_ptsin[0] = pxy[0]; g_ptsin[1] = pxy[1]; g_ptsin[2] = pxy[2]; g_ptsin[3] = pxy[3];
    vdi_emit(VDI_CLIP, 0, handle, 2, 1);
}
