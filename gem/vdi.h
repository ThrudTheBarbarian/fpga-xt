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
#include <stdint.h>

enum {                          // VDI opcodes (standard GEM)
    VDI_OPNVWK      = 100,
    VDI_CLSVWK      = 101,
    VDI_PLINE       = 6,
    VDI_GDP         = 11,       // sub-opcode 1 = v_bar (filled rectangle)
    VDI_SL_COLOR    = 17,       // vsl_color  — polyline colour
    VDI_SF_INTERIOR = 23,       // vsf_interior — 0 hollow, 1 solid
    VDI_SF_COLOR    = 25,       // vsf_color  — fill colour
    VDI_RECFL       = 114,      // vr_recfl   — fill rectangle
    VDI_CLIP        = 129,      // vs_clip
};

// The GEM parameter block: contrl[0]=opcode, [1]=#ptsin pairs, [2]=#ptsout,
// [3]=#intin, [4]=#intout, [5]=sub-opcode, [6]=handle.
typedef struct {
    int16_t *contrl, *intin, *ptsin, *intout, *ptsout;
} vdi_pb;

void vdi_init(gfx_surface *default_target);   // sets the default surface + pen palette
void vdi_call(vdi_pb *pb);                    // the doorbell: dispatch one VDI call

uint32_t vdi_pen_rgba(int pen);               // pen index -> RGBA (for the WM/theming)

// ---- C binding (fills shared arrays, calls vdi_call) ----------------------
int  v_opnvwk(gfx_surface *target);           // -> workstation handle (>0), 0 = fail
void v_clsvwk(int handle);
void vsl_color(int handle, int pen);
void vsf_color(int handle, int pen);
void vsf_interior(int handle, int style);
void v_pline(int handle, int n, const int16_t *pxy);   // n point-pairs
void v_bar(int handle, const int16_t *pxy);            // pxy = x1,y1,x2,y2
void vr_recfl(int handle, const int16_t *pxy);         // pxy = x1,y1,x2,y2
void vs_clip(int handle, int on, const int16_t *pxy);  // pxy = x1,y1,x2,y2

#endif // GEM_VDI_H
