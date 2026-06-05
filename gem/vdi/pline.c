// vdi/pline.c — v_pline (polyline; each segment Cohen–Sutherland clipped, with
// optional arrowhead end styles from vsl_ends).

#include "vdi/vdi.h"
#include "vdi/internal.h"
#include <string.h>
#include <math.h>

// Filled round cap (disc) at an endpoint.  The round pen already rounds thick
// lines; this makes the rounded end explicit and visible on thin ones too.
static void round_cap(const vdi_ws *w, int cx, int cy) {
    double r = w->line_width / 2.0 + 1.0;
    int16_t pts[2 * 16];
    for (int i = 0; i < 16; i++) {
        double a = i * (2.0 * M_PI / 16.0);
        pts[2*i]   = (int16_t)lround(cx + r * cos(a));
        pts[2*i+1] = (int16_t)lround(cy + r * sin(a));
    }
    vdi_fill_poly(w, pts, 16, w->line_color, NULL);
}

// Filled arrowhead with its apex at (tx,ty), pointing away from (fx,fy).
static void arrowhead(const vdi_ws *w, int tx, int ty, int fx, int fy) {
    double dx = tx - fx, dy = ty - fy, len = sqrt(dx*dx + dy*dy);
    if (len < 0.5) return;
    dx /= len; dy /= len;                                // unit dir toward the apex
    double L = 9 + w->line_width * 2.5, hw = 4 + w->line_width * 1.2;
    double bx = tx - L * dx, by = ty - L * dy;           // base centre
    double px = -dy, py = dx;                            // perpendicular
    int16_t tri[6] = {
        (int16_t)tx,                  (int16_t)ty,
        (int16_t)lround(bx + px*hw),  (int16_t)lround(by + py*hw),
        (int16_t)lround(bx - px*hw),  (int16_t)lround(by - py*hw) };
    vdi_fill_poly(w, tri, 3, w->line_color, NULL);
}

void op_pline(vdi_pb *pb) {
    vdi_ws *w = vdi_ws_of(pb->contrl[6]); if (!w) return;
    int n = pb->contrl[1];
    for (int i = 1; i < n; i++)
        vdi_line(w, pb->ptsin[2*i-2], pb->ptsin[2*i-1],
                    pb->ptsin[2*i],   pb->ptsin[2*i+1], w->line_color);
    if (n >= 2) {
        const int16_t *p = pb->ptsin;
        if (w->line_beg == VDI_LE_ARROW) arrowhead(w, p[0], p[1], p[2], p[3]);
        else if (w->line_beg == VDI_LE_ROUND) round_cap(w, p[0], p[1]);
        if (w->line_end == VDI_LE_ARROW) arrowhead(w, p[2*n-2], p[2*n-1], p[2*n-4], p[2*n-3]);
        else if (w->line_end == VDI_LE_ROUND) round_cap(w, p[2*n-2], p[2*n-1]);
    }
}

void v_pline(int handle, int n, const int16_t *pxy) {
    if (n > 128) n = 128;
    memcpy(g_ptsin, pxy, (size_t)n * 2 * sizeof(int16_t));
    vdi_emit(VDI_PLINE, 0, handle, n, 0);
}
