// vdi/qt_justified.c — vqt_justified (132): the per-character (x,y) offsets a
// justified line would use, without drawing it — the inquiry companion to
// v_justified (and a ready input for v_ftext_offset).  Output: ptsout holds one
// (x,y) pair per character; intout[0] = the character count.

#include "vdi/vdi.h"
#include "vdi/internal.h"

void op_qt_justified(vdi_pb *pb) {
    vdi_ws *w = vdi_ws_of(pb->contrl[6]); if (!w) return;
    font *f = vdi_ws_font(w); if (!f) return;
    int nch = pb->contrl[3] - 2; if (nch < 0) nch = 0; if (nch > 125) nch = 125;
    char buf[128];
    for (int i = 0; i < nch; i++) buf[i] = (char)pb->intin[2 + i];
    buf[nch] = '\0';
    int width = pb->ptsin[2];
    int16_t offx[128];
    int n = font_justify_offsets(f, buf, width, pb->intin[0], pb->intin[1], offx);
    for (int i = 0; i < n && i < 128; i++) { pb->ptsout[2*i] = offx[i]; pb->ptsout[2*i+1] = 0; }
    pb->intout[0] = (int16_t)n;
}

// Fills off[] with one (x,y) offset per character; returns the count.
int vqt_justified(int handle, const char *s, int width, int word_space,
                  int char_space, int16_t *off) {
    g_ptsin[0] = 0; g_ptsin[1] = 0; g_ptsin[2] = (int16_t)width; g_ptsin[3] = 0;
    g_intin[0] = (int16_t)(word_space ? 1 : 0);
    g_intin[1] = (int16_t)(char_space ? 1 : 0);
    int n = 0; while (s[n] && n < 125) { g_intin[2 + n] = (unsigned char)s[n]; n++; }
    vdi_emit(VDI_QT_JUSTIFIED, 0, handle, 2, n + 2);
    int cnt = g_intout[0];
    if (off) for (int i = 0; i < cnt; i++) { off[2*i] = g_ptsout[2*i]; off[2*i+1] = g_ptsout[2*i+1]; }
    return cnt;
}
