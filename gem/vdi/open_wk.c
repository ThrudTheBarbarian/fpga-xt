// vdi/open_wk.c — v_opnwk / v_clswk (open/close a *physical* workstation, i.e.
// a device).  work_in[0] is the device id:
//   1..10  screen   — opens a workstation onto the desktop surface
//   31..40 metafile — records subsequent calls to a .gem file (metafile.c)
//   21..30 printer  — PDF device, planned; reports failure for now
// Anything without a driver returns handle 0 (failed to open) rather than the
// opcode being ignored, so an app can probe for a device cleanly.

#include "vdi/vdi.h"
#include "vdi/internal.h"

void op_open_wk(vdi_pb *pb) {
    for (int i = 0; i < 45; i++) pb->intout[i] = 0;     // clear work_out
    for (int i = 0; i < 12; i++) pb->ptsout[i] = 0;
    int dev = pb->intin[0];
    int screen = dev >= VDI_DEV_SCREEN_LO && dev <= VDI_DEV_SCREEN_HI;
    int meta   = dev >= VDI_DEV_META_LO   && dev <= VDI_DEV_META_HI;
    if (!screen && !meta) { pb->contrl[6] = 0; return; }   // no driver (printer = PDF, later)

    int h = vdi_ws_alloc();
    vdi_ws *w = vdi_ws_of(h);
    if (!w) { pb->contrl[6] = 0; return; }                  // out of workstations
    if (meta && metafile_open(w, g_device_file) != 0) {     // file couldn't be created
        vdi_ws_free(h); pb->contrl[6] = 0; return;
    }
    w->device = dev;
    w->target = vdi_screen_target();                        // for extent inquiries
    pb->contrl[6] = (int16_t)h;
    vdi_fill_caps(pb->intout, pb->ptsout);                  // device capabilities
}

void op_close_wk(vdi_pb *pb) {
    vdi_ws *w = vdi_ws_of(pb->contrl[6]);
    if (w && w->device >= VDI_DEV_META_LO && w->device <= VDI_DEV_META_HI)
        metafile_close(w);
    vdi_ws_free(pb->contrl[6]);
}

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
