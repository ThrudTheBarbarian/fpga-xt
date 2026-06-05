// vdi/st_alignment.c — vst_alignment (set the v_gtext anchor).  Horizontal:
// left/center/right.  Vertical uses the GEM codes (baseline/half/ascent/bottom/
// descent/top); op_gtext turns the anchor into the em-box top-left it draws at.

#include "vdi/vdi.h"
#include "vdi/internal.h"

void op_st_alignment(vdi_pb *pb) {
    vdi_ws *w = vdi_ws_of(pb->contrl[6]); if (!w) return;
    int h = pb->intin[0], v = pb->intin[1];
    if (h < VDI_TA_LEFT)     h = VDI_TA_LEFT;
    if (h > VDI_TA_RIGHT)    h = VDI_TA_RIGHT;
    if (v < VDI_TA_BASELINE) v = VDI_TA_BASELINE;
    if (v > VDI_TA_TOP)      v = VDI_TA_TOP;
    w->text_halign = h; w->text_valign = v;
    pb->intout[0] = (int16_t)h; pb->intout[1] = (int16_t)v;
}

void vst_alignment(int handle, int halign, int valign, int *set_h, int *set_v) {
    g_intin[0] = (int16_t)halign; g_intin[1] = (int16_t)valign;
    vdi_emit(VDI_ST_ALIGN, 0, handle, 0, 2);
    if (set_h) *set_h = g_intout[0];
    if (set_v) *set_v = g_intout[1];
}
