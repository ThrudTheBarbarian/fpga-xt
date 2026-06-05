// vdi/sf_udpat.c — vsf_udpat (set the user-defined fill pattern, used when the
// fill interior is VDI_FIS_USER).  One 1-bit plane of 16 rows arrives in
// intin[0..15] (the pattern is device-wide, like the palette).

#include "vdi/vdi.h"
#include "vdi/internal.h"

void op_sf_udpat(vdi_pb *pb) {
    uint16_t rows[16];
    int n = pb->contrl[3]; if (n > 16) n = 16; if (n < 0) n = 0;
    for (int i = 0; i < 16; i++) rows[i] = (i < n) ? (uint16_t)pb->intin[i] : 0;
    vdi_set_userpat(rows);
}

void vsf_udpat(int handle, const uint16_t *pat16) {
    for (int i = 0; i < 16; i++) g_intin[i] = (int16_t)pat16[i];
    vdi_emit(VDI_SF_UDPAT, 0, handle, 0, 16);
}
