// vdi/pline.c — v_pline (polyline; each segment Cohen–Sutherland clipped).

#include "vdi/vdi.h"
#include "vdi/internal.h"
#include <string.h>

void op_pline(vdi_pb *pb) {
    vdi_ws *w = vdi_ws_of(pb->contrl[6]); if (!w) return;
    int n = pb->contrl[1];
    for (int i = 1; i < n; i++)
        vdi_line(w, pb->ptsin[2*i-2], pb->ptsin[2*i-1],
                    pb->ptsin[2*i],   pb->ptsin[2*i+1], w->line_color);
}

void v_pline(int handle, int n, const int16_t *pxy) {
    if (n > 128) n = 128;
    memcpy(g_ptsin, pxy, (size_t)n * 2 * sizeof(int16_t));
    vdi_emit(VDI_PLINE, 0, handle, n, 0);
}
