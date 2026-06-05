// vdi/qt_name.c — vqt_name (inquire a font's id + name).  intin[0] = the font
// id to query; returns the id in intout[0] (0 if unknown) and the name one
// character per word in intout[1..].  Lets an app enumerate the loaded fonts
// (id 1 = system, 2..N = the vst_load_fonts files) to build a font menu.

#include "vdi/vdi.h"
#include "vdi/internal.h"

void op_qt_name(vdi_pb *pb) {
    int id = pb->intin[0];
    const char *name = vdi_font_name(id);
    int valid = (id == 1) || (vdi_font_name(id)[0] != '\0');
    pb->intout[0] = (int16_t)(valid ? id : 0);
    int i = 0;
    for (; name[i] && i < 32; i++) pb->intout[1 + i] = (unsigned char)name[i];
    pb->intout[1 + i] = 0;
}

int vqt_name(int handle, int id, char *name) {
    g_intin[0] = (int16_t)id;
    vdi_emit(VDI_QT_NAME, 0, handle, 0, 1);
    if (name) {
        int i = 0;
        for (; i < 32 && g_intout[1 + i]; i++) name[i] = (char)g_intout[1 + i];
        name[i] = '\0';
    }
    return g_intout[0];
}
