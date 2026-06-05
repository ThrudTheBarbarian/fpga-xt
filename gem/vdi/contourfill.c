// vdi/contourfill.c — v_contourfill: a 4-connected seed (flood) fill from
// (x,y), in the workstation fill colour, clipped to the workstation clip rect.
//   index >= 0 : boundary fill — spread over pixels that are NOT the boundary
//                pen's colour, stopping at it.
//   index <  0 : flood the connected region matching the seed pixel's colour.
// Scanline algorithm with a growable span stack.

#include "vdi/vdi.h"
#include "vdi/internal.h"
#include <stdlib.h>

typedef struct { int x, y; } seed;

void op_contourfill(vdi_pb *pb) {
    vdi_ws *w = vdi_ws_of(pb->contrl[6]); if (!w || !w->target) return;
    int sx = pb->ptsin[0], sy = pb->ptsin[1], index = pb->intin[0];
    int cx0, cy0, cx1, cy1; vdi_ws_clip(w, &cx0, &cy0, &cx1, &cy1);
    if (sx < cx0 || sx > cx1 || sy < cy0 || sy > cy1) return;

    gfx_surface *s = w->target;
    uint32_t fill = vdi_pen_rgba(w->fill_color);
    uint32_t seedc = s->px[(size_t)sy * s->stride + sx];
    int boundary = index >= 0;
    uint32_t ref = boundary ? vdi_pen_rgba(index) : seedc;
    if (boundary) { if (seedc == ref || fill == ref) return; }   // can't fill
    else          { if (fill == seedc) return; }                 // nothing to do
    #define MATCH(p) (boundary ? ((p) != ref) : ((p) == ref))
    #define PX(x,y)  s->px[(size_t)(y) * s->stride + (x)]

    int cap = 1024, sp = 0;
    seed *stk = malloc((size_t)cap * sizeof *stk);
    if (!stk) return;
    stk[sp++] = (seed){ sx, sy };
    while (sp > 0) {
        seed pt = stk[--sp];
        int x = pt.x, y = pt.y;
        if (!(MATCH(PX(x,y)) && PX(x,y) != fill)) continue;
        int xl = x; while (xl > cx0 && MATCH(PX(xl-1,y)) && PX(xl-1,y) != fill) xl--;
        int xr = x; while (xr < cx1 && MATCH(PX(xr+1,y)) && PX(xr+1,y) != fill) xr++;
        for (int i = xl; i <= xr; i++) PX(i,y) = fill;
        for (int ny = y - 1; ny <= y + 1; ny += 2) {
            if (ny < cy0 || ny > cy1) continue;
            int i = xl;
            while (i <= xr) {
                while (i <= xr && !(MATCH(PX(i,ny)) && PX(i,ny) != fill)) i++;
                if (i > xr) break;
                if (sp == cap) { cap *= 2; seed *t = realloc(stk, (size_t)cap * sizeof *stk);
                                 if (!t) { free(stk); return; } stk = t; }
                stk[sp++] = (seed){ i, ny };
                while (i <= xr && MATCH(PX(i,ny)) && PX(i,ny) != fill) i++;
            }
        }
    }
    free(stk);
    #undef MATCH
    #undef PX
}

void v_contourfill(int handle, int x, int y, int index) {
    g_ptsin[0] = (int16_t)x; g_ptsin[1] = (int16_t)y;
    g_intin[0] = (int16_t)index;
    vdi_emit(VDI_CONTOURFILL, 0, handle, 1, 1);
}
