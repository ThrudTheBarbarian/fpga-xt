// vdi/get_pixel.c — v_get_pixel (read a pixel back).  We are true-colour, so we
// return the palette pen whose RGBA matches the pixel (or -1 if none does).

#include "vdi/vdi.h"
#include "vdi/internal.h"
#include <stddef.h>

void op_get_pixel(vdi_pb *pb) {
    vdi_ws *w = vdi_ws_of(pb->contrl[6]); if (!w || !w->target) return;
    int x = pb->ptsin[0], y = pb->ptsin[1];
    gfx_surface *s = w->target;
    uint32_t px = (x >= 0 && x < s->w && y >= 0 && y < s->h)
                ? s->px[(size_t)y * s->stride + x] : 0;
    int idx = -1;
    for (int i = 0; i < 256; i++) if (vdi_pen_rgba(i) == px) { idx = i; break; }
    pb->intout[0] = (int16_t)(idx < 0 ? 0 : idx);       // pel (matching pen)
    pb->intout[1] = (int16_t)idx;                       // colour index (-1 = no match)
}

void v_get_pixel(int handle, int x, int y, int *pel, int *index) {
    g_ptsin[0] = (int16_t)x; g_ptsin[1] = (int16_t)y;
    vdi_emit(VDI_GET_PIXEL, 0, handle, 1, 0);
    if (pel)   *pel   = g_intout[0];
    if (index) *index = g_intout[1];
}
