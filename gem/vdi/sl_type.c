// vdi/sl_type.c — vsl_type (line style: 1 solid, 2 long-dash, 3 dotted,
// 4 dash-dot, 5 dashed, 6 dash-dot-dot).  Applied by vdi_line's dash pattern.

#include "vdi/vdi.h"
#include "vdi/internal.h"

void op_sl_type(vdi_pb *pb) {
    vdi_ws *w = vdi_ws_of(pb->contrl[6]); if (!w) return;
    int t = pb->intin[0]; if (t < 1) t = 1; if (t > 7) t = 7;   // 7 = user (vsl_udsty)
    w->line_type = t;
    pb->intout[0] = (int16_t)t;
}

int vsl_type(int handle, int style) {
    g_intin[0] = (int16_t)style;
    vdi_emit(VDI_SL_TYPE, 0, handle, 0, 1);
    return g_intout[0];
}
