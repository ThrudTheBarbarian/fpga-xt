// font_catalog.c — build / persist / load the OS/Fonts catalog (see header +
// docs/OS/fonts.md).

#include "font_catalog.h"
#include <freetype/ftmm.h>
#include <freetype/ftsnames.h>
#include <freetype/ttnameid.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define TAG(a,b,c,d) (((uint32_t)(a)<<24)|((uint32_t)(b)<<16)|((uint32_t)(c)<<8)|(uint32_t)(d))

// ---- CRC32 (poly 0xEDB88320), incremental ---------------------------------
static uint32_t crc32_bytes(uint32_t c, const uint8_t *p, size_t n) {
    while (n--) { c ^= *p++; for (int k = 0; k < 8; k++) c = (c >> 1) ^ (0xEDB88320u & -(c & 1)); }
    return c;
}
static int ent_cmp(const void *a, const void *b) {
    return strcmp(((const fc_dirent *)a)->name, ((const fc_dirent *)b)->name);
}
uint32_t fc_dir_hash(const fc_dirent *ents, int n) {
    fc_dirent *s = malloc((size_t)n * sizeof *s);
    if (!s) return 0;
    memcpy(s, ents, (size_t)n * sizeof *s);
    qsort(s, (size_t)n, sizeof *s, ent_cmp);          // readdir order isn't stable
    uint32_t c = 0xFFFFFFFFu;
    char buf[FC_FILE_MAX + 32];
    for (int i = 0; i < n; i++) {
        int m = snprintf(buf, sizeof buf, "%s:%ld\n", s[i].name, s[i].size);
        if (m > (int)sizeof buf) m = sizeof buf;
        c = crc32_bytes(c, (const uint8_t *)buf, (size_t)m);
    }
    free(s);
    return c ^ 0xFFFFFFFFu;
}

// ---- helpers --------------------------------------------------------------
static void cpystr(char *dst, int cap, const char *src) {
    if (!src) { dst[0] = '\0'; return; }
    int i = 0; for (; src[i] && i < cap - 1; i++) dst[i] = src[i];
    dst[i] = '\0';
}
static void tag4(uint32_t t, char *s) {
    s[0] = (t>>24)&0xFF; s[1] = (t>>16)&0xFF; s[2] = (t>>8)&0xFF; s[3] = t&0xFF; s[4] = 0;
}
// sfnt `name` id -> ASCII (prefer Windows/UTF-16BE, then Mac).
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
    if (have && best.platform_id == TT_PLATFORM_MICROSOFT)
        for (FT_UInt i = 0; i + 1 < best.string_len && o < cap - 1; i += 2) {
            unsigned cp = (best.string[i] << 8) | best.string[i+1];
            out[o++] = cp < 0x80 ? (char)cp : '?';
        }
    else if (have)
        for (FT_UInt i = 0; i < best.string_len && o < cap - 1; i++)
            out[o++] = best.string[i] < 0x80 ? (char)best.string[i] : '?';
    if (!o) cpystr(out, cap, "Regular");
    else out[o] = '\0';
}
static fc_face *cat_add(fc_catalog *c) {
    if (c->n_faces == c->cap) {
        c->cap = c->cap ? c->cap * 2 : 64;
        c->faces = realloc(c->faces, (size_t)c->cap * sizeof *c->faces);
    }
    fc_face *f = &c->faces[c->n_faces++];
    memset(f, 0, sizeof *f);
    return f;
}
// Case-insensitive search for "italic" anywhere in a style name.
static int name_italic(const char *s) {
    static const char it[] = "italic";
    for (; *s; s++) {
        int k = 0;
        while (it[k] && (s[k] | 0x20) == it[k]) k++;
        if (!it[k]) return 1;
    }
    return 0;
}
// Fill weight/width/italic conveniences from the design coords + style name.
// Italic may be an axis (slnt/ital, e.g. Roboto Flex) OR a whole separate file
// with no italic axis whose instances are just named "... Italic" (e.g. Google's
// Roboto-Italic), so the name is the reliable cross-case signal.
static void derive(fc_face *f) {
    f->weight = 400; f->width = 100;
    for (int i = 0; i < f->n_axes; i++) {
        uint32_t t = f->axes[i].tag; float v = f->axes[i].value;
        if      (t == TAG('w','g','h','t')) f->weight = (int16_t)(v + 0.5f);
        else if (t == TAG('w','d','t','h')) f->width  = (int16_t)(v + 0.5f);
        else if (t == TAG('s','l','n','t')) { if (v < 0)      f->italic = 1; }
        else if (t == TAG('i','t','a','l')) { if (v >= 0.5f)  f->italic = 1; }
    }
    if (name_italic(f->style)) f->italic = 1;
}

// ---- build ----------------------------------------------------------------
int fc_build(fc_catalog *cat, FT_Library lib, const char *dir,
             const fc_dirent *ents, int n) {
    cat->faces = NULL; cat->n_faces = 0; cat->cap = 0;
    cat->hash = fc_dir_hash(ents, n);
    char path[FC_FILE_MAX + 256];
    for (int e = 0; e < n; e++) {
        snprintf(path, sizeof path, "%s/%s", dir, ents[e].name);
        FT_Face face;
        if (FT_New_Face(lib, path, 0, &face)) continue;     // skip unreadable fonts
        if (FT_HAS_MULTIPLE_MASTERS(face)) {
            FT_MM_Var *mv;
            if (!FT_Get_MM_Var(face, &mv)) {
                int na = mv->num_axis < FC_MAX_AXES ? (int)mv->num_axis : FC_MAX_AXES;
                for (FT_UInt s = 0; s < mv->num_namedstyles; s++) {
                    fc_face *f = cat_add(cat);
                    f->variable = 1;
                    f->n_axes = (uint8_t)na;
                    cpystr(f->family, FC_FAMILY_MAX, face->family_name);
                    sfnt_name(face, mv->namedstyle[s].strid, f->style, FC_STYLE_MAX);
                    cpystr(f->file, FC_FILE_MAX, ents[e].name);
                    for (int a = 0; a < na; a++) {
                        f->axes[a].tag = mv->axis[a].tag;
                        f->axes[a].value = mv->namedstyle[s].coords[a] / 65536.0f;
                    }
                    derive(f);
                }
                FT_Done_MM_Var(lib, mv);
            }
        } else {
            fc_face *f = cat_add(cat);
            cpystr(f->family, FC_FAMILY_MAX, face->family_name);
            cpystr(f->style, FC_STYLE_MAX, face->style_name ? face->style_name : "Regular");
            cpystr(f->file, FC_FILE_MAX, ents[e].name);
            f->italic = (face->style_flags & FT_STYLE_FLAG_ITALIC) || name_italic(f->style);
            f->weight = (face->style_flags & FT_STYLE_FLAG_BOLD) ? 700 : 400;
            f->width = 100;
        }
        FT_Done_Face(face);
    }
    return cat->n_faces;
}

// ---- index persistence ----------------------------------------------------
int fc_write_index(const fc_catalog *cat, const char *path) {
    char tmp[FC_FILE_MAX + 256];
    snprintf(tmp, sizeof tmp, "%s.tmp", path);
    FILE *f = fopen(tmp, "wb");
    if (!f) return -1;
    fprintf(f, "FONTCAT 1 %d %u %d\n", FREETYPE_MAJOR, cat->hash, cat->n_faces);
    for (int i = 0; i < cat->n_faces; i++) {
        const fc_face *c = &cat->faces[i];
        fprintf(f, "F|%s|%s|%s|%d|%d|%d|%d|%d",
                c->family, c->style, c->file, c->variable, c->weight, c->width,
                c->italic, c->n_axes);
        for (int a = 0; a < c->n_axes; a++) {
            char t[5]; tag4(c->axes[a].tag, t);
            fprintf(f, "|%s=%g", t, c->axes[a].value);
        }
        fputc('\n', f);
    }
    int ok = (fclose(f) == 0);
    if (!ok || rename(tmp, path) != 0) { remove(tmp); return -1; }   // atomic replace
    return 0;
}

// Split `s` on '|' in place; returns the field count, fields[] point into `s`.
static int split(char *s, char **fields, int max) {
    int n = 0;
    fields[n++] = s;
    for (; *s && n < max; s++) if (*s == '|') { *s = '\0'; fields[n++] = s + 1; }
    char *nl = strpbrk(fields[n-1], "\r\n");
    if (nl) *nl = '\0';
    return n;
}
int fc_read_index(fc_catalog *cat, const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) return -1;
    cat->faces = NULL; cat->n_faces = 0; cat->cap = 0;
    char line[1024];
    int ver = 0, ftmaj = 0, nf = 0; unsigned hash = 0;
    if (!fgets(line, sizeof line, f) ||
        sscanf(line, "FONTCAT %d %d %u %d", &ver, &ftmaj, &hash, &nf) != 4 ||
        ver != 1 || ftmaj != FREETYPE_MAJOR) { fclose(f); return -1; }
    cat->hash = hash;
    while (fgets(line, sizeof line, f)) {
        if (line[0] != 'F' || line[1] != '|') continue;
        char *fl[8 + FC_MAX_AXES + 2];
        int nfl = split(line, fl, 8 + FC_MAX_AXES + 2);
        if (nfl < 9) continue;
        fc_face *c = cat_add(cat);
        cpystr(c->family, FC_FAMILY_MAX, fl[1]);
        cpystr(c->style,  FC_STYLE_MAX,  fl[2]);
        cpystr(c->file,   FC_FILE_MAX,   fl[3]);
        c->variable = (uint8_t)atoi(fl[4]);
        c->weight   = (int16_t)atoi(fl[5]);
        c->width    = (int16_t)atoi(fl[6]);
        c->italic   = (uint8_t)atoi(fl[7]);
        int na = atoi(fl[8]); if (na > FC_MAX_AXES) na = FC_MAX_AXES;
        c->n_axes = (uint8_t)na;
        for (int a = 0; a < na && 9 + a < nfl; a++) {
            char *ax = fl[9 + a];                       // "wght=700"
            if (strlen(ax) < 5) continue;
            c->axes[a].tag = TAG(ax[0], ax[1], ax[2], ax[3]);
            c->axes[a].value = (float)atof(ax + 5);
        }
    }
    fclose(f);
    return 0;
}

// ---- orchestration --------------------------------------------------------
int fc_load(fc_catalog *cat, FT_Library lib, const char *dir,
            const fc_dirent *ents, int n, const char *idxpath, int *from_index) {
    uint32_t h = fc_dir_hash(ents, n);
    if (from_index) *from_index = 0;
    if (idxpath && fc_read_index(cat, idxpath) == 0 && cat->hash == h) {
        if (from_index) *from_index = 1;
        return cat->n_faces;                            // fast path: parsed 0 fonts
    }
    fc_free(cat);                                       // drop a stale/mismatched read
    int r = fc_build(cat, lib, dir, ents, n);
    if (r >= 0 && idxpath) fc_write_index(cat, idxpath);
    return r;
}

void fc_free(fc_catalog *cat) {
    free(cat->faces);
    cat->faces = NULL; cat->n_faces = 0; cat->cap = 0;
}
