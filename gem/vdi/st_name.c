// vdi/st_name.c — vst_name (230): select a text face by family name (the
// name->face counterpart to vst_font's id->face and vqt_name's id->name).
// Returns the matched font id (0 if none; the selection is left unchanged).

#include "vdi/vdi.h"
#include "vdi/internal.h"
#include <strings.h>

// Find a font id by family name.  Returns the id (0 if none).
static int find_by_name(const char *name) {
    for (int id = 1; id <= VDI_MAX_WS * 8; id++) {
        const char *fn = vdi_font_name(id);
        if (id > 1 && fn[0] == '\0') break;              // past the last mapped font
        if (strcasecmp(fn, name) == 0) return id;
    }
    return 0;
}

void op_st_name(vdi_pb *pb) {
    vdi_ws *w = vdi_ws_of(pb->contrl[6]); if (!w) return;
    char name[64];
    int n = pb->contrl[3]; if (n < 0) n = 0; if (n > 63) n = 63;
    for (int i = 0; i < n; i++) name[i] = (char)pb->intin[i];
    name[n] = '\0';
    int id = find_by_name(name);

    if (pb->contrl[5] == 100) {                          // vqt_name_and_id: inquire only
        pb->intout[0] = (int16_t)id;
        const char *cn = id ? vdi_font_name(id) : "";    // canonical name back in intout[1..]
        int i = 0; for (; cn[i] && i < 32; i++) pb->intout[1 + i] = (unsigned char)cn[i];
        pb->intout[1 + i] = 0;
        return;
    }
    if (id) {                                            // vst_name: select it
        if (id == 1) w->text_face = NULL;                // system / default face
        else { font_face *face = vdi_font_by_id(id); if (face) w->text_face = face; }
        w->text_font_id = id;
    }
    pb->intout[0] = (int16_t)id;
}

int vst_name(int handle, const char *name, int *id) {
    int n = 0; while (name[n] && n < 63) { g_intin[n] = (unsigned char)name[n]; n++; }
    vdi_emit(VDI_ST_NAME, 0, handle, 0, n);
    if (id) *id = g_intout[0];
    return g_intout[0];
}

// Inquire (without selecting) the id for a name, plus its canonical spelling.
int vqt_name_and_id(int handle, const char *name, char *out_name) {
    int n = 0; while (name[n] && n < 63) { g_intin[n] = (unsigned char)name[n]; n++; }
    vdi_emit(VDI_ST_NAME, 100, handle, 0, n);
    if (out_name) {
        int i = 0; for (; i < 32 && g_intout[1 + i]; i++) out_name[i] = (char)g_intout[1 + i];
        out_name[i] = '\0';
    }
    return g_intout[0];
}
