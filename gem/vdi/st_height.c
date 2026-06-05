// vdi/st_height.c — vst_height (set text size in pixels).  Binds the workstation
// to a sized view of the default face; reports char/cell metrics in ptsout.

#include "vdi/vdi.h"
#include "vdi/internal.h"

// Shared by vst_height/vst_point: select px on the ws, fill ptsout[0..3] with
// char_w, char_h, cell_w, cell_h.  Returns the pixel size actually used (0 fail).
int vdi_set_text_px(vdi_ws *w, int px, int16_t *ptsout) {
    if (!w || px < 1) return 0;
    font_face *face = w->text_face ? w->text_face : g_default_face;
    if (!face) return 0;
    font *f = font_at(face, px);
    if (!f) return 0;
    w->text_px = px;
    w->text_wpx = 0;                                 // height sets a square cell (vst_setsize overrides)
    if (ptsout) {
        ptsout[0] = (int16_t)font_max_advance(f);   // char width
        ptsout[1] = (int16_t)font_ascent(f);        // char height (cap-ish)
        ptsout[2] = (int16_t)font_max_advance(f);   // cell width
        ptsout[3] = (int16_t)font_height(f);        // cell height (line)
    }
    return font_size(f);
}

void op_st_height(vdi_pb *pb) {
    vdi_ws *w = vdi_ws_of(pb->contrl[6]); if (!w) return;
    vdi_set_text_px(w, pb->intin[0], pb->ptsout);
}

int vst_height(int handle, int height_px, int *cw, int *ch, int *cellw, int *cellh) {
    g_intin[0] = (int16_t)height_px;
    vdi_emit(VDI_ST_HEIGHT, 0, handle, 0, 1);
    if (cw)    *cw    = g_ptsout[0];
    if (ch)    *ch    = g_ptsout[1];
    if (cellw) *cellw = g_ptsout[2];
    if (cellh) *cellh = g_ptsout[3];
    vdi_ws *w = vdi_ws_of(handle);
    return w ? w->text_px : 0;
}
