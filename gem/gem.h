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

// What part of a window a point falls on (for the interaction loop).
typedef enum {
    GEM_HIT_NONE = 0,
    GEM_HIT_CONTENT,    // inside the content area
    GEM_HIT_TITLE,      // title bar -> drag to move
    GEM_HIT_CLOSE,      // close box
    GEM_HIT_RESIZE,     // bottom-right corner -> drag to resize
} gem_hit;

typedef struct {
    gfx_surface *desk;                 // the single live desktop surface
    uint32_t     desktop_color;
    int          desk_vh;              // VDI workstation on the desktop (frames + blits)
    gem_window   win[GEM_MAX_WINDOWS]; // storage; .used marks live slots (not packed)
    int          z[GEM_MAX_WINDOWS];   // slot indices in stacking order, bottom..top
    int          nwin;                 // number of live windows (== entries in z[])
    int          mx, my;               // pointer position (desktop coords)
    int          drag_slot;            // window being dragged, or -1
    gem_hit      drag_mode;            // GEM_HIT_TITLE (move) or GEM_HIT_RESIZE
    int          drag_ox, drag_oy;     // pointer offset within the window at grab
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
// blit each window's backing into place, then the pointer.
void        gem_wm_draw(gem_wm *wm);

// ---- Window stacking / lifecycle ------------------------------------------
gem_window *gem_wm_top(gem_wm *wm);                  // frontmost window, or NULL
void        gem_wm_raise(gem_wm *wm, gem_window *win);   // bring to front
void        gem_wm_focus(gem_wm *wm, gem_window *win);   // make active (clears others)
void        gem_wm_close(gem_wm *wm, gem_window *win);   // remove + free its backing
// Change a window's outer size (reallocates the backing; marks it dirty).
void        gem_wm_resize(gem_wm *wm, gem_window *win, int w, int h);

// ---- Interaction ----------------------------------------------------------
// Topmost live window containing (x,y), or NULL.  Classify a point on a window.
gem_window *gem_wm_window_at(gem_wm *wm, int x, int y);
gem_hit     gem_wm_hit(const gem_window *win, int x, int y);

// Host backend feeds these.  button: 1 = press, 0 = release (left button).
// A press raises+focuses the hit window and begins a move/resize drag or closes
// it; motion continues an active drag; release ends it.
void        gem_wm_mouse_move(gem_wm *wm, int x, int y);
void        gem_wm_mouse_button(gem_wm *wm, int x, int y, int down);

#endif // GEM_H
