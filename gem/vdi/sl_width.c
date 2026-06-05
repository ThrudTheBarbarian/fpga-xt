// vdi/sl_width.c — vsl_width (line width in pixels; the width arrives as the x
// of a point, GEM-style).  vdi_line stamps a square brush of this size.

#include "vdi/vdi.h"
#include "vdi/internal.h"

void op_sl_width(vdi_pb *pb) {
    vdi_ws *w = vdi_ws_of(pb->contrl[6]); if (!w) return;
    int width = pb->ptsin[0]; if (width < 1) width = 1;
    w->line_width = width;
    pb->ptsout[0] = (int16_t)width; pb->ptsout[1] = 0;
}

int vsl_width(int handle, int width) {
    g_ptsin[0] = (int16_t)width; g_ptsin[1] = 0;
    vdi_emit(VDI_SL_WIDTH, 0, handle, 1, 0);
    return g_ptsout[0];
}
