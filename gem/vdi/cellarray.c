// vdi/cellarray.c — v_cellarray: a grid of cols x rows coloured cells (pen
// indices) scaled to fill the destination rectangle ptsin[0..3].  Each cell is
// a solid sub-rectangle in its colour.  Layout (ours, binding + op agree):
// ptsin = x1,y1,x2,y2; intin[0]=cols, intin[1]=rows, intin[2..]=row-major pens.

#include "vdi/vdi.h"
#include "vdi/internal.h"
#include <string.h>

void op_cellarray(vdi_pb *pb) {
    vdi_ws *w = vdi_ws_of(pb->contrl[6]); if (!w) return;
    int cols = pb->intin[0], rows = pb->intin[1];
    if (cols < 1 || rows < 1) return;
    int x0 = pb->ptsin[0], y0 = pb->ptsin[1], x1 = pb->ptsin[2], y1 = pb->ptsin[3];
    if (x0 > x1) { int t = x0; x0 = x1; x1 = t; }
    if (y0 > y1) { int t = y0; y0 = y1; y1 = t; }
    int W = x1 - x0 + 1, H = y1 - y0 + 1;
    for (int r = 0; r < rows; r++) {
        int cy0 = y0 + (int)((long)r * H / rows), cy1 = y0 + (int)((long)(r + 1) * H / rows) - 1;
        for (int c = 0; c < cols; c++) {
            int cx0 = x0 + (int)((long)c * W / cols), cx1 = x0 + (int)((long)(c + 1) * W / cols) - 1;
            int pen = pb->intin[2 + r * cols + c];
            vdi_fill_rect(w, cx0, cy0, cx1, cy1, pen);
        }
    }
}

void v_cellarray(int handle, const int16_t *pxy, int cols, int rows, const int16_t *colors) {
    int n = cols * rows; if (n > 126) n = 126;          // intin holds 2 + cells
    memcpy(g_ptsin, pxy, 4 * sizeof(int16_t));
    g_intin[0] = (int16_t)cols; g_intin[1] = (int16_t)rows;
    memcpy(g_intin + 2, colors, (size_t)n * sizeof(int16_t));
    vdi_emit(VDI_CELLARRAY, 0, handle, 2, n + 2);
}
