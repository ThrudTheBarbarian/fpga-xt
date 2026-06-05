// vdi/sl_ends.c — vsl_ends (polyline end styles for the start and end point).
// VDI_LE_SQUARE / VDI_LE_ROUND both render with the round line pen; VDI_LE_ARROW
// adds a filled arrowhead (op_pline draws it).

#include "vdi/vdi.h"
#include "vdi/internal.h"

static int clamp_end(int v) { return (v < 0 || v > 2) ? 0 : v; }

void op_sl_ends(vdi_pb *pb) {
    vdi_ws *w = vdi_ws_of(pb->contrl[6]); if (!w) return;
    w->line_beg = clamp_end(pb->intin[0]);
    w->line_end = clamp_end(pb->intin[1]);
}

void vsl_ends(int handle, int beg, int end) {
    g_intin[0] = (int16_t)beg; g_intin[1] = (int16_t)end;
    vdi_emit(VDI_SL_ENDS, 0, handle, 0, 2);
}
