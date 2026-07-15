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
#include FT_OUTLINE_H
#include FT_GLYPH_H
#include FT_STROKER_H

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

struct font {                           // a face at one (width x height) px size
    font_face *owner;                   // for the shared FT_Face + tracking
    int        px, wpx, height, ascent, max_adv;   // wpx = cell width (anisotropic)
    glyph      ascii[ASCII_N];          // 0..127, lazily rasterised
    gnode     *hash[GHASH];             // >= 128
    font      *next;                    // next sized view of the same face
};

struct font_face {
    FT_Face     ft;
    int         tracking;               // extra px added to each glyph advance
    int         track_off;              // vst_track_offset (extra letter-spacing)
    int         kern;                   // vst_kern: apply pair kerning when the face has it
    const void *map;                    // mmap'd font file (or NULL if read by path)
    unsigned long maplen;
    font       *sizes;                  // linked list of sized views
};

static FT_Library g_ft;                 // shared, lazily initialised

// Map a font file read-only + shared (zero-copy), or 0 if mapping is unavailable.
// XTOS provides these (gem_stubs.c, via SYS_mmap); on the host the weak defaults
// return 0 and font_face_open falls back to reading the file by path.
__attribute__((weak)) const void *xt_font_map(const char *path, unsigned long *len)
{ (void)path; (void)len; return 0; }
__attribute__((weak)) void xt_font_unmap(const void *p, unsigned long len)
{ (void)p; (void)len; }

font_face *font_face_open(const char *path) {
    if (!g_ft && FT_Init_FreeType(&g_ft)) return NULL;
    font_face *face = calloc(1, sizeof(*face));
    if (!face) return NULL;
    // Prefer a zero-copy mmap of the file (FreeType reads glyphs straight from the
    // shared, read-only mapping — demand-paged); fall back to reading by path.
    unsigned long mlen = 0;
    const void *m = xt_font_map(path, &mlen);
    if (m) {
        if (FT_New_Memory_Face(g_ft, m, (FT_Long)mlen, 0, &face->ft)) {
            xt_font_unmap(m, mlen); free(face); return NULL;
        }
        face->map = m; face->maplen = mlen;
    } else if (FT_New_Face(g_ft, path, 0, &face->ft)) {
        free(face); return NULL;
    }
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
    FT_Done_Face(face->ft);              // FreeType no longer touches the mapping
    if (face->map) xt_font_unmap(face->map, face->maplen);
    free(face);
}

void font_face_set_tracking(font_face *face, int px) { if (face) face->tracking = px; }

const char *font_face_name(const font_face *face) {
    return (face && face->ft && face->ft->family_name) ? face->ft->family_name : "";
}

font *font_at_wh(font_face *face, int wpx, int hpx) {
    if (!face || hpx < 1) return NULL;
    if (wpx < 1) wpx = hpx;
    for (font *f = face->sizes; f; f = f->next) if (f->px == hpx && f->wpx == wpx) return f;
    font *f = calloc(1, sizeof(*f));
    if (!f) return NULL;
    f->owner = face; f->px = hpx; f->wpx = wpx;
    if (FT_Set_Pixel_Sizes(face->ft, wpx, hpx)) { free(f); return NULL; }
    f->ascent  = (int)(face->ft->size->metrics.ascender    >> 6);
    f->height  = (int)(face->ft->size->metrics.height      >> 6);
    f->max_adv = (int)(face->ft->size->metrics.max_advance >> 6);
    f->next = face->sizes; face->sizes = f;
    return f;
}
font *font_at(font_face *face, int px) { return font_at_wh(face, px, px); }

// vst_kern / vst_track_offset / vst_skew support flags on the face.
int  font_face_set_kern(font_face *face, int on) {       // -> 1 if actually kerning
    if (!face) return 0;
    face->kern = on && FT_HAS_KERNING(face->ft);
    return face->kern;
}
int  font_face_has_kern(const font_face *face) { return face && FT_HAS_KERNING(face->ft); }
int  font_kerning_on(const font *f) { return f && f->owner->kern; }   // matches kern_px's gate
void font_face_set_track(font_face *face, int off) { if (face) face->track_off = off; }

// Pair-kern delta (px) between two codepoints at this view's size; 0 unless
// kerning is enabled and the face has a kern table.  The caller sets the size.
static int kern_px(font *f, unsigned prev, unsigned cur) {
    if (!prev || !f->owner->kern || !FT_HAS_KERNING(f->owner->ft)) return 0;
    FT_Face ft = f->owner->ft;
    FT_Vector k;
    if (FT_Get_Kerning(ft, FT_Get_Char_Index(ft, prev), FT_Get_Char_Index(ft, cur),
                       FT_KERNING_DEFAULT, &k)) return 0;
    return (int)(k.x >> 6);
}
static int face_trk(const font *f) { return f->owner->tracking + f->owner->track_off; }

int font_height(const font *f)      { return f ? f->height  : 0; }
int font_ascent(const font *f)      { return f ? f->ascent  : 0; }
int font_max_advance(const font *f) { return f ? f->max_adv : 0; }
int font_size(const font *f)        { return f ? f->px      : 0; }

// Structural vertical metrics for vqt_fontinfo — the five baseline-relative
// distances (all >= 0).  top/bottom come from the design bounding box (so they
// span accents + the deepest descenders); ascent/descent are the typographic
// lines; half is the mid-line.  Any out pointer may be NULL.
void font_vmetrics(const font *f, int *top, int *ascent, int *half,
                   int *descent, int *bottom) {
    int asc = 0, desc = 0, tp = 0, bt = 0;
    if (f) {
        FT_Face ft = f->owner->ft;
        FT_Set_Pixel_Sizes(ft, 0, f->px);               // sized views share the FT_Face
        asc  = (int)(ft->size->metrics.ascender  >> 6);
        desc = (int)(-(ft->size->metrics.descender >> 6));   // make it positive (below baseline)
        long upm = ft->units_per_EM ? ft->units_per_EM : 1;
        tp = (int)((long)ft->bbox.yMax * f->px / upm);  // design box top (accents)
        bt = (int)((long)-ft->bbox.yMin * f->px / upm); // design box bottom (descenders)
        if (tp < asc)  tp = asc;
        if (bt < desc) bt = desc;
    }
    if (top)     *top     = tp;
    if (ascent)  *ascent  = asc;
    if (half)    *half    = asc / 2;
    if (descent) *descent = desc;
    if (bottom)  *bottom  = bt;
}

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
    FT_Set_Pixel_Sizes(f->owner->ft, f->wpx, f->px);   // sized views share the FT_Face
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
    int w = 0, trk = face_trk(f);
    unsigned prev = 0;
    if (f->owner->kern) FT_Set_Pixel_Sizes(f->owner->ft, f->wpx, f->px);
    for (const char *p = s; *p; ) {
        unsigned cp = utf8_next(&p);
        const glyph *g = glyph_get(f, cp);
        if (g) { w += kern_px(f, prev, cp) + g->advance + trk; prev = cp; }
    }
    return w;
}

// Per-character metrics for vqt_width.  Returns the cell width (pen advance,
// tracking included); *lbear = px the ink starts right of the cell origin,
// *rover = px the ink extends past the cell's right edge (both >= 0).
int font_char_metrics(font *f, unsigned cp, int *lbear, int *rover) {
    if (lbear) *lbear = 0;
    if (rover) *rover = 0;
    if (!f) return 0;
    const glyph *g = glyph_get(f, cp);
    if (!g) return 0;
    int adv = g->advance + face_trk(f);
    if (lbear) *lbear = g->left > 0 ? g->left : 0;
    int right = g->left + g->w;            // ink right edge from cell origin
    if (rover) *rover = right > adv ? right - adv : 0;
    return adv;
}

// Fractional advance of one codepoint at this view's size, in 26.6 fixed (1/64
// px), tracking included.  No hinting, so the advance keeps its sub-pixel part
// (the whole point of the NVDI fractional text calls).
long font_f_advance(font *f, unsigned cp) {
    if (!f) return 0;
    FT_Set_Pixel_Sizes(f->owner->ft, f->wpx, f->px);
    if (FT_Load_Char(f->owner->ft, cp, FT_LOAD_NO_HINTING)) return 0;
    return f->owner->ft->glyph->advance.x + ((long)face_trk(f) << 6);
}
// Fractional pen advance for a whole UTF-8 string, in 26.6 fixed.
long font_f_text_width(font *f, const char *s) {
    if (!f || !s) return 0;
    FT_Set_Pixel_Sizes(f->owner->ft, f->wpx, f->px);
    long w = 0;
    for (const char *p = s; *p; ) {
        unsigned cp = utf8_next(&p);
        if (FT_Load_Char(f->owner->ft, cp, FT_LOAD_NO_HINTING)) continue;
        w += f->owner->ft->glyph->advance.x + ((long)face_trk(f) << 6);
    }
    return w;
}

// ---- Glyph outline extraction (v_getoutline) ------------------------------
// Decompose a glyph's FreeType outline into the v_bez point/flag representation:
// xy[] gets (x,y) device-pixel points (y down, relative to the glyph origin),
// bez[] the matching flags (bit0 = start of a cubic, bit1 = move/new contour).
// TrueType quadratics are promoted to cubics so the result feeds straight into
// v_bez / v_bez_fill.
typedef struct { int16_t *xy; uint8_t *bez; int n, max, pen; } outl_ctx;

static void ol_pt(outl_ctx *c, double x, double y, int flag) {
    if (c->n >= c->max) return;
    c->xy[2*c->n] = (int16_t)lround(x); c->xy[2*c->n+1] = (int16_t)lround(-y);  // y down
    c->bez[c->n] = (uint8_t)flag;
    c->n++;
}
static int ol_move(const FT_Vector *to, void *u) {
    outl_ctx *c = u; c->pen = c->n; ol_pt(c, to->x/64.0, to->y/64.0, 2); return 0;
}
static int ol_line(const FT_Vector *to, void *u) {
    outl_ctx *c = u; c->pen = c->n; ol_pt(c, to->x/64.0, to->y/64.0, 0); return 0;
}
static int ol_conic(const FT_Vector *ctl, const FT_Vector *to, void *u) {
    outl_ctx *c = u;
    double x0 = c->xy[2*c->pen], y0 = -c->xy[2*c->pen+1];     // current on-curve point
    double cx = ctl->x/64.0, cy = ctl->y/64.0, ex = to->x/64.0, ey = to->y/64.0;
    if (c->pen < c->n) c->bez[c->pen] |= 1;                  // start anchor of the cubic
    ol_pt(c, x0 + 2.0/3*(cx-x0), y0 + 2.0/3*(cy-y0), 0);     // quad -> cubic controls
    ol_pt(c, ex + 2.0/3*(cx-ex), ey + 2.0/3*(cy-ey), 0);
    c->pen = c->n; ol_pt(c, ex, ey, 0);
    return 0;
}
static int ol_cubic(const FT_Vector *c1, const FT_Vector *c2, const FT_Vector *to, void *u) {
    outl_ctx *c = u;
    if (c->pen < c->n) c->bez[c->pen] |= 1;
    ol_pt(c, c1->x/64.0, c1->y/64.0, 0);
    ol_pt(c, c2->x/64.0, c2->y/64.0, 0);
    c->pen = c->n; ol_pt(c, to->x/64.0, to->y/64.0, 0);
    return 0;
}
int font_get_outline(font *f, unsigned cp, int16_t *xy, uint8_t *bez, int maxpts) {
    if (!f || !xy || !bez || maxpts < 1) return 0;
    FT_Face ft = f->owner->ft;
    FT_Set_Pixel_Sizes(ft, f->wpx, f->px);
    if (FT_Load_Char(ft, cp, FT_LOAD_NO_BITMAP | FT_LOAD_NO_HINTING)) return 0;
    static const FT_Outline_Funcs fns = { ol_move, ol_line, ol_conic, ol_cubic, 0, 0 };
    outl_ctx c = { xy, bez, 0, maxpts, 0 };
    if (FT_Outline_Decompose(&ft->glyph->outline, &fns, &c)) return c.n;
    return c.n;
}

// Drop every rasterised glyph (v_flushcache); the sized views survive so any
// held font* stays valid and re-rasterises on next use.
void font_face_flush(font_face *face) {
    if (!face) return;
    for (font *f = face->sizes; f; f = f->next) {
        for (int i = 0; i < ASCII_N; i++) { free(f->ascii[i].cov); f->ascii[i].cov = 0; f->ascii[i].ready = 0; }
        for (int h = 0; h < GHASH; h++) {
            for (gnode *n = f->hash[h]; n; ) { gnode *nx = n->next; free(n->g.cov); free(n); n = nx; }
            f->hash[h] = 0;
        }
    }
}

// Pair-kern delta (px) between two codepoints, regardless of the kern-enable
// flag (this is the query, vqt_pairkern); 0 if the face has no kern table.
int font_pair_kern(font *f, unsigned a, unsigned b) {
    if (!f || !FT_HAS_KERNING(f->owner->ft)) return 0;
    FT_Face ft = f->owner->ft;
    FT_Set_Pixel_Sizes(ft, f->wpx, f->px);
    FT_Vector k;
    if (FT_Get_Kerning(ft, FT_Get_Char_Index(ft, a), FT_Get_Char_Index(ft, b),
                       FT_KERNING_DEFAULT, &k)) return 0;
    return (int)(k.x >> 6);
}
int font_face_track(const font_face *face) { return face ? face->track_off : 0; }

// Tight inked bounding box of s (vqt_real_extent), relative to the em-box
// top-left: the union of the glyph bitmaps, not the cell box.
void font_ink_extent(font *f, const char *s, int *x0, int *y0, int *x1, int *y1) {
    *x0 = *y0 = *x1 = *y1 = 0;
    if (!f || !s) return;
    int pen = 0, base = f->ascent, trk = face_trk(f), set = 0;
    for (const char *p = s; *p; ) {
        const glyph *g = glyph_get(f, utf8_next(&p)); if (!g) continue;
        if (g->cov && g->w && g->h) {
            int gx0 = pen + g->left, gy0 = base - g->top, gx1 = gx0 + g->w, gy1 = gy0 + g->h;
            if (!set) { *x0 = gx0; *y0 = gy0; *x1 = gx1; *y1 = gy1; set = 1; }
            else { if (gx0 < *x0) *x0 = gx0; if (gy0 < *y0) *y0 = gy0;
                   if (gx1 > *x1) *x1 = gx1; if (gy1 > *y1) *y1 = gy1; }
        }
        pen += g->advance + trk;
    }
}

// Per-codepoint pen-x offsets for a justified line (vqt_justified): same slack
// distribution as font_draw_justified.  Fills offx[i], returns the count.
int font_justify_offsets(font *f, const char *s, int width, int word_space,
                         int char_space, int16_t *offx) {
    if (!f || !s) return 0;
    int trk = face_trk(f), natural = 0, n = 0, nspaces = 0;
    for (const char *p = s; *p; ) {
        unsigned cp = utf8_next(&p);
        const glyph *g = glyph_get(f, cp); if (!g) continue;
        natural += g->advance + trk; if (cp == ' ') nspaces++; n++;
    }
    int gaps = n > 1 ? n - 1 : 0, extra = width - natural, word_add = 0, char_add = 0;
    if (word_space && char_space) {
        if (nspaces > 0) word_add = (extra / 2) / nspaces;
        if (gaps > 0)    char_add = (extra - word_add * nspaces) / gaps;
    } else if (word_space) { if (nspaces > 0) word_add = extra / nspaces; }
    else if (char_space)   { if (gaps > 0)    char_add = extra / gaps; }
    int pen = 0, i = 0;
    for (const char *p = s; *p; i++) {
        unsigned cp = utf8_next(&p);
        const glyph *g = glyph_get(f, cp); if (!g) { i--; continue; }
        if (offx) offx[i] = (int16_t)pen;
        pen += g->advance + trk;
        if (cp == ' ' && word_space) pen += word_add;
        if (i < n - 1 && char_space) pen += char_add;
    }
    return n;
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

    if (mode != 3) {
        // Alpha-blend: clip the glyph rect to the clip box, then hand the
        // visible coverage sub-rect to the gfx backend (hardware SRC_BLIT on
        // the A9 plane, CPU blend on the host / off-screen surfaces).
        int x0 = gx > cx0 ? gx : cx0,                y0 = gy > cy0 ? gy : cy0;
        int x1 = (gx + g->w - 1) < cx1 ? gx + g->w - 1 : cx1;
        int y1 = (gy + g->h - 1) < cy1 ? gy + g->h - 1 : cy1;
        if (x1 < x0 || y1 < y0) return;            // fully clipped
        gfx_blit_coverage(d, x0, y0, g->cov, g->w,
                          x0 - gx, y0 - gy, x1 - x0 + 1, y1 - y0 + 1, rgba);
        return;
    }

    // XOR mode (cursors / highlights) — toggle solid pixels, CPU-side.
    uint32_t xr = rgba & 0xFFFFFF00u;
    for (int row = 0; row < g->h; row++) {
        int py = gy + row; if (py < cy0 || py > cy1) continue;
        const uint8_t *cr = g->cov + (size_t)row * g->w;
        uint32_t *dr = d->px + (size_t)py * d->stride;
        for (int col = 0; col < g->w; col++) {
            int px = gx + col; if (px < cx0 || px > cx1) continue;
            if (cr[col] >= 128) dr[px] ^= xr;
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
    long long gp_t0 = gem_prof_now(); long gp_n = 0;    // TEMP profiler
    int cx0, cy0, cx1, cy1; clip_of(d, clip, &cx0, &cy0, &cx1, &cy1);
    int pen = x, base = y + f->ascent, trk = face_trk(f);
    unsigned prev = 0;
    if (f->owner->kern) FT_Set_Pixel_Sizes(f->owner->ft, f->wpx, f->px);
    for (const char *p = s; *p; ) {
        unsigned cp = utf8_next(&p);
        const glyph *g = glyph_get(f, cp);
        if (!g) continue;
        pen += kern_px(f, prev, cp);
        blit_glyph(d, pen, base, g, rgba, cx0, cy0, cx1, cy1, mode);
        pen += g->advance + trk; prev = cp; gp_n++;
    }
    gfx_text_flush();   // drain the batched glyph blits (no-op on the host)
    gem_prof_add(GEM_PROF_TEXT, gem_prof_now() - gp_t0, gp_n);   // TEMP profiler
}

// Spread `s` to occupy `width` px: extra slack goes to the gaps after spaces
// (word_space) and/or between every glyph (char_space).  Used by v_justified.
void font_draw_justified(font *f, gfx_surface *d, int x, int y, const char *s,
                         int width, int word_space, int char_space,
                         uint32_t rgba, const int *clip, int mode) {
    if (!f || !s || !d) return;
    long long gp_t0 = gem_prof_now(); long gp_n = 0;    // TEMP profiler
    int trk = face_trk(f);
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
        pen += g->advance + trk; gp_n++;
        if (cp == ' ' && word_space) pen += word_add;
        if (i < n - 1 && char_space) pen += char_add;
    }
    gfx_text_flush();
    gem_prof_add(GEM_PROF_TEXT, gem_prof_now() - gp_t0, gp_n);   // TEMP profiler
}

// Draw each glyph of s at its own offset from (x,y) (em-box top-left): glyph
// j (the j-th codepoint) goes at (x + off[2j], y + off[2j+1]).  The app owns the
// layout (v_ftext_offset) — no kerning/tracking is applied here.
void font_draw_offsets(font *f, gfx_surface *d, int x, int y, const char *s,
                       const int16_t *off, uint32_t rgba, const int *clip, int mode) {
    if (!f || !s || !d || !off) return;
    long long gp_t0 = gem_prof_now(); long gp_n = 0;    // TEMP profiler
    int cx0, cy0, cx1, cy1; clip_of(d, clip, &cx0, &cy0, &cx1, &cy1);
    int base0 = y + f->ascent, j = 0;
    for (const char *p = s; *p; j++) {
        const glyph *g = glyph_get(f, utf8_next(&p));
        if (!g) { j--; continue; }
        blit_glyph(d, x + off[2*j], base0 + off[2*j+1], g, rgba, cx0, cy0, cx1, cy1, mode);
        gp_n++;
    }
    gfx_text_flush();
    gem_prof_add(GEM_PROF_TEXT, gem_prof_now() - gp_t0, gp_n);   // TEMP profiler
}

// Blit an FT bitmap's coverage at device top-left.  `light` halves coverage.
static void blit_ft(gfx_surface *d, const FT_Bitmap *bm, int bx, int by,
                    uint32_t rgba, int cx0, int cy0, int cx1, int cy1, int mode, int light) {
    uint32_t xr = rgba & 0xFFFFFF00u;
    for (int row = 0; row < (int)bm->rows; row++) {
        int py = by + row; if (py < cy0 || py > cy1 || py < 0 || py >= d->h) continue;
        const uint8_t *cr = bm->buffer + (size_t)row * bm->pitch;
        uint32_t *dr = d->px + (size_t)py * d->stride;
        for (int col = 0; col < (int)bm->width; col++) {
            int px = bx + col; if (px < cx0 || px > cx1 || px < 0 || px >= d->w) continue;
            unsigned cov = cr[col]; if (light) cov = (cov * 102) / 255;   // ~40%
            if (mode == 3) { if (cov >= 128) dr[px] ^= xr; }
            else dr[px] = blend(dr[px], rgba, cov);
        }
    }
}

// Stamp a thick segment (for underline) directly into the surface.
static void stamp_line(gfx_surface *d, double x0, double y0, double x1, double y1,
                       int thick, uint32_t rgba, int cx0, int cy0, int cx1, int cy1, int mode) {
    double dx = x1 - x0, dy = y1 - y0, len = sqrt(dx*dx + dy*dy);
    int n = (int)len + 1, r = thick / 2;
    uint32_t xr = rgba & 0xFFFFFF00u;
    for (int i = 0; i <= n; i++) {
        int px = (int)lround(x0 + dx * i / n), py = (int)lround(y0 + dy * i / n);
        for (int oy = -r; oy <= r; oy++) for (int ox = -r; ox <= r; ox++) {
            int X = px + ox, Y = py + oy;
            if (X < cx0 || X > cx1 || Y < cy0 || Y > cy1 || X < 0 || Y < 0 || X >= d->w || Y >= d->h) continue;
            uint32_t *q = &d->px[(size_t)Y * d->stride + X];
            *q = (mode == 3) ? (*q ^ xr) : ((rgba & 0xFFFFFF00u) | 0xFF);
        }
    }
}

void font_draw_fx(font *f, gfx_surface *d, int x, int y, const char *s,
                  int angle_tenths, int effects, int skew_tenths,
                  uint32_t rgba, const int *clip, int mode) {
    if (!f || !s || !d) return;
    long long gp_t0 = gem_prof_now(); long gp_n = 0;    // TEMP profiler
    int cx0, cy0, cx1, cy1; clip_of(d, clip, &cx0, &cy0, &cx1, &cy1);
    double a = angle_tenths * (M_PI / 1800.0);          // CCW
    double c = cos(a), sn = sin(a);
    // Shear: the italic effect adds a fixed ~12deg, vst_skew an arbitrary angle.
    double k = (effects & FX_ITALIC) ? 0.21 : 0.0;
    if (skew_tenths) k += tan(skew_tenths * (M_PI / 1800.0));
    // M = rotation . shear  (shear glyph first, then rotate)
    FT_Matrix m = {
        (FT_Fixed)lround(c * 65536.0),              (FT_Fixed)lround((c*k - sn) * 65536.0),
        (FT_Fixed)lround(sn * 65536.0),             (FT_Fixed)lround((sn*k + c) * 65536.0) };
    FT_Face face = f->owner->ft;
    FT_Set_Pixel_Sizes(face, f->wpx, f->px);
    FT_Pos bold = (effects & FX_BOLD) ? (FT_Pos)(f->px * 64 / 22) : 0;
    int light = (effects & FX_LIGHT) ? 1 : 0;
    int sh = (effects & FX_SHADOW) ? (f->px / 12 + 1) : 0;
    uint32_t shadow = ((rgba >> 1) & 0x7F7F7F00u) | 0xFF;   // darkened
    FT_Stroker stroker = NULL;
    if (effects & FX_OUTLINE) { FT_Stroker_New(g_ft, &stroker);
        FT_Pos sr = f->px * 64 / 48; if (sr < 48) sr = 48;   // thin contour (~1px), so it stays hollow
        FT_Stroker_Set(stroker, sr, FT_STROKER_LINECAP_ROUND, FT_STROKER_LINEJOIN_ROUND, 0); }

    double penx = x, peny = y + f->ascent, trk = face_trk(f);
    double startx = penx, starty = peny;
    for (const char *p = s; *p; ) {
        unsigned cp = utf8_next(&p);
        FT_Set_Transform(face, &m, NULL);
        if (FT_Load_Char(face, cp, FT_LOAD_DEFAULT)) continue;
        FT_GlyphSlot g = face->glyph;
        if (bold) FT_Outline_Embolden(&g->outline, bold);
        int ox = (int)lround(penx), oy = (int)lround(peny);
        if (stroker) {                                  // outline: stroke the border
            FT_Glyph gl;
            if (!FT_Get_Glyph(g, &gl)) {
                FT_Glyph_Stroke(&gl, stroker, 1);       // stroke the contour -> hollow
                if (!FT_Glyph_To_Bitmap(&gl, FT_RENDER_MODE_NORMAL, NULL, 1)) {
                    FT_BitmapGlyph bg = (FT_BitmapGlyph)gl;
                    if (sh) blit_ft(d, &bg->bitmap, ox+bg->left+sh, oy-bg->top+sh, shadow, cx0,cy0,cx1,cy1, 0, 0);
                    blit_ft(d, &bg->bitmap, ox+bg->left, oy-bg->top, rgba, cx0,cy0,cx1,cy1, mode, light);
                }
                FT_Done_Glyph(gl);
            }
        } else {
            FT_Render_Glyph(g, FT_RENDER_MODE_NORMAL);
            if (sh) blit_ft(d, &g->bitmap, ox+g->bitmap_left+sh, oy-g->bitmap_top+sh, shadow, cx0,cy0,cx1,cy1, 0, 0);
            blit_ft(d, &g->bitmap, ox+g->bitmap_left, oy-g->bitmap_top, rgba, cx0,cy0,cx1,cy1, mode, light);
        }
        penx += g->advance.x / 64.0 + trk * c;
        peny -= g->advance.y / 64.0 + trk * sn;
        gp_n++;
    }
    if (effects & FX_UNDERLINE) {                        // along the (rotated) baseline, just below
        double uoff = f->px / 8.0 + 1, perpx = sn, perpy = c;   // device "below text"
        stamp_line(d, startx + perpx*uoff, starty + perpy*uoff,
                      penx  + perpx*uoff, peny  + perpy*uoff,
                      f->px / 16 + 1, rgba, cx0, cy0, cx1, cy1, mode);
    }
    if (stroker) FT_Stroker_Done(stroker);
    FT_Set_Transform(face, NULL, NULL);                 // identity again for the cached path
    gem_prof_add(GEM_PROF_TEXT, gem_prof_now() - gp_t0, gp_n);   // TEMP profiler
}
