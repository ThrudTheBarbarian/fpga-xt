// vdi/qt_extent.c — vqt_extent (text bounding box).  Returns the four corners of
// the box enclosing the string in the current font/size/effects/rotation, as
// offsets from the text origin: lower-left, lower-right, upper-right, upper-left
// (ptsout[0..7]).  The box is rotated the same way v_gtext draws, so corner +
// draw-position line up.

#include "vdi/vdi.h"
#include "vdi/internal.h"
#include <math.h>

void op_qt_extent(vdi_pb *pb) {
    // Clear FIRST, then validate: bailing on a bad handle before zeroing left
    // ptsout holding whatever the previous VDI call put there, so a caller that
    // measured through an unbound workstation got STALE GARBAGE rather than a
    // defined answer — and silently, since there is no return code.  Measured
    // -1919 for a string 190 px wide (host, 2026-08-13).  A zero extent is still
    // wrong, but it is wrong the same way every time, which is debuggable.
    for (int i = 0; i < 8; i++) pb->ptsout[i] = 0;
    vdi_ws *w = vdi_ws_of(pb->contrl[6]); if (!w) return;
    font *f = vdi_ws_font(w); if (!f) return;

    int n = pb->contrl[3]; if (n < 0) n = 0; if (n > 127) n = 127;
    char buf[128];
    for (int i = 0; i < n; i++) buf[i] = (char)pb->intin[i];
    buf[n] = '\0';

    double W = font_text_width(f, buf), H = font_height(f), asc = font_ascent(f);
    if (w->text_effects & FX_ITALIC) W += 0.21 * H;     // shear overhang
    // Corners (local, device y-down): LL(0,H) LR(W,H) UR(W,0) UL(0,0).  Rotate
    // about the baseline (0,asc) — the same pivot font_draw_fx uses.
    double cx[4] = { 0, W, W, 0 }, cy[4] = { H, H, 0, 0 };
    double th = w->text_rotation * (M_PI / 1800.0), c = cos(th), s = sin(th);
    for (int i = 0; i < 4; i++) {
        double rx = cx[i], ry = cy[i] - asc;
        pb->ptsout[2*i]   = (int16_t)lround(rx * c + ry * s);
        pb->ptsout[2*i+1] = (int16_t)lround(-rx * s + ry * c + asc);
    }
}

void vqt_extent(int handle, const char *s, int16_t *extent) {
    int n = 0; while (s[n] && n < 127) { g_intin[n] = (unsigned char)s[n]; n++; }
    vdi_emit(VDI_QT_EXTENT, 0, handle, 0, n);
    if (extent) for (int i = 0; i < 8; i++) extent[i] = g_ptsout[i];
}
