// vdi.c — portable GEM VDI implementation (first slice).  See vdi.h.

#include "vdi.h"
#include <stddef.h>
#include <string.h>

// ---- Workstations ---------------------------------------------------------
#define VDI_MAX_WS 16

typedef struct {
    int          used;
    gfx_surface *target;
    int          line_color;       // pen
    int          fill_color;       // pen
    int          fill_interior;    // 0 hollow, 1 solid
    int          clip_on;
    int          cx0, cy0, cx1, cy1;   // clip rect, inclusive
} vdi_ws;

static vdi_ws   ws_tab[VDI_MAX_WS];
static uint32_t pen_tab[256];

static vdi_ws *ws_of(int handle) {
    if (handle < 1 || handle > VDI_MAX_WS) return NULL;
    vdi_ws *w = &ws_tab[handle - 1];
    return w->used ? w : NULL;
}

// Effective clip rect for a workstation (clip rect ∩ surface), inclusive.
static void ws_clip(const vdi_ws *w, int *x0, int *y0, int *x1, int *y1) {
    *x0 = 0; *y0 = 0; *x1 = w->target->w - 1; *y1 = w->target->h - 1;
    if (w->clip_on) {
        if (w->cx0 > *x0) *x0 = w->cx0;
        if (w->cy0 > *y0) *y0 = w->cy0;
        if (w->cx1 < *x1) *x1 = w->cx1;
        if (w->cy1 < *y1) *y1 = w->cy1;
    }
}

// ---- Pen palette (16 standard VDI colours; rest left black for now) -------
static void pen_init(void) {
    static const uint32_t vdi16[16] = {
        GFX_RGB(0xff,0xff,0xff), GFX_RGB(0x00,0x00,0x00), // 0 white, 1 black
        GFX_RGB(0xff,0x00,0x00), GFX_RGB(0x00,0xff,0x00), // 2 red,   3 green
        GFX_RGB(0x00,0x00,0xff), GFX_RGB(0x00,0xff,0xff), // 4 blue,  5 cyan
        GFX_RGB(0xff,0xff,0x00), GFX_RGB(0xff,0x00,0xff), // 6 yellow,7 magenta
        GFX_RGB(0xc0,0xc0,0xc0), GFX_RGB(0x80,0x80,0x80), // 8 ltgrey,9 grey
        GFX_RGB(0x80,0x00,0x00), GFX_RGB(0x00,0x80,0x00), // 10 dk red, 11 dk grn
        GFX_RGB(0x00,0x00,0x80), GFX_RGB(0x00,0x80,0x80), // 12 dk blue,13 dk cyan
        GFX_RGB(0x80,0x80,0x00), GFX_RGB(0x80,0x00,0x80), // 14 dk yel, 15 dk mag
    };
    for (int i = 0; i < 256; i++) pen_tab[i] = (i < 16) ? vdi16[i] : GFX_RGB(0,0,0);
}

uint32_t vdi_pen_rgba(int pen) { return pen_tab[pen & 0xFF]; }

void vdi_init(gfx_surface *default_target) {
    memset(ws_tab, 0, sizeof(ws_tab));
    pen_init();
    // Workstation handle 1 is the "physical" screen workstation on the default
    // target, so the WM can draw without an explicit open.
    ws_tab[0].used = 1;
    ws_tab[0].target = default_target;
    ws_tab[0].line_color = 1; ws_tab[0].fill_color = 1; ws_tab[0].fill_interior = 1;
    ws_tab[0].clip_on = 0;
}

// ---- Clipped primitives ---------------------------------------------------
static void fill_rect_clipped(const vdi_ws *w, int x0, int y0, int x1, int y1, int pen) {
    if (x0 > x1) { int t = x0; x0 = x1; x1 = t; }
    if (y0 > y1) { int t = y0; y0 = y1; y1 = t; }
    int cx0, cy0, cx1, cy1; ws_clip(w, &cx0, &cy0, &cx1, &cy1);
    if (x0 < cx0) x0 = cx0; if (y0 < cy0) y0 = cy0;
    if (x1 > cx1) x1 = cx1; if (y1 > cy1) y1 = cy1;
    if (x0 > x1 || y0 > y1) return;
    gfx_fill_rect(w->target, x0, y0, x1 - x0 + 1, y1 - y0 + 1, pen_tab[pen & 0xFF]);
}

// Cohen–Sutherland line clip to [cx0,cy0]-[cx1,cy1] (inclusive).
static int cs_code(int x, int y, int cx0, int cy0, int cx1, int cy1) {
    int c = 0;
    if (x < cx0) c |= 1; else if (x > cx1) c |= 2;
    if (y < cy0) c |= 4; else if (y > cy1) c |= 8;
    return c;
}
static void line_clipped(const vdi_ws *w, int x0, int y0, int x1, int y1, int pen) {
    int cx0, cy0, cx1, cy1; ws_clip(w, &cx0, &cy0, &cx1, &cy1);
    int c0 = cs_code(x0, y0, cx0, cy0, cx1, cy1);
    int c1 = cs_code(x1, y1, cx0, cy0, cx1, cy1);
    for (;;) {
        if (!(c0 | c1)) break;            // both inside
        if (c0 & c1) return;              // trivially outside
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

// ---- Opcode handlers ------------------------------------------------------
static void op_opnvwk(vdi_pb *pb) {
    int h = 0;
    for (int i = 1; i < VDI_MAX_WS; i++)        // slot 0 reserved (physical)
        if (!ws_tab[i].used) { h = i + 1; break; }
    if (h) {
        vdi_ws *w = &ws_tab[h - 1];
        memset(w, 0, sizeof(*w));
        w->used = 1; w->line_color = 1; w->fill_color = 1; w->fill_interior = 1;
    }
    pb->contrl[6] = (int16_t)h;                 // return handle
}
static void op_clsvwk(vdi_pb *pb) {
    vdi_ws *w = ws_of(pb->contrl[6]);
    if (w && (w - ws_tab) != 0) w->used = 0;    // never close the physical ws
}
static void op_sl_color(vdi_pb *pb)    { vdi_ws *w = ws_of(pb->contrl[6]); if (w) w->line_color = pb->intin[0]; }
static void op_sf_color(vdi_pb *pb)    { vdi_ws *w = ws_of(pb->contrl[6]); if (w) w->fill_color = pb->intin[0]; }
static void op_sf_interior(vdi_pb *pb) { vdi_ws *w = ws_of(pb->contrl[6]); if (w) w->fill_interior = pb->intin[0]; }

static void op_clip(vdi_pb *pb) {
    vdi_ws *w = ws_of(pb->contrl[6]); if (!w) return;
    w->clip_on = pb->intin[0] ? 1 : 0;
    if (w->clip_on) {
        int x0 = pb->ptsin[0], y0 = pb->ptsin[1], x1 = pb->ptsin[2], y1 = pb->ptsin[3];
        w->cx0 = x0 < x1 ? x0 : x1; w->cx1 = x0 < x1 ? x1 : x0;
        w->cy0 = y0 < y1 ? y0 : y1; w->cy1 = y0 < y1 ? y1 : y0;
    }
}
static void op_pline(vdi_pb *pb) {
    vdi_ws *w = ws_of(pb->contrl[6]); if (!w) return;
    int n = pb->contrl[1];
    for (int i = 1; i < n; i++)
        line_clipped(w, pb->ptsin[2*i-2], pb->ptsin[2*i-1],
                        pb->ptsin[2*i],   pb->ptsin[2*i+1], w->line_color);
}
static void op_fillrect(vdi_pb *pb) {   // vr_recfl + v_bar (GDP sub 1)
    vdi_ws *w = ws_of(pb->contrl[6]); if (!w || !w->fill_interior) return;
    fill_rect_clipped(w, pb->ptsin[0], pb->ptsin[1], pb->ptsin[2], pb->ptsin[3], w->fill_color);
}

void vdi_call(vdi_pb *pb) {
    switch (pb->contrl[0]) {
        case VDI_OPNVWK:      op_opnvwk(pb);     break;
        case VDI_CLSVWK:      op_clsvwk(pb);     break;
        case VDI_SL_COLOR:    op_sl_color(pb);   break;
        case VDI_SF_COLOR:    op_sf_color(pb);   break;
        case VDI_SF_INTERIOR: op_sf_interior(pb);break;
        case VDI_CLIP:        op_clip(pb);       break;
        case VDI_PLINE:       op_pline(pb);      break;
        case VDI_RECFL:       op_fillrect(pb);   break;
        case VDI_GDP:         if (pb->contrl[5] == 1) op_fillrect(pb); break;  // v_bar
        default: break;       // unimplemented opcode -> no-op (logged later)
    }
}

// ---- C binding (shared arrays + the dispatcher) ---------------------------
static int16_t g_contrl[16], g_intin[128], g_ptsin[256], g_intout[128], g_ptsout[256];
static vdi_pb  g_pb = { g_contrl, g_intin, g_ptsin, g_intout, g_ptsout };

static void call(int op, int sub, int handle, int npts, int nint) {
    g_contrl[0] = (int16_t)op;  g_contrl[1] = (int16_t)npts;
    g_contrl[3] = (int16_t)nint; g_contrl[5] = (int16_t)sub;
    g_contrl[6] = (int16_t)handle;
    vdi_call(&g_pb);
}

int v_opnvwk(gfx_surface *target) {
    call(VDI_OPNVWK, 0, 0, 0, 0);
    int h = g_contrl[6];
    vdi_ws *w = ws_of(h);
    if (w) w->target = target;          // bind target (WM does this for real apps)
    return h;
}
void v_clsvwk(int handle) { call(VDI_CLSVWK, 0, handle, 0, 0); }
void vsl_color(int handle, int pen)      { g_intin[0] = (int16_t)pen;   call(VDI_SL_COLOR, 0, handle, 0, 1); }
void vsf_color(int handle, int pen)      { g_intin[0] = (int16_t)pen;   call(VDI_SF_COLOR, 0, handle, 0, 1); }
void vsf_interior(int handle, int style) { g_intin[0] = (int16_t)style; call(VDI_SF_INTERIOR, 0, handle, 0, 1); }
void v_pline(int handle, int n, const int16_t *pxy) {
    if (n > 128) n = 128;
    memcpy(g_ptsin, pxy, (size_t)n * 2 * sizeof(int16_t));
    call(VDI_PLINE, 0, handle, n, 0);
}
void v_bar(int handle, const int16_t *pxy) {
    memcpy(g_ptsin, pxy, 4 * sizeof(int16_t));
    call(VDI_GDP, 1, handle, 2, 0);
}
void vr_recfl(int handle, const int16_t *pxy) {
    memcpy(g_ptsin, pxy, 4 * sizeof(int16_t));
    call(VDI_RECFL, 0, handle, 2, 0);
}
void vs_clip(int handle, int on, const int16_t *pxy) {
    g_intin[0] = (int16_t)(on ? 1 : 0);
    memcpy(g_ptsin, pxy, 4 * sizeof(int16_t));
    call(VDI_CLIP, 0, handle, 2, 1);
}
