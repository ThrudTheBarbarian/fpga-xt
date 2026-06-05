// vdi/swr_mode.c — vswr_mode (set the writing mode: replace / transparent /
// XOR / reverse-transparent).  Honoured by every drawing primitive via
// vdi_wrmix.  XOR is the reversible mode used for rubber-banding.

#include "vdi/vdi.h"
#include "vdi/internal.h"

void op_swr_mode(vdi_pb *pb) {
    vdi_ws *w = vdi_ws_of(pb->contrl[6]); if (!w) return;
    int m = pb->intin[0];
    if (m < VDI_MD_REPLACE) m = VDI_MD_REPLACE;
    if (m > VDI_MD_ERASE)   m = VDI_MD_ERASE;
    w->wr_mode = m;
    pb->intout[0] = (int16_t)m;
}

int vswr_mode(int handle, int mode) {
    g_intin[0] = (int16_t)mode;
    vdi_emit(VDI_SWR_MODE, 0, handle, 0, 1);
    return g_intout[0];
}
