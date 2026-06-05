// vdi/clrwk.c — v_clrwk (clear workstation).  A whole-device clear to the
// background colour (VDI pen 0); ignores the clip rectangle, as GEM does.  On
// the screen it's rarely used (something is always shown), but it is the right
// operation for off-screen / printer / metafile workstations.

#include "vdi/vdi.h"
#include "vdi/internal.h"

void op_clrwk(vdi_pb *pb) {
    vdi_ws *w = vdi_ws_of(pb->contrl[6]); if (!w || !w->target) return;
    gfx_fill_rect(w->target, 0, 0, w->target->w, w->target->h, vdi_pen_rgba(0));
}

void v_clrwk(int handle) { vdi_emit(VDI_CLRWK, 0, handle, 0, 0); }
