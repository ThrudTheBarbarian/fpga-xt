// vdi/justified.c — v_justified (GDP sub-opcode 10): graphic text spread to a
// given width.  ptsin[0,1] = position, ptsin[2] = width to justify to; intin[0]
// = word-spacing flag, intin[1] = char-spacing flag, intin[2..] = characters
// (raw bytes, so UTF-8 passes through).  The spreading lives in the font module
// (font_draw_justified); here we just resolve the face/colour and apply the
// workstation's vertical text alignment, like v_gtext.

#include "vdi/vdi.h"
#include "vdi/internal.h"

void op_justified(vdi_pb *pb) {
    vdi_ws *w = vdi_ws_of(pb->contrl[6]); if (!w) return;
    font *f = vdi_ws_font(w); if (!f) return;
    int nint = pb->contrl[3], nch = nint - 2;
    if (nch < 0) nch = 0; if (nch > 125) nch = 125;
    char buf[128];
    for (int i = 0; i < nch; i++) buf[i] = (char)pb->intin[2 + i];
    buf[nch] = '\0';

    int x = pb->ptsin[0], y = pb->ptsin[1], width = pb->ptsin[2];
    int asc = font_ascent(f), H = font_height(f);
    switch (w->text_valign) {                            // (x,y) -> em-box top-left
        case VDI_TA_TOP:     case VDI_TA_ASCENT:               break;
        case VDI_TA_BASELINE:                       y -= asc;  break;
        case VDI_TA_HALF:                           y -= H/2;  break;
        case VDI_TA_BOTTOM:  case VDI_TA_DESCENT:   y -= H;    break;
    }
    int cx0, cy0, cx1, cy1; vdi_ws_clip(w, &cx0, &cy0, &cx1, &cy1);
    int clip[4] = { cx0, cy0, cx1, cy1 };
    font_draw_justified(f, w->target, x, y, buf, width,
                        pb->intin[0], pb->intin[1], vdi_pen_rgba(w->text_color), clip);
}

void v_justified(int handle, int x, int y, const char *s, int width,
                 int word_space, int char_space) {
    g_ptsin[0] = (int16_t)x; g_ptsin[1] = (int16_t)y;
    g_ptsin[2] = (int16_t)width; g_ptsin[3] = 0;
    g_intin[0] = (int16_t)(word_space ? 1 : 0);
    g_intin[1] = (int16_t)(char_space ? 1 : 0);
    int n = 0; while (s[n] && n < 125) { g_intin[2 + n] = (unsigned char)s[n]; n++; }
    vdi_emit(VDI_GDP, GDP_JUSTIFIED, handle, 2, n + 2);
}
