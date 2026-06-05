// vdi/fillarea.c — v_fillarea (filled polygon).  The vertices arrive in ptsin
// (contrl[1] points); it's the GDP fill machinery applied to an arbitrary
// polygon — honouring the fill colour / interior style / perimeter, same as
// vr_recfl and the curved GDPs.

#include "vdi/vdi.h"
#include "vdi/internal.h"
#include <string.h>

void op_fillarea(vdi_pb *pb) {
    vdi_ws *w = vdi_ws_of(pb->contrl[6]); if (!w) return;
    int n = pb->contrl[1]; if (n < 2) return;
    if (w->fill_interior != VDI_FIS_HOLLOW)
        vdi_fill_poly(w, pb->ptsin, n, w->fill_color,
                      vdi_fill_mask(w->fill_interior, w->fill_style));
    if (w->fill_perimeter)
        vdi_polyline(w, pb->ptsin, n, w->fill_color, 1);   // closed outline
}

void v_fillarea(int handle, int n, const int16_t *pxy) {
    if (n > 128) n = 128;
    memcpy(g_ptsin, pxy, (size_t)n * 2 * sizeof(int16_t));
    vdi_emit(VDI_FILLAREA, 0, handle, n, 0);
}
