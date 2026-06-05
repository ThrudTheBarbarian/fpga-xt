// vdi/pmarker.c — v_pmarker (polymarkers) and the marker attributes
// vsm_type / vsm_height / vsm_color.  A marker is a small symbol drawn at each
// ptsin point in the marker colour, scaled to the marker height.  Markers are
// always thin solid lines regardless of the line attributes.

#include "vdi/vdi.h"
#include "vdi/internal.h"
#include <string.h>

static void draw_marker(const vdi_ws *w, int cx, int cy, int type, int r, int pen) {
    switch (type) {
        case VDI_MK_DOT:
            vdi_fill_rect(w, cx, cy, cx, cy, pen);
            break;
        case VDI_MK_PLUS:
            vdi_line(w, cx - r, cy, cx + r, cy, pen);
            vdi_line(w, cx, cy - r, cx, cy + r, pen);
            break;
        case VDI_MK_SQUARE:
            vdi_rect_outline(w, cx - r, cy - r, cx + r, cy + r, pen);
            break;
        case VDI_MK_CROSS:
            vdi_line(w, cx - r, cy - r, cx + r, cy + r, pen);
            vdi_line(w, cx - r, cy + r, cx + r, cy - r, pen);
            break;
        case VDI_MK_DIAMOND: {
            int16_t p[8] = { (int16_t)cx, (int16_t)(cy-r), (int16_t)(cx+r), (int16_t)cy,
                             (int16_t)cx, (int16_t)(cy+r), (int16_t)(cx-r), (int16_t)cy };
            vdi_polyline(w, p, 4, pen, 1);
            break;
        }
        case VDI_MK_ASTERISK:
        default:
            vdi_line(w, cx - r, cy, cx + r, cy, pen);
            vdi_line(w, cx, cy - r, cx, cy + r, pen);
            vdi_line(w, cx - r, cy - r, cx + r, cy + r, pen);
            vdi_line(w, cx - r, cy + r, cx + r, cy - r, pen);
            break;
    }
}

void op_pmarker(vdi_pb *pb) {
    vdi_ws *w = vdi_ws_of(pb->contrl[6]); if (!w) return;
    int n = pb->contrl[1], r = w->marker_height / 2; if (r < 1) r = 1;
    int sw = w->line_width, st = w->line_type;          // markers are thin + solid
    w->line_width = 1; w->line_type = 1;
    for (int i = 0; i < n; i++)
        draw_marker(w, pb->ptsin[2*i], pb->ptsin[2*i+1], w->marker_type, r, w->marker_color);
    w->line_width = sw; w->line_type = st;
}

void op_sm_type(vdi_pb *pb) {
    vdi_ws *w = vdi_ws_of(pb->contrl[6]); if (!w) return;
    int t = pb->intin[0]; if (t < 1) t = 1; if (t > 6) t = 6;
    w->marker_type = t; pb->intout[0] = (int16_t)t;
}
void op_sm_height(vdi_pb *pb) {
    vdi_ws *w = vdi_ws_of(pb->contrl[6]); if (!w) return;
    int h = pb->intin[0]; if (h < 1) h = 1;
    w->marker_height = h; pb->intout[0] = (int16_t)h;
}
void op_sm_color(vdi_pb *pb) {
    vdi_ws *w = vdi_ws_of(pb->contrl[6]); if (w) w->marker_color = pb->intin[0];
}

void v_pmarker(int handle, int n, const int16_t *pxy) {
    if (n > 128) n = 128;
    memcpy(g_ptsin, pxy, (size_t)n * 2 * sizeof(int16_t));
    vdi_emit(VDI_PMARKER, 0, handle, n, 0);
}
void vsm_type(int handle, int type) { g_intin[0] = (int16_t)type; vdi_emit(VDI_SM_TYPE, 0, handle, 0, 1); }
int  vsm_height(int handle, int height) {
    g_intin[0] = (int16_t)height; vdi_emit(VDI_SM_HEIGHT, 0, handle, 0, 1); return g_intout[0];
}
void vsm_color(int handle, int pen) { g_intin[0] = (int16_t)pen; vdi_emit(VDI_SM_COLOR, 0, handle, 0, 1); }
