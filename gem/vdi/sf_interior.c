// vdi/sf_interior.c — vsf_interior (set fill interior style: 0 hollow, 1 solid).

#include "vdi/vdi.h"
#include "vdi/internal.h"

void op_sf_interior(vdi_pb *pb) {
    vdi_ws *w = vdi_ws_of(pb->contrl[6]);
    if (w) w->fill_interior = pb->intin[0];
}

void vsf_interior(int handle, int style) {
    g_intin[0] = (int16_t)style;
    vdi_emit(VDI_SF_INTERIOR, 0, handle, 0, 1);
}
