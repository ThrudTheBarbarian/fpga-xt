// vdi/sf_color.c — vsf_color (set fill colour).

#include "vdi/vdi.h"
#include "vdi/internal.h"

void op_sf_color(vdi_pb *pb) {
    vdi_ws *w = vdi_ws_of(pb->contrl[6]);
    if (w) w->fill_color = pb->intin[0];
}

void vsf_color(int handle, int pen) {
    g_intin[0] = (int16_t)pen;
    vdi_emit(VDI_SF_COLOR, 0, handle, 0, 1);
}
