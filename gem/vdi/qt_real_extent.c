// vdi/qt_real_extent.c — vqt_real_extent (240 sub 4200): the tight *inked*
// bounding box of a string (the union of the glyph bitmaps), as opposed to
// vqt_extent's cell box.  Same 4-corner output (LL, LR, UR, UL), offsets from
// the text origin; upright (no rotation) — it's used for precise framing.

#include "vdi/vdi.h"
#include "vdi/internal.h"

void op_qt_real_extent(vdi_pb *pb) {
    vdi_ws *w = vdi_ws_of(pb->contrl[6]); if (!w) return;
    for (int i = 0; i < 8; i++) pb->ptsout[i] = 0;
    font *f = vdi_ws_font(w); if (!f) return;

    int n = pb->contrl[3]; if (n < 0) n = 0; if (n > 127) n = 127;
    char buf[128];
    for (int i = 0; i < n; i++) buf[i] = (char)pb->intin[i];
    buf[n] = '\0';

    int x0, y0, x1, y1;
    font_ink_extent(f, buf, &x0, &y0, &x1, &y1);         // y0 = top, y1 = bottom
    pb->ptsout[0] = (int16_t)x0; pb->ptsout[1] = (int16_t)y1;   // LL
    pb->ptsout[2] = (int16_t)x1; pb->ptsout[3] = (int16_t)y1;   // LR
    pb->ptsout[4] = (int16_t)x1; pb->ptsout[5] = (int16_t)y0;   // UR
    pb->ptsout[6] = (int16_t)x0; pb->ptsout[7] = (int16_t)y0;   // UL
}

void vqt_real_extent(int handle, const char *s, int16_t *extent) {
    int n = 0; while (s[n] && n < 127) { g_intin[n] = (unsigned char)s[n]; n++; }
    vdi_emit(VDI_QT_F_EXTENT, 4200, handle, 0, n);       // op 240, sub 4200
    if (extent) for (int i = 0; i < 8; i++) extent[i] = g_ptsout[i];
}
