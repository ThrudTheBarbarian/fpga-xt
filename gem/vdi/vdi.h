// vdi.h — portable GEM VDI (Virtual Device Interface), first slice.
//
// The VDI is the GEM graphics layer.  Apps (and the window manager) call it
// through the classic five-array parameter block — opcode + params in
// contrl/intin/ptsin, results in intout/ptsout — and the dispatcher
// (vdi_call) turns each opcode into gfx.h primitive calls on the workstation's
// target surface, clipped to the workstation's clip rectangle.
//
// That param-block IS the doorbell ABI: on the A9 the m68k TRAP-#2 handler will
// call vdi_call() with the app's own arrays (binary-compatible with real GEM);
// the C wrappers below are convenience that fill shared arrays and call the
// same dispatcher, so both paths are identical.  Colours are pen indices into a
// 256-entry palette (the pen table); coordinates are raster coords (0,0 = top
// left).  Opcode numbers are the standard GEM ones.

#ifndef GEM_VDI_H
#define GEM_VDI_H

#include "gfx.h"
#include "font.h"
#include <stdint.h>

enum {                          // VDI opcodes (standard GEM)
    VDI_OPNVWK      = 100,
    VDI_CLSVWK      = 101,
    VDI_PLINE       = 6,
    VDI_GTEXT       = 8,        // v_gtext    — graphic text
    VDI_GDP         = 11,       // sub-opcode 1 = v_bar (filled rectangle)
    VDI_ST_HEIGHT   = 12,       // vst_height — text size in pixels
    VDI_VS_COLOR    = 14,       // vs_color   — set a palette pen (RGB 0..1000)
    VDI_SL_TYPE     = 15,       // vsl_type   — line style (1 solid .. 6)
    VDI_SL_WIDTH    = 16,       // vsl_width  — line width (px)
    VDI_SL_COLOR    = 17,       // vsl_color  — polyline colour
    VDI_ST_COLOR    = 22,       // vst_color  — text colour
    VDI_SF_INTERIOR = 23,       // vsf_interior — see VDI_FIS_*
    VDI_SF_STYLE    = 24,       // vsf_style  — pattern/hatch index
    VDI_SF_COLOR    = 25,       // vsf_color  — fill colour
    VDI_ST_ALIGN    = 39,       // vst_alignment — text anchor
    VDI_SF_PERIM    = 104,      // vsf_perimeter — outline filled areas (0/1)
    VDI_ST_POINT    = 107,      // vst_point  — text size in points
    VDI_CPYFM       = 109,      // vro_cpyfm  — copy raster, opaque
    VDI_RECFL       = 114,      // vr_recfl   — fill rectangle
    VDI_CLIP        = 129,      // vs_clip
};

// Memory Form Definition Block — a bitmap, in device format (RGBA-8888 chunky).
// Real GEM MFDBs are planar with fd_wdwidth/fd_nplanes; the planar<->device
// conversion for ST binary compatibility is a later layer in the trap path.
// addr == NULL means "the destination is the workstation's target surface".
typedef struct {
    uint32_t *addr;            // device pixels (RGBA-8888), or NULL = screen
    int16_t   w, h;            // size in pixels
    int16_t   stride;          // pixels per row
} MFDB;

void mfdb_from_surface(MFDB *m, gfx_surface *s);   // wrap a surface as a device MFDB

// VDI raster copy modes (subset).  3 = S replace (plain copy) — the only one yet.
enum { VRO_COPY = 3 };

// Fill interior style (vsf_interior).  PATTERN/HATCH pick a mask via vsf_style.
enum { VDI_FIS_HOLLOW = 0, VDI_FIS_SOLID = 1, VDI_FIS_PATTERN = 2, VDI_FIS_HATCH = 3 };

// GDP (VDI_GDP) sub-opcodes.  Angles are tenths of a degree, 0 = east, CCW.
enum { GDP_BAR = 1, GDP_ARC = 2, GDP_PIE = 3, GDP_CIRCLE = 4, GDP_ELLIPSE = 5,
       GDP_ELLARC = 6, GDP_ELLPIE = 7, GDP_RBOX = 8, GDP_RFBOX = 9 };

// v_gtext anchor (vst_alignment).  Horizontal is standard GEM; vertical uses the
// GEM codes but DEFAULTS to TOP (our v_gtext anchor has always been the em-box
// top-left), not GEM's baseline.
enum { VDI_TA_LEFT = 0, VDI_TA_CENTER = 1, VDI_TA_RIGHT = 2 };
enum { VDI_TA_BASELINE = 0, VDI_TA_HALF = 1, VDI_TA_ASCENT = 2,
       VDI_TA_BOTTOM   = 3, VDI_TA_DESCENT = 4, VDI_TA_TOP = 5 };

// The GEM parameter block: contrl[0]=opcode, [1]=#ptsin pairs, [2]=#ptsout,
// [3]=#intin, [4]=#intout, [5]=sub-opcode, [6]=handle.
typedef struct {
    int16_t *contrl, *intin, *ptsin, *intout, *ptsout;
} vdi_pb;

void vdi_init(gfx_surface *default_target);   // sets the default surface + pen palette
void vdi_call(vdi_pb *pb);                    // the doorbell: dispatch one VDI call

uint32_t vdi_pen_rgba(int pen);               // pen index -> RGBA (for the WM/theming)

// The default text face used by v_gtext (until per-workstation vst_font lands);
// vst_height / vst_point pick sizes from it.  72 px-per-inch (1 point == 1 px).
void     vdi_set_face(font_face *face);
#define  VDI_TEXT_DPI         72
#define  VDI_TEXT_PX_DEFAULT  16

// ---- C binding (fills shared arrays, calls vdi_call) ----------------------
int  v_opnvwk(gfx_surface *target);           // -> workstation handle (>0), 0 = fail
void v_clsvwk(int handle);
void vsl_color(int handle, int pen);
int  vsl_type(int handle, int style);                  // 1 solid..6; returns selected
int  vsl_width(int handle, int width);                 // px; returns selected
void vst_color(int handle, int pen);                   // text colour
void vsf_color(int handle, int pen);
void vsf_interior(int handle, int style);              // VDI_FIS_*
void vsf_style(int handle, int index);                 // pattern/hatch index (1-based)
void vsf_perimeter(int handle, int on);                // outline filled areas
void vs_color(int handle, int index, const int16_t *rgb);  // rgb[3] each 0..1000
void v_gtext(int handle, int x, int y, const char *s); // anchored per vst_alignment
// Set the text anchor; set_h/set_v (may be NULL) get the clamped values back.
void vst_alignment(int handle, int halign, int valign, int *set_h, int *set_v);
// Set text size; out (each may be NULL) gets char_w, char_h, cell_w, cell_h in
// px.  vst_height returns the pixel size used; vst_point the point size used.
int  vst_height(int handle, int height_px, int *cw, int *ch, int *cellw, int *cellh);
int  vst_point (int handle, int points,    int *cw, int *ch, int *cellw, int *cellh);
void v_pline(int handle, int n, const int16_t *pxy);   // n point-pairs
void v_bar(int handle, const int16_t *pxy);            // pxy = x1,y1,x2,y2
// Curved GDPs.  Filled ones use the fill colour/interior/perimeter; arcs and
// v_rbox use the line colour.  Angles are tenths of a degree (0=east, CCW).
void v_circle(int handle, int x, int y, int r);
void v_ellipse(int handle, int x, int y, int rx, int ry);
void v_pieslice(int handle, int x, int y, int r, int beg, int end);
void v_ellpie(int handle, int x, int y, int rx, int ry, int beg, int end);
void v_arc(int handle, int x, int y, int r, int beg, int end);
void v_ellarc(int handle, int x, int y, int rx, int ry, int beg, int end);
void v_rbox(int handle, const int16_t *pxy);           // rounded rect, outline
void v_rfbox(int handle, const int16_t *pxy);          // rounded rect, filled
void vr_recfl(int handle, const int16_t *pxy);         // pxy = x1,y1,x2,y2
void vs_clip(int handle, int on, const int16_t *pxy);  // pxy = x1,y1,x2,y2
// vro_cpyfm: pxy = src x1,y1,x2,y2, dst x1,y1 (,x2,y2). mode = VRO_COPY.
void vro_cpyfm(int handle, int mode, const int16_t *pxy, const MFDB *src, const MFDB *dst);

#endif // GEM_VDI_H
