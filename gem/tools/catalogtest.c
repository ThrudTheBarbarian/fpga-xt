// tools/catalogtest.c — host exercise for font_catalog: scan a directory (POSIX),
// build the catalog, persist + reload it, and show that an unchanged directory
// reloads from the index with zero fonts parsed.
//
//   make -C gem catalogtest
//   gem/build/catalogtest /tmp/vf

#include "font_catalog.h"
#include <dirent.h>
#include <sys/stat.h>
#include <strings.h>
#include <stdio.h>
#include <string.h>

#define MAXF 512
static char namestore[MAXF][256];

int main(int argc, char **argv) {
    const char *dir = argc > 1 ? argv[1] : "/tmp/vf";

    DIR *d = opendir(dir);
    if (!d) { perror(dir); return 1; }
    fc_dirent ents[MAXF]; int n = 0;
    struct dirent *de;
    while ((de = readdir(d)) && n < MAXF) {
        const char *nm = de->d_name; size_t L = strlen(nm);
        if (L < 4 || strcasecmp(nm + L - 4, ".ttf")) continue;
        char path[600]; snprintf(path, sizeof path, "%s/%s", dir, nm);
        struct stat st; if (stat(path, &st)) continue;
        strncpy(namestore[n], nm, 255); namestore[n][255] = '\0';
        ents[n].name = namestore[n]; ents[n].size = (long)st.st_size; n++;
    }
    closedir(d);
    printf("scanned %d .ttf in %s  (dir hash %08x)\n", n, dir, fc_dir_hash(ents, n));

    FT_Library lib; FT_Init_FreeType(&lib);
    char idx[600]; snprintf(idx, sizeof idx, "%s/.fontindex", dir);
    remove(idx);                                        // start cold so run 1 always builds

    // run 1 cold (rebuild + print), run 2 warm (fast path), run 3 after a
    // simulated content swap (one file's size changes) -> must rebuild.
    for (int run = 1; run <= 3; run++) {
        if (run == 3) ents[0].size += 1;                // pretend a font was replaced
        fc_catalog cat = {0};
        int fi = 0;
        int r = fc_load(&cat, lib, dir, ents, n, idx, &fi);
        const char *how = fi ? "LOADED FROM INDEX (0 fonts parsed)" : "REBUILT (fonts parsed)";
        const char *note = run == 2 ? (fi ? "  <- fast path" : "  <- BUG: should be cached")
                         : run == 3 ? (fi ? "  <- BUG: stale!" : "  <- staleness detected")
                         : "";
        printf("\n== run %d: %d faces — %s%s ==\n", run, r, how, note);
        if (run == 1)
            for (int i = 0; i < cat.n_faces; i++) {
                fc_face *f = &cat.faces[i];
                printf("  %-12s %-22s w=%-4d wd=%-3d %-4s %s  %s\n",
                       f->family, f->style, f->weight, f->width,
                       f->italic ? "ital" : "", f->variable ? "var" : "sta", f->file);
            }
        fc_free(&cat);
    }
    FT_Done_FreeType(lib);
    return 0;
}
