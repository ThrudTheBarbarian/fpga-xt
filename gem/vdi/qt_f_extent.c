// vdi/qt_f_extent.c — vqt_f_extent (op 240): like vqt_extent, but the width is
// the sum of the glyphs' *fractional* advances, rounded once at the end, instead
// of the per-glyph-rounded integer sum.  Over a long string that removes the
// accumulated half-pixel-per-glyph error, so the box tracks the real ink.  Same
// 4-corner output (LL, LR, UR, UL), size/effects/rotation-aware.

#include "vdi/vdi.h"
#include "vdi/internal.h"
#include <math.h>

void op_qt_f_extent(vdi_pb *pb) {
    vdi_ws *w = vdi_ws_of(pb->contrl[6]); if (!w) return;
    for (int i = 0; i < 8; i++) pb->ptsout[i] = 0;
    font *f = vdi_ws_font(w); if (!f) return;

    int n = pb->contrl[3]; if (n < 0) n = 0; if (n > 127) n = 127;
    char buf[128];
    for (int i = 0; i < n; i++) buf[i] = (char)pb->intin[i];
    buf[n] = '\0';

    double W = font_f_text_width(f, buf) / 64.0;        // fractional pen advance
    double H = font_height(f), asc = font_ascent(f);
    if (w->text_effects & FX_ITALIC) W += 0.21 * H;     // shear overhang
    double cx[4] = { 0, W, W, 0 }, cy[4] = { H, H, 0, 0 };
    double th = w->text_rotation * (M_PI / 1800.0), c = cos(th), s = sin(th);
    for (int i = 0; i < 4; i++) {                        // rotate about the baseline
        double rx = cx[i], ry = cy[i] - asc;
        pb->ptsout[2*i]   = (int16_t)lround(rx * c + ry * s);
        pb->ptsout[2*i+1] = (int16_t)lround(-rx * s + ry * c + asc);
    }
}

void vqt_f_extent(int handle, const char *s, int16_t *extent) {
    int n = 0; while (s[n] && n < 127) { g_intin[n] = (unsigned char)s[n]; n++; }
    vdi_emit(VDI_QT_F_EXTENT, 0, handle, 0, n);
    if (extent) for (int i = 0; i < 8; i++) extent[i] = g_ptsout[i];
}
