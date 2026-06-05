// vdi/qt_trackkern.c — vqt_trackkern (234): the track-kerning adjustment vector.
// We model track kerning as a uniform letter-spacing offset (vst_track_offset),
// so this returns that offset in ptsout[0] (x), ptsout[1] = 0.

#include "vdi/vdi.h"
#include "vdi/internal.h"

void op_qt_trackkern(vdi_pb *pb) {
    pb->ptsout[0] = pb->ptsout[1] = 0;
    vdi_ws *w = vdi_ws_of(pb->contrl[6]); if (!w) return;
    font_face *face = w->text_face ? w->text_face : g_default_face;
    pb->ptsout[0] = (int16_t)font_face_track(face);
}

int vqt_trackkern(int handle, int *x, int *y) {
    vdi_emit(VDI_QT_TRACKKERN, 0, handle, 0, 0);
    if (x) *x = g_ptsout[0];
    if (y) *y = g_ptsout[1];
    return g_ptsout[0];
}
