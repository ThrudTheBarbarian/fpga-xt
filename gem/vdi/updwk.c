// vdi/updwk.c — v_updwk (update workstation: flush any deferred output).  Our
// screen drawing is immediate, so this is a no-op there.  When the PDF printer
// device lands, this is where a page is flushed/emitted; a metafile records the
// call so a replay can flush at the same point.

#include "vdi/vdi.h"
#include "vdi/internal.h"

void op_updwk(vdi_pb *pb) { (void)pb; }        // immediate drawing => nothing to flush

void v_updwk(int handle) { vdi_emit(VDI_UPDWK, 0, handle, 0, 0); }
