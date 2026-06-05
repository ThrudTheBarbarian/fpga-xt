// vdi/load_fonts.c — the font registry + vst_load_fonts / vst_unload_fonts.
//
// Font id 1 is the system font (the default face, set via vdi_set_face).
// vst_load_fonts scans the fonts directory (OS/Fonts on the target; set with
// vdi_set_font_dir) and *maps* each file to id 2..N — it does not open them.  A
// face is opened lazily on first selection (vst_font / vdi_font_by_id), then
// its glyphs cache as usual.  vst_load_fonts returns the extra-font count.

#include "vdi/vdi.h"
#include "vdi/internal.h"
#include <stdio.h>
#include <string.h>
#include <strings.h>
#include <dirent.h>

static const char *g_font_dir = "OS/Fonts";
void vdi_set_font_dir(const char *path) { if (path) g_font_dir = path; }

#define MAX_EXTRA 32
static struct { char path[256]; char name[64]; font_face *face; } g_extra[MAX_EXTRA];
static int g_nextra;

static int is_font(const char *name) {
    const char *dot = strrchr(name, '.');
    return dot && (!strcasecmp(dot, ".ttf") || !strcasecmp(dot, ".otf") || !strcasecmp(dot, ".ttc"));
}

// Scan the directory and (re)build the id->path map.  No faces are opened here.
static int scan_fonts(void) {
    for (int i = 0; i < g_nextra; i++) g_extra[i].face = NULL;   // drop stale faces
    g_nextra = 0;
    DIR *d = opendir(g_font_dir);
    if (!d) return 0;
    for (struct dirent *e; (e = readdir(d)) && g_nextra < MAX_EXTRA; ) {
        if (!is_font(e->d_name)) continue;
        snprintf(g_extra[g_nextra].path, sizeof g_extra[0].path, "%s/%s", g_font_dir, e->d_name);
        size_t n = strlen(e->d_name);                           // name = filename sans extension
        const char *dot = strrchr(e->d_name, '.'); if (dot) n = (size_t)(dot - e->d_name);
        if (n >= sizeof g_extra[0].name) n = sizeof g_extra[0].name - 1;
        memcpy(g_extra[g_nextra].name, e->d_name, n); g_extra[g_nextra].name[n] = '\0';
        g_extra[g_nextra].face = NULL;
        g_nextra++;
    }
    closedir(d);
    return g_nextra;
}

// Face for a font id: id 1 (system) -> NULL (caller uses the default); id 2..N
// -> the mapped face, opened on first use.
font_face *vdi_font_by_id(int id) {
    if (id < 2 || id - 2 >= g_nextra) return NULL;
    int k = id - 2;
    if (!g_extra[k].face) g_extra[k].face = font_face_open(g_extra[k].path);
    return g_extra[k].face;
}

const char *vdi_font_name(int id) {
    if (id == 1) return font_face_name(g_default_face);          // system family name
    if (id < 2 || id - 2 >= g_nextra) return "";
    return g_extra[id - 2].name;
}

void op_load_fonts(vdi_pb *pb)   { pb->intout[0] = (int16_t)scan_fonts(); }
void op_unload_fonts(vdi_pb *pb) { (void)pb; }   // faces are kept (cheap); nothing to free now

int vst_load_fonts(int handle, int select) {
    g_intin[0] = (int16_t)select;
    vdi_emit(VDI_LOAD_FONTS, 0, handle, 0, 1);
    return g_intout[0];
}
void vst_unload_fonts(int handle, int select) {
    g_intin[0] = (int16_t)select;
    vdi_emit(VDI_UNLOAD_FONTS, 0, handle, 0, 1);
}
