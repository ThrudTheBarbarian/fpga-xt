// vdi/vq_cellarray.c — vq_cellarray (27): read back a rectangular region as a
// grid of colour indices (the inverse of v_cellarray).  The rectangle ptsin
// [0..3] is divided into num_rows x row_length cells; each cell samples its
// centre pixel and maps it to a pen.  Output: intout[0]=elements/row used,
// [1]=rows used, [2]=status, [3..]=the colour indices (row-major).

#include "vdi/vdi.h"
#include "vdi/internal.h"
#include <stddef.h>

void op_vq_cellarray(vdi_pb *pb) {
    pb->intout[0] = pb->intout[1] = 0; pb->intout[2] = 0;
    vdi_ws *w = vdi_ws_of(pb->contrl[6]); if (!w || !w->target) return;
    gfx_surface *s = w->target;
    int x1 = pb->ptsin[0], y1 = pb->ptsin[1], x2 = pb->ptsin[2], y2 = pb->ptsin[3];
    if (x2 < x1) { int t = x1; x1 = x2; x2 = t; }
    if (y2 < y1) { int t = y1; y1 = y2; y2 = t; }
    int row_len = pb->intin[0], nrows = pb->intin[1];
    if (row_len < 1) row_len = 1; if (nrows < 1) nrows = 1;
    if (row_len * nrows > 124) { pb->intout[2] = 1; return; }   // won't fit intout (status=fail)

    int rw = x2 - x1 + 1, rh = y2 - y1 + 1, k = 0;
    for (int r = 0; r < nrows; r++) for (int c = 0; c < row_len; c++) {
        int px = x1 + (2*c + 1) * rw / (2*row_len);     // cell centre
        int py = y1 + (2*r + 1) * rh / (2*nrows);
        int pen = 0;
        if (px >= 0 && px < s->w && py >= 0 && py < s->h) {
            int p = vdi_pen_of(s->px[(size_t)py * s->stride + px]);
            pen = p < 0 ? 0 : p;
        }
        pb->intout[3 + k++] = (int16_t)pen;
    }
    pb->intout[0] = (int16_t)row_len;                   // elements per row used
    pb->intout[1] = (int16_t)nrows;                     // rows used
    pb->intout[2] = 0;                                  // status ok
}

void vq_cellarray(int handle, const int16_t *pxy, int row_len, int num_rows,
                  int *el_used, int *rows_used, int *status, int16_t *colarray) {
    for (int i = 0; i < 4; i++) g_ptsin[i] = pxy[i];
    g_intin[0] = (int16_t)row_len; g_intin[1] = (int16_t)num_rows;
    vdi_emit(VDI_VQ_CELLARRAY, 0, handle, 2, 2);
    if (el_used)   *el_used   = g_intout[0];
    if (rows_used) *rows_used = g_intout[1];
    if (status)    *status    = g_intout[2];
    if (colarray && g_intout[2] == 0)
        for (int i = 0; i < g_intout[0] * g_intout[1]; i++) colarray[i] = g_intout[3 + i];
}
