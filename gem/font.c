// font.c — FreeType-backed text: a face, and per-size views with glyph caches.
//
// One shared FT_Library (lazily created).  A font_face wraps an FT_Face; a font
// is that face at a pixel size (font_at), holding its own rasterised alpha-
// coverage cache.  Sized views share the FT_Face, so glyph_get re-selects the
// size before rasterising (cached glyphs are untouched afterwards).  Caches
// ASCII (0..127) inline.  Blend keeps the destination opaque (alpha 0xFF).

#include "font.h"
#include <stdlib.h>
#include <string.h>

#include <ft2build.h>
#include FT_FREETYPE_H

#define GLYPH_CACHE 128                 // ASCII 0..127

typedef struct {
    int      ready;                     // 0 = not yet rasterised
    int      w, h;                      // coverage bitmap size
    int      left, top;                 // bearings (FreeType convention)
    int      advance;                   // pen advance (px)
    uint8_t *cov;                       // w*h alpha coverage (malloc'd), or NULL
} glyph;

struct font {                           // a face at one pixel size
    font_face *owner;                   // for the shared FT_Face + tracking
    int        px, height, ascent, max_adv;
    glyph      cache[GLYPH_CACHE];
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
        for (int i = 0; i < GLYPH_CACHE; i++) free(f->cache[i].cov);
        free(f);
        f = next;
    }
    FT_Done_Face(face->ft);
    free(face);
}

void font_face_set_tracking(font_face *face, int px) { if (face) face->tracking = px; }

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

// Rasterise codepoint c into this view's cache (no-op if already there).
static const glyph *glyph_get(font *f, unsigned c) {
    if (c >= GLYPH_CACHE) c = '?';
    glyph *g = &f->cache[c];
    if (g->ready) return g;
    FT_Set_Pixel_Sizes(f->owner->ft, 0, f->px);     // sized views share the FT_Face
    if (FT_Load_Char(f->owner->ft, c, FT_LOAD_RENDER)) return NULL;
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
    return g;
}

int font_text_width(font *f, const char *s) {
    if (!f || !s) return 0;
    int w = 0, trk = f->owner->tracking;
    for (; *s; s++) { const glyph *g = glyph_get(f, (unsigned char)*s); if (g) w += g->advance + trk; }
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

void font_draw(font *f, gfx_surface *d, int x, int y, const char *s,
               uint32_t rgba, const int *clip) {
    if (!f || !s || !d) return;
    int cx0 = 0, cy0 = 0, cx1 = d->w - 1, cy1 = d->h - 1;
    if (clip) {
        if (clip[0] > cx0) cx0 = clip[0]; if (clip[1] > cy0) cy0 = clip[1];
        if (clip[2] < cx1) cx1 = clip[2]; if (clip[3] < cy1) cy1 = clip[3];
    }
    int pen = x, base = y + f->ascent, trk = f->owner->tracking;
    for (; *s; s++) {
        const glyph *g = glyph_get(f, (unsigned char)*s);
        if (!g) continue;
        if (g->cov) {
            int gx = pen + g->left, gy = base - g->top;
            for (int row = 0; row < g->h; row++) {
                int py = gy + row; if (py < cy0 || py > cy1) continue;
                const uint8_t *cr = g->cov + (size_t)row * g->w;
                uint32_t *dr = d->px + (size_t)py * d->stride;
                for (int col = 0; col < g->w; col++) {
                    int px = gx + col; if (px < cx0 || px > cx1) continue;
                    dr[px] = blend(dr[px], rgba, cr[col]);
                }
            }
        }
        pen += g->advance + trk;
    }
}
