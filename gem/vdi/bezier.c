// vdi/bezier.c — NVDI Bézier extension: v_bez (op 6 sub 13), v_bez_fill (op 9
// sub 13), v_bez_qual (escape 5 sub 99), v_bez_on / v_bez_off (op 11 sub 13).
//
// A Bézier path interleaves anchor and control points in one (x,y) array; a
// parallel byte array flags each point's role:
//   bit 0 (1) — this point is the START anchor of a cubic: it plus the next
//               three points (ctrl, ctrl, end anchor) form one curve; scanning
//               then resumes at that end anchor.
//   bit 1 (2) — pen-up: start a new sub-path (contour) at this point.
// A point with neither bit is an ordinary polyline vertex; the first point is
// an implicit move.  Curves are flattened to polylines (adaptively, to a
// tolerance set by v_bez_qual) and drawn through the shared polyline / polygon
// fillers, so they pick up the current line/fill attributes for free.

#include "vdi/vdi.h"
#include "vdi/internal.h"
#include <math.h>
#include <string.h>

#define BEZ_MAXPTS 1024
#define BEZ_MAXCONT 64

static int g_bez_qual = 100;            // 0..100 %; higher = finer flattening

static double bez_tol(void) {           // 100% -> 0.3px chords, 0% -> ~4px
    int q = g_bez_qual; if (q < 0) q = 0; if (q > 100) q = 100;
    return 0.3 + (100 - q) * 0.037;
}

// Append the cubic p0..p3 (p0 already emitted) to out[], subdividing until the
// control points lie within tol of the chord, or depth runs out.
static void flatten(double x0, double y0, double x1, double y1,
                    double x2, double y2, double x3, double y3,
                    int depth, int16_t *out, int *n) {
    if (*n + 1 >= BEZ_MAXPTS) return;
    double dx = x3 - x0, dy = y3 - y0;
    double d1 = fabs((x1 - x3) * dy - (y1 - y3) * dx);
    double d2 = fabs((x2 - x3) * dy - (y2 - y3) * dx);
    double tol = bez_tol();
    if (depth <= 0 || (d1 + d2) * (d1 + d2) <= tol * tol * (dx * dx + dy * dy)) {
        out[2 * *n] = (int16_t)lround(x3); out[2 * *n + 1] = (int16_t)lround(y3); (*n)++;
        return;
    }
    double x01 = (x0+x1)/2, y01 = (y0+y1)/2, x12 = (x1+x2)/2, y12 = (y1+y2)/2;
    double x23 = (x2+x3)/2, y23 = (y2+y3)/2;
    double xa = (x01+x12)/2, ya = (y01+y12)/2, xb = (x12+x23)/2, yb = (y12+y23)/2;
    double xm = (xa+xb)/2, ym = (ya+yb)/2;
    flatten(x0, y0, x01, y01, xa, ya, xm, ym, depth - 1, out, n);
    flatten(xm, ym, xb, yb, x23, y23, x3, y3, depth - 1, out, n);
}

// Flatten the whole path into out[]; record each contour's start in cstart[].
// Returns the generated point count; *ncont/*nmoves get the contour count.
static int bez_build(vdi_pb *pb, int16_t *out, int *cstart, int *ncont, int *nmoves) {
    int count = pb->contrl[1];
    const int16_t *xy = pb->ptsin;
    int n = 0, nc = 0, i = 0, pen = 0;
    while (i < count) {
        int flag = pb->intin[i] & 0x03;
        int cubic = (flag & 1) && i + 3 < count;
        if ((flag & 2) || !pen) {                       // move: open a contour
            if (n < BEZ_MAXPTS && nc < BEZ_MAXCONT) {
                cstart[nc++] = n;
                out[2*n] = xy[2*i]; out[2*n+1] = xy[2*i+1]; n++;
            }
            pen = 1;
        } else if (!cubic) {                             // plain polyline vertex
            if (n < BEZ_MAXPTS) { out[2*n] = xy[2*i]; out[2*n+1] = xy[2*i+1]; n++; }
        }
        // A cubic's start anchor xy[i] is already emitted (move or previous end);
        // flatten appends the rest and advances to the shared end anchor, whose
        // own flag is then read next iteration (so chained cubics aren't skipped).
        if (cubic) {
            flatten(xy[2*i], xy[2*i+1], xy[2*(i+1)], xy[2*(i+1)+1],
                    xy[2*(i+2)], xy[2*(i+2)+1], xy[2*(i+3)], xy[2*(i+3)+1], 10, out, &n);
            i += 3;
        } else {
            i += 1;
        }
    }
    *ncont = nc; *nmoves = nc;
    return n;
}

// Bounding box of the flattened points into ptsout[0..3]; counts into intout.
static void bez_report(vdi_pb *pb, const int16_t *out, int n, int nmoves) {
    int x0 = 0, y0 = 0, x1 = 0, y1 = 0;
    for (int i = 0; i < n; i++) {
        int x = out[2*i], y = out[2*i+1];
        if (i == 0 || x < x0) x0 = x; if (i == 0 || y < y0) y0 = y;
        if (i == 0 || x > x1) x1 = x; if (i == 0 || y > y1) y1 = y;
    }
    pb->ptsout[0] = (int16_t)x0; pb->ptsout[1] = (int16_t)y0;
    pb->ptsout[2] = (int16_t)x1; pb->ptsout[3] = (int16_t)y1;
    pb->intout[0] = (int16_t)n;          // total generated points
    pb->intout[1] = (int16_t)nmoves;     // total contours / moves
}

// op_bez: fill==0 stroke, fill==1 fill.  Called from op_pline / op_fillarea
// when contrl[5] == VDI_BEZ_SUB.
void op_bez(vdi_pb *pb, int fill) {
    vdi_ws *w = vdi_ws_of(pb->contrl[6]); if (!w) return;
    static int16_t out[2 * BEZ_MAXPTS];
    int cstart[BEZ_MAXCONT], nc = 0, nmoves = 0;
    int n = bez_build(pb, out, cstart, &nc, &nmoves);
    for (int c = 0; c < nc; c++) {
        int s = cstart[c], e = (c + 1 < nc) ? cstart[c + 1] : n, cn = e - s;
        if (cn < 2) continue;
        if (fill) {
            if (w->fill_interior != VDI_FIS_HOLLOW)
                vdi_fill_poly(w, out + 2*s, cn, w->fill_color,
                              vdi_fill_mask(w->fill_interior, w->fill_style));
            if (w->fill_perimeter) vdi_polyline(w, out + 2*s, cn, w->fill_color, 1);
        } else {
            vdi_polyline(w, out + 2*s, cn, w->line_color, 0);
        }
    }
    bez_report(pb, out, n, nmoves);
}

// op_bez_qual: escape 5 sub 99 — set the flattening quality (intin[0] = %).
void op_bez_qual(vdi_pb *pb) {
    if (pb->contrl[5] != ESC_BEZ_QUAL) return;
    int q = pb->intin[0]; if (q < 0) q = 0; if (q > 100) q = 100;
    g_bez_qual = q;
    pb->intout[0] = (int16_t)q;
}

// op_bez_onoff: op 11 sub 13 — enable/return Bézier capability.  Beziers are
// always available here; v_bez_on returns a nonzero quality-level count.
void op_bez_onoff(vdi_pb *pb) {
    pb->intout[0] = 7;                   // levels of quality available
    pb->ptsout[0] = 0;
}

// ===========================================================================
// C bindings
// ===========================================================================
static void bez_emit(int op, int handle, int count, const int16_t *xy, const uint8_t *bez,
                     int16_t *extent, int *totpts, int *totmoves) {
    if (count > 128) count = 128;
    memcpy(g_ptsin, xy, (size_t)count * 2 * sizeof(int16_t));
    for (int i = 0; i < count; i++) g_intin[i] = bez[i];
    vdi_emit(op, VDI_BEZ_SUB, handle, count, count);
    if (extent) for (int i = 0; i < 4; i++) extent[i] = g_ptsout[i];
    if (totpts)   *totpts   = g_intout[0];
    if (totmoves) *totmoves = g_intout[1];
}
void v_bez(int handle, int count, const int16_t *xy, const uint8_t *bez,
           int16_t *extent, int *totpts, int *totmoves) {
    bez_emit(VDI_PLINE, handle, count, xy, bez, extent, totpts, totmoves);
}
void v_bez_fill(int handle, int count, const int16_t *xy, const uint8_t *bez,
                int16_t *extent, int *totpts, int *totmoves) {
    bez_emit(VDI_FILLAREA, handle, count, xy, bez, extent, totpts, totmoves);
}
int v_bez_qual(int handle, int percent, int16_t *set) {
    g_intin[0] = (int16_t)percent;
    vdi_emit(VDI_ESCAPE, ESC_BEZ_QUAL, handle, 0, 1);
    if (set) set[0] = g_intout[0];
    return g_intout[0];
}
int  v_bez_on(int handle)  { vdi_emit(VDI_GDP, GDP_BEZ, handle, 0, 0); return g_intout[0]; }
void v_bez_off(int handle) { vdi_emit(VDI_GDP, GDP_BEZ, handle, 0, 0); }
