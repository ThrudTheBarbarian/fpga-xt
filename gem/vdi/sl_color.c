// vdi/sl_color.c — vsl_color (set polyline / line colour).

#include "vdi/vdi.h"
#include "vdi/internal.h"

void op_sl_color(vdi_pb *pb) {
    vdi_ws *w = vdi_ws_of(pb->contrl[6]);
    if (w) w->line_color = pb->intin[0];
}

void vsl_color(int handle, int pen) {
    g_intin[0] = (int16_t)pen;
    vdi_emit(VDI_SL_COLOR, 0, handle, 0, 1);
}
