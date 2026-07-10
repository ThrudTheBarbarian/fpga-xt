// aes/object.c — the OBJECT tree renderer + hit-tester.  Each object type maps
// to a theme element (buttons/fields/checks via theme_draw) or a VDI primitive
// (boxes, text), so dialogs are themed without AES knowing any pixels.

#include "aes/aes.h"
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

static void draw_obj(OBJECT *o, int x, int y) {
    int w = o->ob_w, h = o->ob_h, st = o->ob_state, fl = o->ob_flags;
    const char *txt = (const char *)o->ob_spec;
    switch (o->ob_type) {
        case G_BOX: case G_BOXTEXT:
            box(x, y, w, h, 1);
            if (o->ob_type == G_BOXTEXT && txt) centered(txt, x, y, w, h, 1, 0);
            break;
        case G_IBOX: break;                                     // invisible container
        case G_BUTTON: {
            int def = fl & OF_DEFAULT;
            const char *v = (st & OS_DISABLED)         ? "button.disabled"
                          : def && (st & OS_SELECTED)  ? "button.default.pressed"
                          : def                        ? "button.default"
                          : (st & OS_SELECTED)         ? "button.selected" : "button";
            theme_draw(g_vh, g_th, v, x, y, w, h);
            centered(txt ? txt : "", x, y, w, h, def ? 0 : (st & OS_DISABLED) ? 9 : 1, def);
            break;
        }
        case G_CHECKBOX: {
            const char *v = (st & OS_SELECTED) ? "check.selected" : "check";
            const theme_slice *s = theme_find(g_th, v);
            int bs = s ? s->sh : 16;
            theme_draw(g_vh, g_th, v, x, y + (h-bs)/2, bs, bs);
            if (txt) { vst_color(g_vh,1); vst_height(g_vh,14,0,0,0,0); v_gtext(g_vh, x+bs+8, y+h/2-7, txt); }
            break;
        }
        case G_RADIO: {
            const char *v = (st & OS_SELECTED) ? "radio.selected" : "radio";
            const theme_slice *s = theme_find(g_th, v);
            int bs = s ? s->sh : 16;
            theme_draw(g_vh, g_th, v, x, y + (h-bs)/2, bs, bs);
            if (txt) { vst_color(g_vh,1); vst_height(g_vh,14,0,0,0,0); v_gtext(g_vh, x+bs+8, y+h/2-7, txt); }
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
        case G_STRING: case G_TITLE:
            if (txt) { vst_color(g_vh, (st & OS_DISABLED) ? 9 : 1); vst_height(g_vh,14,0,0,0,0);
                       v_gtext(g_vh, x, y + h/2 - 7, txt); }
            break;
        case G_TEXT: case G_FTEXT:
            if (txt) { vst_color(g_vh,1); vst_height(g_vh,14,0,0,0,0); v_gtext(g_vh, x, y, txt); }
            break;
        default: break;
    }
}

static void draw_rec(OBJECT *t, int obj, int ax, int ay, int depth) {
    if (t[obj].ob_flags & OF_HIDETREE) return;
    draw_obj(&t[obj], ax, ay);
    if (depth > 0) EACH_CHILD(t, obj, c) draw_rec(t, c, ax + t[c].ob_x, ay + t[c].ob_y, depth - 1);
}

void objc_draw(OBJECT *t, int start, int depth, int clx, int cly, int clw, int clh) {
    int x, y; objc_offset(t, start, &x, &y);
    int16_t clip[4] = { (int16_t)clx, (int16_t)cly, (int16_t)(clx+clw-1), (int16_t)(cly+clh-1) };
    vs_clip(g_vh, 1, clip);
    draw_rec(t, start, x, y, depth);
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
