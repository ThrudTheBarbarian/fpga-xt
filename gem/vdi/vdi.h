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
    VDI_OPEN_WK     = 1,        // v_opnwk  — open a physical device workstation
    VDI_CLOSE_WK    = 2,        // v_clswk
    VDI_CLRWK       = 3,        // v_clrwk  — clear workstation to pen 0
    VDI_UPDWK       = 4,        // v_updwk  — flush workstation (screen: no-op)
    VDI_OPNVWK      = 100,
    VDI_CLSVWK      = 101,
    VDI_VQ_EXTND    = 102,      // vq_extnd  — extended workstation inquiry
    VDI_META_END    = 0xFFFF,   // end-of-metafile marker (not a real opcode)
    VDI_PLINE       = 6,
    VDI_PMARKER     = 7,        // v_pmarker  — polymarkers
    VDI_GTEXT       = 8,        // v_gtext    — graphic text
    VDI_FILLAREA    = 9,        // v_fillarea — filled polygon
    VDI_CELLARRAY   = 10,       // v_cellarray — grid of coloured cells
    VDI_GDP         = 11,       // sub-opcode 1 = v_bar (filled rectangle)
    VDI_ST_HEIGHT   = 12,       // vst_height — text size in pixels
    VDI_ST_ROTATION = 13,       // vst_rotation — text baseline angle (1/10 deg)
    VDI_VS_COLOR    = 14,       // vs_color   — set a palette pen (RGB 0..1000)
    VDI_SL_TYPE     = 15,       // vsl_type   — line style (1 solid .. 6)
    VDI_SL_WIDTH    = 16,       // vsl_width  — line width (px)
    VDI_SL_COLOR    = 17,       // vsl_color  — polyline colour
    VDI_SL_ENDS     = 108,      // vsl_ends   — polyline end styles
    VDI_SL_UDSTY    = 113,      // vsl_udsty  — user-defined line style (type 7)
    VDI_SM_TYPE     = 18,       // vsm_type   — marker type
    VDI_SM_HEIGHT   = 19,       // vsm_height — marker height
    VDI_SM_COLOR    = 20,       // vsm_color  — marker colour
    VDI_ST_FONT     = 21,       // vst_font   — select text face by id
    VDI_SWR_MODE    = 32,       // vswr_mode  — writing mode
    VDI_QT_EXTENT   = 116,      // vqt_extent — text bounding box
    VDI_QT_WIDTH    = 117,      // vqt_width  — one character's cell width
    VDI_QT_NAME     = 130,      // vqt_name   — inquire a font's id + name
    VDI_CONTOURFILL = 103,      // v_contourfill — seed fill
    VDI_ST_COLOR    = 22,       // vst_color  — text colour
    VDI_SF_INTERIOR = 23,       // vsf_interior — see VDI_FIS_*
    VDI_SF_STYLE    = 24,       // vsf_style  — pattern/hatch index
    VDI_SF_COLOR    = 25,       // vsf_color  — fill colour
    VDI_SF_UDPAT    = 112,      // vsf_udpat  — set user-defined fill pattern
    VDI_ST_ALIGN    = 39,       // vst_alignment — text anchor
    VDI_GET_PIXEL   = 105,      // v_get_pixel — read a pixel
    VDI_VR_TRNFM    = 110,      // vr_trnfm   — transform form (standard<->device)
    VDI_VRT_CPYFM   = 121,      // vrt_cpyfm  — colour a monochrome raster
    VDI_SF_PERIM    = 104,      // vsf_perimeter — outline filled areas (0/1)
    VDI_ST_EFFECTS  = 106,      // vst_effects — text effects bitmask
    VDI_ST_POINT    = 107,      // vst_point  — text size in points
    VDI_LOAD_FONTS  = 119,      // vst_load_fonts   — returns the font-file count
    VDI_UNLOAD_FONTS= 120,      // vst_unload_fonts — no-op
    VDI_CPYFM       = 109,      // vro_cpyfm  — copy raster, opaque
    VDI_RECFL       = 114,      // vr_recfl   — fill rectangle
    VDI_CLIP        = 129,      // vs_clip
    VDI_Q_COLOR     = 26,       // vq_color   — read a palette pen (RGB 0..1000)
    VDI_QL_ATTR     = 35,       // vql_attributes — current line attributes
    VDI_QM_ATTR     = 36,       // vqm_attributes — current marker attributes
    VDI_QF_ATTR     = 37,       // vqf_attributes — current fill attributes
    VDI_QT_ATTR     = 38,       // vqt_attributes — current text attributes
    VDI_LOCATOR     = 28,       // vrq/vsm_locator  — pointer position
    VDI_VALUATOR    = 29,       // vrq/vsm_valuator — a scalar input
    VDI_CHOICE      = 30,       // vrq/vsm_choice   — a numbered selection
    VDI_STRING      = 31,       // vrq/vsm_string   — a typed line
    VDI_SIN_MODE    = 33,       // vsin_mode  — request/sample per device
    VDI_VEX_TIMV    = 118,      // vex_timv   — timer vector
    VDI_SHOW_C      = 122,      // v_show_c   — show the mouse pointer
    VDI_HIDE_C      = 123,      // v_hide_c   — hide the mouse pointer
    VDI_Q_MOUSE     = 124,      // vq_mouse   — pointer position + buttons
    VDI_VEX_BUTV    = 125,      // vex_butv   — button-change vector
    VDI_VEX_MOTV    = 126,      // vex_motv   — pointer-motion vector
    VDI_VEX_CURV    = 127,      // vex_curv   — cursor-draw vector
    VDI_Q_KEY_S     = 128,      // vq_key_s   — keyboard shift state
};

// Input device classes (vsin_mode) and the two input modes.
enum { VDI_DEV_LOCATOR = 1, VDI_DEV_VALUATOR = 2, VDI_DEV_CHOICE = 3, VDI_DEV_STRING = 4 };
enum { VDI_MODE_REQUEST = 1, VDI_MODE_SAMPLE = 2 };
// Button mask bits / keyboard shift-state bits (GEM convention).
enum { VDI_BTN_LEFT = 0x01, VDI_BTN_RIGHT = 0x02, VDI_BTN_MIDDLE = 0x04 };
enum { VDI_KS_RSHIFT = 0x01, VDI_KS_LSHIFT = 0x02, VDI_KS_CTRL = 0x04, VDI_KS_ALT = 0x08 };

// Memory Form Definition Block — a bitmap.  In device format it is RGBA-8888
// chunky (one uint32 per pixel, `stride` pixels per row).  In standard format
// it is planar: `nplanes` bit planes, word-interleaved per scanline, MSB =
// leftmost pixel, `stride` 16-bit words per row per plane — that's the device-
// independent layout vr_trnfm converts to/from device.  addr == NULL means "the
// destination is the workstation's target surface".
typedef struct {
    uint32_t *addr;            // device: RGBA-8888 pixels; standard: planar bits; NULL = screen
    int16_t   w, h;            // size in pixels
    int16_t   stride;          // device: pixels/row; standard: 16-bit words/row/plane
    int16_t   nplanes;         // standard form: number of bit planes (device: unused)
    int16_t   stand;           // 0 = device (chunky RGBA), 1 = standard (planar)
} MFDB;

void mfdb_from_surface(MFDB *m, gfx_surface *s);   // wrap a surface as a device MFDB

// VDI raster copy modes (subset).  3 = S replace (plain copy) — the only one yet.
enum { VRO_COPY = 3 };

// Polyline end styles (vsl_ends), for the start and the end point: SQUARE (a
// flat butt cap), ARROW (an arrowhead; the line stops at its base), ROUND (the
// round pen cap).
enum { VDI_LE_SQUARE = 0, VDI_LE_ARROW = 1, VDI_LE_ROUND = 2 };

// Writing modes (vswr_mode).  Per pixel, given a source foreground bit:
//   REPLACE: fg -> ink, bg -> colour 0 (opaque)
//   TRANS:   fg -> ink, bg -> unchanged (the default in classic GEM)
//   XOR:     fg -> dst XOR ink, bg -> unchanged (reversible)
//   ERASE:   fg -> unchanged, bg -> ink (reverse transparent)
enum { VDI_MD_REPLACE = 1, VDI_MD_TRANS = 2, VDI_MD_XOR = 3, VDI_MD_ERASE = 4 };

// Marker types (vsm_type) for v_pmarker.
enum { VDI_MK_DOT = 1, VDI_MK_PLUS = 2, VDI_MK_ASTERISK = 3,
       VDI_MK_SQUARE = 4, VDI_MK_CROSS = 5, VDI_MK_DIAMOND = 6 };

// Fill interior style (vsf_interior).  PATTERN (24 styles) / HATCH (12 styles)
// pick a mask via vsf_style; USER uses the 16x16 pattern set by vsf_udpat.
enum { VDI_FIS_HOLLOW = 0, VDI_FIS_SOLID = 1, VDI_FIS_PATTERN = 2,
       VDI_FIS_HATCH  = 3, VDI_FIS_USER  = 4 };

// GDP (VDI_GDP) sub-opcodes.  Angles are tenths of a degree, 0 = east, CCW.
enum { GDP_BAR = 1, GDP_ARC = 2, GDP_PIE = 3, GDP_CIRCLE = 4, GDP_ELLIPSE = 5,
       GDP_ELLARC = 6, GDP_ELLPIE = 7, GDP_RBOX = 8, GDP_RFBOX = 9, GDP_JUSTIFIED = 10 };

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
// Directory scanned by vst_load_fonts to count font files (default "OS/Fonts").
void     vdi_set_font_dir(const char *path);
#define  VDI_TEXT_DPI         72
#define  VDI_TEXT_PX_DEFAULT  16

// ---- C binding (fills shared arrays, calls vdi_call) ----------------------
// v_opnwk device-id ranges (work_in[0]).
enum { VDI_DEV_SCREEN_LO = 1,  VDI_DEV_SCREEN_HI = 10,
       VDI_DEV_PRINT_LO  = 21, VDI_DEV_PRINT_HI  = 30,   // PDF later
       VDI_DEV_META_LO   = 31, VDI_DEV_META_HI   = 40 };

// Open a physical device: work_in[0] = device id (1..10 screen; 31..40 metafile;
// others no driver yet => *handle == 0).  work_out (57 WORDs) gets the caps.
void v_opnwk(const int16_t *work_in, int *handle, int16_t *work_out);
void v_clswk(int handle);
void v_clrwk(int handle);                     // clear the workstation to pen 0
void v_updwk(int handle);                     // flush pending output (screen: no-op)

// Set the output file for the next metafile/printer v_opnwk (else a default).
void vdi_set_device_file(const char *path);
// Replay a recorded metafile, re-issuing each call on `handle`.  Returns the
// number of calls played, or -1 on error.
int  vdi_play_metafile(const char *path, int handle);
int  v_opnvwk(gfx_surface *target);           // -> workstation handle (>0), 0 = fail
void v_clsvwk(int handle);
// Extended inquiry.  owflag 0 = the open-workstation caps; 1 = extended info
// (work_out[5] == 0 => true-colour / no palette LUT).  work_out is 57 WORDs.
void vq_extnd(int handle, int owflag, int16_t *work_out);
int  vswr_mode(int handle, int mode);                  // VDI_MD_*; returns selected
void vsl_color(int handle, int pen);
int  vsl_type(int handle, int style);                  // 1 solid..6, 7 user; returns selected
int  vsl_width(int handle, int width);                 // px; returns selected
void vsl_ends(int handle, int beg, int end);           // VDI_LE_* for start/end of a polyline
void vsl_udsty(int handle, uint16_t pattern);          // 16-bit dash mask for vsl_type 7
void vst_color(int handle, int pen);                   // text colour
int  vst_rotation(int handle, int angle);              // baseline angle, 1/10 deg CCW; -> selected
int  vst_effects(int handle, int effects);             // FX_* bitmask (from font.h); -> selected
void vsf_color(int handle, int pen);
void vsf_interior(int handle, int style);              // VDI_FIS_*
void vsf_style(int handle, int index);                 // pattern/hatch index (1-based)
void vsf_udpat(int handle, const uint16_t *pat16);     // user fill pattern: 16 rows
void vsf_perimeter(int handle, int on);                // outline filled areas
void vs_color(int handle, int index, const int16_t *rgb);  // rgb[3] each 0..1000
void v_gtext(int handle, int x, int y, const char *s); // anchored per vst_alignment
// Justify s to occupy `width` px from (x,y): word_space/char_space (0/1) pick
// whether slack goes to spaces and/or between characters.
void v_justified(int handle, int x, int y, const char *s, int width,
                 int word_space, int char_space);
// Set the text anchor; set_h/set_v (may be NULL) get the clamped values back.
void vst_alignment(int handle, int halign, int valign, int *set_h, int *set_v);
// Set text size; out (each may be NULL) gets char_w, char_h, cell_w, cell_h in
// px.  vst_height returns the pixel size used; vst_point the point size used.
int  vst_height(int handle, int height_px, int *cw, int *ch, int *cellw, int *cellh);
int  vst_point (int handle, int points,    int *cw, int *ch, int *cellw, int *cellh);
int  vst_font(int handle, int id);                     // select face (1=system); -> id in use
int  vqt_name(int handle, int id, char *name);         // name of font id (>=32-byte buf); -> id
// Bounding box of `s` in the current font/size/effects/rotation: 4 corner points
// (offsets from the text origin) as LL, LR, UR, UL in extent[0..7].
void vqt_extent(int handle, const char *s, int16_t *extent);
// Cell width of one character `ch` in the current font/size.  *left/*right get
// the left bearing and right overhang past the cell (px).  Returns the cell
// width, or -1 if the character has no glyph.
int  vqt_width(int handle, int ch, int *left, int *right);
// Read a palette pen as RGB on the 0..1000 scale (set_flag 0 requested, 1
// realised — identical here).  rgb[3] out.
void vq_color(int handle, int index, int set_flag, int16_t *rgb);
// Inquire the workstation's current attributes into a caller array:
//   vql attrib[4]  = line type, colour, writing mode, width
//   vqm attrib[4]  = marker type, colour, writing mode, height
//   vqf attrib[5]  = interior, colour, style, writing mode, perimeter
//   vqt attrib[10] = font id, colour, rotation, halign, valign, writing mode,
//                    char_w, char_h, cell_w, cell_h
void vql_attributes(int handle, int16_t *attrib);
void vqm_attributes(int handle, int16_t *attrib);
void vqf_attributes(int handle, int16_t *attrib);
void vqt_attributes(int handle, int16_t *attrib);
int  vst_load_fonts(int handle, int select);           // map OS/Fonts; -> extra-font count
void vst_unload_fonts(int handle, int select);         // no-op
void v_pline(int handle, int n, const int16_t *pxy);   // n point-pairs
void v_pmarker(int handle, int n, const int16_t *pxy); // markers at n points
void vsm_type(int handle, int type);                   // VDI_MK_*
int  vsm_height(int handle, int height);               // px; returns selected
void vsm_color(int handle, int pen);
void v_fillarea(int handle, int n, const int16_t *pxy);// filled polygon, n vertices
// Grid of cols x rows coloured cells (pen indices) scaled into pxy=x1,y1,x2,y2.
void v_cellarray(int handle, const int16_t *pxy, int cols, int rows, const int16_t *colors);
// Seed fill from (x,y) with the fill colour; index>=0 = fill up to that boundary
// pen, index<0 = fill the connected region matching the seed pixel's colour.
void v_contourfill(int handle, int x, int y, int index);
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
// vrt_cpyfm: colour a 1-bit-per-pixel source (MSB first; src->stride = 16-bit
// words per row) — col[0]=foreground pen, col[1]=background pen; mode = VDI_MD_*.
void vrt_cpyfm(int handle, int mode, const int16_t *pxy,
               const MFDB *src, const MFDB *dst, const int16_t *col);
// vr_trnfm: convert src to dst between standard (planar) and device (RGBA
// chunky) format; the direction follows src->stand.  Set src->nplanes for a
// standard source, dst->nplanes for a standard destination.
void vr_trnfm(int handle, const MFDB *src, const MFDB *dst);
// v_get_pixel: read (x,y); *pel and *index get the matching palette pen, or
// *index = -1 if the (true-colour) pixel matches no pen.
void v_get_pixel(int handle, int x, int y, int *pel, int *index);

// ---- Input / cursor -------------------------------------------------------
// The VDI's input devices read a host-fed state.  The backend (SDL today, the
// AES event pump on hardware) pushes the live pointer/keyboard state in through
// these setters; the vrq_*/vsm_* calls below read it.
void vdi_input_mouse(int x, int y, int buttons);  // pointer pos + button mask
void vdi_input_key(int ch);                        // enqueue a typed character
void vdi_input_shift(int mask);                    // shift/ctrl/alt state
void vdi_input_valuator(int v);                    // current valuator value
void vdi_input_choice(int c);                      // current choice number
// REQUEST-mode (blocking) input drives this pump until the device triggers;
// with no pump set, REQUEST degrades to one non-blocking read (never hangs).
void vdi_input_set_pump(void (*pump)(void *), void *ctx);
int  vdi_cursor_visible(void);                     // WM asks: draw the pointer?

void vsin_mode(int handle, int dev, int mode);     // VDI_DEV_* x VDI_MODE_*
// Locator: (x,y) seeds the pointer; *ox,*oy get the final position.  REQUEST
// blocks for a button/key and returns the terminator; SAMPLE returns at once
// with the button mask (or a pending key).
int  vrq_locator(int handle, int x, int y, int *ox, int *oy);
int  vsm_locator(int handle, int x, int y, int *ox, int *oy);
int  vrq_valuator(int handle, int valin);          // -> final value
int  vsm_valuator(int handle, int *val);           // sample; -> terminator
int  vrq_choice(int handle, int chin);             // -> chosen number
int  vsm_choice(int handle, int *choice);          // sample; -> nonzero if a choice
// Read a typed line into out[] (NUL-terminated, up to maxlen).  echo!=0 lets
// the host echo it.  Returns the character count.
int  vrq_string(int handle, int maxlen, int echo, char *out);
int  vsm_string(int handle, int maxlen, int echo, char *out);
void v_show_c(int handle, int reset);              // reset!=0 forces visible
void v_hide_c(int handle);                         // nests (matching v_show_c)
int  vq_mouse(int handle, int *buttons, int *x, int *y);  // -> button mask
int  vq_key_s(int handle, int *shift);             // -> shift mask
// Exchange an input-interrupt vector; returns the previous handler.
typedef void (*vdi_vec)(void);
vdi_vec vex_butv(int handle, vdi_vec f);           // button change
vdi_vec vex_motv(int handle, vdi_vec f);           // pointer motion
vdi_vec vex_curv(int handle, vdi_vec f);           // cursor draw
vdi_vec vex_timv(int handle, vdi_vec f);           // timer tick

#endif // GEM_VDI_H
