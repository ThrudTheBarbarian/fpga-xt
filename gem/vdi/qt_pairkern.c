// vdi/qt_pairkern.c — vqt_pairkern (235): the kerning adjustment between two
// characters, in pixels (ptsout[0] = x, ptsout[1] = 0).  Reported from the
// face's kern table regardless of whether kerning is currently enabled; 0 if
// the font has none.

#include "vdi/vdi.h"
#include "vdi/internal.h"

void op_qt_pairkern(vdi_pb *pb) {
    pb->ptsout[0] = pb->ptsout[1] = 0;
    vdi_ws *w = vdi_ws_of(pb->contrl[6]); if (!w) return;
    font *f = vdi_ws_font(w); if (!f) return;
    pb->ptsout[0] = (int16_t)font_pair_kern(f, (unsigned)(pb->intin[0] & 0xFFFF),
                                               (unsigned)(pb->intin[1] & 0xFFFF));
}

int vqt_pairkern(int handle, int ch1, int ch2, int *x, int *y) {
    g_intin[0] = (int16_t)ch1; g_intin[1] = (int16_t)ch2;
    vdi_emit(VDI_QT_PAIRKERN, 0, handle, 0, 2);
    if (x) *x = g_ptsout[0];
    if (y) *y = g_ptsout[1];
    return g_ptsout[0];
}
