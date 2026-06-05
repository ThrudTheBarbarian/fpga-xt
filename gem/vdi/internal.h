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
    int          line_width;       // px (default 1)
    int          line_type;        // 1 solid .. 6 (vsl_type)
    int          fill_color;       // pen
    int          text_color;       // pen
    int          text_halign;      // VDI_TA_LEFT/CENTER/RIGHT
    int          text_valign;      // VDI_TA_* (default TOP)
    int          fill_interior;    // VDI_FIS_*
    int          fill_style;       // pattern/hatch index (1-based)
    int          fill_perimeter;   // outline filled areas (default 1)
    int          marker_type;      // vsm_type (default 3 = asterisk)
    int          marker_height;    // px (vsm_height)
    int          marker_color;     // pen (vsm_color)
    font_face   *text_face;        // selected face (vst_font); NULL => the VDI default
    int          text_px;          // selected size (0 => VDI_TEXT_PX_DEFAULT)
    int          text_font_id;     // selected font id (vst_font; 1 = system)
    int          clip_on, cx0, cy0, cx1, cy1;   // clip rect, inclusive
    int          device;           // v_opnwk device id (0 = virtual/screen draw)
    void        *dev;              // device state (metafile recorder / PDF page)
} vdi_ws;

// ---- core.c: workstation table + clipped primitives + dispatch ------------
vdi_ws     *vdi_ws_of(int handle);
int         vdi_ws_alloc(void);                  // -> handle (>0), 0 = none free
void        vdi_ws_free(int handle);             // never frees the physical ws
void        vdi_ws_clip(const vdi_ws *w, int *x0, int *y0, int *x1, int *y1);
void        vdi_fill_rect(const vdi_ws *w, int x0, int y0, int x1, int y1, int pen);
// Masked fill: mask==NULL is solid, else a 16x16 pattern (bit 1<<(x&15) of row
// y&15, aligned to surface coords so adjacent fills tile).
void        vdi_fill_rect_masked(const vdi_ws *w, int x0, int y0, int x1, int y1,
                                 int pen, const uint16_t *mask);
const uint16_t *vdi_fill_mask(int interior, int style);  // NULL = solid/hollow
void        vdi_set_userpat(const uint16_t *rows16);     // vsf_udpat (16 rows)
void        vdi_rect_outline(const vdi_ws *w, int x0, int y0, int x1, int y1, int pen);
void        vdi_fill_poly(const vdi_ws *w, const int16_t *xy, int n, int pen, const uint16_t *mask);
void        vdi_polyline(const vdi_ws *w, const int16_t *xy, int n, int pen, int closed);
void        vdi_line(const vdi_ws *w, int x0, int y0, int x1, int y1, int pen);
void        vdi_set_pen(int index, uint32_t rgba);       // vs_color writes the palette
gfx_surface *vdi_screen_target(void);                    // the desktop surface (physical ws)
void        vdi_fill_caps(int16_t *intout, int16_t *ptsout);   // v_opnwk/v_opnvwk work_out

// Device file path consumed by the next v_opnwk (metafile / printer); set via
// vdi_set_device_file, else a per-device default.  And the metafile recorder.
extern char g_device_file[256];
int  metafile_open(vdi_ws *w, const char *path);         // 0 = ok
void metafile_record(vdi_ws *w, vdi_pb *pb);             // serialise one call
void metafile_close(vdi_ws *w);                          // end record + close
gfx_surface vdi_mfdb_surf(const MFDB *m, const vdi_ws *w);

// Shared C-binding scratch (filled by the per-call wrappers).
extern int16_t     g_contrl[16], g_intin[128], g_ptsin[256], g_intout[128], g_ptsout[256];
extern vdi_pb      g_pb;
extern const MFDB *g_cpyfm_src, *g_cpyfm_dst;
extern font_face  *g_default_face;     // set by vdi_set_face; the system font (id 1)
font       *vdi_ws_font(const vdi_ws *w);   // the ws's face at its size (or the default)
int         vdi_set_text_px(vdi_ws *w, int px, int16_t *ptsout);  // size ws + report metrics

// Font registry (load_fonts.c): vst_load_fonts maps OS/Fonts files to ids 2..N
// (id 1 = the system/default face); faces are opened on first selection.
font_face  *vdi_font_by_id(int id);              // id>=2 -> lazily-opened face; else NULL
const char *vdi_font_name(int id);               // name for a font id ("" if none)
void        vdi_emit(int op, int sub, int handle, int npts, int nint);   // fill contrl + dispatch

// ---- opcode handlers (one per vdi/<call>.c) -------------------------------
void op_open_wk(vdi_pb *pb);
void op_close_wk(vdi_pb *pb);
void op_clrwk(vdi_pb *pb);
void op_updwk(vdi_pb *pb);
void op_opnvwk(vdi_pb *pb);
void op_clsvwk(vdi_pb *pb);
void op_vq_extnd(vdi_pb *pb);
void op_sl_color(vdi_pb *pb);
void op_sl_width(vdi_pb *pb);
void op_sl_type(vdi_pb *pb);
void op_st_color(vdi_pb *pb);
void op_st_height(vdi_pb *pb);
void op_st_point(vdi_pb *pb);
void op_st_font(vdi_pb *pb);
void op_qt_name(vdi_pb *pb);
void op_st_alignment(vdi_pb *pb);
void op_load_fonts(vdi_pb *pb);
void op_unload_fonts(vdi_pb *pb);
void op_vs_color(vdi_pb *pb);
void op_sf_color(vdi_pb *pb);
void op_sf_interior(vdi_pb *pb);
void op_sf_style(vdi_pb *pb);
void op_sf_udpat(vdi_pb *pb);
void op_sf_perimeter(vdi_pb *pb);
void op_clip(vdi_pb *pb);
void op_pline(vdi_pb *pb);
void op_pmarker(vdi_pb *pb);
void op_sm_type(vdi_pb *pb);
void op_sm_height(vdi_pb *pb);
void op_sm_color(vdi_pb *pb);
void op_fillarea(vdi_pb *pb);
void op_cellarray(vdi_pb *pb);
void op_contourfill(vdi_pb *pb);
void op_gdp(vdi_pb *pb);        // GDP dispatch (v_bar + curved primitives)
void op_gtext(vdi_pb *pb);
void op_justified(vdi_pb *pb);  // GDP sub 10 (justified text)
void op_fillrect(vdi_pb *pb);
void op_cpyfm(vdi_pb *pb);

#endif // GEM_VDI_INTERNAL_H
