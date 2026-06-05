// vdi/st_font.c — vst_font (select the text face by id).  Id 1 is the system
// font (the default face); ids 2..N are the files mapped by vst_load_fonts,
// opened on first selection.  Subsequent v_gtext / vst_height use the selected
// face.  Returns the id actually in effect (a bad id leaves it unchanged).

#include "vdi/vdi.h"
#include "vdi/internal.h"
#include <stddef.h>

void op_st_font(vdi_pb *pb) {
    vdi_ws *w = vdi_ws_of(pb->contrl[6]); if (!w) return;
    int id = pb->intin[0];
    if (id == 1) {                                   // system / default face
        w->text_face = NULL; w->text_font_id = 1;
    } else {
        font_face *face = vdi_font_by_id(id);        // lazily opened
        if (face) { w->text_face = face; w->text_font_id = id; }
    }
    pb->intout[0] = (int16_t)w->text_font_id;
}

int vst_font(int handle, int id) {
    g_intin[0] = (int16_t)id;
    vdi_emit(VDI_ST_FONT, 0, handle, 0, 1);
    return g_intout[0];
}
