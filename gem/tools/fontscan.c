// tools/fontscan.c — host prototype for the OS/Fonts catalog/indexer.
//
// Proves the variable-font query path the runtime catalog will use: for each TTF
// it reports the family, whether it's variable, and (when it is) the variation
// axes (tag + min/def/max) and named instances (name + per-axis design coords) via
// FT_Get_MM_Var.  This is exactly the metadata the persisted catalog stores so the
// rest of the system never has to re-parse a font to know its weights/widths.
//
//   make -C gem fontscan
//   gem/build/fontscan font1.ttf [font2.ttf ...]

#include <ft2build.h>
#include <freetype/freetype.h>
#include <freetype/ftmm.h>
#include <freetype/ftsnames.h>
#include <freetype/ttnameid.h>
#include <stdio.h>

static FT_Library lib;

// Resolve an sfnt `name` table id to ASCII (prefer Windows/UTF-16BE, then Mac).
// The real catalog keeps full UTF-8; the prototype only needs it legible.
static void sfnt_name(FT_Face face, FT_UShort id, char *out, int cap) {
    FT_UInt n = FT_Get_Sfnt_Name_Count(face);
    FT_SfntName best; int have = 0, best_score = -1;
    for (FT_UInt i = 0; i < n; i++) {
        FT_SfntName nm;
        if (FT_Get_Sfnt_Name(face, i, &nm) || nm.name_id != id) continue;
        int score = nm.platform_id == TT_PLATFORM_MICROSOFT ? 2
                  : nm.platform_id == TT_PLATFORM_MACINTOSH ? 1 : 0;
        if (score > best_score) { best = nm; best_score = score; have = 1; }
    }
    int o = 0;
    if (have && best.platform_id == TT_PLATFORM_MICROSOFT)          // UTF-16BE
        for (FT_UInt i = 0; i + 1 < best.string_len && o + 1 < cap; i += 2) {
            unsigned cp = (best.string[i] << 8) | best.string[i+1];
            out[o++] = cp < 0x80 ? (char)cp : '?';
        }
    else if (have)                                                  // Latin-1 / Mac
        for (FT_UInt i = 0; i < best.string_len && o + 1 < cap; i++)
            out[o++] = best.string[i] < 0x80 ? (char)best.string[i] : '?';
    if (!o) out[o++] = '?';
    out[o] = 0;
}

static void tag4(FT_ULong t, char *s) {
    s[0] = (t>>24)&0xFF; s[1] = (t>>16)&0xFF; s[2] = (t>>8)&0xFF; s[3] = t&0xFF; s[4] = 0;
}

static void scan(const char *path) {
    FT_Face face;
    if (FT_New_Face(lib, path, 0, &face)) { printf("\n%s: cannot open\n", path); return; }
    int var = FT_HAS_MULTIPLE_MASTERS(face);
    printf("\n%s\n  family   : %s\n  variable : %s\n",
           path, face->family_name ? face->family_name : "?", var ? "yes" : "no");
    if (var) {
        FT_MM_Var *mv;
        if (!FT_Get_MM_Var(face, &mv)) {
            printf("  axes (%u):\n", mv->num_axis);
            for (FT_UInt a = 0; a < mv->num_axis; a++) {
                char t[5]; tag4(mv->axis[a].tag, t);
                printf("    %-4s  min %-7.1f def %-7.1f max %-7.1f\n", t,
                       mv->axis[a].minimum/65536.0, mv->axis[a].def/65536.0,
                       mv->axis[a].maximum/65536.0);
            }
            printf("  named instances (%u):\n", mv->num_namedstyles);
            for (FT_UInt s = 0; s < mv->num_namedstyles; s++) {
                char nm[128]; sfnt_name(face, mv->namedstyle[s].strid, nm, sizeof nm);
                printf("    %2u  %-26s [", s + 1, nm);           // index is 1-based for FT_Set_Named_Instance
                for (FT_UInt a = 0; a < mv->num_axis; a++) {
                    char t[5]; tag4(mv->axis[a].tag, t);
                    printf("%s%s=%g", a ? " " : "", t, mv->namedstyle[s].coords[a]/65536.0);
                }
                printf("]\n");
            }
            FT_Done_MM_Var(lib, mv);
        }
    } else {
        printf("  style    : %s%s%s\n", face->style_name ? face->style_name : "?",
               (face->style_flags & FT_STYLE_FLAG_BOLD)   ? "  [bold]"   : "",
               (face->style_flags & FT_STYLE_FLAG_ITALIC) ? "  [italic]" : "");
    }
    FT_Done_Face(face);
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s font.ttf ...\n", argv[0]); return 1; }
    if (FT_Init_FreeType(&lib)) { fprintf(stderr, "FreeType init failed\n"); return 1; }
    for (int i = 1; i < argc; i++) scan(argv[i]);
    FT_Done_FreeType(lib);
    return 0;
}
