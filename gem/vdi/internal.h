// vdi/internal.h — private internals shared across the per-call VDI files.
// Public API is vdi/vdi.h; each VDI call lives in its own vdi/<call>.c.

#ifndef GEM_VDI_INTERNAL_H
#define GEM_VDI_INTERNAL_H

#include "vdi/vdi.h"
#include <stdint.h>

// Combine an ink pixel into the destination per the writing mode.  `bit` is the
// source foreground/background bit (solid primitives pass 1); `ground` is VDI
// colour 0.  XOR touches only RGB so it stays reversible and keeps dst alpha.
static inline uint32_t vdi_wrmix(int mode, uint32_t dst, uint32_t ink, uint32_t ground, int bit) {
    if (bit) return mode == VDI_MD_XOR   ? (dst ^ (ink & 0xFFFFFF00u))
                  : mode == VDI_MD_ERASE ? dst : ink;
    else     return mode == VDI_MD_REPLACE ? ground
                  : mode == VDI_MD_ERASE   ? ink : dst;
}

#define VDI_MAX_WS 16

// A workstation: target surface + drawing attributes + clip rect.
typedef struct {
    int          used;
    gfx_surface *target;
    int          line_color;       // pen
    int          line_width;       // px (default 1)
    int          line_type;        // 1 solid .. 6, 7 user (vsl_type)
    int          line_udsty;       // 16-bit user dash mask (vsl_udsty, type 7)
    int          line_beg, line_end;  // VDI_LE_* end styles (vsl_ends)
    int          fill_color;       // pen
    int          text_color;       // pen
    int          text_halign;      // VDI_TA_LEFT/CENTER/RIGHT
    int          text_valign;      // VDI_TA_* (default TOP)
    int          text_rotation;    // tenths of a degree, CCW (vst_rotation)
    int          text_effects;     // FX_* bitmask (vst_effects)
    int          text_skew;        // extra shear, tenths of a degree (vst_skew)
    int          text_wpx;         // cell width override px (vst_setsize/width; 0 = square)
    int          text_bg_color;    // opaque-text background pen, or -1 = none (vst_bg_color)
    int          fill_interior;    // VDI_FIS_*
    int          fill_style;       // pattern/hatch index (1-based)
    int          fill_perimeter;   // outline filled areas (default 1)
    int          marker_type;      // vsm_type (default 3 = asterisk)
    int          marker_height;    // px (vsm_height)
    int          marker_color;     // pen (vsm_color)
    font_face   *text_face;        // selected face (vst_font); NULL => the VDI default
    int          text_px;          // selected size (0 => VDI_TEXT_PX_DEFAULT)
    int          text_font_id;     // selected font id (vst_font; 1 = system)
    int          wr_mode;          // VDI_MD_* (vswr_mode; default REPLACE)
    int          in_mode[5];       // vsin_mode per device class (1..4)
    int          clip_on, cx0, cy0, cx1, cy1;   // clip rect, inclusive
    int          device;           // v_opnwk device id (0 = virtual/screen draw)
    void        *dev;              // device state (metafile recorder / PDF page)
    gfx_surface  bm;               // backing surface for an off-screen bitmap ws (v_opnbm)
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
// As vdi_line, but sq0/sq1 give the start/end a flat (square) cap, not round.
void        vdi_line_ex(const vdi_ws *w, int x0, int y0, int x1, int y1, int pen, int sq0, int sq1);
void        vdi_set_pen(int index, uint32_t rgba);       // vs_color writes the palette
uint32_t    vdi_pen_rgba(int pen);                       // read a pen's RGBA
int         vdi_pen_of(uint32_t rgba);                   // pen index for an exact RGBA, else -1
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
void op_swr_mode(vdi_pb *pb);
void op_sl_color(vdi_pb *pb);
void op_sl_width(vdi_pb *pb);
void op_sl_type(vdi_pb *pb);
void op_sl_udsty(vdi_pb *pb);
void op_sl_ends(vdi_pb *pb);
void op_st_color(vdi_pb *pb);
void op_st_height(vdi_pb *pb);
void op_st_point(vdi_pb *pb);
void op_st_font(vdi_pb *pb);
void op_qt_name(vdi_pb *pb);
void op_qt_extent(vdi_pb *pb);
void op_qt_width(vdi_pb *pb);
void op_q_color(vdi_pb *pb);
void op_ql_attr(vdi_pb *pb);
void op_qm_attr(vdi_pb *pb);
void op_qf_attr(vdi_pb *pb);
void op_qt_attr(vdi_pb *pb);
void op_qt_fontinfo(vdi_pb *pb);
void op_qt_f_extent(vdi_pb *pb);
void op_qt_advance(vdi_pb *pb);
void op_st_arbpt(vdi_pb *pb);
void op_st_fg_color(vdi_pb *pb);
void op_st_bg_color(vdi_pb *pb);
void op_v_setrgb(vdi_pb *pb);
void op_st_name(vdi_pb *pb);
void op_st_setsize(vdi_pb *pb);
void op_st_width(vdi_pb *pb);
void op_st_skew(vdi_pb *pb);
void op_st_kern(vdi_pb *pb);
void op_st_charmap(vdi_pb *pb);
void op_vq_fg_color(vdi_pb *pb);
void op_vq_bg_color(vdi_pb *pb);
void op_qt_pairkern(vdi_pb *pb);
void op_qt_real_extent(vdi_pb *pb);
void op_qt_justified(vdi_pb *pb);
void op_qt_trackkern(vdi_pb *pb);
void op_qt_char_index(vdi_pb *pb);
void op_vq_cellarray(vdi_pb *pb);
void op_sin_mode(vdi_pb *pb);
void op_locator(vdi_pb *pb);
void op_valuator(vdi_pb *pb);
void op_choice(vdi_pb *pb);
void op_string(vdi_pb *pb);
void op_show_c(vdi_pb *pb);
void op_hide_c(vdi_pb *pb);
void op_q_mouse(vdi_pb *pb);
void op_q_key_s(vdi_pb *pb);
void op_vex(vdi_pb *pb);
void op_vex_wheel(vdi_pb *pb);
void op_sc_form(vdi_pb *pb);
extern vdi_vec g_vex_in, g_vex_out;     // out-of-band vex_* handler exchange
extern vdi_wheel_vec g_vex_wheel_in, g_vex_wheel_out;   // vex_wheelv exchange
void op_bez(vdi_pb *pb, int fill);      // v_bez (fill=0) / v_bez_fill (fill=1)
void op_bez_qual(vdi_pb *pb);
void op_bez_onoff(vdi_pb *pb);
void op_opnbm(vdi_pb *pb);
extern const MFDB *g_opnbm_mfdb;        // out-of-band MFDB for v_opnbm
void op_getoutline(vdi_pb *pb);
void op_killoutline(vdi_pb *pb);
void op_flushcache(vdi_pb *pb);
extern int16_t *g_outline_xy;           // out-of-band v_getoutline buffers
extern uint8_t *g_outline_bez;
extern int      g_outline_max;
void op_st_rotation(vdi_pb *pb);
void op_st_effects(vdi_pb *pb);
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
void op_ftext(vdi_pb *pb);      // v_ftext / v_ftext_offset (outline text)
void op_justified(vdi_pb *pb);  // GDP sub 10 (justified text)
void op_fillrect(vdi_pb *pb);
void op_cpyfm(vdi_pb *pb);
void op_vrt_cpyfm(vdi_pb *pb);
void op_vr_trnfm(vdi_pb *pb);
void op_get_pixel(vdi_pb *pb);

#endif // GEM_VDI_INTERNAL_H
