// font.h — portable scalable text for the GEM core (FreeType-backed).
//
// A font_face is a TrueType face (the TTF).  A font is that face at a specific
// pixel size, with its own per-codepoint glyph cache (the rasterised alpha
// coverage).  Multiple sizes of one face coexist — the WM title at one size, an
// app at another — via font_at(), which caches sized views inside the face.
// Glyphs alpha-blend onto an RGBA-8888 surface in the requested colour, so text
// antialiases over whatever it lands on.  Backend-neutral: the A9 build can
// rasterise once into a DDR3 glyph atlas behind the same calls.

#ifndef GEM_FONT_H
#define GEM_FONT_H

#include "gfx.h"

typedef struct font_face font_face;
typedef struct font      font;

font_face *font_face_open(const char *path);    // load a TTF/OTF (NULL on fail)
void       font_face_close(font_face *face);     // frees the face + all sized views
void       font_face_set_tracking(font_face *face, int px);  // extra letter-spacing
const char *font_face_name(const font_face *face);           // family name ("" if none)

// A view of the face at a pixel size (cached inside the face; do not free).
font *font_at(font_face *face, int px);
// Anisotropic view: independent cell width / height in px (condensed/expanded
// text via vst_setsize / vst_width).  font_at(px) == font_at_wh(px, px).
font *font_at_wh(font_face *face, int wpx, int hpx);

// vst_kern: enable pair kerning; returns 1 only if the face actually has a kern
// table (else stays off).  vst_track_offset: extra uniform letter-spacing (px).
int  font_face_set_kern(font_face *face, int on);
int  font_face_has_kern(const font_face *face);
void font_face_set_track(font_face *face, int off);

int   font_height(const font *f);              // line height (px)
int   font_ascent(const font *f);              // baseline offset from the top (px)
int   font_max_advance(const font *f);         // widest glyph advance (px)
int   font_size(const font *f);                // the pixel size of this view
int   font_text_width(font *f, const char *s); // pen advance for the string (px)
// Per-character cell width (advance); *lbear/*rover = left bearing / right
// overhang past the cell (>=0).  cp is a Unicode codepoint.  vqt_width.
int   font_char_metrics(font *f, unsigned cp, int *lbear, int *rover);
// The five baseline-relative structural distances (all >=0) for vqt_fontinfo:
// top (accent line), ascent, half, descent, bottom (deepest descender).
void  font_vmetrics(const font *f, int *top, int *ascent, int *half,
                    int *descent, int *bottom);
// Fractional (sub-pixel) advances in 26.6 fixed (1/64 px), tracking included —
// the basis of the NVDI fractional text calls (vqt_advance / vqt_f_extent).
long  font_f_advance(font *f, unsigned cp);
long  font_f_text_width(font *f, const char *s);
// Inquiry helpers: pair-kern delta (px), uniform track offset, tight inked bbox
// (relative to the em-box top-left), and per-codepoint justified x offsets.
int   font_pair_kern(font *f, unsigned a, unsigned b);
int   font_face_track(const font_face *face);
void  font_ink_extent(font *f, const char *s, int *x0, int *y0, int *x1, int *y1);
int   font_justify_offsets(font *f, const char *s, int width, int word_space,
                           int char_space, int16_t *offx);

// Draw NUL-terminated ASCII with the em box's top-left at (x,y), antialiased in
// colour rgba over the existing pixels.  Clipped to the inclusive rect
// [clip[0],clip[1]]-[clip[2],clip[3]] when clip != NULL, else surface bounds.
// `mode` is the VDI writing mode: 3 (XOR) toggles solid pixels where the glyph
// is mostly covered (for cursors/highlights); any other value alpha-blends.
void  font_draw(font *f, gfx_surface *dst, int x, int y, const char *s,
                uint32_t rgba, const int *clip, int mode);

// Draw `s` spread to occupy `width` px (em box top-left at x,y): slack is added
// to the gaps after spaces (word_space) and/or between all glyphs (char_space).
void  font_draw_justified(font *f, gfx_surface *dst, int x, int y, const char *s,
                          int width, int word_space, int char_space,
                          uint32_t rgba, const int *clip, int mode);

// Text effects (vst_effects), matching the GEM bitmask.
enum { FX_BOLD = 0x01, FX_LIGHT = 0x02, FX_ITALIC = 0x04,
       FX_UNDERLINE = 0x08, FX_OUTLINE = 0x10, FX_SHADOW = 0x20 };

// Draw `s` rotated by `angle_tenths` (tenths of a degree, CCW) about the
// baseline start (em box top-left at x,y), with the given effects.  Glyph
// outlines are transformed/emboldened/stroked via FreeType, so any angle and
// effect works (these aren't cached).  Honours the writing mode.
void  font_draw_fx(font *f, gfx_surface *dst, int x, int y, const char *s,
                   int angle_tenths, int effects, int skew_tenths,
                   uint32_t rgba, const int *clip, int mode);

// Draw each glyph at an app-supplied offset from (x,y): codepoint j at
// (x+off[2j], y+off[2j+1]).  Backs v_ftext_offset (explicit glyph placement).
void  font_draw_offsets(font *f, gfx_surface *dst, int x, int y, const char *s,
                        const int16_t *off, uint32_t rgba, const int *clip, int mode);

#endif // GEM_FONT_H
