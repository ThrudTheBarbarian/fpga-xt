// vdi/internal.h — private internals shared across the per-call VDI files.
// Public API is vdi/vdi.h; each VDI call lives in its own vdi/<call>.c.

#ifndef GEM_VDI_INTERNAL_H
#define GEM_VDI_INTERNAL_H

#include "vdi/vdi.h"
#include <stdint.h>

#define VDI_MAX_WS 16

// A workstation: target surface + drawing attributes + clip rect.
typedef struct {
    int          used;
    gfx_surface *target;
    int          line_color;       // pen
    int          fill_color;       // pen
    int          fill_interior;    // 0 hollow, 1 solid
    int          clip_on, cx0, cy0, cx1, cy1;   // clip rect, inclusive
} vdi_ws;

// ---- core.c: workstation table + clipped primitives + dispatch ------------
vdi_ws     *vdi_ws_of(int handle);
int         vdi_ws_alloc(void);                  // -> handle (>0), 0 = none free
void        vdi_ws_free(int handle);             // never frees the physical ws
void        vdi_ws_clip(const vdi_ws *w, int *x0, int *y0, int *x1, int *y1);
void        vdi_fill_rect(const vdi_ws *w, int x0, int y0, int x1, int y1, int pen);
void        vdi_line(const vdi_ws *w, int x0, int y0, int x1, int y1, int pen);
gfx_surface vdi_mfdb_surf(const MFDB *m, const vdi_ws *w);

// Shared C-binding scratch (filled by the per-call wrappers).
extern int16_t     g_contrl[16], g_intin[128], g_ptsin[256], g_intout[128], g_ptsout[256];
extern vdi_pb      g_pb;
extern const MFDB *g_cpyfm_src, *g_cpyfm_dst;
void        vdi_emit(int op, int sub, int handle, int npts, int nint);   // fill contrl + dispatch

// ---- opcode handlers (one per vdi/<call>.c) -------------------------------
void op_opnvwk(vdi_pb *pb);
void op_clsvwk(vdi_pb *pb);
void op_sl_color(vdi_pb *pb);
void op_sf_color(vdi_pb *pb);
void op_sf_interior(vdi_pb *pb);
void op_clip(vdi_pb *pb);
void op_pline(vdi_pb *pb);
void op_fillrect(vdi_pb *pb);
void op_cpyfm(vdi_pb *pb);

#endif // GEM_VDI_INTERNAL_H
