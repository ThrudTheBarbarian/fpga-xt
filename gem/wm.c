// wm.c — portable GEM window-manager core.  See gem.h.
//
// Draws frames through the VDI on the desktop surface, and composites each
// window's backing-store content with vro_cpyfm.  Windows are kept in a z[]
// stacking order (bottom..top); the pointer + mouse interaction (raise, focus,
// drag-move, resize, close) live here too.  No platform calls.

#include "gem.h"
#include "vdi/vdi.h"
#include <stddef.h>

// Provisional theme as VDI pens (-> themed artwork / OS/Themes later).
#define PEN_EDGE      1     // black
#define PEN_BODY      8     // light grey
#define PEN_TITLE_ACT 4     // blue
#define PEN_TITLE_INA 9     // grey

#define TITLE_H    30
#define EDGE       2
#define TITLE_PX   18       // title text size (fits the 30px bar)
#define CLOSE_M 7           // close-box inset from the title's left/top
#define CLOSE_S (TITLE_H - 16)   // close-box side
#define RESIZE  14          // bottom-right resize-grip extent
#define MIN_W   120
#define MIN_H   80

static int slot_of(const gem_wm *wm, const gem_window *win) { return (int)(win - wm->win); }

// ---- Geometry helpers (must match draw_frame) -----------------------------
static void close_box(const gem_window *win, int *x0, int *y0, int *x1, int *y1) {
    *x0 = win->x + EDGE + CLOSE_M;       *y0 = win->y + EDGE + 8;
    *x1 = *x0 + CLOSE_S;                 *y1 = *y0 + CLOSE_S;
}

static void recompute_content(gem_window *win) {
    win->cx = win->x + EDGE;          win->cy = win->y + EDGE + TITLE_H;
    win->cw = win->w - 2 * EDGE;      win->ch = win->h - 2 * EDGE - TITLE_H;
}

// ---- Init / add -----------------------------------------------------------
void gem_wm_init(gem_wm *wm, gfx_surface *desk, uint32_t desktop_color) {
    wm->desk          = desk;
    wm->desktop_color = desktop_color;
    wm->nwin          = 0;
    wm->mx = wm->my   = 0;
    wm->drag_slot     = -1;
    wm->title_face    = NULL;
    wm->title_font    = NULL;
    for (int i = 0; i < GEM_MAX_WINDOWS; i++) wm->win[i].used = 0;
    vdi_init(desk);          // pen palette + physical workstation (handle 1) on desk
    wm->desk_vh = 1;
}

void gem_wm_set_font(gem_wm *wm, font_face *face) {
    wm->title_face = face;
    wm->title_font = face ? font_at(face, TITLE_PX) : NULL;
    vdi_set_face(face);                          // v_gtext default face
    if (face) vst_height(wm->desk_vh, TITLE_PX, NULL, NULL, NULL, NULL);  // desk ws @ title size
}

gem_window *gem_wm_add(gem_wm *wm, int x, int y, int w, int h,
                       const char *title, int active) {
    if (wm->nwin >= GEM_MAX_WINDOWS) return NULL;
    int slot = -1;
    for (int i = 0; i < GEM_MAX_WINDOWS; i++) if (!wm->win[i].used) { slot = i; break; }
    if (slot < 0) return NULL;
    gem_window *win = &wm->win[slot];
    win->used   = 1;
    win->x = x; win->y = y; win->w = w; win->h = h;
    win->title  = title;
    win->active = active;
    recompute_content(win);
    win->backing = gfx_surface_alloc(win->cw, win->ch);
    win->vh      = win->backing ? v_opnvwk(win->backing) : 0;
    win->dirty   = 1;
    win->redraw  = NULL;
    win->ud      = NULL;
    if (!win->backing || !win->vh) { win->used = 0; return NULL; }
    wm->z[wm->nwin++] = slot;        // new window on top
    return win;
}

void gem_wm_set_redraw(gem_window *win, gem_redraw_fn fn, void *ud) {
    win->redraw = fn; win->ud = ud; win->dirty = 1;
}
void gem_wm_invalidate(gem_window *win) { win->dirty = 1; }

// ---- Stacking / lifecycle -------------------------------------------------
gem_window *gem_wm_top(gem_wm *wm) {
    return wm->nwin ? &wm->win[wm->z[wm->nwin - 1]] : NULL;
}

void gem_wm_raise(gem_wm *wm, gem_window *win) {
    int slot = slot_of(wm, win), k = -1;
    for (int i = 0; i < wm->nwin; i++) if (wm->z[i] == slot) { k = i; break; }
    if (k < 0 || k == wm->nwin - 1) return;
    for (int i = k; i < wm->nwin - 1; i++) wm->z[i] = wm->z[i + 1];
    wm->z[wm->nwin - 1] = slot;
}

void gem_wm_focus(gem_wm *wm, gem_window *win) {
    for (int i = 0; i < wm->nwin; i++) wm->win[wm->z[i]].active = 0;
    if (win) win->active = 1;
}

void gem_wm_close(gem_wm *wm, gem_window *win) {
    int slot = slot_of(wm, win), k = -1;
    for (int i = 0; i < wm->nwin; i++) if (wm->z[i] == slot) { k = i; break; }
    if (k < 0) return;
    if (win->vh)      v_clsvwk(win->vh);
    if (win->backing) gfx_surface_free(win->backing);
    win->backing = NULL; win->vh = 0; win->used = 0;
    for (int i = k; i < wm->nwin - 1; i++) wm->z[i] = wm->z[i + 1];
    wm->nwin--;
    if (wm->drag_slot == slot) wm->drag_slot = -1;
    gem_window *t = gem_wm_top(wm);             // focus the new frontmost
    gem_wm_focus(wm, t);
}

void gem_wm_resize(gem_wm *wm, gem_window *win, int w, int h) {
    (void)wm;
    if (w < MIN_W) w = MIN_W;
    if (h < MIN_H) h = MIN_H;
    if (w == win->w && h == win->h) return;
    win->w = w; win->h = h;
    recompute_content(win);
    if (win->vh)      v_clsvwk(win->vh);
    if (win->backing) gfx_surface_free(win->backing);
    win->backing = gfx_surface_alloc(win->cw, win->ch);
    win->vh      = win->backing ? v_opnvwk(win->backing) : 0;
    win->dirty   = 1;
}

// ---- Hit testing ----------------------------------------------------------
gem_hit gem_wm_hit(const gem_window *win, int x, int y) {
    if (x < win->x || y < win->y || x >= win->x + win->w || y >= win->y + win->h)
        return GEM_HIT_NONE;
    // Resize grip wins over content in the bottom-right corner.
    if (x >= win->x + win->w - RESIZE && y >= win->y + win->h - RESIZE)
        return GEM_HIT_RESIZE;
    int bx0, by0, bx1, by1; close_box(win, &bx0, &by0, &bx1, &by1);
    if (x >= bx0 && x <= bx1 && y >= by0 && y <= by1) return GEM_HIT_CLOSE;
    if (y < win->cy) return GEM_HIT_TITLE;           // above the content = title strip
    if (x >= win->cx && x < win->cx + win->cw &&
        y >= win->cy && y < win->cy + win->ch) return GEM_HIT_CONTENT;
    return GEM_HIT_TITLE;                             // edges / borders behave as frame
}

gem_window *gem_wm_window_at(gem_wm *wm, int x, int y) {
    for (int i = wm->nwin - 1; i >= 0; i--) {        // top..bottom
        gem_window *win = &wm->win[wm->z[i]];
        if (gem_wm_hit(win, x, y) != GEM_HIT_NONE) return win;
    }
    return NULL;
}

// ---- Mouse ----------------------------------------------------------------
void gem_wm_mouse_move(gem_wm *wm, int x, int y) {
    wm->mx = x; wm->my = y;
    if (wm->drag_slot < 0) return;
    gem_window *win = &wm->win[wm->drag_slot];
    if (wm->drag_mode == GEM_HIT_TITLE) {
        win->x = x - wm->drag_ox;  win->y = y - wm->drag_oy;
        recompute_content(win);
    } else if (wm->drag_mode == GEM_HIT_RESIZE) {
        gem_wm_resize(wm, win, x - win->x + wm->drag_ox, y - win->y + wm->drag_oy);
    }
}

void gem_wm_mouse_button(gem_wm *wm, int x, int y, int down) {
    wm->mx = x; wm->my = y;
    if (!down) { wm->drag_slot = -1; return; }       // release ends any drag
    gem_window *win = gem_wm_window_at(wm, x, y);
    if (!win) return;
    gem_wm_raise(wm, win);
    gem_wm_focus(wm, win);
    gem_hit h = gem_wm_hit(win, x, y);
    if (h == GEM_HIT_CLOSE) { gem_wm_close(wm, win); return; }
    if (h == GEM_HIT_TITLE) {
        wm->drag_slot = slot_of(wm, win); wm->drag_mode = GEM_HIT_TITLE;
        wm->drag_ox = x - win->x; wm->drag_oy = y - win->y;
    } else if (h == GEM_HIT_RESIZE) {
        wm->drag_slot = slot_of(wm, win); wm->drag_mode = GEM_HIT_RESIZE;
        wm->drag_ox = (win->x + win->w) - x;    // distance from corner, kept on resize
        wm->drag_oy = (win->y + win->h) - y;
    }
}

// ---- Frame + pointer drawing ----------------------------------------------
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
    int bx0, by0, bx1, by1; close_box(win, &bx0, &by0, &bx1, &by1);
    r[0]=bx0; r[1]=by0; r[2]=bx1; r[3]=by1; vr_recfl(vh, r);

    if (wm->title_font && win->title) {                                     // centred title text
        int rl = bx1 + 8, rr = x + w - 1 - EDGE;                            // between close box + edge
        int16_t tc[4] = { (int16_t)rl, (int16_t)(y+EDGE),
                          (int16_t)rr, (int16_t)(y+EDGE+TITLE_H-1) };
        vs_clip(vh, 1, tc);                                                 // keep text in the bar
        vst_color(vh, PEN_EDGE);
        vst_alignment(vh, VDI_TA_CENTER, VDI_TA_HALF, NULL, NULL);
        v_gtext(vh, (rl + rr) / 2, y + EDGE + TITLE_H / 2, win->title);
        vst_alignment(vh, VDI_TA_LEFT, VDI_TA_TOP, NULL, NULL);            // restore
        int16_t full[4] = { 0, 0, (int16_t)(wm->desk->w-1), (int16_t)(wm->desk->h-1) };
        vs_clip(vh, 0, full);                                              // restore
    }
}

// A minimal arrow pointer (hot spot = top-left).  X = black outline, . = white.
static void draw_pointer(gem_wm *wm) {
    static const char *arrow[] = {
        "X           ", "XX          ", "X.X         ", "X..X        ",
        "X...X       ", "X....X      ", "X.....X     ", "X......X    ",
        "X.......X   ", "X........X  ", "X.....XXXXX ", "X..X..X     ",
        "X.X X..X    ", "XX  X..X    ", "X    X..X   ", "     X..X   ",
        "      X..X  ", "      X..X  ", "       XX   ",
    };
    gfx_surface *d = wm->desk;
    for (int row = 0; row < 19; row++) {
        int py = wm->my + row; if (py < 0 || py >= d->h) continue;
        const char *s = arrow[row];
        for (int col = 0; s[col]; col++) {
            char c = s[col]; if (c == ' ') continue;
            int px = wm->mx + col; if (px < 0 || px >= d->w) continue;
            d->px[(size_t)py * d->stride + px] = (c == 'X') ? GFX_RGB(0,0,0)
                                                            : GFX_RGB(255,255,255);
        }
    }
}

void gem_wm_draw(gem_wm *wm) {
    gfx_fill_rect(wm->desk, 0, 0, wm->desk->w, wm->desk->h, wm->desktop_color);
    for (int k = 0; k < wm->nwin; k++) {             // bottom..top
        gem_window *win = &wm->win[wm->z[k]];
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
    draw_pointer(wm);
}
