// vdi/ql_attr.c — vql_attributes (current polyline attributes).  Reports the
// line type, colour and writing mode in intout[0..2] and the line width in
// ptsout[0] (height ptsout[1] = 0).

#include "vdi/vdi.h"
#include "vdi/internal.h"

void op_ql_attr(vdi_pb *pb) {
    vdi_ws *w = vdi_ws_of(pb->contrl[6]); if (!w) return;
    pb->intout[0] = (int16_t)w->line_type;
    pb->intout[1] = (int16_t)w->line_color;
    pb->intout[2] = (int16_t)w->wr_mode;
    pb->ptsout[0] = (int16_t)w->line_width;
    pb->ptsout[1] = 0;
}

// attrib[0]=type, [1]=colour, [2]=writing mode, [3]=line width.
void vql_attributes(int handle, int16_t *attrib) {
    vdi_emit(VDI_QL_ATTR, 0, handle, 0, 0);
    if (attrib) {
        attrib[0] = g_intout[0]; attrib[1] = g_intout[1];
        attrib[2] = g_intout[2]; attrib[3] = g_ptsout[0];
    }
}
