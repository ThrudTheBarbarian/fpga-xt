// vdi/opnvwk.c — v_opnvwk / v_clsvwk (open & close a virtual workstation).

#include "vdi/vdi.h"
#include "vdi/internal.h"

void op_opnvwk(vdi_pb *pb) {
    pb->contrl[6] = (int16_t)vdi_ws_alloc();     // return handle (0 = none free)
}
void op_clsvwk(vdi_pb *pb) {
    vdi_ws_free(pb->contrl[6]);                  // never closes the physical ws
}

int v_opnvwk(gfx_surface *target) {
    vdi_emit(VDI_OPNVWK, 0, 0, 0, 0);
    int h = g_contrl[6];
    vdi_ws *w = vdi_ws_of(h);
    if (w) w->target = target;                   // bind target (WM does this for real apps)
    return h;
}
void v_clsvwk(int handle) { vdi_emit(VDI_CLSVWK, 0, handle, 0, 0); }
