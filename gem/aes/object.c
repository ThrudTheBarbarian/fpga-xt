// aes/object.c — the OBJECT tree renderer + hit-tester.  Each object type maps
// to a theme element (buttons/fields/checks via theme_draw) or a VDI primitive
// (boxes, text), so dialogs are themed without AES knowing any pixels.

#include "aes/aes.h"
#include <string.h>

static int g_vh;
static const theme *g_th;

// scratch pens for box fill / border (set from the theme at init)
enum { PEN_DLG = 248, PEN_BORDER = 249 };

void aes_init(int vh, const theme *th) {
    g_vh = vh; g_th = th;
    v_setrgb(vh, PEN_DLG, 236, 238, 240);
    if (th) v_setrgb(vh, PEN_BORDER, (th->border>>24)&0xFF, (th->border>>16)&0xFF, (th->border>>8)&0xFF);
}

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
int objc_find(OBJECT *t, int start, int depth, int mx, int my) {
    int x, y; objc_offset(t, start, &x, &y);
    return find_rec(t, start, x, y, depth, mx, my);
}
