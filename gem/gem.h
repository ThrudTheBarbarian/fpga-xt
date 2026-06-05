// gem.h — portable GEM window-manager core.
//
// Backing-store windows: each window owns an off-screen content surface and a
// VDI workstation that targets it.  Apps draw into that backing surface in
// LOCAL coordinates (0,0 = top-left of the content) on a redraw, clipped to the
// surface — no overlap/expose logic in the app.  The WM draws the frames
// through the VDI on the desktop surface, then blits each window's backing into
// place with vro_cpyfm.  Steady state is one live desktop surface; the per-
// window backings are blit sources, on demand only (see docs/OS/creation.md).
//
// Platform-neutral: SDL host today, A9 hardware blitter later — no SDL here.

#ifndef GEM_H
#define GEM_H

#include "gfx.h"

#define GEM_MAX_WINDOWS 32

struct gem_window;
typedef void (*gem_redraw_fn)(struct gem_window *win, void *ud);

typedef struct gem_window {
    int           used;
    int           x, y, w, h;          // outer window rect on the desktop
    const char   *title;
    int           active;
    int           cx, cy, cw, ch;      // content rect on the desktop
    gfx_surface  *backing;             // off-screen content (cw x ch), local coords
    int           vh;                  // VDI workstation targeting the backing
    int           dirty;               // content needs a redraw (WM_REDRAW)
    gem_redraw_fn redraw;
    void         *ud;
} gem_window;

typedef struct {
    gfx_surface *desk;                 // the single live desktop surface
    uint32_t     desktop_color;
    int          desk_vh;              // VDI workstation on the desktop (frames + blits)
    gem_window   win[GEM_MAX_WINDOWS];
    int          nwin;
} gem_wm;

// init also brings up the VDI on the desktop surface (vdi_init).
void        gem_wm_init(gem_wm *wm, gfx_surface *desk, uint32_t desktop_color);

// Add a window (top of the stack).  Allocates its backing surface + a VDI
// workstation on it, and marks it dirty so it redraws once.  NULL if full.
gem_window *gem_wm_add(gem_wm *wm, int x, int y, int w, int h,
                       const char *title, int active);

void        gem_wm_set_redraw(gem_window *win, gem_redraw_fn fn, void *ud);
void        gem_wm_invalidate(gem_window *win);   // request a redraw (WM_REDRAW)

// Compose a frame: redraw any dirty window content, draw the desktop + frames,
// blit each window's backing into place.
void        gem_wm_draw(gem_wm *wm);

#endif // GEM_H
