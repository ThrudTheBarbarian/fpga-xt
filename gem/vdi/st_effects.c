// vdi/st_effects.c — vst_effects (text effects bitmask: thicken / light / skew
// / underline / outline / shadow; see FX_* in font.h).  Applied by v_gtext via
// the FreeType effects path.  Returns the effects in effect.

#include "vdi/vdi.h"
#include "vdi/internal.h"

void op_st_effects(vdi_pb *pb) {
    vdi_ws *w = vdi_ws_of(pb->contrl[6]); if (!w) return;
    w->text_effects = pb->intin[0] & 0x3F;             // six defined bits
    pb->intout[0] = (int16_t)w->text_effects;
}

int vst_effects(int handle, int effects) {
    g_intin[0] = (int16_t)effects;
    vdi_emit(VDI_ST_EFFECTS, 0, handle, 0, 1);
    return g_intout[0];
}
