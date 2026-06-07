// vdi/printers/pdf_device.h — the PDF "printer" VDI device (v_opnwk id 21..30).
//
// A PDF workstation translates VDI drawing calls into PDF page content, vector
// where it can and (later) raster where it can't, instead of drawing to a
// surface.  It mirrors the metafile device (vdi/metafile.c): open at v_opnwk,
// intercept calls in vdi_call, finalise at v_clswk.  Unlike the metafile — which
// records *every* call — the PDF device intercepts only the drawing/page opcodes
// and lets attribute-setters and inquiries fall through to their normal handlers,
// so the workstation's graphics state (colour, line, fill, clip) is maintained
// for us and read back at emit time.
//
// Coordinates: VDI device units, top-left origin, y down.  Each page begins with
// one CTM (`cm`) that scales device units to PDF points and flips y, so the
// translation code emits raw VDI coordinates and the page transform does the
// rest.  Vector geometry is resolution-independent; a DPI is only ever chosen for
// raster-fallback tiles (a later milestone).
//
// This is the printers/ subsystem entry point so other page devices (PostScript,
// raw raster) can sit alongside later.

#ifndef GEM_VDI_PDF_DEVICE_H
#define GEM_VDI_PDF_DEVICE_H

#include "vdi/vdi.h"
#include "vdi/internal.h"

// Open a PDF workstation onto `path` (NULL/empty => "out.pdf").  Stores the page
// context in w->dev.  Returns 0 on success, -1 if the file can't be created.
int  pdf_open(vdi_ws *w, const char *path);

// Override the v_opnwk capability extent (intout/ptsout) with the PDF page size
// in device units (call after vdi_fill_caps, which reports the screen extent).
void pdf_caps(vdi_ws *w, int16_t *intout, int16_t *ptsout);

// Handle one VDI call on a PDF workstation.  Returns 1 if the call was consumed
// (a drawing op was translated, or a page op handled), 0 if the caller should let
// it fall through to the normal opcode handler (attribute setters, inquiries).
int  pdf_intercept(vdi_ws *w, vdi_pb *pb);

// Finalise the document (flush the last page, write the xref/trailer) and close.
void pdf_close(vdi_ws *w);

#endif // GEM_VDI_PDF_DEVICE_H
