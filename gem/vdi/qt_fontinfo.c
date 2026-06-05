// vdi/qt_fontinfo.c — vqt_fontinfo (op 131): structural information about the
// current font, the vector-era counterpart to vqt_attributes' coarse cell box.
// Reports the character range and the five baseline-relative distances (bottom
// of the deepest descender, descent, half line, ascent, top of the accents) so
// a caller can lay out text by the real font geometry rather than a line box.

#include "vdi/vdi.h"
#include "vdi/internal.h"

void op_qt_fontinfo(vdi_pb *pb) {
    vdi_ws *w = vdi_ws_of(pb->contrl[6]); if (!w) return;
    for (int i = 0; i < 5; i++) pb->intout[i] = 0;
    for (int i = 0; i < 10; i++) pb->ptsout[i] = 0;

    pb->intout[0] = 32;                 // minADE — first printable character
    pb->intout[1] = 255;                // maxADE — last (Latin-1)
    // intout[2..4] = special-effect offsets (extra width from thicken/skew etc.)
    pb->intout[2] = (int16_t)((w->text_effects & FX_BOLD)   ? 1 : 0);   // left
    pb->intout[3] = (int16_t)((w->text_effects & (FX_BOLD | FX_ITALIC)) ? 1 : 0); // right
    pb->intout[4] = 0;

    font *f = vdi_ws_font(w); if (!f) return;
    int top, asc, half, desc, bot;
    font_vmetrics(f, &top, &asc, &half, &desc, &bot);
    pb->ptsout[0] = (int16_t)font_max_advance(f);   // maximum cell width
    pb->ptsout[1] = (int16_t)bot;                   // bottom line  (below baseline)
    pb->ptsout[3] = (int16_t)desc;                  // descent line
    pb->ptsout[5] = (int16_t)half;                  // half line
    pb->ptsout[7] = (int16_t)asc;                   // ascent line
    pb->ptsout[9] = (int16_t)top;                   // top line     (accents)
}

// distances[5] = bottom, descent, half, ascent, top.  effects[3] = the special-
// effect left/right/extra offsets.  *minADE/*maxADE = character range,
// *maxwidth = the maximum cell width.
void vqt_fontinfo(int handle, int *minADE, int *maxADE, int16_t distances[5],
                  int *maxwidth, int16_t effects[3]) {
    vdi_emit(VDI_QT_FONTINFO, 0, handle, 0, 0);
    if (minADE)   *minADE   = g_intout[0];
    if (maxADE)   *maxADE   = g_intout[1];
    if (effects)  for (int i = 0; i < 3; i++) effects[i] = g_intout[2 + i];
    if (maxwidth) *maxwidth = g_ptsout[0];
    if (distances) {
        distances[0] = g_ptsout[1]; distances[1] = g_ptsout[3];
        distances[2] = g_ptsout[5]; distances[3] = g_ptsout[7];
        distances[4] = g_ptsout[9];
    }
}
