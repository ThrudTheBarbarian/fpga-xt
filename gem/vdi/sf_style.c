// vdi/sf_style.c — vsf_style (select the pattern/hatch index used when the fill
// interior is VDI_FIS_PATTERN or VDI_FIS_HATCH).  1-based, clamped at fill time.

#include "vdi/vdi.h"
#include "vdi/internal.h"

void op_sf_style(vdi_pb *pb) {
    vdi_ws *w = vdi_ws_of(pb->contrl[6]);
    if (w) w->fill_style = pb->intin[0];
}

void vsf_style(int handle, int index) {
    g_intin[0] = (int16_t)index;
    vdi_emit(VDI_SF_STYLE, 0, handle, 0, 1);
}
