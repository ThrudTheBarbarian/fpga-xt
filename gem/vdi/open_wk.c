// vdi/open_wk.c — v_opnwk / v_clswk (open/close a *physical* workstation, i.e.
// a device).  work_in[0] is the device id: 1..10 = the screen (we have one
// display), 11+ = plotter / printer / metafile / camera / tablet — none of
// which have a driver yet, so v_opnwk reports failure (handle 0) for them.  An
// app prints by opening the printer device and drawing to its handle; once a
// driver exists it slots in here.  The screen device opens a workstation onto
// the desktop surface and returns a minimal work_out (extent + colour count).

#include "vdi/vdi.h"
#include "vdi/internal.h"

static int is_screen(int dev) { return dev >= 1 && dev <= 10; }

void op_open_wk(vdi_pb *pb) {
    for (int i = 0; i < 45; i++) pb->intout[i] = 0;     // clear work_out
    for (int i = 0; i < 12; i++) pb->ptsout[i] = 0;
    if (!is_screen(pb->intin[0])) { pb->contrl[6] = 0; return; }   // no driver
    int h = vdi_ws_alloc();
    vdi_ws *w = vdi_ws_of(h);
    if (!w) { pb->contrl[6] = 0; return; }              // out of workstations
    w->target = vdi_screen_target();
    pb->contrl[6] = (int16_t)h;
    if (w->target) {
        pb->intout[0] = (int16_t)(w->target->w - 1);    // device extent
        pb->intout[1] = (int16_t)(w->target->h - 1);
    }
    pb->intout[13] = 256;                               // simultaneous colours
}

void op_close_wk(vdi_pb *pb) { vdi_ws_free(pb->contrl[6]); }

// work_in: 11 WORDs (work_in[0] = device id).  work_out: 57 WORDs (45 + 12 pts).
void v_opnwk(const int16_t *work_in, int *handle, int16_t *work_out) {
    for (int i = 0; i < 11; i++) g_intin[i] = work_in[i];
    vdi_emit(VDI_OPEN_WK, 0, 0, 0, 11);
    if (handle) *handle = g_contrl[6];
    if (work_out) {
        for (int i = 0; i < 45; i++) work_out[i]      = g_intout[i];
        for (int i = 0; i < 12; i++) work_out[45 + i] = g_ptsout[i];
    }
}
void v_clswk(int handle) { vdi_emit(VDI_CLOSE_WK, 0, handle, 0, 0); }
