// vdi/printers/pdf_device.c — PDF printer device (v_opnwk id 21..30).
//
// Milestone 1: vector translation of the line/fill/rectangle primitives —
// v_pline, v_fillarea, v_bar/vr_recfl.  Curved GDPs, clipping, patterns, text
// and raster blits are dropped (counted) for now and land in later milestones;
// the hooks here are shaped so they slot in without disturbing this path.
//
// Output is a minimal, dependency-free PDF 1.4: one content stream per page
// (uncompressed — valid, just larger; Flate is a later refinement), a flat page
// tree, and an xref built from real byte offsets.  Each page opens with a CTM
// that maps VDI device units (top-left, y down) to PDF points (bottom-left, y
// up), so every primitive below emits raw VDI coordinates.

#include "vdi/printers/pdf_device.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>

// Page geometry.  Vector content is resolution-independent; PDF_DPI only sets how
// finely apps can *place* things (the device-unit grid v_opnwk reports), not the
// smoothness of the output.  720 = 72*10 gives a clean 0.1 pt/unit scale and
// sub-pixel placement against any real printer resolution.  A4 page.
#define PDF_DPI         720
#define PDF_PAGE_PT_W   595             // A4 width  in points (1/72")
#define PDF_PAGE_PT_H   842             // A4 height in points
#define PDF_UNITS_PER_PT (PDF_DPI / 72) // 10 device units per point

// ---- Growable per-page content buffer -------------------------------------
typedef struct pdfpage { struct pdfpage *next; char *data; size_t len, cap; } pdfpage;

typedef struct {
    FILE    *f;                         // output file
    pdfpage *pages, *plast;             // finalised pages (in order)
    pdfpage *cur;                       // page under construction (NULL = none yet)
    int      dirty;                     // cur has real content (not just its CTM)
    double   scale;                     // points per device unit (= 72/PDF_DPI)
    int      page_pt_w, page_pt_h;      // page size, points (the MediaBox)
    int      units_w, units_h;          // page size, device units (the caps extent)
    long     dropped;                   // drawing ops not yet translated (M2+)
} pdfdev;

static void pg_raw(pdfpage *p, const char *s, size_t n) {
    if (p->len + n + 1 > p->cap) {
        size_t nc = p->cap ? p->cap : 1024;
        while (nc < p->len + n + 1) nc *= 2;
        p->data = realloc(p->data, nc);
        p->cap = nc;
    }
    memcpy(p->data + p->len, s, n);
    p->len += n;
    p->data[p->len] = '\0';
}
static void pg_str(pdfpage *p, const char *s) { pg_raw(p, s, strlen(s)); }
static void pg_fmt(pdfpage *p, const char *fmt, ...) {
    char t[256];
    va_list a; va_start(a, fmt);
    int n = vsnprintf(t, sizeof t, fmt, a);
    va_end(a);
    if (n < 0) return;
    pg_raw(p, t, (size_t)n < sizeof t ? (size_t)n : sizeof t - 1);
}

// ---- Page lifecycle -------------------------------------------------------
// Start a page if none is open: a fresh buffer seeded with the device->points
// CTM (scale + y-flip).  [scale 0 0 -scale 0 pageH] maps (x,y) -> (scale*x,
// pageH - scale*y), i.e. VDI top-left/y-down into PDF bottom-left/y-up.
static void pdf_ensure_page(pdfdev *d) {
    if (d->cur) return;
    pdfpage *p = calloc(1, sizeof *p);
    d->cur = p;
    pg_fmt(p, "%g 0 0 %g 0 %d cm\n", d->scale, -d->scale, d->page_pt_h);
}
static void pdf_finalize(pdfdev *d) {            // move cur onto the finalised list
    if (!d->cur) return;
    d->cur->next = NULL;
    if (d->plast) d->plast->next = d->cur; else d->pages = d->cur;
    d->plast = d->cur;
    d->cur = NULL; d->dirty = 0;
}
// v_clrwk on a page that has been drawn into = form feed (eject, start fresh);
// on a still-blank page it's just "clear" — a no-op here, so no blank pages leak.
static void pdf_page_break(pdfdev *d) {
    if (d->dirty) pdf_finalize(d);
}

// ---- Graphics-state + primitive emission ----------------------------------
static void emit_rgb(pdfpage *p, int pen, int stroke) {
    uint32_t c = vdi_pen_rgba(pen);              // 0xRRGGBBAA
    double r = ((c >> 24) & 0xFF) / 255.0;
    double g = ((c >> 16) & 0xFF) / 255.0;
    double b = ((c >>  8) & 0xFF) / 255.0;
    pg_fmt(p, "%.4g %.4g %.4g %s\n", r, g, b, stroke ? "RG" : "rg");
}

// vsl_type 1..6 as a PDF dash array, in device units (~0.1 pt each).  Type 1 and
// the user style (7) render solid in M1.
static const char *dash_for(int type) {
    switch (type) {
        case 2:  return "[180 60] 0";                   // long dash
        case 3:  return "[20 60] 0";                    // dotted
        case 4:  return "[180 60 20 60] 0";             // dash-dot
        case 5:  return "[120 80] 0";                   // dashed
        case 6:  return "[180 60 20 60 20 60] 0";       // dash-dot-dot
        default: return "[] 0";                         // solid
    }
}
static void emit_stroke_state(pdfpage *p, const vdi_ws *w) {
    pg_fmt(p, "%d w\n", w->line_width < 1 ? 1 : w->line_width);
    int round = (w->line_beg == VDI_LE_ROUND || w->line_end == VDI_LE_ROUND);
    pg_fmt(p, "%d J 1 j\n", round ? 1 : 0);             // cap; round join (round pen)
    pg_fmt(p, "%s d\n", dash_for(w->line_type));
}
static void path_polyline(pdfpage *p, const int16_t *pts, int n) {
    pg_fmt(p, "%d %d m\n", pts[0], pts[1]);
    for (int i = 1; i < n; i++) pg_fmt(p, "%d %d l\n", pts[2*i], pts[2*i+1]);
}

static void pdf_pline(pdfpage *p, const vdi_ws *w, const int16_t *pts, int n) {
    if (n < 2) return;
    emit_rgb(p, w->line_color, 1);
    emit_stroke_state(p, w);
    path_polyline(p, pts, n);
    pg_str(p, "S\n");                                   // stroke open path
}

// v_fillarea: even-odd fill (matches vdi_fill_poly) and/or a closed perimeter in
// the fill colour with the current line attributes (matches fillarea.c).  M1
// renders pattern/hatch interiors as a solid fill (tiling patterns are M2).
static void pdf_fillarea(pdfpage *p, const vdi_ws *w, const int16_t *pts, int n) {
    if (n < 2) return;
    int fill  = (w->fill_interior != VDI_FIS_HOLLOW);
    int perim = w->fill_perimeter;
    if (!fill && !perim) return;
    if (fill)  emit_rgb(p, w->fill_color, 0);
    if (perim) { emit_rgb(p, w->fill_color, 1); emit_stroke_state(p, w); }
    path_polyline(p, pts, n);
    pg_str(p, "h\n");                                   // close
    pg_str(p, fill && perim ? "B*\n" : fill ? "f*\n" : "S\n");
}

// v_bar / vr_recfl: pts = x1,y1,x2,y2.  Pixel-inclusive extent (+1) so a zero-
// span bar still has area, matching the raster primitive.
static void pdf_bar(pdfpage *p, const vdi_ws *w, const int16_t *pxy) {
    int x1 = pxy[0], y1 = pxy[1], x2 = pxy[2], y2 = pxy[3];
    int x = x1 < x2 ? x1 : x2, y = y1 < y2 ? y1 : y2;
    int bw = (x1 < x2 ? x2 - x1 : x1 - x2) + 1;
    int bh = (y1 < y2 ? y2 - y1 : y1 - y2) + 1;
    int fill  = (w->fill_interior != VDI_FIS_HOLLOW);
    int perim = w->fill_perimeter;
    if (!fill && !perim) return;
    if (fill)  emit_rgb(p, w->fill_color, 0);
    if (perim) { emit_rgb(p, w->fill_color, 1); emit_stroke_state(p, w); }
    pg_fmt(p, "%d %d %d %d re\n", x, y, bw, bh);
    pg_str(p, fill && perim ? "B\n" : fill ? "f\n" : "S\n");
}

// ---- Dispatch -------------------------------------------------------------
int pdf_intercept(vdi_ws *w, vdi_pb *pb) {
    pdfdev *d = w->dev;
    if (!d) return 1;                                   // no context: swallow safely
    int op = pb->contrl[0], sub = pb->contrl[5];
    switch (op) {
        case VDI_CLRWK: pdf_page_break(d); return 1;
        case VDI_UPDWK: return 1;                       // flush; page break is CLRWK

        case VDI_PLINE:
            if (sub == VDI_BEZ_SUB) { d->dropped++; return 1; }   // v_bez: M2
            pdf_ensure_page(d); pdf_pline(d->cur, w, pb->ptsin, pb->contrl[1]);
            d->dirty = 1; return 1;
        case VDI_FILLAREA:
            if (sub == VDI_BEZ_SUB) { d->dropped++; return 1; }   // v_bez_fill: M2
            pdf_ensure_page(d); pdf_fillarea(d->cur, w, pb->ptsin, pb->contrl[1]);
            d->dirty = 1; return 1;
        case VDI_RECFL:
            pdf_ensure_page(d); pdf_bar(d->cur, w, pb->ptsin);
            d->dirty = 1; return 1;
        case VDI_GDP:
            if (sub == GDP_BAR) { pdf_ensure_page(d); pdf_bar(d->cur, w, pb->ptsin);
                                  d->dirty = 1; return 1; }
            d->dropped++; return 1;                     // curves / justified: M2/M3

        // Drawing ops not yet translated — drop (counted), don't let them scribble
        // on the screen surface via the normal handlers.
        case VDI_GTEXT: case VDI_FTEXT:
        case VDI_PMARKER: case VDI_CELLARRAY: case VDI_CONTOURFILL:
        case VDI_CPYFM: case VDI_VRT_CPYFM: case VDI_TRANSFER_BITS:
            d->dropped++; return 1;

        default:
            return 0;       // attribute setters / inquiries: run the normal handler
    }
}

// ---- File output ----------------------------------------------------------
static void pdf_write_file(pdfdev *d) {
    FILE *f = d->f;
    int n = 0;
    for (pdfpage *p = d->pages; p; p = p->next) n++;
    int total = 2 + 2 * n;                              // catalog + pages + 2/page
    long *off = calloc((size_t)total + 1, sizeof(long));

    fprintf(f, "%%PDF-1.4\n");
    off[1] = ftell(f);
    fprintf(f, "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");
    off[2] = ftell(f);
    fprintf(f, "2 0 obj\n<< /Type /Pages /Count %d /Kids [", n);
    for (int i = 0; i < n; i++) fprintf(f, "%s%d 0 R", i ? " " : "", 3 + 2 * i);
    fprintf(f, "] >>\nendobj\n");

    int i = 0;
    for (pdfpage *p = d->pages; p; p = p->next, i++) {
        int pageobj = 3 + 2 * i, contobj = 4 + 2 * i;
        off[pageobj] = ftell(f);
        fprintf(f, "%d 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 %d %d]"
                   " /Contents %d 0 R /Resources << >> >>\nendobj\n",
                pageobj, d->page_pt_w, d->page_pt_h, contobj);
        off[contobj] = ftell(f);
        fprintf(f, "%d 0 obj\n<< /Length %zu >>\nstream\n", contobj, p->len);
        fwrite(p->data, 1, p->len, f);
        fprintf(f, "endstream\nendobj\n");
    }

    long xref = ftell(f);
    fprintf(f, "xref\n0 %d\n0000000000 65535 f \n", total + 1);
    for (int o = 1; o <= total; o++) fprintf(f, "%010ld 00000 n \n", off[o]);
    fprintf(f, "trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%ld\n%%%%EOF\n",
            total + 1, xref);
    free(off);
}

// ---- Open / caps / close --------------------------------------------------
int pdf_open(vdi_ws *w, const char *path) {
    FILE *f = fopen(path && path[0] ? path : "out.pdf", "wb");
    if (!f) return -1;
    pdfdev *d = calloc(1, sizeof *d);
    if (!d) { fclose(f); return -1; }
    d->f = f;
    d->scale = 72.0 / PDF_DPI;
    d->page_pt_w = PDF_PAGE_PT_W; d->page_pt_h = PDF_PAGE_PT_H;
    d->units_w = PDF_PAGE_PT_W * PDF_UNITS_PER_PT;
    d->units_h = PDF_PAGE_PT_H * PDF_UNITS_PER_PT;
    w->dev = d;
    return 0;
}

void pdf_caps(vdi_ws *w, int16_t *io, int16_t *po) {
    pdfdev *d = w->dev;
    if (!d) return;
    io[0] = (int16_t)(d->units_w - 1);          // addressable extent, device units
    io[1] = (int16_t)(d->units_h - 1);
    io[3] = io[4] = (int16_t)(25400 / PDF_DPI);  // pixel size, microns (1/720" ~= 35)
    po[0] = io[0]; po[1] = io[1];
}

void pdf_close(vdi_ws *w) {
    pdfdev *d = w->dev;
    if (!d) return;
    if (d->cur) {                                // finalise or discard the open page
        if (d->dirty || !d->pages) pdf_finalize(d);
        else { free(d->cur->data); free(d->cur); d->cur = NULL; }
    }
    if (!d->pages) { pdf_ensure_page(d); pdf_finalize(d); }   // guarantee >= 1 page
    pdf_write_file(d);
    fclose(d->f);
    for (pdfpage *p = d->pages; p; ) { pdfpage *nx = p->next; free(p->data); free(p); p = nx; }
    free(d);
    w->dev = NULL;
}
