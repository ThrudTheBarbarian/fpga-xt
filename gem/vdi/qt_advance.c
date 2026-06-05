// vdi/qt_advance.c — vqt_advance (op 247): the advance of one character to
// sub-pixel precision.  Returns the integer advance plus a fractional remainder
// in 1/65536 px, so an app can accumulate exact pen positions (advance_x =
// advx + remx/65536) instead of drifting by the per-glyph rounding error.

#include "vdi/vdi.h"
#include "vdi/internal.h"

void op_qt_advance(vdi_pb *pb) {
    for (int i = 0; i < 4; i++) pb->ptsout[i] = 0;
    vdi_ws *w = vdi_ws_of(pb->contrl[6]); if (!w) return;
    font *f = vdi_ws_font(w); if (!f) return;
    long adv64 = font_f_advance(f, (unsigned)(pb->intin[0] & 0xFFFF));  // 26.6
    long adv16 = adv64 << 10;                            // 26.6 -> 16.16
    pb->ptsout[0] = (int16_t)(adv16 >> 16);              // integer advance x
    pb->ptsout[1] = 0;                                   // advance y (horizontal)
    pb->ptsout[2] = (int16_t)(adv16 & 0xFFFF);           // fractional x (/65536)
    pb->ptsout[3] = 0;                                   // fractional y
}

// advance_x = *advx + *remx/65536 (px); *advy/*remy = 0 for horizontal text.
void vqt_advance(int handle, int ch, int *advx, int *advy, int *remx, int *remy) {
    g_intin[0] = (int16_t)ch;
    vdi_emit(VDI_QT_ADVANCE, 0, handle, 0, 1);
    if (advx) *advx = g_ptsout[0];
    if (advy) *advy = g_ptsout[1];
    if (remx) *remx = (uint16_t)g_ptsout[2];
    if (remy) *remy = (uint16_t)g_ptsout[3];
}
// Same advance as one 16.16 fixed value per axis (*advx/*advy), the full-
// precision form (integer part << 16 | fractional part).
void vqt_advance32(int handle, int ch, long *advx, long *advy) {
    g_intin[0] = (int16_t)ch;
    vdi_emit(VDI_QT_ADVANCE, 0, handle, 0, 1);
    if (advx) *advx = ((long)g_ptsout[0] << 16) | (uint16_t)g_ptsout[2];
    if (advy) *advy = ((long)g_ptsout[1] << 16) | (uint16_t)g_ptsout[3];
}
