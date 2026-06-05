// vdi/vq_color_ext.c — read back the per-class foreground / background pens set
// by the extended colour attributes.  vq?_fg_color (202, sub: 0 text, 1 fill,
// 2 line, 3 marker) returns that class's current colour; vqt_bg_color (203/0)
// returns the opaque-text background (-1 = none).  These mirror vst_fg_color /
// vst_bg_color and the existing per-class colour setters.

#include "vdi/vdi.h"
#include "vdi/internal.h"

void op_vq_fg_color(vdi_pb *pb) {
    vdi_ws *w = vdi_ws_of(pb->contrl[6]); if (!w) return;
    int pen;
    switch (pb->contrl[5]) {
        case 1:  pen = w->fill_color;   break;
        case 2:  pen = w->line_color;   break;
        case 3:  pen = w->marker_color; break;
        default: pen = w->text_color;   break;          // 0 = text
    }
    pb->intout[0] = (int16_t)pen;
}
void op_vq_bg_color(vdi_pb *pb) {
    vdi_ws *w = vdi_ws_of(pb->contrl[6]); if (!w) return;
    pb->intout[0] = (int16_t)(pb->contrl[5] == 0 ? w->text_bg_color : 0);  // only text has a bg
}

static int fg(int handle, int sub) { vdi_emit(VDI_VQ_FG_COLOR, sub, handle, 0, 0); return g_intout[0]; }
int vqt_fg_color(int handle) { return fg(handle, 0); }
int vqf_fg_color(int handle) { return fg(handle, 1); }
int vql_fg_color(int handle) { return fg(handle, 2); }
int vqm_fg_color(int handle) { return fg(handle, 3); }
int vqt_bg_color(int handle) { vdi_emit(VDI_VQ_BG_COLOR, 0, handle, 0, 0); return g_intout[0]; }
