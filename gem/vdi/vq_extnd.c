// vdi/vq_extnd.c — vq_extnd (extended workstation inquiry).  owflag 0 returns
// the same capability array as v_opnwk; owflag 1 returns extended device info.
//
// True-colour detection (what apps actually use): v_opnvwk reports >= 2 in
// work_out[13] (a colour device), then vq_extnd(owflag=1) reports work_out[5]
// == 0 — no colour lookup table — meaning a direct/true-colour device.  Ours is
// RGBA-8888, so we report 32 planes and no LUT.

#include "vdi/vdi.h"
#include "vdi/internal.h"

// vq_scrninfo (op 102 sub 1): the screen pixel format.  We are direct (true-)
// colour, chunky RGBA-8888 (0xRRGGBBAA), so we report 32 bpp and the per-
// component bit counts + shifts.  (Field layout is our convention — remap to
// NVDI's exact vq_scrninfo struct when the m68k trap ABI lands.)
static void scrninfo(vdi_pb *pb) {
    for (int i = 0; i < 45; i++) pb->intout[i] = 0;
    pb->intout[0] = 2;       // colour model: 2 = direct / true colour
    pb->intout[1] = 32;      // bits per pixel
    pb->intout[2] = 0;       // 0 = packed/chunky (not planar)
    pb->intout[3] = 8;  pb->intout[4]  = 24;   // red:   8 bits at shift 24
    pb->intout[5] = 8;  pb->intout[6]  = 16;   // green: 8 bits at shift 16
    pb->intout[7] = 8;  pb->intout[8]  = 8;    // blue:  8 bits at shift 8
    pb->intout[9] = 8;  pb->intout[10] = 0;    // alpha: 8 bits at shift 0
}

void op_vq_extnd(vdi_pb *pb) {
    if (pb->contrl[5] == 1) { scrninfo(pb); return; }   // vq_scrninfo
    for (int i = 0; i < 45; i++) pb->intout[i] = 0;
    for (int i = 0; i < 12; i++) pb->ptsout[i] = 0;
    if (pb->intin[0] == 0) { vdi_fill_caps(pb->intout, pb->ptsout); return; }
    pb->intout[4]  = 32;     // colour planes (RGBA-8888)
    pb->intout[5]  = 0;      // 0 = no lookup table => TRUE COLOUR
    pb->intout[8]  = 2;      // text rotation: 2 = arbitrary angles (not just 90s)
    pb->intout[9]  = 4;      // writing modes
    pb->intout[14] = 256;    // max polyline vertices (nominal)
    pb->intout[16] = 2;      // mouse buttons
}

void vq_extnd(int handle, int owflag, int16_t *work_out) {
    g_intin[0] = (int16_t)owflag;
    vdi_emit(VDI_VQ_EXTND, 0, handle, 0, 1);
    if (work_out) {
        for (int i = 0; i < 45; i++) work_out[i]      = g_intout[i];
        for (int i = 0; i < 12; i++) work_out[45 + i] = g_ptsout[i];
    }
}

// Screen pixel format: work_out[0]=colour model (2=true colour), [1]=bpp,
// [2]=packed/planar, then (bits, shift) for red, green, blue, alpha.
void vq_scrninfo(int handle, int16_t *work_out) {
    vdi_emit(VDI_VQ_EXTND, 1, handle, 0, 0);
    if (work_out) for (int i = 0; i < 11; i++) work_out[i] = g_intout[i];
}
