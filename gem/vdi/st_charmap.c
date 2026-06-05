// vdi/st_charmap.c — vst_charmap (236) / vst_map_mode (236 sub 1): select the
// character-set mapping.  This device is Unicode-native (v_gtext transports raw
// UTF-8, decoded per codepoint), so it only ever operates in Unicode mode: the
// call accepts the request but always reports Unicode in effect.  The legacy
// Atari / Bitstream byte encodings aren't supported.

#include "vdi/vdi.h"
#include "vdi/internal.h"

void op_st_charmap(vdi_pb *pb) {
    // intin[0] = requested mode; we are Unicode-only, so report it regardless.
    pb->intout[0] = VDI_MAP_UNICODE;
}

int vst_charmap(int handle, int mode) {
    g_intin[0] = (int16_t)mode;
    vdi_emit(VDI_ST_CHARMAP, 0, handle, 0, 1);
    return g_intout[0];                                 // always VDI_MAP_UNICODE
}
int vst_map_mode(int handle, int mode) {
    g_intin[0] = (int16_t)mode;
    vdi_emit(VDI_ST_CHARMAP, 1, handle, 0, 1);
    return g_intout[0];
}
