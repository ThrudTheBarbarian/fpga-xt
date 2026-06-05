// vdi/st_skew.c — vst_skew (253): an arbitrary text shear angle (tenths of a
// degree), the continuous cousin of the fixed italic effect.  Folded into the
// transform matrix in font_draw_fx, so it composes with rotation and the other
// effects.  0 = upright.

#include "vdi/vdi.h"
#include "vdi/internal.h"

void op_st_skew(vdi_pb *pb) {
    vdi_ws *w = vdi_ws_of(pb->contrl[6]); if (!w) return;
    pb->intout[0] = (int16_t)w->text_skew;              // previous
    w->text_skew = pb->intin[0];                        // tenths of a degree
}

int vst_skew(int handle, int skew_tenths) {
    g_intin[0] = (int16_t)skew_tenths;
    vdi_emit(VDI_ST_SKEW, 0, handle, 0, 1);
    return g_intout[0];
}
