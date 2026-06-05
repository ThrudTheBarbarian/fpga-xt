// vdi/st_rotation.c — vst_rotation (text baseline angle, tenths of a degree,
// CCW).  Classic GEM only managed 0/90/180/270; we rotate the glyph outlines
// via FreeType, so any angle works.  Returns the angle in effect.

#include "vdi/vdi.h"
#include "vdi/internal.h"

void op_st_rotation(vdi_pb *pb) {
    vdi_ws *w = vdi_ws_of(pb->contrl[6]); if (!w) return;
    int a = pb->intin[0] % 3600; if (a < 0) a += 3600;
    w->text_rotation = a;
    pb->intout[0] = (int16_t)a;
}

int vst_rotation(int handle, int angle) {
    g_intin[0] = (int16_t)angle;
    vdi_emit(VDI_ST_ROTATION, 0, handle, 0, 1);
    return g_intout[0];
}
