// vdi/clip.c — vs_clip (set / clear the workstation clip rectangle).

#include "vdi/vdi.h"
#include "vdi/internal.h"

// vs_clip is now a NESTING stack: ON pushes the current clip and sets the active
// clip to (new rect ∩ current); OFF pops (restores the clip that was active before
// the matching ON); mode 2 resets to no-clip + empty stack.  Backward-compatible
// with balanced ON/OFF pairs (a top-level pair still ends at no-clip), but nested
// pairs now intersect and restore instead of the inner OFF disabling clipping
// wholesale — which is what damage-rect redraw needs.
void op_clip(vdi_pb *pb) {
    vdi_ws *w = vdi_ws_of(pb->contrl[6]); if (!w) return;
    int mode = pb->intin[0];
    if (mode == 2) { w->clip_sp = 0; w->clip_on = 0; return; }   // hard reset
    if (mode) {                                                  // ON: push + intersect
        if (w->clip_sp < 16) {
            int *s = w->clip_stk[w->clip_sp++];
            s[0] = w->clip_on; s[1] = w->cx0; s[2] = w->cy0; s[3] = w->cx1; s[4] = w->cy1;
        }
        int x0 = pb->ptsin[0], y0 = pb->ptsin[1], x1 = pb->ptsin[2], y1 = pb->ptsin[3];
        int nx0 = x0<x1?x0:x1, nx1 = x0<x1?x1:x0, ny0 = y0<y1?y0:y1, ny1 = y0<y1?y1:y0;
        if (w->clip_on) {                                        // ∩ the current clip
            if (w->cx0 > nx0) nx0 = w->cx0; if (w->cy0 > ny0) ny0 = w->cy0;
            if (w->cx1 < nx1) nx1 = w->cx1; if (w->cy1 < ny1) ny1 = w->cy1;
        }
        w->clip_on = 1; w->cx0 = nx0; w->cy0 = ny0; w->cx1 = nx1; w->cy1 = ny1;
    } else {                                                     // OFF: pop
        if (w->clip_sp > 0) {
            int *s = w->clip_stk[--w->clip_sp];
            w->clip_on = s[0]; w->cx0 = s[1]; w->cy0 = s[2]; w->cx1 = s[3]; w->cy1 = s[4];
        } else w->clip_on = 0;
    }
}

void vs_clip(int handle, int on, const int16_t *pxy) {
    g_intin[0] = (int16_t)on;                                   // 0 off / 1 on / 2 reset
    if (pxy) { g_ptsin[0]=pxy[0]; g_ptsin[1]=pxy[1]; g_ptsin[2]=pxy[2]; g_ptsin[3]=pxy[3]; }
    vdi_emit(VDI_CLIP, 0, handle, 2, 1);
}
