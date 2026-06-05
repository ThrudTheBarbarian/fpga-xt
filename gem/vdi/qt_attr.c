// vdi/qt_attr.c — vqt_attributes (current text attributes).  Reports the font
// id, colour, rotation (tenths of a degree), horizontal/vertical alignment and
// writing mode in intout[0..5], and char/cell width/height in ptsout[0..3]
// (the same metrics vst_height returns).

#include "vdi/vdi.h"
#include "vdi/internal.h"

void op_qt_attr(vdi_pb *pb) {
    vdi_ws *w = vdi_ws_of(pb->contrl[6]); if (!w) return;
    pb->intout[0] = (int16_t)w->text_font_id;
    pb->intout[1] = (int16_t)w->text_color;
    pb->intout[2] = (int16_t)w->text_rotation;
    pb->intout[3] = (int16_t)w->text_halign;
    pb->intout[4] = (int16_t)w->text_valign;
    pb->intout[5] = (int16_t)w->wr_mode;
    for (int i = 0; i < 4; i++) pb->ptsout[i] = 0;
    font *f = vdi_ws_font(w);
    if (f) {
        pb->ptsout[0] = (int16_t)font_max_advance(f);   // char width
        pb->ptsout[1] = (int16_t)font_ascent(f);        // char height
        pb->ptsout[2] = (int16_t)font_max_advance(f);   // cell width
        pb->ptsout[3] = (int16_t)font_height(f);        // cell height
    }
}

// attrib[0]=font id, [1]=colour, [2]=rotation, [3]=halign, [4]=valign,
// [5]=writing mode, [6..9]=char_w, char_h, cell_w, cell_h.
void vqt_attributes(int handle, int16_t *attrib) {
    vdi_emit(VDI_QT_ATTR, 0, handle, 0, 0);
    if (attrib) {
        for (int i = 0; i < 6; i++) attrib[i] = g_intout[i];
        for (int i = 0; i < 4; i++) attrib[6 + i] = g_ptsout[i];
    }
}
