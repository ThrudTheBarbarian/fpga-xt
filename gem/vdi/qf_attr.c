// vdi/qf_attr.c — vqf_attributes (current fill-area attributes).  Reports the
// interior style, colour, fill style index, writing mode and perimeter flag in
// intout[0..4].

#include "vdi/vdi.h"
#include "vdi/internal.h"

void op_qf_attr(vdi_pb *pb) {
    vdi_ws *w = vdi_ws_of(pb->contrl[6]); if (!w) return;
    pb->intout[0] = (int16_t)w->fill_interior;
    pb->intout[1] = (int16_t)w->fill_color;
    pb->intout[2] = (int16_t)w->fill_style;
    pb->intout[3] = (int16_t)w->wr_mode;
    pb->intout[4] = (int16_t)w->fill_perimeter;
}

// attrib[0]=interior, [1]=colour, [2]=style index, [3]=writing mode, [4]=perimeter.
void vqf_attributes(int handle, int16_t *attrib) {
    vdi_emit(VDI_QF_ATTR, 0, handle, 0, 0);
    if (attrib) for (int i = 0; i < 5; i++) attrib[i] = g_intout[i];
}
