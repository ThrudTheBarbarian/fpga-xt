// aes/object.c — the OBJECT tree renderer + hit-tester.  Each object type maps
// to a theme element (buttons/fields/checks via theme_draw) or a VDI primitive
// (boxes, text), so dialogs are themed without AES knowing any pixels.

#include "aes/aes_internal.h"
#include "font.h"
#include <string.h>

static int g_vh;
static const theme *g_th;

// scratch pens for box fill / border / icon-selection (set from the theme at init)
enum { PEN_DLG = 248, PEN_BORDER = 249, PEN_SEL = 250 };

void aes_init(int vh, const theme *th) {
    g_vh = vh; g_th = th;
    v_setrgb(vh, PEN_DLG, 236, 238, 240);
    if (th) {
        v_setrgb(vh, PEN_BORDER, (th->border>>24)&0xFF, (th->border>>16)&0xFF, (th->border>>8)&0xFF);
        v_setrgb(vh, PEN_SEL,    (th->sel_bg>>24)&0xFF, (th->sel_bg>>16)&0xFF, (th->sel_bg>>8)&0xFF);
    }
}
int          aes_handle(void) { return g_vh; }
const theme *aes_theme(void)  { return g_th; }

// G_CICON label style: 1 = over a dark backdrop (desktop/wallpaper) -> white text
// + shadow, selection = white-on-black; 0 = over a light window -> black text,
// selection = black-on-white.  The container sets this before objc_draw.
static int g_icon_dark = 1;
void aes_icon_label_style(int dark_bg) { g_icon_dark = dark_bg; }

// Iterate the children of `parent` (stops after ob_tail, whose ob_next is the
// parent again).
#define EACH_CHILD(t, parent, c) \
    for (int c = (t)[parent].ob_head; c >= 0; c = (c == (t)[parent].ob_tail ? -1 : (t)[c].ob_next))

static int off_rec(OBJECT *t, int root, int target, int ax, int ay, int *ox, int *oy) {
    ax += t[root].ob_x; ay += t[root].ob_y;
    if (root == target) { *ox = ax; *oy = ay; return 1; }
    EACH_CHILD(t, root, c) if (off_rec(t, c, target, ax, ay, ox, oy)) return 1;
    return 0;
}
void objc_offset(OBJECT *t, int obj, int *x, int *y) { *x = *y = 0; off_rec(t, 0, obj, 0, 0, x, y); }

// ---- live tree edits (classic AES: pure index relinking of the child chain) --
// The last child's ob_next points back to its parent, so following ob_next from
// `obj` reaches the parent exactly when we arrive at that parent's tail child.
static int objc_parent(OBJECT *t, int obj) {
    for (int q = obj; t[q].ob_next >= 0; q = t[q].ob_next)
        if (t[t[q].ob_next].ob_tail == q) return t[q].ob_next;
    return NIL;
}
// Append `obj` (already sized/placed by the caller) as the LAST child of parent.
void objc_add(OBJECT *tree, int parent, int obj) {
    tree[obj].ob_next = (int16_t)parent;                       // tail child -> parent
    if (tree[parent].ob_head < 0) tree[parent].ob_head = (int16_t)obj;
    else                          tree[tree[parent].ob_tail].ob_next = (int16_t)obj;
    tree[parent].ob_tail = (int16_t)obj;
}
// Unlink `obj` from its parent's child list (frees nothing; OF_LASTOB untouched).
void objc_delete(OBJECT *tree, int obj) {
    int parent = objc_parent(tree, obj); if (parent < 0) return;
    OBJECT *p = &tree[parent];
    if (p->ob_head == obj) {
        p->ob_head = (p->ob_tail == obj) ? NIL : tree[obj].ob_next;   // first child
        if (p->ob_tail == obj) p->ob_tail = NIL;
    } else {                                                   // find the sibling before obj
        int s = p->ob_head;
        while (tree[s].ob_next != obj) s = tree[s].ob_next;
        tree[s].ob_next = tree[obj].ob_next;
        if (p->ob_tail == obj) p->ob_tail = (int16_t)s;
    }
    tree[obj].ob_next = NIL;
}
// Move `obj` to position `pos` among its siblings: 0 = first (bottom of the draw
// order), >= child-count = last (top).  Pure relink within the same parent.
void objc_order(OBJECT *tree, int obj, int pos) {
    int parent = objc_parent(tree, obj); if (parent < 0) return;
    objc_delete(tree, obj);
    OBJECT *p = &tree[parent];
    if (pos <= 0) {                                           // first child
        tree[obj].ob_next = (p->ob_head < 0) ? (int16_t)parent : p->ob_head;
        if (p->ob_tail < 0) p->ob_tail = (int16_t)obj;
        p->ob_head = (int16_t)obj;
        return;
    }
    int n = 0; EACH_CHILD(tree, parent, c) n++;               // remaining children
    if (pos >= n) { objc_add(tree, parent, obj); return; }    // last child
    int prev = p->ob_head;
    for (int i = 0; i < pos - 1; i++) prev = tree[prev].ob_next;
    tree[obj].ob_next = tree[prev].ob_next;
    tree[prev].ob_next = (int16_t)obj;
}

// USERDEF draw seam (mirrors form_set_hook): one registered callback, invoked for
// each G_USERDEF object during objc_draw.  The app gets the object's position via
// objc_offset(tree,obj,&x,&y) and draws through aes_handle().
static objc_userdraw_fn g_userdraw;
static void            *g_userdraw_ud;
void objc_set_userdraw(objc_userdraw_fn fn, void *ud) { g_userdraw = fn; g_userdraw_ud = ud; }

static void box(int x, int y, int w, int h, int border) {
    vsf_color(g_vh, PEN_DLG); vsf_interior(g_vh, VDI_FIS_SOLID); vsf_perimeter(g_vh, 0);
    int16_t r[4] = { (int16_t)x, (int16_t)y, (int16_t)(x+w-1), (int16_t)(y+h-1) };
    vr_recfl(g_vh, r);
    if (border) {
        vsl_color(g_vh, PEN_BORDER); vsl_width(g_vh, 1);
        int16_t o[10] = { (int16_t)x,(int16_t)y, (int16_t)(x+w-1),(int16_t)y,
                          (int16_t)(x+w-1),(int16_t)(y+h-1), (int16_t)x,(int16_t)(y+h-1), (int16_t)x,(int16_t)y };
        v_pline(g_vh, 5, o);
    }
}

static void centered(const char *s, int x, int y, int w, int h, int pen, int bold) {
    vst_color(g_vh, pen); vst_height(g_vh, 14, 0,0,0,0);
    if (bold) vst_effects(g_vh, FX_BOLD);
    vst_alignment(g_vh, VDI_TA_CENTER, VDI_TA_HALF, 0,0);
    v_gtext(g_vh, x + w/2, y + h/2, s);
    vst_alignment(g_vh, VDI_TA_LEFT, VDI_TA_TOP, 0,0); vst_effects(g_vh, 0);
}

// A tinted copy of an icon for the selected state: RGB scaled by num/den (< 1
// darkens, > 1 brightens) only where the alpha mask is set, so the effect follows
// the icon silhouette.  Returns a static scratch surface (blit it immediately).
static gfx_surface *icon_tint(const gfx_surface *s, int num, int den) {
    static uint32_t buf[128*128];
    static gfx_surface t;
    if (s->w <= 0 || s->h <= 0 || s->w > 128 || s->h > 128) return (gfx_surface *)s;
    t.w = s->w; t.h = s->h; t.stride = s->w; t.px = buf;
    for (int yy = 0; yy < s->h; yy++)
        for (int xx = 0; xx < s->w; xx++) {
            uint32_t p = s->px[(size_t)yy*s->stride + xx], a = p & 0xFF;
            uint32_t r = ((p>>24)&0xFF)*num/den, g = ((p>>16)&0xFF)*num/den, b = ((p>>8)&0xFF)*num/den;
            if (r>255) r=255; if (g>255) g=255; if (b>255) b=255;
            buf[(size_t)yy*t.stride + xx] = (r<<24)|(g<<16)|(b<<8)|a;
        }
    return &t;
}

// A ghosted copy of an icon for uncached network entries: alpha scaled to 2/5
// so the silhouette shows dimmed over whatever is behind it.  Unlike icon_tint
// this is a real allocation (pre-baked per entry, not per-frame) — the caller
// owns the returned surface.
gfx_surface *icon_ghost(const gfx_surface *s) {
    gfx_surface *t = gfx_surface_alloc(s->w, s->h);
    if (!t) return NULL;
    for (int yy = 0; yy < s->h; yy++)
        for (int xx = 0; xx < s->w; xx++) {
            uint32_t p = s->px[(size_t)yy*s->stride + xx];
            t->px[(size_t)yy*t->stride + xx] = (p & ~0xFFu) | ((p & 0xFF)*2/5);
        }
    return t;
}

// 1-px mnemonic underline under label character `idx` (the WHITEBAK
// convention).  tx = text start x under the CURRENT vst settings; uy = the
// underline row.  Prefix/char widths via vqt_extent, so it tracks the face.
static void underline_ch(const char *txt, int idx, int tx, int uy, int pen) {
    if (idx < 0 || idx >= (int)strlen(txt)) return;
    char pre[96]; int16_t e[8]; int x0 = 0;
    int n = idx < (int)sizeof pre - 1 ? idx : (int)sizeof pre - 1;
    if (n) { memcpy(pre, txt, n); pre[n] = 0; vqt_extent(g_vh, pre, e); x0 = e[2]-e[0]; }
    char ch[2] = { txt[idx], 0 };
    vqt_extent(g_vh, ch, e); int cw = e[2]-e[0]; if (cw < 2) cw = 2;
    vsl_color(g_vh, pen); vsl_width(g_vh, 1);
    int16_t l[4] = { (int16_t)(tx+x0), (int16_t)uy, (int16_t)(tx+x0+cw-1), (int16_t)uy };
    v_pline(g_vh, 2, l);
}

static void draw_obj(OBJECT *t, int obj, int x, int y) {
    OBJECT *o = &t[obj];
    int w = o->ob_w, h = o->ob_h, st = o->ob_state, fl = o->ob_flags;
    const char *txt = (const char *)o->ob_spec;
    switch (o->ob_type) {
        case G_BOX: case G_BOXTEXT:
            box(x, y, w, h, 1);
            if (o->ob_type == G_BOXTEXT && txt) centered(txt, x, y, w, h, 1, 0);
            if (fl & OF_MOVEABLE) {                     // fly corner: dog-ear grip, top-right
                vsl_color(g_vh, PEN_BORDER); vsl_width(g_vh, 1);
                for (int i = 0; i < 3; i++) {
                    int d = 5 + i*4;
                    int16_t l[4] = { (int16_t)(x+w-1-d), (int16_t)(y+1),
                                     (int16_t)(x+w-2),   (int16_t)(y+d) };
                    v_pline(g_vh, 2, l);
                }
            }
            break;
        case G_IBOX: break;                                     // invisible container

        // A themed scrollbar and a themed value slider.  The AES only DRAWS them; the
        // caller owns the interaction (objc_find gives it the hit, and it writes `value`
        // back).  That keeps the AES dumb and the toolkit smart, which is the right way
        // round -- and it is why XGScrollBar, like XGButton, contains no drawing code.
        case G_SCROLL: {
            SCROLLBAR *s = (SCROLLBAR *)o->ob_spec;
            if (!s) break;
            int val  = s->value < 0 ? 0 : (s->value > 1000 ? 1000 : s->value);
            int page = s->page  < 1 ? 1 : (s->page  > 1000 ? 1000 : s->page);
            const char *trk = s->vert ? "vscroll.track" : "hscroll.track";
            const char *thm = s->vert ? "vscroll.thumb" : "hscroll.thumb";
            const char *a0  = s->vert ? "vscroll.up"    : "hscroll.left";
            const char *a1  = s->vert ? "vscroll.down"  : "hscroll.right";

            int ax0 = x, ay0 = y, aw = w, ah = h;      // the track, minus the arrow caps
            if (s->arrows) {
                const theme_slice *s0 = theme_find(g_th, a0);
                const theme_slice *s1 = theme_find(g_th, a1);
                int c0 = s0 ? (s->vert ? s0->sh : s0->sw) : 0;
                int c1 = s1 ? (s->vert ? s1->sh : s1->sw) : 0;
                if (s->vert) {
                    if (s0) theme_blit(g_vh, g_th, s0, x + (w - s0->sw)/2, y, s0->sw, s0->sh);
                    if (s1) theme_blit(g_vh, g_th, s1, x + (w - s1->sw)/2, y + h - s1->sh, s1->sw, s1->sh);
                    ay0 += c0; ah -= c0 + c1;
                } else {
                    if (s0) theme_blit(g_vh, g_th, s0, x, y + (h - s0->sh)/2, s0->sw, s0->sh);
                    if (s1) theme_blit(g_vh, g_th, s1, x + w - s1->sw, y + (h - s1->sh)/2, s1->sw, s1->sh);
                    ax0 += c0; aw -= c0 + c1;
                }
            }
            if (aw <= 0 || ah <= 0) break;
            theme_draw(g_vh, g_th, trk, ax0, ay0, aw, ah);

            if (s->vert) {                              // thumb: size = page, pos = value
                int th = ah * page / 1000; if (th < 12) th = 12; if (th > ah) th = ah;
                int ty = ay0 + (ah - th) * val / 1000;
                int tw = aw - 2; if (tw < 5) tw = aw;
                theme_draw(g_vh, g_th, thm, ax0 + (aw - tw)/2, ty, tw, th);
            } else {
                int tw = aw * page / 1000; if (tw < 12) tw = 12; if (tw > aw) tw = aw;
                int tx = ax0 + (aw - tw) * val / 1000;
                int th = ah - 2; if (th < 5) th = ah;
                theme_draw(g_vh, g_th, thm, tx, ay0 + (ah - th)/2, tw, th);
            }
            break;
        }

        case G_SLIDER: {                                // a value slider: a knob, no page
            SCROLLBAR *s = (SCROLLBAR *)o->ob_spec;
            if (!s) break;
            int val = s->value < 0 ? 0 : (s->value > 1000 ? 1000 : s->value);
            const theme_slice *k = theme_find(g_th, (st & OS_SELECTED) ? "slider.knob.hi"
                                                                       : "slider.knob");
            int kw = k ? k->sw : 16, kh = k ? k->sh : 16;
            if (s->vert) {
                int tw = 6; if (tw > w) tw = w;
                theme_draw(g_vh, g_th, "slider.vtrack", x + (w - tw)/2, y + kh/2, tw, h - kh);
                int ky = y + (h - kh) * val / 1000;
                if (k) theme_blit(g_vh, g_th, k, x + (w - kw)/2, ky, kw, kh);
            } else {
                int th = 6; if (th > h) th = h;
                theme_draw(g_vh, g_th, "slider.htrack", x + kw/2, y + (h - th)/2, w - kw, th);
                int kx = x + (w - kw) * val / 1000;
                if (k) theme_blit(g_vh, g_th, k, kx, y + (h - kh)/2, kw, kh);
            }
            break;
        }
        case G_USERDEF: if (g_userdraw) g_userdraw(t, obj, g_userdraw_ud); break;   // app-drawn
        case G_BUTTON: {
            int def = fl & OF_DEFAULT;
            const char *v = (st & OS_DISABLED)         ? "button.disabled"
                          : def && (st & OS_SELECTED)  ? "button.default.pressed"
                          : def                        ? "button.default"
                          : (st & OS_SELECTED)         ? "button.selected" : "button";
            theme_draw(g_vh, g_th, v, x, y, w, h);
            int pen = def ? 0 : (st & OS_DISABLED) ? 9 : 1;
            centered(txt ? txt : "", x, y, w, h, pen, def);
            if (txt && (st & OS_WHITEBAK)) {            // mnemonic underline (centred text)
                vst_height(g_vh, 14, 0,0,0,0);
                if (def) vst_effects(g_vh, FX_BOLD);
                int16_t e[8]; vqt_extent(g_vh, txt, e); int tw = e[2]-e[0];
                underline_ch(txt, WB_INDEX(st), x + w/2 - tw/2, y + h/2 + 9, pen);
                vst_effects(g_vh, 0);
            }
            break;
        }
        case G_CHECKBOX: case G_RADIO: {
            const char *v = o->ob_type == G_RADIO
                          ? ((st & OS_SELECTED) ? "radio.selected" : "radio")
                          : ((st & OS_SELECTED) ? "check.selected" : "check");
            const theme_slice *s = theme_find(g_th, v);
            int bs = s ? s->sh : 16;
            theme_draw(g_vh, g_th, v, x, y + (h-bs)/2, bs, bs);
            if (txt) {
                vst_color(g_vh,1); vst_height(g_vh,14,0,0,0,0);
                v_gtext(g_vh, x+bs+8, y+h/2-7, txt);
                if (st & OS_WHITEBAK) underline_ch(txt, WB_INDEX(st), x+bs+8, y+h/2+9, 1);
            }
            break;
        }
        case G_FIELD: case G_POPUP: {
            theme_draw(g_vh, g_th, o->ob_type == G_POPUP ? "popup" : "textfield", x, y, w, h);
            if (txt) { vst_color(g_vh,1); vst_height(g_vh,13,0,0,0,0); v_gtext(g_vh, x+8, y+h/2-7, txt); }
            break;
        }
        case G_IMAGE:           // ob_spec = a theme element name (e.g. an alert icon)
            if (txt) theme_draw(g_vh, g_th, txt, x, y, w, h);
            break;
        case G_CICON: {          // ob_spec = CICON* : RGBA bitmap + label under it
            CICON *ci = (CICON *)o->ob_spec;
            if (!ci) break;
            int sel = st & OS_SELECTED, ih = 0;
            if (ci->img) {                                   // icon, centred at the top;
                gfx_surface *src = sel ? icon_tint(ci->img, 3, 5) : ci->img;   // darkened when selected
                int iw = src->w; ih = src->h;
                int ix = x + (w - iw)/2, iy = y;
                MFDB m; mfdb_from_surface(&m, src);
                int16_t pxy[8] = { 0, 0, (int16_t)(iw-1), (int16_t)(ih-1),
                                   (int16_t)ix, (int16_t)iy, (int16_t)(ix+iw-1), (int16_t)(iy+ih-1) };
                vr_transfer_bits(g_vh, &m, NULL, pxy, VR_OVER);
            }
            if (ci->text) {                                  // label, centred beneath the icon
                int tcx = x + w/2, ly = y + ih + 2;
                int barpen = g_icon_dark ? 1 : 0;            // bar : black (desktop) / white (window)
                int txtpen = g_icon_dark ? 0 : 1;            // text: white (desktop) / black (window)
                vst_height(g_vh, 12, 0,0,0,0);
                vst_alignment(g_vh, VDI_TA_CENTER, VDI_TA_TOP, 0,0);
                char lbl[96];                        // ellipsised to the cell
                aes_label_fit(g_vh, ci->text, w - 4, lbl, sizeof lbl);
                if (sel) {                                   // label bar sized to the text
                    int16_t ext[8]; vqt_extent(g_vh, lbl, ext);
                    int tw = ext[2]-ext[0]; if (tw < 0) tw = -tw;
                    int th = ext[1]-ext[7]; if (th < 0) th = -th;
                    int16_t r[4] = { (int16_t)(tcx-tw/2-3), (int16_t)(ly-1),
                                     (int16_t)(tcx+tw/2+2), (int16_t)(ly+th+1) };
                    vsf_color(g_vh, barpen); vsf_interior(g_vh, VDI_FIS_SOLID); vsf_perimeter(g_vh, 0);
                    vr_recfl(g_vh, r);
                    if (!g_icon_dark) {                      // outline so a white bar reads on a light window
                        vsl_color(g_vh, PEN_BORDER); vsl_width(g_vh, 1);
                        int16_t o[10] = { r[0],r[1], r[2],r[1], r[2],r[3], r[0],r[3], r[0],r[1] };
                        v_pline(g_vh, 5, o);
                    }
                    vst_color(g_vh, txtpen);
                    v_gtext(g_vh, tcx, ly, lbl);
                } else if (g_icon_dark) {                    // white + shadow -> readable over a wallpaper
                    vst_color(g_vh, 1); v_gtext(g_vh, tcx+1, ly+1, lbl);
                    vst_color(g_vh, 0); v_gtext(g_vh, tcx,   ly,   lbl);
                } else {                                     // black on the light window (grey when ghosted)
                    vst_color(g_vh, (st & OS_DISABLED) ? 9 : 1); v_gtext(g_vh, tcx, ly, lbl);
                }
                vst_alignment(g_vh, VDI_TA_LEFT, VDI_TA_TOP, 0,0);
            }
            break;
        }
        case G_STRING: case G_TITLE: {
            if (txt) { int pen = (st & OS_DISABLED) ? 9 : 1;
                       vst_color(g_vh, pen); vst_height(g_vh,14,0,0,0,0);
                       v_gtext(g_vh, x, y + h/2 - 7, txt);
                       if (st & OS_WHITEBAK) underline_ch(txt, WB_INDEX(st), x, y+h/2+9, pen); }
            break;
        }
        case G_FTEXT: case G_FBOXTEXT: {                 // editable text field (TEDINFO)
            TEDINFO *te = (TEDINFO *)o->ob_spec;
            theme_draw(g_vh, g_th, "textfield", x, y, w, h);
            if (!te) break;
            int caret = -1, foc = objc_edit_state(t, obj, &caret);
            char disp[160]; int dpos = 0;
            ted_display(te, disp, sizeof disp, foc ? caret : -1, &dpos);
            vst_color(g_vh, (st & OS_DISABLED) ? 9 : 1); vst_height(g_vh, 13, 0,0,0,0);
            int16_t e[8]; int tw = 0;
            if (disp[0]) { vqt_extent(g_vh, disp, e); tw = e[2]-e[0]; }
            int tx = x + 8;                              // TE_LEFT default
            if      (te->te_just == TE_RIGHT) tx = x + w - 8 - tw;
            else if (te->te_just == TE_CNTR)  tx = x + (w - tw)/2;
            if (disp[0]) v_gtext(g_vh, tx, y + h/2 - 7, disp);
            if (foc) {                                   // caret at the input position
                int cx = tx;
                if (dpos > 0) { char pre[160];
                    memcpy(pre, disp, (size_t)dpos); pre[dpos] = 0;
                    vqt_extent(g_vh, pre, e); cx = tx + (e[2]-e[0]); }
                vsl_color(g_vh, 1); vsl_width(g_vh, 1);
                int16_t l[4] = { (int16_t)cx, (int16_t)(y + h/2 - 8),
                                 (int16_t)cx, (int16_t)(y + h/2 + 8) };
                v_pline(g_vh, 2, l);
            }
            break;
        }
        case G_TEXT:
            if (txt) { vst_color(g_vh,1); vst_height(g_vh,14,0,0,0,0); v_gtext(g_vh, x, y, txt); }
            break;
        default: break;
    }
}

/* `cl` is the clip currently in force.  An object flagged OF_CLIPCHILDREN narrows it to
 * its own rect for the duration of its subtree, then restores it — which is what lets a
 * container SCROLL: the partially-visible row at its edge is cut off at the container's
 * boundary instead of painting over its neighbours.  (NSView clips subviews to bounds by
 * default; this is that, opt-in.)  Without the flag the behaviour is exactly as before. */
static void draw_rec(OBJECT *t, int obj, int ax, int ay, int depth, const int16_t *cl) {
    if (t[obj].ob_flags & OF_HIDETREE) return;

    /* Damage-driven repaint: an object outside the clip is not drawn.  The VDI would
     * throw the pixels away anyway, but it cannot stop draw_obj COMPUTING them --
     * theme_draw still looks up its slices and sets up its blits.  With a small damage
     * rect and a large tree that is nearly all the work, and all of it wasted.
     *
     * And if the object CLIPS ITS CHILDREN, the whole subtree is confined to it, so an
     * out-of-clip container prunes its entire subtree in one test.  That is what makes a
     * long scrolling list cheap: the rows you cannot see are never visited at all. */
    int ox0 = ax, oy0 = ay, ox1 = ax + t[obj].ob_w - 1, oy1 = ay + t[obj].ob_h - 1;
    int miss = (ox1 < cl[0] || ox0 > cl[2] || oy1 < cl[1] || oy0 > cl[3]);
    if (miss && (t[obj].ob_flags & OF_CLIPCHILDREN)) return;   /* prune the whole subtree */
    if (!miss) draw_obj(t, obj, ax, ay);

    if (depth <= 0) return;

    int16_t kid[4];
    const int16_t *kcl = cl;
    if (t[obj].ob_flags & OF_CLIPCHILDREN) {
        int16_t r0 = (int16_t)ax, r1 = (int16_t)ay;
        int16_t r2 = (int16_t)(ax + t[obj].ob_w - 1), r3 = (int16_t)(ay + t[obj].ob_h - 1);
        kid[0] = r0 > cl[0] ? r0 : cl[0];          /* intersect with the parent's clip */
        kid[1] = r1 > cl[1] ? r1 : cl[1];
        kid[2] = r2 < cl[2] ? r2 : cl[2];
        kid[3] = r3 < cl[3] ? r3 : cl[3];
        if (kid[0] > kid[2] || kid[1] > kid[3]) return;   /* empty -> the subtree is invisible */
        vs_clip(g_vh, 1, kid);                           /* PUSH + intersect (see op_clip) */
        kcl = kid;
    }
    EACH_CHILD(t, obj, c) draw_rec(t, c, ax + t[c].ob_x, ay + t[c].ob_y, depth - 1, kcl);
    if (kcl != cl) vs_clip(g_vh, 0, 0);                  /* POP.  Mode 1 would push AND
                                                          * INTERSECT again, leaving the clip
                                                          * still narrowed to this object --
                                                          * every later sibling would vanish. */
}

SCROLLBAR *objc_scrollbar(OBJECT *t, int obj)
{
    uint16_t ty = t[obj].ob_type & 0x00FFu;
    if (ty != G_SCROLL && ty != G_SLIDER) return 0;
    return (SCROLLBAR *)t[obj].ob_spec;
}

/* Pixel position -> value (0..1000) for a G_SCROLL / G_SLIDER, thumb centred on the
 * cursor.  Same geometry the draw code uses, so a drag tracks exactly what is painted. */
int16_t objc_scroll_value(OBJECT *t, int obj, int mx, int my)
{
    SCROLLBAR *s = (SCROLLBAR *)t[obj].ob_spec;
    if (!s) return 0;
    int ax, ay; objc_offset(t, obj, &ax, &ay);
    int w = t[obj].ob_w, h = t[obj].ob_h;
    int scroll = (t[obj].ob_type == G_SCROLL);

    int t0, tlen, thumb;                                  /* track origin, length, thumb size */
    if (s->vert) {
        t0 = ay; tlen = h;
        if (scroll && s->arrows) {
            const theme_slice *a = theme_find(g_th, "vscroll.up");
            const theme_slice *b = theme_find(g_th, "vscroll.down");
            int c0 = a ? a->sh : 0, c1 = b ? b->sh : 0;
            t0 += c0; tlen -= c0 + c1;
        }
        if (scroll) { int p = s->page < 1 ? 1 : s->page;
                      thumb = tlen * p / 1000; if (thumb < 12) thumb = 12; }
        else        { const theme_slice *k = theme_find(g_th, "slider.knob");
                      thumb = k ? k->sh : 16; }
    } else {
        t0 = ax; tlen = w;
        if (scroll && s->arrows) {
            const theme_slice *a = theme_find(g_th, "hscroll.left");
            const theme_slice *b = theme_find(g_th, "hscroll.right");
            int c0 = a ? a->sw : 0, c1 = b ? b->sw : 0;
            t0 += c0; tlen -= c0 + c1;
        }
        if (scroll) { int p = s->page < 1 ? 1 : s->page;
                      thumb = tlen * p / 1000; if (thumb < 12) thumb = 12; }
        else        { const theme_slice *k = theme_find(g_th, "slider.knob");
                      thumb = k ? k->sw : 16; }
    }
    if (thumb > tlen) thumb = tlen;
    int span = tlen - thumb;                              /* travel available to the thumb */
    if (span <= 0) return 0;

    int pos = (s->vert ? my - t0 : mx - t0) - thumb / 2;  /* centre the thumb on the cursor */
    if (pos < 0) pos = 0;
    if (pos > span) pos = span;
    return (int16_t)(pos * 1000 / span);
}

void objc_draw(OBJECT *t, int start, int depth, int clx, int cly, int clw, int clh) {
    int x, y; objc_offset(t, start, &x, &y);
    int16_t clip[4] = { (int16_t)clx, (int16_t)cly, (int16_t)(clx+clw-1), (int16_t)(cly+clh-1) };
    vs_clip(g_vh, 1, clip);
    draw_rec(t, start, x, y, depth, clip);
    vs_clip(g_vh, 0, clip);
}

static int find_rec(OBJECT *t, int obj, int ax, int ay, int depth, int mx, int my) {
    if (t[obj].ob_flags & OF_HIDETREE) return -1;
    int found = -1;
    if (mx >= ax && mx < ax + t[obj].ob_w && my >= ay && my < ay + t[obj].ob_h) {
        found = obj;
        if (depth > 0) EACH_CHILD(t, obj, c) {
            int f = find_rec(t, c, ax + t[c].ob_x, ay + t[c].ob_y, depth - 1, mx, my);
            if (f >= 0) found = f;
        }
    }
    return found;
}
/* middle-ellipsis `text` into out so it fits maxw pixels at the CURRENT
 * vst_height: "A Very Long Filename.xex" -> "A Very...name.xex". Cells are
 * narrow and icon sizes will become user-specifiable, so the width is the
 * caller's. */
void aes_label_fit(int vh, const char *text, int maxw, char *out, int cap)
{
    int16_t ext[8];
    const int flen = (int)strlen(text);
    int len = flen > cap - 1 ? cap - 1 : flen;
    memcpy(out, text, len); out[len] = 0;
    vqt_extent(vh, out, ext);
    if (ext[2] - ext[0] <= maxw || maxw <= 0)
        return;
    for (int keep = len - 1; keep >= 2; keep--) {
        int head = (keep + 1) / 2, tail = keep / 2;
        if (head + 3 + tail > cap - 1) continue;
        memcpy(out, text, head);
        memcpy(out + head, "...", 3);
        memcpy(out + head + 3, text + flen - tail, tail);
        out[head + 3 + tail] = 0;
        vqt_extent(vh, out, ext);
        if (ext[2] - ext[0] <= maxw)
            return;
    }
}

int objc_find(OBJECT *t, int start, int depth, int mx, int my) {
    int x, y; objc_offset(t, start, &x, &y);
    return find_rec(t, start, x, y, depth, mx, my);
}
