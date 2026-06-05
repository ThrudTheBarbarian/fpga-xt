// vdi/st_color.c — vst_color (set graphic-text colour).

#include "vdi/vdi.h"
#include "vdi/internal.h"

void op_st_color(vdi_pb *pb) {
    vdi_ws *w = vdi_ws_of(pb->contrl[6]);
    if (w) w->text_color = pb->intin[0];
}

void vst_color(int handle, int pen) {
    g_intin[0] = (int16_t)pen;
    vdi_emit(VDI_ST_COLOR, 0, handle, 0, 1);
}
