// vdi/qm_attr.c — vqm_attributes (current polymarker attributes).  Reports the
// marker type, colour and writing mode in intout[0..2] and the marker height in
// ptsout[1] (width ptsout[0] = 0, markers being square).

#include "vdi/vdi.h"
#include "vdi/internal.h"

void op_qm_attr(vdi_pb *pb) {
    vdi_ws *w = vdi_ws_of(pb->contrl[6]); if (!w) return;
    pb->intout[0] = (int16_t)w->marker_type;
    pb->intout[1] = (int16_t)w->marker_color;
    pb->intout[2] = (int16_t)w->wr_mode;
    pb->ptsout[0] = 0;
    pb->ptsout[1] = (int16_t)w->marker_height;
}

// attrib[0]=type, [1]=colour, [2]=writing mode, [3]=marker height.
void vqm_attributes(int handle, int16_t *attrib) {
    vdi_emit(VDI_QM_ATTR, 0, handle, 0, 0);
    if (attrib) {
        attrib[0] = g_intout[0]; attrib[1] = g_intout[1];
        attrib[2] = g_intout[2]; attrib[3] = g_ptsout[1];
    }
}
