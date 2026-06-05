// vdi/q_color.c — vq_color (read a palette pen).  intin[0] = pen index, intin[1]
// = flag (0 = the value last requested, 1 = the realised value; identical here,
// the device renders exactly what was set).  Returns the pen in intout[0] and
// RGB on the GEM 0..1000 intensity scale in intout[1..3].

#include "vdi/vdi.h"
#include "vdi/internal.h"

static int to1000(unsigned c8) { return (int)((c8 * 1000 + 127) / 255); }

void op_q_color(vdi_pb *pb) {
    int index = pb->intin[0];
    uint32_t rgba = vdi_pen_rgba(index);        // 0xRRGGBBAA
    pb->intout[0] = (int16_t)(index & 0xFF);
    pb->intout[1] = (int16_t)to1000((rgba >> 24) & 0xFF);
    pb->intout[2] = (int16_t)to1000((rgba >> 16) & 0xFF);
    pb->intout[3] = (int16_t)to1000((rgba >>  8) & 0xFF);
}

void vq_color(int handle, int index, int set_flag, int16_t *rgb) {
    g_intin[0] = (int16_t)index;
    g_intin[1] = (int16_t)set_flag;
    vdi_emit(VDI_Q_COLOR, 0, handle, 0, 2);
    if (rgb) { rgb[0] = g_intout[1]; rgb[1] = g_intout[2]; rgb[2] = g_intout[3]; }
}
