// vdi/vs_color.c — vs_color (set a palette pen).  The colour table is device-
// wide (shared by all workstations), as in GEM.  RGB come in on the GEM 0..1000
// intensity scale.

#include "vdi/vdi.h"
#include "vdi/internal.h"

static int scale1000(int v) {
    if (v < 0) v = 0; if (v > 1000) v = 1000;
    return (v * 255 + 500) / 1000;
}

void op_vs_color(vdi_pb *pb) {
    int index = pb->intin[0];
    int r = scale1000(pb->intin[1]), g = scale1000(pb->intin[2]), b = scale1000(pb->intin[3]);
    vdi_set_pen(index, GFX_RGB(r, g, b));
}

void vs_color(int handle, int index, const int16_t *rgb) {
    g_intin[0] = (int16_t)index;
    g_intin[1] = rgb[0]; g_intin[2] = rgb[1]; g_intin[3] = rgb[2];
    vdi_emit(VDI_VS_COLOR, 0, handle, 0, 4);
}
