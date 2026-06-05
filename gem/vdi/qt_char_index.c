// vdi/qt_char_index.c — vqt_char_index (190): map a character value between
// encodings (Atari / Bitstream / Unicode).  This device is Unicode-native, so
// the mapping is the identity: the input value comes straight back.

#include "vdi/vdi.h"
#include "vdi/internal.h"

void op_qt_char_index(vdi_pb *pb) {
    pb->intout[0] = pb->intin[0];                        // Unicode-only: identity
}

int vqt_char_index(int handle, int src, int src_mode, int dst_mode) {
    (void)src_mode; (void)dst_mode;
    g_intin[0] = (int16_t)src;
    g_intin[1] = (int16_t)src_mode;
    g_intin[2] = (int16_t)dst_mode;
    vdi_emit(VDI_QT_CHAR_INDEX, 0, handle, 0, 3);
    return g_intout[0];
}
