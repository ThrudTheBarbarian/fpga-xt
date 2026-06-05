// gem.h — portable GEM window-manager core (starting skeleton).
//
// Platform-neutral: draws a desktop + windows using only the gfx.h primitives,
// so it runs identically on the SDL host testbed and the A9 hardware blitter.
// The window/event model here is deliberately minimal and will grow (backing
// surfaces, z-order, WM_REDRAW, hit-testing, theming) — but the seam is set:
// this file knows nothing about SDL, and the harness (sdl_main.c) only owns the
// window + final present.

#ifndef GEM_H
#define GEM_H

#include "gfx.h"

#define GEM_MAX_WINDOWS 32

typedef struct {
    int         used;
    int         x, y, w, h;            // outer window rect on the desktop
    const char *title;
    int         active;
    // Content rect within the frame (where an app — or the live XL plane —
    // draws); computed by the WM each draw so callers can fill it.
    int         cx, cy, cw, ch;
} gem_window;

typedef struct {
    gfx_surface *desk;                 // the single live desktop surface
    uint32_t     desktop_color;
    gem_window   win[GEM_MAX_WINDOWS]; // bottom-to-top draw order
    int          nwin;
} gem_wm;

void        gem_wm_init(gem_wm *wm, gfx_surface *desk, uint32_t desktop_color);

// Add a window (top of the stack).  Returns it, or NULL if full.
gem_window *gem_wm_add(gem_wm *wm, int x, int y, int w, int h,
                       const char *title, int active);

// Redraw the whole desktop + all windows (frames + bodies).  Window content
// (app pixels / the XL plane) is drawn by the caller into win->c{x,y,w,h}.
void        gem_wm_draw(gem_wm *wm);

#endif // GEM_H
