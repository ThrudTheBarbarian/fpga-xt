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
void  font_draw(font *f, gfx_surface *dst, int x, int y, const char *s,
                uint32_t rgba, const int *clip);

#endif // GEM_FONT_H
