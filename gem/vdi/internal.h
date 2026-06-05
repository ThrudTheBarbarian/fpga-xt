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
    int          text_color;       // pen
    int          text_halign;      // VDI_TA_LEFT/CENTER/RIGHT
    int          text_valign;      // VDI_TA_* (default TOP)
    int          fill_interior;    // VDI_FIS_*
    int          fill_style;       // pattern/hatch index (1-based)
    int          fill_perimeter;   // outline filled areas (default 1)
    font        *text_font;        // face for v_gtext (NULL => the VDI default)
    int          clip_on, cx0, cy0, cx1, cy1;   // clip rect, inclusive
} vdi_ws;

// ---- core.c: workstation table + clipped primitives + dispatch ------------
vdi_ws     *vdi_ws_of(int handle);
int         vdi_ws_alloc(void);                  // -> handle (>0), 0 = none free
void        vdi_ws_free(int handle);             // never frees the physical ws
void        vdi_ws_clip(const vdi_ws *w, int *x0, int *y0, int *x1, int *y1);
void        vdi_fill_rect(const vdi_ws *w, int x0, int y0, int x1, int y1, int pen);
// Masked fill: mask==NULL is solid, else an 8x8 pattern (bit 1<<(x&7) of row y&7,
// aligned to surface coords so adjacent fills tile).
void        vdi_fill_rect_masked(const vdi_ws *w, int x0, int y0, int x1, int y1,
                                 int pen, const uint8_t *mask);
const uint8_t *vdi_fill_mask(int interior, int style);   // NULL = solid/hollow
void        vdi_rect_outline(const vdi_ws *w, int x0, int y0, int x1, int y1, int pen);
void        vdi_fill_poly(const vdi_ws *w, const int16_t *xy, int n, int pen, const uint8_t *mask);
void        vdi_polyline(const vdi_ws *w, const int16_t *xy, int n, int pen, int closed);
void        vdi_line(const vdi_ws *w, int x0, int y0, int x1, int y1, int pen);
void        vdi_set_pen(int index, uint32_t rgba);       // vs_color writes the palette
gfx_surface vdi_mfdb_surf(const MFDB *m, const vdi_ws *w);

// Shared C-binding scratch (filled by the per-call wrappers).
extern int16_t     g_contrl[16], g_intin[128], g_ptsin[256], g_intout[128], g_ptsout[256];
extern vdi_pb      g_pb;
extern const MFDB *g_cpyfm_src, *g_cpyfm_dst;
extern font_face  *g_default_face;     // set by vdi_set_face; sized views via font_at
font       *vdi_ws_font(const vdi_ws *w);   // the ws's sized font (or the default)
int         vdi_set_text_px(vdi_ws *w, int px, int16_t *ptsout);  // size ws + report metrics
void        vdi_emit(int op, int sub, int handle, int npts, int nint);   // fill contrl + dispatch

// ---- opcode handlers (one per vdi/<call>.c) -------------------------------
void op_opnvwk(vdi_pb *pb);
void op_clsvwk(vdi_pb *pb);
void op_sl_color(vdi_pb *pb);
void op_st_color(vdi_pb *pb);
void op_st_height(vdi_pb *pb);
void op_st_point(vdi_pb *pb);
void op_st_alignment(vdi_pb *pb);
void op_vs_color(vdi_pb *pb);
void op_sf_color(vdi_pb *pb);
void op_sf_interior(vdi_pb *pb);
void op_sf_style(vdi_pb *pb);
void op_sf_perimeter(vdi_pb *pb);
void op_clip(vdi_pb *pb);
void op_pline(vdi_pb *pb);
void op_gdp(vdi_pb *pb);        // GDP dispatch (v_bar + curved primitives)
void op_gtext(vdi_pb *pb);
void op_fillrect(vdi_pb *pb);
void op_cpyfm(vdi_pb *pb);

#endif // GEM_VDI_INTERNAL_H
