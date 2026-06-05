// vdi/sl_udsty.c — vsl_udsty (user-defined line style): a 16-bit dash mask used
// when the line type is 7.  Bit n of the mask is drawn at every 16th device
// pixel along the line (the dash phase is distance-based, see vdi_line_ex).

#include "vdi/vdi.h"
#include "vdi/internal.h"

void op_sl_udsty(vdi_pb *pb) {
    vdi_ws *w = vdi_ws_of(pb->contrl[6]);
    if (w) w->line_udsty = (uint16_t)pb->intin[0];
}

void vsl_udsty(int handle, uint16_t pattern) {
    g_intin[0] = (int16_t)pattern;
    vdi_emit(VDI_SL_UDSTY, 0, handle, 0, 1);
}
