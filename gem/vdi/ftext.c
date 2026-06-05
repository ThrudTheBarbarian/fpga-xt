// vdi/ftext.c — v_ftext / v_ftext_offset (op 241): output text using the
// outline (vector) font.  Every glyph on this device is already FreeType-
// rendered, so plain v_ftext is v_gtext (it shares that path verbatim, honouring
// alignment / rotation / effects / opaque background).  v_ftext_offset adds an
// app-supplied (x,y) offset per character so the caller controls exact glyph
// placement (custom kerning, justification, text on a path); ptsin carries the
// anchor in [0] and one offset pair per codepoint after it.

#include "vdi/vdi.h"
#include "vdi/internal.h"
#include <string.h>

void op_ftext(vdi_pb *pb) {
    if (pb->contrl[1] <= 1) { op_gtext(pb); return; }   // no offsets -> plain graphic text
    vdi_ws *w = vdi_ws_of(pb->contrl[6]); if (!w) return;
    font *f = vdi_ws_font(w); if (!f) return;
    int n = pb->contrl[3]; if (n < 0) n = 0; if (n > 127) n = 127;
    char buf[128];
    for (int i = 0; i < n; i++) buf[i] = (char)pb->intin[i];
    buf[n] = '\0';

    int x = pb->ptsin[0], y = pb->ptsin[1];
    int asc = font_ascent(f), H = font_height(f);
    switch (w->text_valign) {                            // anchor -> em-box top-left
        case VDI_TA_TOP:     case VDI_TA_ASCENT:               break;
        case VDI_TA_BASELINE:                       y -= asc;  break;
        case VDI_TA_HALF:                           y -= H/2;  break;
        case VDI_TA_BOTTOM:  case VDI_TA_DESCENT:   y -= H;    break;
    }
    int cx0, cy0, cx1, cy1; vdi_ws_clip(w, &cx0, &cy0, &cx1, &cy1);
    int clip[4] = { cx0, cy0, cx1, cy1 };
    font_draw_offsets(f, w->target, x, y, buf, pb->ptsin + 2,
                      vdi_pen_rgba(w->text_color), clip, w->wr_mode);
}

void v_ftext(int handle, int x, int y, const char *s) {
    g_ptsin[0] = (int16_t)x; g_ptsin[1] = (int16_t)y;
    int n = (int)strlen(s); if (n > 127) n = 127;
    for (int i = 0; i < n; i++) g_intin[i] = (unsigned char)s[i];
    vdi_emit(VDI_FTEXT, 0, handle, 1, n);
}

// off[] holds one (x,y) pair per character (codepoint), packed after the anchor.
void v_ftext_offset(int handle, int x, int y, const char *s, const int16_t *off) {
    g_ptsin[0] = (int16_t)x; g_ptsin[1] = (int16_t)y;
    int nb = 0, ncp = 0;
    for (const char *p = s; *p && nb < 127; p++, nb++) {
        g_intin[nb] = (unsigned char)*p;
        if (((unsigned char)*p & 0xC0) != 0x80 && 2 + 2*ncp + 1 < 256) {   // a lead byte = a codepoint
            g_ptsin[2 + 2*ncp]     = off[2*ncp];
            g_ptsin[2 + 2*ncp + 1] = off[2*ncp + 1];
            ncp++;
        }
    }
    vdi_emit(VDI_FTEXT, 0, handle, 1 + ncp, nb);
}
