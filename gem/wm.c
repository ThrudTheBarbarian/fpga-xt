// wm.c — portable GEM window-manager core.  See gem.h.
//
// Draws frames through the VDI on the desktop surface, and composites each
// window's backing-store content with vro_cpyfm.  No platform calls.

#include "gem.h"
#include "vdi/vdi.h"
#include <stddef.h>

// Provisional theme as VDI pens (-> themed artwork / OS/Themes later).
#define PEN_EDGE      1     // black
#define PEN_BODY      8     // light grey
#define PEN_TITLE_ACT 4     // blue
#define PEN_TITLE_INA 9     // grey

#define TITLE_H 30
#define EDGE    2

void gem_wm_init(gem_wm *wm, gfx_surface *desk, uint32_t desktop_color) {
    wm->desk          = desk;
    wm->desktop_color = desktop_color;
    wm->nwin          = 0;
    for (int i = 0; i < GEM_MAX_WINDOWS; i++) wm->win[i].used = 0;
    vdi_init(desk);          // pen palette + physical workstation (handle 1) on desk
    wm->desk_vh = 1;
}

gem_window *gem_wm_add(gem_wm *wm, int x, int y, int w, int h,
                       const char *title, int active) {
    if (wm->nwin >= GEM_MAX_WINDOWS) return NULL;
    gem_window *win = &wm->win[wm->nwin];
    win->used   = 1;
    win->x = x; win->y = y; win->w = w; win->h = h;
    win->title  = title;
    win->active = active;
    win->cx = x + EDGE;          win->cy = y + EDGE + TITLE_H;
    win->cw = w - 2 * EDGE;      win->ch = h - 2 * EDGE - TITLE_H;
    win->backing = gfx_surface_alloc(win->cw, win->ch);
    win->vh      = win->backing ? v_opnvwk(win->backing) : 0;
    win->dirty   = 1;
    win->redraw  = NULL;
    win->ud      = NULL;
    if (!win->backing || !win->vh) return NULL;
    wm->nwin++;
    return win;
}

void gem_wm_set_redraw(gem_window *win, gem_redraw_fn fn, void *ud) {
    win->redraw = fn; win->ud = ud; win->dirty = 1;
}
void gem_wm_invalidate(gem_window *win) { win->dirty = 1; }

// Draw the window frame (edge + title bar + close box) through the VDI; the
// body is the backing-store content, blitted in by gem_wm_draw.
static void draw_frame(gem_wm *wm, gem_window *win) {
    int vh = wm->desk_vh, x = win->x, y = win->y, w = win->w, h = win->h;
    int16_t r[4];
    vsf_interior(vh, 1);
    vsf_color(vh, PEN_EDGE);
    r[0]=x; r[1]=y; r[2]=x+w-1; r[3]=y+h-1; vr_recfl(vh, r);                 // outer edge
    vsf_color(vh, win->active ? PEN_TITLE_ACT : PEN_TITLE_INA);
    r[0]=x+EDGE; r[1]=y+EDGE; r[2]=x+w-1-EDGE; r[3]=y+EDGE+TITLE_H-1; vr_recfl(vh, r); // title
    vsf_color(vh, PEN_BODY);                                                 // close box
    r[0]=x+EDGE+7; r[1]=y+EDGE+8; r[2]=x+EDGE+7+TITLE_H-16; r[3]=y+EDGE+8+TITLE_H-16;
    vr_recfl(vh, r);
}

void gem_wm_draw(gem_wm *wm) {
    gfx_fill_rect(wm->desk, 0, 0, wm->desk->w, wm->desk->h, wm->desktop_color);
    for (int i = 0; i < wm->nwin; i++) {
        gem_window *win = &wm->win[i];
        if (!win->used) continue;
        if (win->dirty && win->redraw) { win->redraw(win, win->ud); win->dirty = 0; }
        draw_frame(wm, win);
        // Composite the backing-store content into the window's content rect.
        MFDB src, dst;
        mfdb_from_surface(&src, win->backing);
        mfdb_from_surface(&dst, wm->desk);
        int16_t pxy[8] = { 0, 0, (int16_t)(win->cw - 1), (int16_t)(win->ch - 1),
                           (int16_t)win->cx, (int16_t)win->cy,
                           (int16_t)(win->cx + win->cw - 1), (int16_t)(win->cy + win->ch - 1) };
        vro_cpyfm(wm->desk_vh, VRO_COPY, pxy, &src, &dst);
    }
}
