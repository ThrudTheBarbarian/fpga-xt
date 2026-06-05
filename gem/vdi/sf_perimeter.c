// vdi/sf_perimeter.c — vsf_perimeter (outline filled areas in the fill colour).
// On by default (GEM); for a solid same-colour fill the outline is invisible.

#include "vdi/vdi.h"
#include "vdi/internal.h"

void op_sf_perimeter(vdi_pb *pb) {
    vdi_ws *w = vdi_ws_of(pb->contrl[6]);
    if (w) w->fill_perimeter = pb->intin[0] ? 1 : 0;
}

void vsf_perimeter(int handle, int on) {
    g_intin[0] = (int16_t)(on ? 1 : 0);
    vdi_emit(VDI_SF_PERIM, 0, handle, 0, 1);
}
