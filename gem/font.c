// font.c — FreeType-backed text: a face, and per-size views with glyph caches.
//
// One shared FT_Library (lazily created).  A font_face wraps an FT_Face; a font
// is that face at a pixel size (font_at), holding its own rasterised alpha-
// coverage cache.  Strings are UTF-8: ASCII (0..127) is cached in an inline
// array (the common path); higher codepoints hang off a small chained hash, so
// accented Latin, dashes, arrows etc. cost only what's used.  Sized views share
// the FT_Face, so a raster re-selects the size first (cached glyphs untouched).
// Blend keeps the destination opaque (alpha 0xFF).

#include "font.h"
#include <stdlib.h>
#include <string.h>
#include <math.h>

#include <ft2build.h>
#include FT_FREETYPE_H

#define ASCII_N 128
#define GHASH   97                      // buckets for codepoints >= 128

typedef struct {
    int      ready;                     // 0 = not yet rasterised
    int      w, h;                      // coverage bitmap size
    int      left, top;                 // bearings (FreeType convention)
    int      advance;                   // pen advance (px)
    uint8_t *cov;                       // w*h alpha coverage (malloc'd), or NULL
} glyph;

typedef struct gnode { unsigned cp; glyph g; struct gnode *next; } gnode;

struct font {                           // a face at one pixel size
    font_face *owner;                   // for the shared FT_Face + tracking
    int        px, height, ascent, max_adv;
    glyph      ascii[ASCII_N];          // 0..127, lazily rasterised
    gnode     *hash[GHASH];             // >= 128
    font      *next;                    // next sized view of the same face
};

struct font_face {
    FT_Face ft;
    int     tracking;                   // extra px added to each glyph advance
    font   *sizes;                      // linked list of sized views
};

static FT_Library g_ft;                 // shared, lazily initialised

font_face *font_face_open(const char *path) {
    if (!g_ft && FT_Init_FreeType(&g_ft)) return NULL;
    font_face *face = calloc(1, sizeof(*face));
    if (!face) return NULL;
    if (FT_New_Face(g_ft, path, 0, &face->ft)) { free(face); return NULL; }
    return face;
}

void font_face_close(font_face *face) {
    if (!face) return;
    for (font *f = face->sizes; f; ) {
        font *next = f->next;
        for (int i = 0; i < ASCII_N; i++) free(f->ascii[i].cov);
        for (int b = 0; b < GHASH; b++)
            for (gnode *n = f->hash[b]; n; ) { gnode *nx = n->next; free(n->g.cov); free(n); n = nx; }
        free(f);
        f = next;
    }
    FT_Done_Face(face->ft);
    free(face);
}

void font_face_set_tracking(font_face *face, int px) { if (face) face->tracking = px; }

const char *font_face_name(const font_face *face) {
    return (face && face->ft && face->ft->family_name) ? face->ft->family_name : "";
}

font *font_at(font_face *face, int px) {
    if (!face || px < 1) return NULL;
    for (font *f = face->sizes; f; f = f->next) if (f->px == px) return f;
    font *f = calloc(1, sizeof(*f));
    if (!f) return NULL;
    f->owner = face; f->px = px;
    if (FT_Set_Pixel_Sizes(face->ft, 0, px)) { free(f); return NULL; }
    f->ascent  = (int)(face->ft->size->metrics.ascender    >> 6);
    f->height  = (int)(face->ft->size->metrics.height      >> 6);
    f->max_adv = (int)(face->ft->size->metrics.max_advance >> 6);
    f->next = face->sizes; face->sizes = f;
    return f;
}

int font_height(const font *f)      { return f ? f->height  : 0; }
int font_ascent(const font *f)      { return f ? f->ascent  : 0; }
int font_max_advance(const font *f) { return f ? f->max_adv : 0; }
int font_size(const font *f)        { return f ? f->px      : 0; }

// Decode one UTF-8 codepoint and advance *ps past it.  Malformed bytes yield
// U+FFFD and advance one byte.  Never reads past a NUL (it fails as a bad
// continuation byte first).
static unsigned utf8_next(const char **ps) {
    const unsigned char *s = (const unsigned char *)(*ps);
    unsigned c = s[0], cp; int n;
    if      (c < 0x80)        { cp = c;        n = 1; }
    else if ((c & 0xE0)==0xC0){ cp = c & 0x1F; n = 2; }
    else if ((c & 0xF0)==0xE0){ cp = c & 0x0F; n = 3; }
    else if ((c & 0xF8)==0xF0){ cp = c & 0x07; n = 4; }
    else { *ps = (const char *)(s + 1); return 0xFFFD; }
    for (int i = 1; i < n; i++) {
        if ((s[i] & 0xC0) != 0x80) { *ps = (const char *)(s + 1); return 0xFFFD; }
        cp = (cp << 6) | (s[i] & 0x3F);
    }
    *ps = (const char *)(s + n);
    return cp;
}

static void raster_into(font *f, glyph *g, unsigned cp) {
    FT_Set_Pixel_Sizes(f->owner->ft, 0, f->px);     // sized views share the FT_Face
    if (FT_Load_Char(f->owner->ft, cp, FT_LOAD_RENDER)) { g->ready = 1; return; }
    FT_GlyphSlot s = f->owner->ft->glyph;
    FT_Bitmap *bm = &s->bitmap;
    g->w = bm->width; g->h = bm->rows;
    g->left = s->bitmap_left; g->top = s->bitmap_top;
    g->advance = (int)(s->advance.x >> 6);
    if (g->w && g->h) {
        g->cov = malloc((size_t)g->w * g->h);
        if (g->cov)
            for (int row = 0; row < g->h; row++)
                memcpy(g->cov + (size_t)row * g->w,
                       bm->buffer + (size_t)row * bm->pitch, g->w);
    }
    g->ready = 1;
}

// Cached glyph for a codepoint: inline array for ASCII, chained hash above it.
static const glyph *glyph_get(font *f, unsigned cp) {
    if (cp < ASCII_N) {
        glyph *g = &f->ascii[cp];
        if (!g->ready) raster_into(f, g, cp);
        return g;
    }
    unsigned h = cp % GHASH;
    for (gnode *n = f->hash[h]; n; n = n->next) if (n->cp == cp) return &n->g;
    gnode *n = calloc(1, sizeof(*n));
    if (!n) return NULL;
    n->cp = cp; raster_into(f, &n->g, cp);
    n->next = f->hash[h]; f->hash[h] = n;
    return &n->g;
}

int font_text_width(font *f, const char *s) {
    if (!f || !s) return 0;
    int w = 0, trk = f->owner->tracking;
    for (const char *p = s; *p; ) {
        const glyph *g = glyph_get(f, utf8_next(&p));
        if (g) w += g->advance + trk;
    }
    return w;
}

// out = src*cov + dst*(1-cov), per channel; alpha forced opaque.
static inline uint32_t blend(uint32_t dst, uint32_t src, unsigned cov) {
    if (cov == 0)   return dst;
    if (cov == 255) return (src & 0xFFFFFF00u) | 0xFF;
    unsigned dr = (dst>>24)&0xFF, dg = (dst>>16)&0xFF, db = (dst>>8)&0xFF;
    unsigned sr = (src>>24)&0xFF, sg = (src>>16)&0xFF, sb = (src>>8)&0xFF;
    unsigned ico = 255 - cov;
    unsigned r = (sr*cov + dr*ico) / 255;
    unsigned g = (sg*cov + dg*ico) / 255;
    unsigned b = (sb*cov + db*ico) / 255;
    return (r<<24) | (g<<16) | (b<<8) | 0xFF;
}

// Render one glyph's coverage at pen/base, clipped.  mode 3 (VDI XOR) toggles
// solid pixels where coverage is high; otherwise alpha-blend.
static void blit_glyph(gfx_surface *d, int pen, int base, const glyph *g,
                       uint32_t rgba, int cx0, int cy0, int cx1, int cy1, int mode) {
    if (!g->cov) return;
    int gx = pen + g->left, gy = base - g->top;
    uint32_t xr = rgba & 0xFFFFFF00u;
    for (int row = 0; row < g->h; row++) {
        int py = gy + row; if (py < cy0 || py > cy1) continue;
        const uint8_t *cr = g->cov + (size_t)row * g->w;
        uint32_t *dr = d->px + (size_t)py * d->stride;
        for (int col = 0; col < g->w; col++) {
            int px = gx + col; if (px < cx0 || px > cx1) continue;
            if (mode == 3) { if (cr[col] >= 128) dr[px] ^= xr; }   // XOR
            else dr[px] = blend(dr[px], rgba, cr[col]);
        }
    }
}

static void clip_of(gfx_surface *d, const int *clip, int *cx0, int *cy0, int *cx1, int *cy1) {
    *cx0 = 0; *cy0 = 0; *cx1 = d->w - 1; *cy1 = d->h - 1;
    if (clip) {
        if (clip[0] > *cx0) *cx0 = clip[0]; if (clip[1] > *cy0) *cy0 = clip[1];
        if (clip[2] < *cx1) *cx1 = clip[2]; if (clip[3] < *cy1) *cy1 = clip[3];
    }
}

void font_draw(font *f, gfx_surface *d, int x, int y, const char *s,
               uint32_t rgba, const int *clip, int mode) {
    if (!f || !s || !d) return;
    int cx0, cy0, cx1, cy1; clip_of(d, clip, &cx0, &cy0, &cx1, &cy1);
    int pen = x, base = y + f->ascent, trk = f->owner->tracking;
    for (const char *p = s; *p; ) {
        const glyph *g = glyph_get(f, utf8_next(&p));
        if (!g) continue;
        blit_glyph(d, pen, base, g, rgba, cx0, cy0, cx1, cy1, mode);
        pen += g->advance + trk;
    }
}

// Spread `s` to occupy `width` px: extra slack goes to the gaps after spaces
// (word_space) and/or between every glyph (char_space).  Used by v_justified.
void font_draw_justified(font *f, gfx_surface *d, int x, int y, const char *s,
                         int width, int word_space, int char_space,
                         uint32_t rgba, const int *clip, int mode) {
    if (!f || !s || !d) return;
    int trk = f->owner->tracking;
    int natural = 0, n = 0, nspaces = 0;                 // measure
    for (const char *p = s; *p; ) {
        unsigned cp = utf8_next(&p);
        const glyph *g = glyph_get(f, cp); if (!g) continue;
        natural += g->advance + trk;
        if (cp == ' ') nspaces++;
        n++;
    }
    int gaps = n > 1 ? n - 1 : 0, extra = width - natural;
    int word_add = 0, char_add = 0;
    if (word_space && char_space) {
        if (nspaces > 0) word_add = (extra / 2) / nspaces;
        if (gaps > 0)    char_add = (extra - word_add * nspaces) / gaps;
    } else if (word_space) {
        if (nspaces > 0) word_add = extra / nspaces;
    } else if (char_space) {
        if (gaps > 0)    char_add = extra / gaps;
    }
    int cx0, cy0, cx1, cy1; clip_of(d, clip, &cx0, &cy0, &cx1, &cy1);
    int pen = x, base = y + f->ascent, i = 0;
    for (const char *p = s; *p; i++) {
        unsigned cp = utf8_next(&p);
        const glyph *g = glyph_get(f, cp); if (!g) { i--; continue; }
        blit_glyph(d, pen, base, g, rgba, cx0, cy0, cx1, cy1, mode);
        pen += g->advance + trk;
        if (cp == ' ' && word_space) pen += word_add;
        if (i < n - 1 && char_space) pen += char_add;
    }
}

// Blit a freshly-rendered (transformed) FT bitmap's coverage at device top-left.
static void blit_ft(gfx_surface *d, const FT_Bitmap *bm, int bx, int by,
                    uint32_t rgba, int cx0, int cy0, int cx1, int cy1, int mode) {
    uint32_t xr = rgba & 0xFFFFFF00u;
    for (int row = 0; row < (int)bm->rows; row++) {
        int py = by + row; if (py < cy0 || py > cy1 || py < 0 || py >= d->h) continue;
        const uint8_t *cr = bm->buffer + (size_t)row * bm->pitch;
        uint32_t *dr = d->px + (size_t)py * d->stride;
        for (int col = 0; col < (int)bm->width; col++) {
            int px = bx + col; if (px < cx0 || px > cx1 || px < 0 || px >= d->w) continue;
            if (mode == 3) { if (cr[col] >= 128) dr[px] ^= xr; }
            else dr[px] = blend(dr[px], rgba, cr[col]);
        }
    }
}

void font_draw_rotated(font *f, gfx_surface *d, int x, int y, const char *s,
                       int angle_tenths, uint32_t rgba, const int *clip, int mode) {
    if (!f || !s || !d) return;
    int cx0, cy0, cx1, cy1; clip_of(d, clip, &cx0, &cy0, &cx1, &cy1);
    double a = angle_tenths * (M_PI / 1800.0);          // tenths of a degree, CCW
    FT_Matrix m = {
        (FT_Fixed)lround( cos(a) * 65536.0), (FT_Fixed)lround(-sin(a) * 65536.0),
        (FT_Fixed)lround( sin(a) * 65536.0), (FT_Fixed)lround( cos(a) * 65536.0) };
    FT_Face face = f->owner->ft;
    FT_Set_Pixel_Sizes(face, 0, f->px);
    double penx = x, peny = y + f->ascent;              // baseline origin = pivot (device y-down)
    int trk = f->owner->tracking;
    for (const char *p = s; *p; ) {
        unsigned cp = utf8_next(&p);
        FT_Set_Transform(face, &m, NULL);
        if (FT_Load_Char(face, cp, FT_LOAD_RENDER)) continue;
        FT_GlyphSlot g = face->glyph;
        blit_ft(d, &g->bitmap, (int)lround(penx) + g->bitmap_left,
                (int)lround(peny) - g->bitmap_top, rgba, cx0, cy0, cx1, cy1, mode);
        penx += g->advance.x / 64.0 + trk * cos(a);     // advance along the rotated baseline
        peny -= g->advance.y / 64.0 + trk * sin(a);     // FT y is up; device y is down
    }
    FT_Set_Transform(face, NULL, NULL);                 // identity again for the cached path
}
