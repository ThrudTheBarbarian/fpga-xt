// vdi/load_fonts.c — vst_load_fonts / vst_unload_fonts.  We rasterise faces on
// demand through FreeType, so there is nothing to (un)load — these are no-ops.
// But GEM apps expect vst_load_fonts to return how many extra font files are
// available, so we report the count of font files in the fonts directory
// (OS/Fonts on the target; set per-platform with vdi_set_font_dir).

#include "vdi/vdi.h"
#include "vdi/internal.h"
#include <string.h>
#include <strings.h>
#include <dirent.h>

static const char *g_font_dir = "OS/Fonts";
void vdi_set_font_dir(const char *path) { if (path) g_font_dir = path; }

static int is_font(const char *name) {
    const char *dot = strrchr(name, '.');
    if (!dot) return 0;
    return !strcasecmp(dot, ".ttf") || !strcasecmp(dot, ".otf") || !strcasecmp(dot, ".ttc");
}

static int count_fonts(void) {
    DIR *d = opendir(g_font_dir);
    if (!d) return 0;
    int n = 0;
    for (struct dirent *e; (e = readdir(d)); ) if (is_font(e->d_name)) n++;
    closedir(d);
    return n;
}

void op_load_fonts(vdi_pb *pb)   { pb->intout[0] = (int16_t)count_fonts(); }
void op_unload_fonts(vdi_pb *pb) { (void)pb; }   // nothing to free (faces are on-demand)

int vst_load_fonts(int handle, int select) {
    g_intin[0] = (int16_t)select;
    vdi_emit(VDI_LOAD_FONTS, 0, handle, 0, 1);
    return g_intout[0];
}
void vst_unload_fonts(int handle, int select) {
    g_intin[0] = (int16_t)select;
    vdi_emit(VDI_UNLOAD_FONTS, 0, handle, 0, 1);
}
