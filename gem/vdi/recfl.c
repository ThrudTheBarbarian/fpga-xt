// vdi/recfl.c — vr_recfl + v_bar (filled rectangle; GDP sub-opcode 1 = v_bar).
// Both land on op_fillrect, which honours the fill colour & interior style.

#include "vdi/vdi.h"
#include "vdi/internal.h"
#include <string.h>

void op_fillrect(vdi_pb *pb) {
    vdi_ws *w = vdi_ws_of(pb->contrl[6]); if (!w) return;
    int x0 = pb->ptsin[0], y0 = pb->ptsin[1], x1 = pb->ptsin[2], y1 = pb->ptsin[3];
    if (w->fill_interior != VDI_FIS_HOLLOW)             // hollow = perimeter only
        vdi_fill_rect_masked(w, x0, y0, x1, y1, w->fill_color,
                             vdi_fill_mask(w->fill_interior, w->fill_style));
    if (w->fill_perimeter)
        vdi_rect_outline(w, x0, y0, x1, y1, w->fill_color);
}

void vr_recfl(int handle, const int16_t *pxy) {
    memcpy(g_ptsin, pxy, 4 * sizeof(int16_t));
    vdi_emit(VDI_RECFL, 0, handle, 2, 0);
}
void v_bar(int handle, const int16_t *pxy) {
    memcpy(g_ptsin, pxy, 4 * sizeof(int16_t));
    vdi_emit(VDI_GDP, 1, handle, 2, 0);
}
