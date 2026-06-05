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

int   font_height(const font *f);              // line height (px)
int   font_ascent(const font *f);              // baseline offset from the top (px)
int   font_max_advance(const font *f);         // widest glyph advance (px)
int   font_size(const font *f);                // the pixel size of this view
int   font_text_width(font *f, const char *s); // pen advance for the string (px)

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
                   int angle_tenths, int effects, uint32_t rgba, const int *clip, int mode);

#endif // GEM_FONT_H
