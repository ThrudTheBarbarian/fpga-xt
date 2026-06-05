// vdi/st_color_ext.c — the extended colour setters:
//   vst_fg_color (200/0) — text foreground pen (an alias of vst_color).
//   vst_bg_color (201/0) — text *background* pen for opaque text.  Default none
//     (-1): v_gtext alpha-blends as before.  Set it and REPLACE-mode text fills
//     its cell box with this pen first (true opaque GEM text).
//   v_setrgb (138)       — set a palette pen straight from 8-bit RGB (our native
//     RGBA-8888 precision), the true-colour companion to vs_color's 0..1000.

#include "vdi/vdi.h"
#include "vdi/internal.h"

void op_st_fg_color(vdi_pb *pb) {
    vdi_ws *w = vdi_ws_of(pb->contrl[6]); if (!w) return;
    pb->intout[0] = (int16_t)w->text_color;             // previous
    w->text_color = pb->intin[0];
}
void op_st_bg_color(vdi_pb *pb) {
    vdi_ws *w = vdi_ws_of(pb->contrl[6]); if (!w) return;
    pb->intout[0] = (int16_t)w->text_bg_color;          // previous (-1 = none)
    w->text_bg_color = pb->intin[0];                    // -1 disables opaque bg
}
void op_v_setrgb(vdi_pb *pb) {
    int idx = pb->intin[0];
    int r = pb->intin[1] & 0xFF, g = pb->intin[2] & 0xFF, b = pb->intin[3] & 0xFF;
    vdi_set_pen(idx, GFX_RGB(r, g, b));
}

int vst_fg_color(int handle, int pen) {
    g_intin[0] = (int16_t)pen;
    vdi_emit(VDI_ST_FG_COLOR, 0, handle, 0, 1);
    return g_intout[0];
}
int vst_bg_color(int handle, int pen) {                 // pen<0 disables opaque bg
    g_intin[0] = (int16_t)pen;
    vdi_emit(VDI_ST_BG_COLOR, 0, handle, 0, 1);
    return g_intout[0];
}
void v_setrgb(int handle, int index, int r, int g, int b) {
    g_intin[0] = (int16_t)index; g_intin[1] = (int16_t)r;
    g_intin[2] = (int16_t)g; g_intin[3] = (int16_t)b;
    vdi_emit(VDI_V_SETRGB, 0, handle, 0, 4);
}
