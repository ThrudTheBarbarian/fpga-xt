// vdi/st_kern.c — vst_kern (237): enable pair kerning, and vst_track_offset
// (237 sub 255): extra uniform letter-spacing.  Kerning only engages if the
// selected face actually carries a kern table — vst_kern returns the mode that
// is really in effect (0 when the font can't kern), per the request to honour
// it only where supported.  Both act on the current face (shared by its sizes).

#include "vdi/vdi.h"
#include "vdi/internal.h"
#include <stddef.h>

#define KERN_TRACK_SUB 255

static font_face *cur_face(vdi_ws *w) {
    return w->text_face ? w->text_face : g_default_face;
}

void op_st_kern(vdi_pb *pb) {
    vdi_ws *w = vdi_ws_of(pb->contrl[6]); if (!w) return;
    font_face *face = cur_face(w);
    if (pb->contrl[5] == KERN_TRACK_SUB) {              // vst_track_offset
        if (face) font_face_set_track(face, pb->intin[0]);
        pb->intout[0] = (int16_t)pb->intin[0];
        return;
    }
    int on = pb->intin[0] != 0;                         // mode 0 = off, else pair-kern
    pb->intout[0] = (int16_t)(face ? font_face_set_kern(face, on) : 0);  // actual mode
}

// Returns the kerning mode actually in effect (0 if the font has no kern table).
int vst_kern(int handle, int mode) {
    g_intin[0] = (int16_t)mode;
    vdi_emit(VDI_ST_KERN, 0, handle, 0, 1);
    return g_intout[0];
}
void vst_track_offset(int handle, int offset) {
    g_intin[0] = (int16_t)offset;
    vdi_emit(VDI_ST_KERN, KERN_TRACK_SUB, handle, 0, 1);
}
