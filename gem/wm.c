// wm.c — portable GEM window-manager core.
//
// Draws a desktop and stacked window frames through the gfx.h primitives only.
// Theming is placeholder flat colours for now; these become the pen table /
// themed artwork blits later.  No platform calls here.

#include "gem.h"
#include <stddef.h>     // NULL

// Provisional theme (-> pen table / OS/Themes artwork later).
#define COL_WIN_BODY   GFX_RGB(0xc8, 0xc8, 0xc8)
#define COL_WIN_EDGE   GFX_RGB(0x20, 0x20, 0x20)
#define COL_TITLE_ACT  GFX_RGB(0x28, 0x5a, 0xc0)
#define COL_TITLE_INA  GFX_RGB(0x70, 0x70, 0x70)

#define TITLE_H 30
#define EDGE    2

void gem_wm_init(gem_wm *wm, gfx_surface *desk, uint32_t desktop_color) {
    wm->desk          = desk;
    wm->desktop_color = desktop_color;
    wm->nwin          = 0;
    for (int i = 0; i < GEM_MAX_WINDOWS; i++) wm->win[i].used = 0;
}

gem_window *gem_wm_add(gem_wm *wm, int x, int y, int w, int h,
                       const char *title, int active) {
    if (wm->nwin >= GEM_MAX_WINDOWS) return NULL;
    gem_window *win = &wm->win[wm->nwin++];
    win->used   = 1;
    win->x = x; win->y = y; win->w = w; win->h = h;
    win->title  = title;
    win->active = active;
    // content rect (constant for a fixed frame; recomputed in draw too)
    win->cx = x + EDGE;
    win->cy = y + EDGE + TITLE_H;
    win->cw = w - 2 * EDGE;
    win->ch = h - 2 * EDGE - TITLE_H;
    return win;
}

static void draw_window(gfx_surface *s, gem_window *win) {
    int x = win->x, y = win->y, w = win->w, h = win->h;
    gfx_fill_rect(s, x, y, w, h, COL_WIN_EDGE);                          // outer edge
    gfx_fill_rect(s, x + EDGE, y + EDGE, w - 2 * EDGE, TITLE_H,          // title bar
                  win->active ? COL_TITLE_ACT : COL_TITLE_INA);
    win->cx = x + EDGE;
    win->cy = y + EDGE + TITLE_H;
    win->cw = w - 2 * EDGE;
    win->ch = h - 2 * EDGE - TITLE_H;
    gfx_fill_rect(s, win->cx, win->cy, win->cw, win->ch, COL_WIN_BODY);  // body
    // crude close box (themed art later)
    gfx_fill_rect(s, x + EDGE + 6, y + EDGE + 7,
                  TITLE_H - 14, TITLE_H - 14, COL_WIN_BODY);
}

void gem_wm_draw(gem_wm *wm) {
    gfx_fill_rect(wm->desk, 0, 0, wm->desk->w, wm->desk->h, wm->desktop_color);
    for (int i = 0; i < wm->nwin; i++)
        if (wm->win[i].used) draw_window(wm->desk, &wm->win[i]);
}
