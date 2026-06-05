// vdi/gdp.c — Generalized Drawing Primitives (VDI_GDP, op 11).  Sub-opcode 1 is
// v_bar (in recfl.c); the rest are curved shapes built as point lists and drawn
// through the shared polygon fill / polyline.  Filled shapes (circle, ellipse,
// pieslice, rfbox, ellpie) use the fill colour + interior + perimeter; arcs and
// v_rbox are line primitives drawn in the line colour.  Angles are tenths of a
// degree, 0 = east, counter-clockwise.

#include "vdi/vdi.h"
#include "vdi/internal.h"
#include <math.h>

#define GDP_MAXPTS 256

// Sample an (elliptical) arc from beg..end (tenths of a degree) into out[].
static int build_arc(int16_t *out, double cx, double cy, double rx, double ry,
                     int beg, int end) {
    double a0 = beg * (M_PI / 1800.0), a1 = end * (M_PI / 1800.0);
    if (a1 <= a0) a1 += 2 * M_PI;
    double span = a1 - a0;
    // ~3px chords, scaled by radius, so the curve stays smooth at any size /
    // line width (too few segments => visible facets, worst at the apex).
    double rr = rx > ry ? rx : ry;
    int segs = (int)(span * rr / 3.0) + 1;
    if (segs < 8) segs = 8; if (segs > GDP_MAXPTS - 2) segs = GDP_MAXPTS - 2;
    int n = 0;
    for (int i = 0; i <= segs && n < GDP_MAXPTS; i++) {
        double a = a0 + span * i / segs;
        out[2*n]   = (int16_t)lround(cx + rx * cos(a));
        out[2*n+1] = (int16_t)lround(cy - ry * sin(a));  // y grows downward => +angle is up
        n++;
    }
    return n;
}

// Build a rounded-rectangle polygon (clockwise).  r<=0 picks a default radius.
static int build_rrect(int16_t *out, int x1, int y1, int x2, int y2, int r) {
    if (x1 > x2) { int t = x1; x1 = x2; x2 = t; }
    if (y1 > y2) { int t = y1; y1 = y2; y2 = t; }
    int w = x2 - x1, h = y2 - y1, rmax = (w < h ? w : h) / 2;
    if (r <= 0) r = (w < h ? w : h) / 6;
    if (r > rmax) r = rmax; if (r < 1) r = 1;
    const struct { int cx, cy, a0, a1; } cor[4] = {
        { x1+r, y1+r, 180,  90 },   // top-left:     left -> top
        { x2-r, y1+r,  90,   0 },   // top-right:    top  -> right
        { x2-r, y2-r, 360, 270 },   // bottom-right: right-> bottom
        { x1+r, y2-r, 270, 180 },   // bottom-left:  bottom->left
    };
    int steps = r / 3 + 2; if (steps < 4) steps = 4; if (steps > 32) steps = 32;
    int n = 0;
    for (int c = 0; c < 4; c++) {
        double a0 = cor[c].a0 * (M_PI/180.0), a1 = cor[c].a1 * (M_PI/180.0);
        for (int i = 0; i <= steps && n < GDP_MAXPTS; i++) {
            double a = a0 + (a1 - a0) * i / steps;
            out[2*n]   = (int16_t)lround(cor[c].cx + r * cos(a));
            out[2*n+1] = (int16_t)lround(cor[c].cy - r * sin(a));
            n++;
        }
    }
    return n;
}

void op_gdp(vdi_pb *pb) {
    int sub = pb->contrl[5];
    if (sub == GDP_BAR)       { op_fillrect(pb);  return; }
    if (sub == GDP_JUSTIFIED) { op_justified(pb); return; }
    if (sub == GDP_BEZ)       { op_bez_onoff(pb); return; }   // v_bez_on/off
    vdi_ws *w = vdi_ws_of(pb->contrl[6]); if (!w) return;

    const int16_t *p = pb->ptsin;
    int cx = p[0], cy = p[1], beg = pb->intin[0], end = pb->intin[1];
    int16_t pts[2 * GDP_MAXPTS];
    int n = 0, filled = 0, closed = 1;

    switch (sub) {
        case GDP_CIRCLE:  n = build_arc(pts, cx, cy, p[2], p[2], 0, 3600); filled = 1; break;
        case GDP_ELLIPSE: n = build_arc(pts, cx, cy, p[2], p[3], 0, 3600); filled = 1; break;
        case GDP_PIE:     n = build_arc(pts, cx, cy, p[2], p[2], beg, end);
                          pts[2*n] = (int16_t)cx; pts[2*n+1] = (int16_t)cy; n++; filled = 1; break;
        case GDP_ELLPIE:  n = build_arc(pts, cx, cy, p[2], p[3], beg, end);
                          pts[2*n] = (int16_t)cx; pts[2*n+1] = (int16_t)cy; n++; filled = 1; break;
        case GDP_ARC:     n = build_arc(pts, cx, cy, p[2], p[2], beg, end); closed = 0; break;
        case GDP_ELLARC:  n = build_arc(pts, cx, cy, p[2], p[3], beg, end); closed = 0; break;
        case GDP_RBOX:    n = build_rrect(pts, p[0], p[1], p[2], p[3], 0); break;
        case GDP_RFBOX:   n = build_rrect(pts, p[0], p[1], p[2], p[3], 0); filled = 1; break;
        default: return;
    }
    if (filled) {
        if (w->fill_interior != VDI_FIS_HOLLOW)
            vdi_fill_poly(w, pts, n, w->fill_color, vdi_fill_mask(w->fill_interior, w->fill_style));
        if (w->fill_perimeter)
            vdi_polyline(w, pts, n, w->fill_color, 1);
    } else {
        vdi_polyline(w, pts, n, w->line_color, closed);
    }
}

// ---- C bindings -----------------------------------------------------------
static void gdp(int sub, int handle, int npts) { vdi_emit(VDI_GDP, sub, handle, npts, 0); }

void v_circle(int handle, int x, int y, int r) {
    g_ptsin[0] = (int16_t)x; g_ptsin[1] = (int16_t)y; g_ptsin[2] = (int16_t)r;
    gdp(GDP_CIRCLE, handle, 2);
}
void v_ellipse(int handle, int x, int y, int rx, int ry) {
    g_ptsin[0] = (int16_t)x; g_ptsin[1] = (int16_t)y; g_ptsin[2] = (int16_t)rx; g_ptsin[3] = (int16_t)ry;
    gdp(GDP_ELLIPSE, handle, 2);
}
static void gdp_arc(int sub, int handle, int x, int y, int rx, int ry, int beg, int end) {
    g_ptsin[0] = (int16_t)x; g_ptsin[1] = (int16_t)y; g_ptsin[2] = (int16_t)rx; g_ptsin[3] = (int16_t)ry;
    g_intin[0] = (int16_t)beg; g_intin[1] = (int16_t)end;
    vdi_emit(VDI_GDP, sub, handle, 2, 2);
}
void v_pieslice(int handle, int x, int y, int r, int beg, int end)            { gdp_arc(GDP_PIE,   handle, x, y, r, r, beg, end); }
void v_ellpie  (int handle, int x, int y, int rx, int ry, int beg, int end)   { gdp_arc(GDP_ELLPIE,handle, x, y, rx, ry, beg, end); }
void v_arc     (int handle, int x, int y, int r, int beg, int end)            { gdp_arc(GDP_ARC,   handle, x, y, r, r, beg, end); }
void v_ellarc  (int handle, int x, int y, int rx, int ry, int beg, int end)   { gdp_arc(GDP_ELLARC,handle, x, y, rx, ry, beg, end); }
void v_rbox(int handle, const int16_t *pxy) {
    for (int i = 0; i < 4; i++) g_ptsin[i] = pxy[i];
    gdp(GDP_RBOX, handle, 2);
}
void v_rfbox(int handle, const int16_t *pxy) {
    for (int i = 0; i < 4; i++) g_ptsin[i] = pxy[i];
    gdp(GDP_RFBOX, handle, 2);
}
