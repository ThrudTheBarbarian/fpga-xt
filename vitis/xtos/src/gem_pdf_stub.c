// gem_pdf_stub.c — failure/no-op stubs for the GEM PDF printer device.
//
// open_wk.c / core.c reference the printers/ entry points (pdf_open/_caps/
// _intercept/_close) for v_opnwk device ids 21..30.  The real PDF device
// (gem/vdi/printers/pdf_device.c) Flate-compresses streams and needs zlib,
// which the A9 build doesn't carry — and printing isn't in scope for the VDI+
// FreeType bring-up.  These stubs make the printer report "no device" (pdf_open
// fails) and never intercept screen drawing, satisfying the link.  Swap for the
// real device once a deflate provider is vendored.

#include "vdi/printers/pdf_device.h"

int  pdf_open(vdi_ws *w, const char *path) { (void)w; (void)path; return -1; }
void pdf_caps(vdi_ws *w, int16_t *intout, int16_t *ptsout) { (void)w; (void)intout; (void)ptsout; }
int  pdf_intercept(vdi_ws *w, vdi_pb *pb) { (void)w; (void)pb; return 0; }
void pdf_close(vdi_ws *w) { (void)w; }
