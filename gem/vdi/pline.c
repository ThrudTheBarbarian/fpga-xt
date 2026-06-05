// vdi/pline.c — v_pline (polyline; each segment Cohen–Sutherland clipped, with
// optional arrowhead end styles from vsl_ends).

#include "vdi/vdi.h"
#include "vdi/internal.h"
#include <string.h>
#include <math.h>

static double arrow_len(const vdi_ws *w) { return 9 + w->line_width * 2.5; }

// Filled arrowhead with its apex at (tx,ty), pointing away from (fx,fy).
static void arrowhead(const vdi_ws *w, int tx, int ty, int fx, int fy) {
    double dx = tx - fx, dy = ty - fy, len = sqrt(dx*dx + dy*dy);
    if (len < 0.5) return;
    dx /= len; dy /= len;                                // unit dir toward the apex
    double L = arrow_len(w), hw = 4 + w->line_width * 1.2;
    double bx = tx - L * dx, by = ty - L * dy;           // base centre
    double px = -dy, py = dx;                            // perpendicular
    int16_t tri[6] = {
        (int16_t)tx,                  (int16_t)ty,
        (int16_t)lround(bx + px*hw),  (int16_t)lround(by + py*hw),
        (int16_t)lround(bx - px*hw),  (int16_t)lround(by - py*hw) };
    vdi_fill_poly(w, tri, 3, w->line_color, NULL);
}

// 1 for a flat (square) cap, 0 for the round pen.  An arrow end is squared at
// its (shortened) base, which the arrowhead then covers.
static int cap_square(int style) { return style != VDI_LE_ROUND; }

// Move (x,y) toward (tx,ty) by `d` pixels (to pull a line end back to an
// arrowhead base).
static void pull_back(int16_t *x, int16_t *y, int tx, int ty, double d) {
    double dx = tx - *x, dy = ty - *y, len = sqrt(dx*dx + dy*dy);
    if (len < 0.5) return;
    *x = (int16_t)lround(*x + dx / len * d);
    *y = (int16_t)lround(*y + dy / len * d);
}

void op_pline(vdi_pb *pb) {
    if (pb->contrl[5] == VDI_BEZ_SUB) { op_bez(pb, 0); return; }   // v_bez
    vdi_ws *w = vdi_ws_of(pb->contrl[6]); if (!w) return;
    int n = pb->contrl[1]; if (n < 1) return;
    int16_t pts[256];
    for (int i = 0; i < 2*n && i < 256; i++) pts[i] = pb->ptsin[i];   // local, shortened for arrows
    if (n >= 2) {
        double L = arrow_len(w);
        if (w->line_beg == VDI_LE_ARROW) pull_back(&pts[0], &pts[1], pts[2], pts[3], L);
        if (w->line_end == VDI_LE_ARROW) pull_back(&pts[2*n-2], &pts[2*n-1], pts[2*n-4], pts[2*n-3], L);
    }
    for (int i = 1; i < n; i++) {
        int sq0 = (i == 1)     ? cap_square(w->line_beg) : 0;   // interior joins stay round
        int sq1 = (i == n-1)   ? cap_square(w->line_end) : 0;
        vdi_line_ex(w, pts[2*i-2], pts[2*i-1], pts[2*i], pts[2*i+1], w->line_color, sq0, sq1);
    }
    if (n >= 2) {                                          // arrowheads at the real endpoints
        const int16_t *p = pb->ptsin;
        if (w->line_beg == VDI_LE_ARROW) arrowhead(w, p[0], p[1], p[2], p[3]);
        if (w->line_end == VDI_LE_ARROW) arrowhead(w, p[2*n-2], p[2*n-1], p[2*n-4], p[2*n-3]);
    }
}

void v_pline(int handle, int n, const int16_t *pxy) {
    if (n > 128) n = 128;
    memcpy(g_ptsin, pxy, (size_t)n * 2 * sizeof(int16_t));
    vdi_emit(VDI_PLINE, 0, handle, n, 0);
}
