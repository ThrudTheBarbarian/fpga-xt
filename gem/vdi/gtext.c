// vdi/gtext.c — v_gtext (graphic text).  Renders a UTF-8 string anchored at
// ptsin[0,1] per the workstation's vst_alignment, through the FreeType font
// module, in the workstation's text colour, clipped to the workstation clip
// rect.
//
// GEM transports the characters one-per-int in intin[] (raw bytes, so UTF-8
// passes straight through); the C wrapper packs the string for us.  The face is
// the workstation's or the VDI default (vdi_set_face), sized by vst_height/
// vst_point.

#include "vdi/vdi.h"
#include "vdi/internal.h"
#include <string.h>

void op_gtext(vdi_pb *pb) {
    vdi_ws *w = vdi_ws_of(pb->contrl[6]); if (!w) return;
    font *f = vdi_ws_font(w);
    if (!f) return;
    int n = pb->contrl[3]; if (n < 0) n = 0; if (n > 127) n = 127;
    char buf[128];
    for (int i = 0; i < n; i++) buf[i] = (char)pb->intin[i];
    buf[n] = '\0';

    // Anchor (ptsin) -> em-box top-left, which is what font_draw takes.
    int x = pb->ptsin[0], y = pb->ptsin[1];
    int asc = font_ascent(f), H = font_height(f);
    switch (w->text_halign) {
        case VDI_TA_CENTER: x -= font_text_width(f, buf) / 2; break;
        case VDI_TA_RIGHT:  x -= font_text_width(f, buf);     break;
    }
    switch (w->text_valign) {
        case VDI_TA_TOP:     case VDI_TA_ASCENT:               break;   // y = top
        case VDI_TA_BASELINE:                       y -= asc;  break;
        case VDI_TA_HALF:                           y -= H/2;  break;
        case VDI_TA_BOTTOM:  case VDI_TA_DESCENT:   y -= H;    break;
    }
    int cx0, cy0, cx1, cy1; vdi_ws_clip(w, &cx0, &cy0, &cx1, &cy1);
    int clip[4] = { cx0, cy0, cx1, cy1 };
    font_draw(f, w->target, x, y, buf, vdi_pen_rgba(w->text_color), clip);
}

void v_gtext(int handle, int x, int y, const char *s) {
    g_ptsin[0] = (int16_t)x; g_ptsin[1] = (int16_t)y;
    int n = (int)strlen(s); if (n > 127) n = 127;
    for (int i = 0; i < n; i++) g_intin[i] = (unsigned char)s[i];
    vdi_emit(VDI_GTEXT, 0, handle, 1, n);
}
