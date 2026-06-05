// vdi/qt_width.c — vqt_width (one character's cell width).  intin[0] = the
// character; returns the character in intout[0] (or -1 if it has no glyph) and
// ptsout[0]=cell width, ptsout[2]=left delta, ptsout[4]=right delta (the px the
// ink starts right of / extends past the cell).  Used to lay text out by hand.

#include "vdi/vdi.h"
#include "vdi/internal.h"

void op_qt_width(vdi_pb *pb) {
    for (int i = 0; i < 6; i++) pb->ptsout[i] = 0;
    pb->intout[0] = -1;
    vdi_ws *w = vdi_ws_of(pb->contrl[6]); if (!w) return;
    font *f = vdi_ws_font(w); if (!f) return;

    unsigned cp = (unsigned)(pb->intin[0] & 0xFFFF);
    int left = 0, right = 0;
    int cw = font_char_metrics(f, cp, &left, &right);
    if (cw <= 0) return;                       // no glyph -> intout[0] stays -1
    pb->intout[0] = (int16_t)cp;
    pb->ptsout[0] = (int16_t)cw;               // cell width
    pb->ptsout[2] = (int16_t)left;             // left delta
    pb->ptsout[4] = (int16_t)right;            // right delta
}

int vqt_width(int handle, int ch, int *left, int *right) {
    g_intin[0] = (int16_t)ch;
    vdi_emit(VDI_QT_WIDTH, 0, handle, 0, 1);
    if (left)  *left  = g_ptsout[2];
    if (right) *right = g_ptsout[4];
    return g_intout[0] < 0 ? -1 : g_ptsout[0];
}
