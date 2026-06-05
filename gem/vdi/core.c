// vdi/core.c — VDI workstation table, pen palette, clipped primitives, the
// dispatcher, and the shared C-binding scratch.  The individual opcodes live in
// vdi/<call>.c; this file is the shared spine they hang off.

#include "vdi/vdi.h"
#include "vdi/internal.h"
#include <stddef.h>
#include <string.h>

// ---- Workstations ---------------------------------------------------------
static vdi_ws   ws_tab[VDI_MAX_WS];
static uint32_t pen_tab[256];

vdi_ws *vdi_ws_of(int handle) {
    if (handle < 1 || handle > VDI_MAX_WS) return NULL;
    vdi_ws *w = &ws_tab[handle - 1];
    return w->used ? w : NULL;
}
int vdi_ws_alloc(void) {
    for (int i = 1; i < VDI_MAX_WS; i++) if (!ws_tab[i].used) {   // slot 0 = physical
        memset(&ws_tab[i], 0, sizeof(ws_tab[i]));
        ws_tab[i].used = 1; ws_tab[i].line_color = 1;
        ws_tab[i].fill_color = 1; ws_tab[i].text_color = 1; ws_tab[i].fill_interior = 1;
        ws_tab[i].text_valign = VDI_TA_TOP;
        return i + 1;
    }
    return 0;
}
void vdi_ws_free(int handle) {
    vdi_ws *w = vdi_ws_of(handle);
    if (w && (w - ws_tab) != 0) w->used = 0;
}

// Effective clip rect: ws clip ∩ surface, inclusive.
void vdi_ws_clip(const vdi_ws *w, int *x0, int *y0, int *x1, int *y1) {
    *x0 = 0; *y0 = 0; *x1 = w->target->w - 1; *y1 = w->target->h - 1;
    if (w->clip_on) {
        if (w->cx0 > *x0) *x0 = w->cx0;
        if (w->cy0 > *y0) *y0 = w->cy0;
        if (w->cx1 < *x1) *x1 = w->cx1;
        if (w->cy1 < *y1) *y1 = w->cy1;
    }
}

// ---- Pen palette ----------------------------------------------------------
static void pen_init(void) {
    static const uint32_t vdi16[16] = {
        GFX_RGB(0xff,0xff,0xff), GFX_RGB(0x00,0x00,0x00),   // 0 white, 1 black
        GFX_RGB(0xff,0x00,0x00), GFX_RGB(0x00,0xff,0x00),   // 2 red,   3 green
        GFX_RGB(0x00,0x00,0xff), GFX_RGB(0x00,0xff,0xff),   // 4 blue,  5 cyan
        GFX_RGB(0xff,0xff,0x00), GFX_RGB(0xff,0x00,0xff),   // 6 yellow,7 magenta
        GFX_RGB(0xc0,0xc0,0xc0), GFX_RGB(0x80,0x80,0x80),   // 8 ltgrey,9 grey
        GFX_RGB(0x80,0x00,0x00), GFX_RGB(0x00,0x80,0x00),   // 10 dkred, 11 dkgrn
        GFX_RGB(0x00,0x00,0x80), GFX_RGB(0x00,0x80,0x80),   // 12 dkblue,13 dkcyan
        GFX_RGB(0x80,0x80,0x00), GFX_RGB(0x80,0x00,0x80),   // 14 dkyel, 15 dkmag
    };
    for (int i = 0; i < 256; i++) pen_tab[i] = (i < 16) ? vdi16[i] : GFX_RGB(0,0,0);
}
uint32_t vdi_pen_rgba(int pen) { return pen_tab[pen & 0xFF]; }

// ---- Clipped primitives ---------------------------------------------------
void vdi_fill_rect(const vdi_ws *w, int x0, int y0, int x1, int y1, int pen) {
    if (x0 > x1) { int t = x0; x0 = x1; x1 = t; }
    if (y0 > y1) { int t = y0; y0 = y1; y1 = t; }
    int cx0, cy0, cx1, cy1; vdi_ws_clip(w, &cx0, &cy0, &cx1, &cy1);
    if (x0 < cx0) x0 = cx0; if (y0 < cy0) y0 = cy0;
    if (x1 > cx1) x1 = cx1; if (y1 > cy1) y1 = cy1;
    if (x0 > x1 || y0 > y1) return;
    gfx_fill_rect(w->target, x0, y0, x1 - x0 + 1, y1 - y0 + 1, pen_tab[pen & 0xFF]);
}
static int cs_code(int x, int y, int cx0, int cy0, int cx1, int cy1) {
    int c = 0;
    if (x < cx0) c |= 1; else if (x > cx1) c |= 2;
    if (y < cy0) c |= 4; else if (y > cy1) c |= 8;
    return c;
}
void vdi_line(const vdi_ws *w, int x0, int y0, int x1, int y1, int pen) {
    int cx0, cy0, cx1, cy1; vdi_ws_clip(w, &cx0, &cy0, &cx1, &cy1);
    int c0 = cs_code(x0, y0, cx0, cy0, cx1, cy1);
    int c1 = cs_code(x1, y1, cx0, cy0, cx1, cy1);
    for (;;) {
        if (!(c0 | c1)) break;
        if (c0 & c1) return;
        int co = c0 ? c0 : c1, x = 0, y = 0;
        if (co & 8)      { x = x0 + (x1 - x0) * (cy1 - y0) / (y1 - y0); y = cy1; }
        else if (co & 4) { x = x0 + (x1 - x0) * (cy0 - y0) / (y1 - y0); y = cy0; }
        else if (co & 2) { y = y0 + (y1 - y0) * (cx1 - x0) / (x1 - x0); x = cx1; }
        else             { y = y0 + (y1 - y0) * (cx0 - x0) / (x1 - x0); x = cx0; }
        if (co == c0) { x0 = x; y0 = y; c0 = cs_code(x0, y0, cx0, cy0, cx1, cy1); }
        else          { x1 = x; y1 = y; c1 = cs_code(x1, y1, cx0, cy0, cx1, cy1); }
    }
    gfx_line(w->target, x0, y0, x1, y1, pen_tab[pen & 0xFF]);
}

// ---- MFDB -----------------------------------------------------------------
void mfdb_from_surface(MFDB *m, gfx_surface *s) {
    m->addr = s->px; m->w = (int16_t)s->w; m->h = (int16_t)s->h; m->stride = (int16_t)s->stride;
}
const MFDB *g_cpyfm_src, *g_cpyfm_dst;
gfx_surface vdi_mfdb_surf(const MFDB *m, const vdi_ws *w) {
    if (!m || !m->addr) return *w->target;
    gfx_surface s = { m->w, m->h, m->stride, m->addr };
    return s;
}

// ---- Init + dispatch ------------------------------------------------------
void vdi_init(gfx_surface *default_target) {
    memset(ws_tab, 0, sizeof(ws_tab));
    pen_init();
    ws_tab[0].used = 1; ws_tab[0].target = default_target;     // handle 1 = physical
    ws_tab[0].line_color = 1; ws_tab[0].fill_color = 1;
    ws_tab[0].text_color = 1; ws_tab[0].fill_interior = 1;
    ws_tab[0].text_valign = VDI_TA_TOP;
}

font_face *g_default_face;
void vdi_set_face(font_face *face) { g_default_face = face; }

// The sized font a workstation draws text with: its own (set by vst_height/
// vst_point), else the default face at the default size.
font *vdi_ws_font(const vdi_ws *w) {
    if (w->text_font) return w->text_font;
    return g_default_face ? font_at(g_default_face, VDI_TEXT_PX_DEFAULT) : NULL;
}

void vdi_call(vdi_pb *pb) {
    switch (pb->contrl[0]) {
        case VDI_OPNVWK:      op_opnvwk(pb);     break;
        case VDI_CLSVWK:      op_clsvwk(pb);     break;
        case VDI_SL_COLOR:    op_sl_color(pb);   break;
        case VDI_ST_COLOR:    op_st_color(pb);   break;
        case VDI_ST_HEIGHT:   op_st_height(pb);  break;
        case VDI_ST_POINT:    op_st_point(pb);   break;
        case VDI_ST_ALIGN:    op_st_alignment(pb);break;
        case VDI_SF_COLOR:    op_sf_color(pb);   break;
        case VDI_SF_INTERIOR: op_sf_interior(pb);break;
        case VDI_CLIP:        op_clip(pb);       break;
        case VDI_PLINE:       op_pline(pb);      break;
        case VDI_GTEXT:       op_gtext(pb);      break;
        case VDI_RECFL:       op_fillrect(pb);   break;
        case VDI_CPYFM:       op_cpyfm(pb);      break;
        case VDI_GDP:         if (pb->contrl[5] == 1) op_fillrect(pb); break;  // v_bar
        default: break;       // unimplemented opcode -> no-op
    }
}

// ---- Shared C-binding scratch ---------------------------------------------
int16_t g_contrl[16], g_intin[128], g_ptsin[256], g_intout[128], g_ptsout[256];
vdi_pb  g_pb = { g_contrl, g_intin, g_ptsin, g_intout, g_ptsout };

void vdi_emit(int op, int sub, int handle, int npts, int nint) {
    g_contrl[0] = (int16_t)op;   g_contrl[1] = (int16_t)npts;
    g_contrl[3] = (int16_t)nint; g_contrl[5] = (int16_t)sub;
    g_contrl[6] = (int16_t)handle;
    vdi_call(&g_pb);
}
