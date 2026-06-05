// font.h — portable scalable text for the GEM core (FreeType-backed).
//
// A font is a TrueType face opened at a pixel size, with a per-codepoint glyph
// cache (the rasterised alpha-coverage bitmap is kept after first use).  Glyphs
// are alpha-blended onto an RGBA-8888 surface in the requested colour, so text
// antialiases over whatever it lands on.  The interface is backend-neutral: the
// A9 build can rasterise once into a DDR3 glyph atlas behind the same calls.

#ifndef GEM_FONT_H
#define GEM_FONT_H

#include "gfx.h"

typedef struct font font;

// Open a TTF/OTF face at the given pixel height (NULL on failure).
font *font_open(const char *path, int px_height);
void  font_close(font *f);

int   font_height(const font *f);              // line height (px)
int   font_ascent(const font *f);              // baseline offset from the top (px)
int   font_text_width(font *f, const char *s); // pen advance for the string (px)

// Extra letter-spacing added to every glyph advance (px; default 0 = the face's
// own metrics).  Some faces are cut very tight; a little tracking opens them up.
void  font_set_tracking(font *f, int px);

// Draw NUL-terminated ASCII with the em box's top-left at (x,y), antialiased in
// colour rgba over the existing pixels.  Clipped to the inclusive rect
// [clip[0],clip[1]]-[clip[2],clip[3]] when clip != NULL, else surface bounds.
void  font_draw(font *f, gfx_surface *dst, int x, int y, const char *s,
                uint32_t rgba, const int *clip);

#endif // GEM_FONT_H
