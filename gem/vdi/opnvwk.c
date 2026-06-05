// vdi/opnvwk.c — v_opnvwk / v_clsvwk (open & close a virtual workstation), and
// the NVDI v_opnbm (open an off-screen bitmap as a workstation: every VDI call
// then draws into the caller's MFDB instead of the screen).

#include "vdi/vdi.h"
#include "vdi/internal.h"

const MFDB *g_opnbm_mfdb;               // out-of-band MFDB for v_opnbm

// Open a workstation whose target surface IS the bitmap.  Requires a device-
// format MFDB (chunky RGBA-8888, stand==0) — our native bitmap layout; a
// standard (planar) MFDB must be vr_trnfm'd to device form first.
void op_opnbm(vdi_pb *pb) {
    const MFDB *m = g_opnbm_mfdb;
    if (!m || !m->addr || m->stand) { pb->contrl[6] = 0; return; }   // need device form
    int h = vdi_ws_alloc();
    pb->contrl[6] = (int16_t)h;
    if (!h) return;
    vdi_ws *w = vdi_ws_of(h);
    w->bm.w = m->w; w->bm.h = m->h;
    w->bm.stride = m->stride ? m->stride : m->w;
    w->bm.px = m->addr;
    w->target = &w->bm;                  // points into the (stable) ws table slot
    vdi_fill_caps(pb->intout, pb->ptsout);
    pb->intout[0] = (int16_t)(m->w - 1); pb->intout[1] = (int16_t)(m->h - 1);
    pb->ptsout[0] = (int16_t)(m->w - 1); pb->ptsout[1] = (int16_t)(m->h - 1);
}

void op_opnvwk(vdi_pb *pb) {
    if (pb->contrl[5] == 1) { op_opnbm(pb); return; }   // v_opnbm path
    pb->contrl[6] = (int16_t)vdi_ws_alloc();     // return handle (0 = none free)
    vdi_fill_caps(pb->intout, pb->ptsout);       // work_out (incl. colour count)
}
void op_clsvwk(vdi_pb *pb) {
    vdi_ws_free(pb->contrl[6]);                  // never closes the physical ws
}

int v_opnvwk(gfx_surface *target) {
    vdi_emit(VDI_OPNVWK, 0, 0, 0, 0);
    int h = g_contrl[6];
    vdi_ws *w = vdi_ws_of(h);
    if (w) w->target = target;                   // bind target (WM does this for real apps)
    return h;
}
void v_clsvwk(int handle) { vdi_emit(VDI_CLSVWK, 0, handle, 0, 0); }

// Open the device-format bitmap `bitmap` as a workstation; returns the handle
// (0 on failure).  work_out (>= 57 words) gets the workstation capabilities,
// with the addressable extent set to the bitmap size.
int v_opnbm(const MFDB *bitmap, int16_t *work_out) {
    g_opnbm_mfdb = bitmap;
    vdi_emit(VDI_OPNVWK, 1, 0, 0, 0);
    g_opnbm_mfdb = 0;
    if (work_out) {
        for (int i = 0; i < 45; i++) work_out[i] = g_intout[i];
        for (int i = 0; i < 12; i++) work_out[45 + i] = g_ptsout[i];
    }
    return g_contrl[6];
}
