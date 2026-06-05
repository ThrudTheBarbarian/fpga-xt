// vdi/sc_form.c — vsc_form (111): set the mouse-pointer shape.  The form is the
// classic 16x16 mono cursor: a hot spot, foreground/background pens, and two
// bitplanes — `data` (the foreground shape) over `mask` (the background/outline).
// A pixel is foreground where data=1, background where mask=1 & data=0, else
// transparent.  Stored device-wide; the WM draws it instead of the built-in
// arrow (see vdi_cursor_form).  intin layout (37 words) matches GEM's MFORM.

#include "vdi/vdi.h"
#include "vdi/internal.h"

static MFORM g_mform;            // current pointer shape (g_mform.planes>0 once set)

const MFORM *vdi_cursor_form(void) { return g_mform.planes > 0 ? &g_mform : 0; }

void op_sc_form(vdi_pb *pb) {
    g_mform.hotx   = pb->intin[0];
    g_mform.hoty   = pb->intin[1];
    g_mform.planes = pb->intin[2] ? pb->intin[2] : 1;
    g_mform.bg     = pb->intin[3];
    g_mform.fg     = pb->intin[4];
    for (int i = 0; i < 16; i++) g_mform.mask[i] = (uint16_t)pb->intin[5 + i];
    for (int i = 0; i < 16; i++) g_mform.data[i] = (uint16_t)pb->intin[21 + i];
}

void vsc_form(int handle, const MFORM *form) {
    if (!form) return;
    g_intin[0] = form->hotx; g_intin[1] = form->hoty;
    g_intin[2] = form->planes ? form->planes : 1;
    g_intin[3] = form->bg;   g_intin[4] = form->fg;
    for (int i = 0; i < 16; i++) g_intin[5 + i]  = (int16_t)form->mask[i];
    for (int i = 0; i < 16; i++) g_intin[21 + i] = (int16_t)form->data[i];
    vdi_emit(VDI_SC_FORM, 0, handle, 0, 37);
}
