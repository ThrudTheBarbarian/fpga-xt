// theme.h — GEM widget theming.  A theme is one RGBA atlas bitmap plus a table
// of named slices; each slice is a source rect, its 9-slice insets, and a fill
// mode.  theme_blit() renders a slice to any destination rect: the four corners
// stay 1:1, the edges stretch along one axis, the centre stretches both — all
// through vr_transfer_bits in VR_OVER (src-over alpha) so the artwork's
// anti-aliased edges and shadows composite correctly.  AES widgets call
// theme_draw(element, state, rect, label) and never touch pixels.
//
// The atlas is baked (host `themepack` tool, from the Aristo2 PNGs) into a raw
// `.tex` (so the target needs no PNG decoder); `locations.txt` lists the slices
// and `theme.ini` the colours.

#ifndef GEM_THEME_H
#define GEM_THEME_H

#include "gfx.h"
#include "vdi/vdi.h"

enum { THEME_STRETCH = 0, THEME_TILE = 1, THEME_NONE = 2 };   // centre/edge fill

typedef struct {
    char name[40];
    int  sx, sy, sw, sh;       // source rect in the atlas
    int  l, t, r, b;           // 9-slice insets (0 on an axis = no slicing there)
    int  fill;                 // THEME_*
} theme_slice;

#define THEME_MAX_SLICES 256

typedef struct {
    gfx_surface *atlas;
    MFDB         atlas_mfdb;
    theme_slice  slice[THEME_MAX_SLICES];
    int          nslices;
    // Colours (RGBA), from theme.ini.
    uint32_t fg, highlight, sel_bg, border, disabled;
} theme;

// Load a raw atlas (`GTEX` header + RGBA8888).  Returns a surface (free with
// gfx_surface_free) or NULL.
gfx_surface *theme_tex_load(const char *path);

// Load a whole theme dir (artwork.tex + locations.txt + theme.ini) into `th`.
// Returns 0 on success.
int  theme_load(theme *th, const char *dir);
void theme_free(theme *th);
const theme_slice *theme_find(const theme *th, const char *name);

// 9-slice (or stretch / 1:1) blit of a slice to the dst rect on workstation
// `handle` (drawing onto its target surface), src-over via VR_OVER.
void theme_blit(int handle, const theme *th, const theme_slice *s,
                int dx, int dy, int dw, int dh);
// Convenience: look the slice up by name, then blit.
void theme_draw(int handle, const theme *th, const char *name,
                int dx, int dy, int dw, int dh);

#endif // GEM_THEME_H
