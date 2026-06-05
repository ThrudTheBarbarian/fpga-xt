// vdi/raster_color.c — the colours that drive the extended raster blends of
// vr_transfer_bits: vs_hilite_color (207/0), vs_min_color (/1), vs_max_color
// (/2), vs_weight_color (/3), and the vq_* read-backs (209).  Each is a palette
// pen index, device-wide; resolved to RGBA by the blend modes (VR_HILITE/MAX/
// MIN/BLEND).  Defaults: hilite black, min black (floor 0), max white (ceil
// 255), weight mid-grey (~50% blend).

#include "vdi/vdi.h"
#include "vdi/internal.h"

int g_hilite_color = 1, g_min_color = 1, g_max_color = 0, g_weight_color = 9;

static int *slot(int sub) {
    switch (sub) {
        case 1:  return &g_min_color;
        case 2:  return &g_max_color;
        case 3:  return &g_weight_color;
        default: return &g_hilite_color;        // 0
    }
}

void op_vs_rcolor(vdi_pb *pb) {
    int *p = slot(pb->contrl[5]);
    pb->intout[0] = (int16_t)*p;                // previous
    *p = pb->intin[0];
}
void op_vq_rcolor(vdi_pb *pb) { pb->intout[0] = (int16_t)*slot(pb->contrl[5]); }

static int set_rc(int handle, int sub, int idx) {
    g_intin[0] = (int16_t)idx; vdi_emit(VDI_VS_RCOLOR, sub, handle, 0, 1); return g_intout[0];
}
static int get_rc(int handle, int sub) { vdi_emit(VDI_VQ_RCOLOR, sub, handle, 0, 0); return g_intout[0]; }

int vs_hilite_color(int handle, int pen) { return set_rc(handle, 0, pen); }
int vs_min_color(int handle, int pen)    { return set_rc(handle, 1, pen); }
int vs_max_color(int handle, int pen)    { return set_rc(handle, 2, pen); }
int vs_weight_color(int handle, int pen) { return set_rc(handle, 3, pen); }
int vq_hilite_color(int handle) { return get_rc(handle, 0); }
int vq_min_color(int handle)    { return get_rc(handle, 1); }
int vq_max_color(int handle)    { return get_rc(handle, 2); }
int vq_weight_color(int handle) { return get_rc(handle, 3); }
