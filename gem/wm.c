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

// Border + title height match the Aristo2 theme (window inset 5, titlebar 31) so
// the content rect + hit-testing line up with the 9-slice chrome (draw_frame).
#define TITLE_H    31
#define EDGE       5
#define TITLE_PX   18       // title text size (fits the title bar)
#define CLOSE_M 8           // close glyph inset from the title's left
#define CLOSE_S 16          // close glyph side (theme sprite is 16x16)
#define RESIZE  14          // bottom-right resize-grip extent
#define MIN_W   120
#define MIN_H   80

static int slot_of(const gem_wm *wm, const gem_window *win) { return (int)(win - wm->win); }

// ---- Geometry helpers (must match draw_frame) -----------------------------
static void close_box(const gem_window *win, int *x0, int *y0, int *x1, int *y1) {
    *x0 = win->x + EDGE + CLOSE_M;       *y0 = win->y + (TITLE_H - CLOSE_S) / 2;
    *x1 = *x0 + CLOSE_S;                 *y1 = *y0 + CLOSE_S;
}

// Scale controls (emu-backed windows only): two small up/down arrows near the
// title-bar right edge — click to grow/shrink the emulation a step.
#define SCALE_W 10
#define SCALE_H 7
static void scale_up_box(const gem_window *w, int *x0, int *y0) {
    *x0 = w->x + w->w - EDGE - 2 * SCALE_W - 8;   *y0 = w->y + (TITLE_H - SCALE_H) / 2;
}
static void scale_dn_box(const gem_window *w, int *x0, int *y0) {
    *x0 = w->x + w->w - EDGE - SCALE_W - 4;       *y0 = w->y + (TITLE_H - SCALE_H) / 2;
}

static void recompute_content(gem_window *win) {
    // Title bar spans the full width at the very top (its caps are the rounded top
    // corners); content sits below it with a side+bottom border only.
    win->cx = win->x + EDGE;          win->cy = win->y + TITLE_H;
    win->cw = win->w - 2 * EDGE;      win->ch = win->h - TITLE_H - EDGE;
}

// ---- Init / add -----------------------------------------------------------
void gem_wm_init(gem_wm *wm, gfx_surface *desk, uint32_t desktop_color) {
    wm->desk          = desk;
    wm->desktop_color = desktop_color;
    wm->wallpaper     = NULL;
    wm->th            = NULL;
    wm->nwin          = 0;
    wm->mx = wm->my   = 0;
    wm->drag_slot     = -1;
    wm->hide_slot     = -1;
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

// Native emulation surface size per target (the plane's source resolution).
void gem_emu_src_size(gem_emu_target target, int *w, int *h) {
    switch (target) {
        case GEM_EMU_ST: *w = GEM_ST_SRC_W; *h = GEM_ST_SRC_H; break;
        case GEM_EMU_XL: default: *w = GEM_XL_SRC_W; *h = GEM_XL_SRC_H; break;
    }
}

// Bind/unbind an existing window to a live HW emulation plane (XL or ST).  Binding
// resizes the window so its content rect is the emulation surface at `scale`; the
// content blit is skipped (the HW plane shows there) — the A9 points the plane at
// the content rect.  Geometry uses the same EDGE/TITLE_H insets as the chrome, so
// the content rect comes out exactly src_w*scale x src_h*scale.
void gem_wm_bind_emu(gem_wm *wm, gem_window *win, gem_emu_target target, int scale) {
    if (scale < 1) scale = 1; if (scale > 5) scale = 5;
    int sw, sh; gem_emu_src_size(target, &sw, &sh);
    win->emu_backed = 1;
    win->emu_target = target;
    win->emu_scale  = scale;
    win->w = sw * scale + 2 * EDGE;
    win->h = sh * scale + TITLE_H + EDGE;
    if (win->x + win->w > wm->desk->w) win->x = wm->desk->w - win->w;  // keep on-screen
    if (win->y + win->h > wm->desk->h) win->y = wm->desk->h - win->h;
    if (win->x < 0) win->x = 0;
    if (win->y < 0) win->y = 0;
    recompute_content(win);
    win->redraw = NULL;   // content is the HW plane; don't run a backing-store redraw
    win->dirty  = 0;      // (the now-larger content rect would overflow the old backing)
}

void gem_wm_unbind_emu(gem_wm *wm, gem_window *win) {
    (void)wm;
    win->emu_backed = 0;
    win->emu_target = GEM_EMU_NONE;
    win->dirty = 1;
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

// Hit-test the ^/v scale arrows on the frontmost emu-backed window covering (x,y):
// +1 = scale up, -1 = scale down, 0 = none; *slot gets that window's slot.  A few px
// of padding makes the small arrows easier to click.
int gem_wm_emu_scale_hit(gem_wm *wm, int x, int y, int *slot) {
    for (int i = wm->nwin - 1; i >= 0; i--) {        // top..bottom
        gem_window *w = &wm->win[wm->z[i]];
        if (!w->used) continue;
        if (x < w->x || x >= w->x + w->w || y < w->y || y >= w->y + w->h) continue;
        if (w->emu_backed) {
            const int P = 3;
            int ux, uy, dxx, dyy; scale_up_box(w, &ux, &uy); scale_dn_box(w, &dxx, &dyy);
            if (slot) *slot = wm->z[i];
            if (x >= ux - P && x < ux + SCALE_W + P && y >= uy - P && y < uy + SCALE_H + P) return +1;
            if (x >= dxx - P && x < dxx + SCALE_W + P && y >= dyy - P && y < dyy + SCALE_H + P) return -1;
        }
        return 0;                                     // frontmost window here; don't fall through
    }
    return 0;
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
    int bx0, by0, bx1, by1; close_box(win, &bx0, &by0, &bx1, &by1);
    if (wm->th) {
        // Themed chrome (Aristo2): one 9-slice whose top row IS the rounded titlebar
        // (the "head"), so it's flush to the edges with rounded top+bottom corners.
        theme_draw(vh, wm->th, win->active ? "window" : "window.inactive", x, y, w, h);
        const theme_slice *cs = theme_find(wm->th, "close");
        if (cs) theme_blit(vh, wm->th, cs, bx0, by0, cs->sw, cs->sh);
        if (win->emu_backed) {                        // ^/v scale arrows on the right
            const theme_slice *up = theme_find(wm->th, "vscroll.up");
            const theme_slice *dn = theme_find(wm->th, "vscroll.down");
            int ux, uy, dxx, dyy; scale_up_box(win, &ux, &uy); scale_dn_box(win, &dxx, &dyy);
            if (up) theme_blit(vh, wm->th, up, ux, uy, up->sw, up->sh);
            if (dn) theme_blit(vh, wm->th, dn, dxx, dyy, dn->sw, dn->sh);
        }
    } else {
        // VDI-pen skeleton fallback (no theme loaded, e.g. SDL host).
        int16_t r[4];
        vsf_interior(vh, 1);
        vsf_color(vh, PEN_EDGE);
        r[0]=x; r[1]=y; r[2]=x+w-1; r[3]=y+h-1; vr_recfl(vh, r);                 // outer edge
        vsf_color(vh, win->active ? PEN_TITLE_ACT : PEN_TITLE_INA);
        r[0]=x; r[1]=y; r[2]=x+w-1; r[3]=y+TITLE_H-1; vr_recfl(vh, r);           // full-width title
        vsf_color(vh, PEN_BODY);                                                 // close box
        r[0]=bx0; r[1]=by0; r[2]=bx1; r[3]=by1; vr_recfl(vh, r);
    }

    if (wm->title_font && win->title) {                                     // centred title text
        int rl = bx1 + 8, rr = x + w - 1 - EDGE;                            // between close box + edge
        if (win->emu_backed) { int sx, sy; scale_up_box(win, &sx, &sy); rr = sx - 8; }  // clear the arrows
        int16_t tc[4] = { (int16_t)rl, (int16_t)y,
                          (int16_t)rr, (int16_t)(y+TITLE_H-1) };
        vs_clip(vh, 1, tc);                                                 // keep text in the bar
        vst_color(vh, PEN_EDGE);
        vst_alignment(vh, VDI_TA_CENTER, VDI_TA_HALF, NULL, NULL);
        v_gtext(vh, (rl + rr) / 2, y + TITLE_H / 2, win->title);
        vst_alignment(vh, VDI_TA_LEFT, VDI_TA_TOP, NULL, NULL);            // restore
        int16_t full[4] = { 0, 0, (int16_t)(wm->desk->w-1), (int16_t)(wm->desk->h-1) };
        vs_clip(vh, 0, full);                                              // restore
    }
}

// Draw the vsc_form mouse shape (16x16 mono, MSB = leftmost): foreground where
// data=1, background where mask=1 & data=0, else transparent.  Placed so its hot
// spot sits at the pointer position.
static void draw_mform(gem_wm *wm, const MFORM *m) {
    gfx_surface *d = wm->desk;
    uint32_t fg = vdi_pen_rgba(m->fg), bg = vdi_pen_rgba(m->bg);
    for (int row = 0; row < 16; row++) {
        int py = wm->my - m->hoty + row; if (py < 0 || py >= d->h) continue;
        for (int col = 0; col < 16; col++) {
            uint16_t bit = (uint16_t)(0x8000u >> col);
            int on = (m->data[row] & bit) != 0, out = (m->mask[row] & bit) != 0;
            if (!on && !out) continue;                          // transparent
            int px = wm->mx - m->hotx + col; if (px < 0 || px >= d->w) continue;
            d->px[(size_t)py * d->stride + px] = on ? fg : bg;
        }
    }
}

// A minimal arrow pointer (hot spot = top-left).  X = black outline, . = white.
static void draw_pointer(gem_wm *wm) {
    const MFORM *m = vdi_cursor_form();
    if (m) { draw_mform(wm, m); return; }                       // app/AES-set shape
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

void gem_wm_set_theme(gem_wm *wm, const theme *th) {
    wm->th = th;
}

void gem_wm_set_wallpaper(gem_wm *wm, gfx_surface *wallpaper) {
    wm->wallpaper = wallpaper;
}

// Erase a desktop rect back to the backdrop: copy from the wallpaper (desk-sized,
// same coords) when one is set, else a solid desktop_color fill.  This is what
// keeps the textured background visible instead of painting it solid blue.
static void wm_erase(gem_wm *wm, int x, int y, int w, int h) {
    if (wm->wallpaper)
        gfx_blit(wm->desk, x, y, wm->wallpaper, x, y, w, h);
    else
        gfx_fill_rect(wm->desk, x, y, w, h, wm->desktop_color);
}

void gem_wm_draw(gem_wm *wm) {
    wm_erase(wm, 0, 0, wm->desk->w, wm->desk->h);
    for (int k = 0; k < wm->nwin; k++) {             // bottom..top
        gem_window *win = &wm->win[wm->z[k]];
        if (!win->used) continue;
        if (wm->z[k] == wm->hide_slot) continue;     // lifted into a HW overlay
        if (win->dirty && win->redraw) { win->redraw(win, win->ud); win->dirty = 0; }
        draw_frame(wm, win);
        if (win->emu_backed) continue;  // content area is a live HW emulation plane
        // Composite the backing-store content into the window's content rect.
        MFDB src, dst;
        mfdb_from_surface(&src, win->backing);
        mfdb_from_surface(&dst, wm->desk);
        int16_t pxy[8] = { 0, 0, (int16_t)(win->cw - 1), (int16_t)(win->ch - 1),
                           (int16_t)win->cx, (int16_t)win->cy,
                           (int16_t)(win->cx + win->cw - 1), (int16_t)(win->cy + win->ch - 1) };
        vro_cpyfm(wm->desk_vh, VRO_COPY, pxy, &src, &dst);
    }
    if (!wm->no_cursor && vdi_cursor_visible()) draw_pointer(wm);  // A9 owns its own pointer
}

// Redraw only the screen rectangle [x0,y0]..[x1,y1] (a "damage" rect): fill the
// background, then recomposite every window that intersects it, clipped to it.
// Used while dragging — avoids the whole-desktop clear + recomposite (and its
// flicker) by touching just the union of the window's old and new rect.
void gem_wm_draw_rect(gem_wm *wm, int x0, int y0, int x1, int y1) {
    if (x0 < 0) x0 = 0; if (y0 < 0) y0 = 0;
    if (x1 > wm->desk->w - 1) x1 = wm->desk->w - 1;
    if (y1 > wm->desk->h - 1) y1 = wm->desk->h - 1;
    if (x1 < x0 || y1 < y0) return;
    wm_erase(wm, x0, y0, x1 - x0 + 1, y1 - y0 + 1);
    int16_t clip[4] = { (int16_t)x0, (int16_t)y0, (int16_t)x1, (int16_t)y1 };
    vs_clip(wm->desk_vh, 1, clip);
    for (int k = 0; k < wm->nwin; k++) {             // bottom..top
        gem_window *win = &wm->win[wm->z[k]];
        if (!win->used) continue;
        if (wm->z[k] == wm->hide_slot) continue;     // lifted into a HW overlay
        if (win->x > x1 || win->x + win->w - 1 < x0 ||
            win->y > y1 || win->y + win->h - 1 < y0) continue;      // outside the damage
        if (win->dirty && win->redraw) { win->redraw(win, win->ud); win->dirty = 0; }
        draw_frame(wm, win);                          // clipped by vs_clip
        if (win->emu_backed) continue;                // content is a live HW plane
        int ix0 = win->cx > x0 ? win->cx : x0;        // content rect ∩ damage
        int iy0 = win->cy > y0 ? win->cy : y0;
        int ix1 = (win->cx + win->cw - 1) < x1 ? (win->cx + win->cw - 1) : x1;
        int iy1 = (win->cy + win->ch - 1) < y1 ? (win->cy + win->ch - 1) : y1;
        if (ix1 < ix0 || iy1 < iy0) continue;
        MFDB src, dst;
        mfdb_from_surface(&src, win->backing);
        mfdb_from_surface(&dst, wm->desk);
        int16_t pxy[8] = { (int16_t)(ix0 - win->cx), (int16_t)(iy0 - win->cy),
                           (int16_t)(ix1 - win->cx), (int16_t)(iy1 - win->cy),
                           (int16_t)ix0, (int16_t)iy0, (int16_t)ix1, (int16_t)iy1 };
        vro_cpyfm(wm->desk_vh, VRO_COPY, pxy, &src, &dst);
    }
    int16_t full[4] = { 0, 0, (int16_t)(wm->desk->w - 1), (int16_t)(wm->desk->h - 1) };
    vs_clip(wm->desk_vh, 0, full);
}

// Draw ONE window (frame + composite its backing) at its current position,
// overwriting in place — no background erase, so it doesn't flicker.  Used for
// the dragged window: bg-fill only the strip it vacated, then redraw it here.
void gem_wm_draw_window(gem_wm *wm, int slot) {
    gem_window *win = &wm->win[slot];
    if (!win->used) return;
    if (win->dirty && win->redraw) { win->redraw(win, win->ud); win->dirty = 0; }
    draw_frame(wm, win);
    if (win->emu_backed) return;        // content area is a live HW emulation plane
    MFDB src, dst;
    mfdb_from_surface(&src, win->backing);
    mfdb_from_surface(&dst, wm->desk);
    int16_t pxy[8] = { 0, 0, (int16_t)(win->cw - 1), (int16_t)(win->ch - 1),
                       (int16_t)win->cx, (int16_t)win->cy,
                       (int16_t)(win->cx + win->cw - 1), (int16_t)(win->cy + win->ch - 1) };
    vro_cpyfm(wm->desk_vh, VRO_COPY, pxy, &src, &dst);
}

// Render ONE window into `target` (via VDI handle `target_vh`) at the surface origin.
// We reuse the full themed draw path by temporarily pointing the WM at the target and
// moving the window to (0,0) — so the chrome (theme 9-slice incl. rounded AA corners),
// close box, title, and content land exactly as on screen, but composited over the
// (caller-cleared, transparent) overlay so undrawn pixels keep alpha=0.  All WM state
// is restored before returning.
void gem_wm_render_window_to(gem_wm *wm, int slot, gfx_surface *target, int target_vh) {
    gem_window *win = &wm->win[slot];
    if (!win->used) return;
    gfx_surface *save_desk = wm->desk;          // retarget the WM at the overlay
    int          save_vh   = wm->desk_vh;
    int          sx = win->x, sy = win->y;      // and place the window at the origin
    wm->desk = target; wm->desk_vh = target_vh;
    win->x = 0; win->y = 0; recompute_content(win);

    if (win->dirty && win->redraw) { win->redraw(win, win->ud); win->dirty = 0; }
    draw_frame(wm, win);
    if (!win->emu_backed) {                      // composite the backing content
        MFDB src, dst;
        mfdb_from_surface(&src, win->backing);
        mfdb_from_surface(&dst, target);
        int16_t pxy[8] = { 0, 0, (int16_t)(win->cw - 1), (int16_t)(win->ch - 1),
                           (int16_t)win->cx, (int16_t)win->cy,
                           (int16_t)(win->cx + win->cw - 1), (int16_t)(win->cy + win->ch - 1) };
        vro_cpyfm(target_vh, VRO_COPY, pxy, &src, &dst);
    }

    win->x = sx; win->y = sy; recompute_content(win);   // restore
    wm->desk = save_desk; wm->desk_vh = save_vh;
}
