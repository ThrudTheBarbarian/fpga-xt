// vdi/printers/pdf_device.c — PDF printer device (v_opnwk id 21..30).
//
// Milestones 1-2: vector translation of the line / fill / rectangle primitives
// (v_pline, v_fillarea, v_bar/vr_recfl), the curved GDPs (circle, ellipse, arc,
// pie, rounded box) as true cubic beziers, the workstation clip rectangle as a
// PDF clip path, and pattern/hatch/user fills as PDF tiling patterns.  Text and
// raster blits are dropped (counted) for now and land in later milestones; the
// dispatch cases below are shaped so they slot in without disturbing this path.
//
// Output is a minimal, dependency-free PDF 1.4: one content stream per page
// (uncompressed — valid, just larger; Flate is a later refinement), pattern
// objects for the tiling fills, a flat page tree, and an xref built from real
// byte offsets.  Each page opens with a CTM that maps VDI device units (top-left,
// y down) to PDF points (bottom-left, y up), so every primitive emits raw VDI
// coordinates and the transform does the scaling + flip.

#include "vdi/printers/pdf_device.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <math.h>

// Page geometry.  Vector content is resolution-independent; PDF_DPI only sets how
// finely apps can *place* things (the device-unit grid v_opnwk reports), not the
// smoothness of the output.  720 = 72*10 gives a clean 0.1 pt/unit scale and
// sub-pixel placement against any real printer resolution.  A4 page.
#define PDF_DPI         720
#define PDF_PAGE_PT_W   595             // A4 width  in points (1/72")
#define PDF_PAGE_PT_H   842             // A4 height in points
#define PDF_UNITS_PER_PT (PDF_DPI / 72) // 10 device units per point

// A 16x16 fill mask tiles as a PDF pattern cell of 16 points (each mask pixel = 1
// point), so a pattern is the same physical size as on the 72-dpi screen device.
#define PDF_MAX_PATTERNS 64

// ---- Growable per-page content buffer -------------------------------------
typedef struct pdfpage { struct pdfpage *next; char *data; size_t len, cap; } pdfpage;

// A tiling-fill pattern actually used in the document (deduped by interior +
// style + colour; the mask is snapshotted at first use).
typedef struct { int interior, style, color; uint16_t mask[16]; } pdfpat;

typedef struct {
    FILE    *f;                         // output file
    pdfpage *pages, *plast;             // finalised pages (in order)
    pdfpage *cur;                       // page under construction (NULL = none yet)
    int      dirty;                     // cur has real content (not just its CTM)
    double   scale;                     // points per device unit (= 72/PDF_DPI)
    int      page_pt_w, page_pt_h;      // page size, points (the MediaBox)
    int      units_w, units_h;          // page size, device units (the caps extent)
    pdfpat   pats[PDF_MAX_PATTERNS];    // tiling patterns used
    int      npats;
    long     dropped;                   // drawing ops not yet translated (M3+)
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
// Snap sub-micro values to 0 so %g never emits scientific notation (e.g. cos(90
// deg) ~ 6e-17), which PDF's number syntax rejects.  Our coordinate range never
// reaches the large-magnitude exponent threshold.
static double snap0(double v) { return (v < 1e-6 && v > -1e-6) ? 0.0 : v; }
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

// ---- Graphics-state helpers -----------------------------------------------
static void emit_rgb(pdfpage *p, int pen, int stroke) {
    uint32_t c = vdi_pen_rgba(pen);              // 0xRRGGBBAA
    double r = ((c >> 24) & 0xFF) / 255.0;
    double g = ((c >> 16) & 0xFF) / 255.0;
    double b = ((c >>  8) & 0xFF) / 255.0;
    pg_fmt(p, "%.4g %.4g %.4g %s\n", r, g, b, stroke ? "RG" : "rg");
}

// vsl_type 1..6 as a PDF dash array, in device units (~0.1 pt each).  Type 1 and
// the user style (7) render solid in M2.
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

// The workstation clip rect as a PDF clip path, wrapped in q/Q so it applies only
// to the one primitive (VDI clip persists and only ever intersects the surface;
// per-primitive q ... W n ... Q models that without tracking nesting).
static int clip_push(pdfpage *p, const vdi_ws *w) {
    if (!w->clip_on) return 0;
    int x = w->cx0, y = w->cy0;
    int cw = w->cx1 - w->cx0 + 1, ch = w->cy1 - w->cy0 + 1;
    pg_fmt(p, "q\n%d %d %d %d re W n\n", x, y, cw, ch);
    return 1;
}
static void clip_pop(pdfpage *p, int pushed) { if (pushed) pg_str(p, "Q\n"); }

// Register (dedup) a tiling pattern; returns its index (and stable /Pp name), or
// -1 if the table is full so the caller can fall back to a solid fill.
static int pattern_register(pdfdev *d, int interior, int style, int color,
                            const uint16_t *mask) {
    for (int i = 0; i < d->npats; i++)
        if (d->pats[i].interior == interior && d->pats[i].style == style
            && d->pats[i].color == color)
            return i;
    if (d->npats >= PDF_MAX_PATTERNS) return -1;
    int i = d->npats++;
    d->pats[i].interior = interior; d->pats[i].style = style; d->pats[i].color = color;
    memcpy(d->pats[i].mask, mask, sizeof d->pats[i].mask);
    return i;
}

// Set up the fill paint for the current fill state.  Returns 0 if hollow (no
// fill), else 1 having emitted either a solid colour (rg) or a tiling pattern
// (/Pattern cs /PpK scn).  Pattern/hatch/user interiors come back as a 16x16
// mask from vdi_fill_mask; solid comes back NULL.
static int setup_fill(pdfdev *d, const vdi_ws *w) {
    pdfpage *p = d->cur;
    if (w->fill_interior == VDI_FIS_HOLLOW) return 0;
    const uint16_t *mask = vdi_fill_mask(w->fill_interior, w->fill_style);
    if (mask) {
        int idx = pattern_register(d, w->fill_interior, w->fill_style, w->fill_color, mask);
        if (idx >= 0) { pg_fmt(p, "/Pattern cs /Pp%d scn\n", idx); return 1; }
        // table full -> solid fallback
    }
    emit_rgb(p, w->fill_color, 0);
    return 1;
}
static void paint_fp(pdfpage *p, int fill, int perim, int evenodd) {
    if (fill && perim) pg_str(p, evenodd ? "B*\n" : "B\n");
    else if (fill)     pg_str(p, evenodd ? "f*\n" : "f\n");
    else if (perim)    pg_str(p, "S\n");
}

// ---- Path builders --------------------------------------------------------
static void path_polyline(pdfpage *p, const int16_t *pts, int n) {
    pg_fmt(p, "%d %d m\n", pts[0], pts[1]);
    for (int i = 1; i < n; i++) pg_fmt(p, "%d %d l\n", pts[2*i], pts[2*i+1]);
}

// Append an elliptical arc, centre (cx,cy) radii (rx,ry), from a0..a1 (radians),
// as cubic beziers (<=90 deg per segment).  VDI convention: a point at angle a is
// (cx + rx cos a, cy - ry sin a) — y down, so +angle is visually up, matching the
// on-screen GDPs.  move!=0 starts the subpath (moveto); else a lineto joins the
// current point to the arc start (the straight edges of a rounded box).
static void arc_bezier(pdfpage *p, double cx, double cy, double rx, double ry,
                       double a0, double a1, int move) {
    double span = a1 - a0;
    int nseg = (int)ceil(fabs(span) / (M_PI / 2));
    if (nseg < 1) nseg = 1;
    double d = span / nseg;
    double k = (4.0 / 3.0) * tan(d / 4.0);              // control-point distance
    double a = a0;
    double sx = cx + rx * cos(a), sy = cy - ry * sin(a);
    pg_fmt(p, "%g %g %s\n", sx, sy, move ? "m" : "l");
    for (int i = 0; i < nseg; i++) {
        double b = a + d;
        double x0 = cx + rx * cos(a), y0 = cy - ry * sin(a);
        double x3 = cx + rx * cos(b), y3 = cy - ry * sin(b);
        double dx0 = -rx * sin(a), dy0 = -ry * cos(a);  // dP/da at a, b
        double dx3 = -rx * sin(b), dy3 = -ry * cos(b);
        pg_fmt(p, "%g %g %g %g %g %g c\n",
               snap0(x0 + k*dx0), snap0(y0 + k*dy0), snap0(x3 - k*dx3),
               snap0(y3 - k*dy3), snap0(x3), snap0(y3));
        a = b;
    }
}

// Rounded-rectangle path (four quarter-circle corners + straight edges), matching
// gdp.c's default corner radius (min(w,h)/6, clamped).
static void rrect_path(pdfpage *p, int x1, int y1, int x2, int y2) {
    if (x1 > x2) { int t = x1; x1 = x2; x2 = t; }
    if (y1 > y2) { int t = y1; y1 = y2; y2 = t; }
    int ww = x2 - x1, hh = y2 - y1, rmax = (ww < hh ? ww : hh) / 2;
    int r = (ww < hh ? ww : hh) / 6;
    if (r > rmax) r = rmax; if (r < 1) r = 1;
    const double D = M_PI / 180.0;
    const struct { double cx, cy, a0, a1; } c[4] = {
        { x1 + r, y1 + r, 180, 90 },    // top-left:     left  -> top
        { x2 - r, y1 + r,  90,  0 },    // top-right:    top   -> right
        { x2 - r, y2 - r, 360, 270 },   // bottom-right: right -> bottom
        { x1 + r, y2 - r, 270, 180 },   // bottom-left:  bottom-> left
    };
    for (int i = 0; i < 4; i++)
        arc_bezier(p, c[i].cx, c[i].cy, r, r, c[i].a0 * D, c[i].a1 * D, i == 0);
    pg_str(p, "h\n");
}

// ---- Primitives -----------------------------------------------------------
static void pdf_pline(pdfdev *d, const vdi_ws *w, const int16_t *pts, int n) {
    if (n < 2) return;
    pdfpage *p = d->cur;
    int clp = clip_push(p, w);
    emit_rgb(p, w->line_color, 1);
    emit_stroke_state(p, w);
    path_polyline(p, pts, n);
    pg_str(p, "S\n");
    clip_pop(p, clp);
}

// v_fillarea: even-odd fill (matches vdi_fill_poly) and/or a closed perimeter in
// the fill colour with the current line attributes (matches fillarea.c).
static void pdf_fillarea(pdfdev *d, const vdi_ws *w, const int16_t *pts, int n) {
    if (n < 2) return;
    pdfpage *p = d->cur;
    int clp = clip_push(p, w);
    int fill = setup_fill(d, w);
    int perim = w->fill_perimeter;
    if (perim) { emit_rgb(p, w->fill_color, 1); emit_stroke_state(p, w); }
    if (fill || perim) {
        path_polyline(p, pts, n);
        pg_str(p, "h\n");
        paint_fp(p, fill, perim, 1);                    // even-odd
    }
    clip_pop(p, clp);
}

// v_bar / vr_recfl: pts = x1,y1,x2,y2.  Pixel-inclusive extent (+1) so a zero-
// span bar still has area, matching the raster primitive.
static void pdf_bar(pdfdev *d, const vdi_ws *w, const int16_t *pxy) {
    pdfpage *p = d->cur;
    int x1 = pxy[0], y1 = pxy[1], x2 = pxy[2], y2 = pxy[3];
    int x = x1 < x2 ? x1 : x2, y = y1 < y2 ? y1 : y2;
    int bw = (x1 < x2 ? x2 - x1 : x1 - x2) + 1;
    int bh = (y1 < y2 ? y2 - y1 : y1 - y2) + 1;
    int clp = clip_push(p, w);
    int fill = setup_fill(d, w);
    int perim = w->fill_perimeter;
    if (perim) { emit_rgb(p, w->fill_color, 1); emit_stroke_state(p, w); }
    if (fill || perim) {
        pg_fmt(p, "%d %d %d %d re\n", x, y, bw, bh);
        paint_fp(p, fill, perim, 0);
    }
    clip_pop(p, clp);
}

// Curved GDPs (circle / ellipse / arc / pie / rounded box).  Filled shapes use
// the fill attributes + perimeter; open arcs use the line attributes — matching
// gdp.c.  Returns 1 if it drew something.
static int pdf_gdp(pdfdev *d, const vdi_ws *w, vdi_pb *pb) {
    pdfpage *p = d->cur;
    int sub = pb->contrl[5];
    const int16_t *pt = pb->ptsin;
    double cx = pt[0], cy = pt[1];
    double a0 = pb->intin[0] * (M_PI / 1800.0);         // tenths of a degree -> rad
    double a1 = pb->intin[1] * (M_PI / 1800.0);
    if (a1 <= a0) a1 += 2 * M_PI;
    int clp = clip_push(p, w);
    int drew = 1;

    switch (sub) {
        case GDP_CIRCLE: case GDP_ELLIPSE: {
            double rx = pt[2], ry = (sub == GDP_CIRCLE) ? pt[2] : pt[3];
            int fill = setup_fill(d, w), perim = w->fill_perimeter;
            if (perim) { emit_rgb(p, w->fill_color, 1); emit_stroke_state(p, w); }
            arc_bezier(p, cx, cy, rx, ry, 0, 2 * M_PI, 1);
            pg_str(p, "h\n");
            paint_fp(p, fill, perim, 0);
            break;
        }
        case GDP_PIE: case GDP_ELLPIE: {
            double rx = pt[2], ry = (sub == GDP_PIE) ? pt[2] : pt[3];
            int fill = setup_fill(d, w), perim = w->fill_perimeter;
            if (perim) { emit_rgb(p, w->fill_color, 1); emit_stroke_state(p, w); }
            arc_bezier(p, cx, cy, rx, ry, a0, a1, 1);
            pg_fmt(p, "%g %g l\nh\n", cx, cy);          // wedge to centre + close
            paint_fp(p, fill, perim, 0);
            break;
        }
        case GDP_ARC: case GDP_ELLARC: {
            double rx = pt[2], ry = (sub == GDP_ARC) ? pt[2] : pt[3];
            emit_rgb(p, w->line_color, 1);
            emit_stroke_state(p, w);
            arc_bezier(p, cx, cy, rx, ry, a0, a1, 1);
            pg_str(p, "S\n");
            break;
        }
        case GDP_RBOX: case GDP_RFBOX: {
            if (sub == GDP_RFBOX) {
                int fill = setup_fill(d, w), perim = w->fill_perimeter;
                if (perim) { emit_rgb(p, w->fill_color, 1); emit_stroke_state(p, w); }
                rrect_path(p, pt[0], pt[1], pt[2], pt[3]);
                paint_fp(p, fill, perim, 0);
            } else {
                emit_rgb(p, w->line_color, 1);
                emit_stroke_state(p, w);
                rrect_path(p, pt[0], pt[1], pt[2], pt[3]);
                pg_str(p, "S\n");
            }
            break;
        }
        default: drew = 0; break;
    }
    clip_pop(p, clp);
    return drew;
}

// ---- Text (glyph outlines as vector paths) --------------------------------
// On this device, font pixels are device units (as surface pixels are on the
// screen device), so glyph outlines emit directly — no scale factor — and the
// page CTM maps them to points.  The app sizes text in device units (vst_height)
// or converts points using the reported device resolution.
#define GLYPH_MAXPTS 1024

static unsigned utf8_next(const char **pp) {
    const unsigned char *s = (const unsigned char *)*pp;
    unsigned cp; int n;
    if (*s < 0x80)             { cp = *s;         n = 1; }
    else if ((*s & 0xE0)==0xC0){ cp = *s & 0x1F;  n = 2; }
    else if ((*s & 0xF0)==0xE0){ cp = *s & 0x0F;  n = 3; }
    else if ((*s & 0xF8)==0xF0){ cp = *s & 0x07;  n = 4; }
    else { (*pp)++; return 0xFFFD; }
    for (int i = 1; i < n; i++) {
        if ((s[i] & 0xC0) != 0x80) { (*pp)++; return 0xFFFD; }
        cp = (cp << 6) | (s[i] & 0x3F);
    }
    *pp += n;
    return cp;
}

// Append one glyph's outline (FreeType v_bez form: bit1 = move/new contour,
// bit0 = cubic anchor whose next 3 points are the two controls + end) as closed
// PDF subpaths, glyph origin at (ox,oy) device units (oy = baseline, y down).
static void glyph_path(pdfpage *p, font *f, unsigned cp, double ox, double oy) {
    int16_t xy[2 * GLYPH_MAXPTS]; uint8_t bz[GLYPH_MAXPTS];
    int n = font_get_outline(f, cp, xy, bz, GLYPH_MAXPTS);
    int started = 0;
    for (int i = 0; i < n; ) {
        int fl = bz[i];
        if (fl & 2) {                                   // move: close prev, open new
            if (started) pg_str(p, "h\n");
            pg_fmt(p, "%g %g m\n", ox + xy[2*i], oy + xy[2*i+1]);
            started = 1;
        } else if (!(fl & 1)) {                         // plain on-curve point
            pg_fmt(p, "%g %g l\n", ox + xy[2*i], oy + xy[2*i+1]);
        }
        if (fl & 1) {                                   // cubic: anchor i, ctrls i+1,i+2, end i+3
            if (i + 3 >= n) break;
            pg_fmt(p, "%g %g %g %g %g %g c\n",
                   ox+xy[2*(i+1)], oy+xy[2*(i+1)+1],
                   ox+xy[2*(i+2)], oy+xy[2*(i+2)+1],
                   ox+xy[2*(i+3)], oy+xy[2*(i+3)+1]);
            i += 4;
        } else i++;
    }
    if (started) pg_str(p, "h\n");
}

// Sum of per-glyph cell advances — matches the placement below, so centre/right
// alignment lands correctly.
static int text_adv(font *f, const char *s) {
    int w = 0;
    for (const char *q = s; *q; ) w += font_char_metrics(f, utf8_next(&q), NULL, NULL);
    return w;
}
// Lay glyphs along a baseline from (x0,baseline), advancing by metrics, each glyph
// origin offset by (dx,dy).
static void glyph_run(pdfpage *p, font *f, double x0, double baseline,
                      const char *s, double dx, double dy) {
    double penx = x0;
    for (const char *q = s; *q; ) {
        unsigned cp = utf8_next(&q);
        glyph_path(p, f, cp, penx + dx, baseline + dy);
        penx += font_char_metrics(f, cp, NULL, NULL);
    }
}
// q + a text matrix (rotation a rad, shear k) about pivot (px,py); close with Q.
static void text_matrix(pdfpage *p, double a, double k, double px, double py) {
    double A = cos(a), B = -sin(a), C = sin(a) - k*cos(a), D = cos(a) + k*sin(a);
    double E = px - (A*px + C*py), F = py - (B*px + D*py);
    pg_fmt(p, "q\n%g %g %g %g %g %g cm\n",
           snap0(A), snap0(B), snap0(C), snap0(D), snap0(E), snap0(F));
}
// Anchor y -> em-box top (vertical alignment), matching gtext.c.
static int text_top(const vdi_ws *w, font *f, int ay) {
    int asc = font_ascent(f), H = font_height(f);
    switch (w->text_valign) {
        case VDI_TA_BASELINE: return ay - asc;
        case VDI_TA_HALF:     return ay - H/2;
        case VDI_TA_BOTTOM: case VDI_TA_DESCENT: return ay - H;
        default: return ay;                             // TOP / ASCENT
    }
}

// v_gtext / v_ftext: advancing text with alignment, rotation, italic/skew, the
// bold/outline/underline/shadow effects, and the opaque background box.  Writing
// mode (XOR) has no PDF equivalent and is ignored.
static void pdf_text(pdfdev *d, const vdi_ws *w, int ax, int ay, const char *s) {
    if (!s[0]) return;
    pdfpage *p = d->cur;
    font *f = vdi_ws_font(w); if (!f) return;
    int H = font_height(f), sz = font_size(f);
    int ytop = text_top(w, f, ay);
    double baseline = ytop + font_ascent(f);
    int fx = w->text_effects;
    double a = w->text_rotation * (M_PI / 1800.0);
    double k = (fx & FX_ITALIC) ? 0.21 : 0.0;
    if (w->text_skew) k += tan(w->text_skew * (M_PI / 1800.0));
    int total = text_adv(f, s);
    int px0 = ax;
    if (a == 0.0) {                                     // halign only when upright
        if (w->text_halign == VDI_TA_CENTER) px0 -= total / 2;
        else if (w->text_halign == VDI_TA_RIGHT) px0 -= total;
    }
    int clp = clip_push(p, w);
    if (w->text_bg_color >= 0 && w->wr_mode == VDI_MD_REPLACE && a == 0.0 && k == 0.0) {
        emit_rgb(p, w->text_bg_color, 0);              // opaque cell box
        pg_fmt(p, "%d %d %d %d re\nf\n", px0, ytop, total, H);
    }
    int wrapped = (a != 0.0 || k != 0.0);
    if (wrapped) text_matrix(p, a, k, px0, baseline);
    if (fx & FX_SHADOW) {                              // offset darker copy first
        int sh = sz / 12 + 1;
        uint32_t c = vdi_pen_rgba(w->text_color);
        pg_fmt(p, "%.4g %.4g %.4g rg\n",
               ((c>>24)&0xFF)/510.0, ((c>>16)&0xFF)/510.0, ((c>>8)&0xFF)/510.0);
        glyph_run(p, f, px0, baseline, s, sh, sh);
        pg_str(p, "f\n");
    }
    glyph_run(p, f, px0, baseline, s, 0, 0);
    if (fx & FX_OUTLINE) {                             // hollow: stroke only
        emit_rgb(p, w->text_color, 1);
        pg_fmt(p, "[] 0 d\n%d w\nS\n", sz / 48 + 1);
    } else if (fx & FX_BOLD) {                         // approximate embolden
        emit_rgb(p, w->text_color, 0); emit_rgb(p, w->text_color, 1);
        pg_fmt(p, "[] 0 d\n%d w\nB\n", sz / 22 + 1);
    } else {
        emit_rgb(p, w->text_color, 0); pg_str(p, "f\n");
    }
    if (fx & FX_UNDERLINE) {
        double uo = sz / 8.0 + 1;
        emit_rgb(p, w->text_color, 1);
        pg_fmt(p, "[] 0 d\n%d w\n%g %g m %g %g l\nS\n",
               sz / 16 + 1, (double)px0, baseline + uo, (double)(px0 + total), baseline + uo);
    }
    if (wrapped) pg_str(p, "Q\n");
    clip_pop(p, clp);
}

// v_ftext_offset: each codepoint at an app-supplied (x,y) offset from the anchor.
static void pdf_text_offsets(pdfdev *d, const vdi_ws *w, int ax, int ay,
                             const char *s, const int16_t *off) {
    if (!s[0]) return;
    pdfpage *p = d->cur;
    font *f = vdi_ws_font(w); if (!f) return;
    int ytop = text_top(w, f, ay), asc = font_ascent(f);
    int clp = clip_push(p, w);
    int j = 0;
    for (const char *q = s; *q; j++) {
        unsigned cp = utf8_next(&q);
        glyph_path(p, f, cp, ax + off[2*j], ytop + off[2*j+1] + asc);
    }
    emit_rgb(p, w->text_color, 0); pg_str(p, "f\n");
    clip_pop(p, clp);
}

// v_justified (GDP 10): glyphs placed at the font module's justified x offsets.
static void pdf_justified(pdfdev *d, const vdi_ws *w, vdi_pb *pb) {
    pdfpage *p = d->cur;
    font *f = vdi_ws_font(w); if (!f) return;
    int nch = pb->contrl[3] - 2; if (nch < 0) nch = 0; if (nch > 125) nch = 125;
    char buf[128];
    for (int i = 0; i < nch; i++) buf[i] = (char)pb->intin[2 + i];
    buf[nch] = '\0';
    if (!buf[0]) return;
    int ax = pb->ptsin[0], width = pb->ptsin[2];
    int ytop = text_top(w, f, pb->ptsin[1]);
    double baseline = ytop + font_ascent(f);
    int16_t offx[256];
    int ncp = font_justify_offsets(f, buf, width, pb->intin[0], pb->intin[1], offx);
    int clp = clip_push(p, w);
    int j = 0;
    for (const char *q = buf; *q && j < ncp; j++)
        glyph_path(p, f, utf8_next(&q), ax + offx[j], baseline);
    emit_rgb(p, w->text_color, 0); pg_str(p, "f\n");
    clip_pop(p, clp);
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
            if (sub == VDI_BEZ_SUB) { d->dropped++; return 1; }   // v_bez: later
            pdf_ensure_page(d); pdf_pline(d, w, pb->ptsin, pb->contrl[1]);
            d->dirty = 1; return 1;
        case VDI_FILLAREA:
            if (sub == VDI_BEZ_SUB) { d->dropped++; return 1; }   // v_bez_fill: later
            pdf_ensure_page(d); pdf_fillarea(d, w, pb->ptsin, pb->contrl[1]);
            d->dirty = 1; return 1;
        case VDI_RECFL:
            pdf_ensure_page(d); pdf_bar(d, w, pb->ptsin);
            d->dirty = 1; return 1;
        case VDI_GDP:
            if (sub == GDP_BAR)        { pdf_ensure_page(d); pdf_bar(d, w, pb->ptsin); d->dirty = 1; }
            else if (sub == GDP_JUSTIFIED) { pdf_ensure_page(d); pdf_justified(d, w, pb); d->dirty = 1; }
            else if (sub == GDP_BEZ)   { /* v_bez_on/off: state only, ignore */ }
            else { pdf_ensure_page(d); if (pdf_gdp(d, w, pb)) d->dirty = 1; }
            return 1;

        case VDI_GTEXT: case VDI_FTEXT: {
            pdf_ensure_page(d);
            int n = pb->contrl[3]; if (n < 0) n = 0; if (n > 127) n = 127;
            char b[128];
            for (int i = 0; i < n; i++) b[i] = (char)pb->intin[i];
            b[n] = '\0';
            if (op == VDI_FTEXT && pb->contrl[1] > 1)
                pdf_text_offsets(d, w, pb->ptsin[0], pb->ptsin[1], b, pb->ptsin + 2);
            else
                pdf_text(d, w, pb->ptsin[0], pb->ptsin[1], b);
            d->dirty = 1; return 1;
        }

        // Drawing ops not yet translated — drop (counted), don't let them scribble
        // on the screen surface via the normal handlers.
        case VDI_PMARKER: case VDI_CELLARRAY: case VDI_CONTOURFILL:
        case VDI_CPYFM: case VDI_VRT_CPYFM: case VDI_TRANSFER_BITS:
            d->dropped++; return 1;

        default:
            return 0;       // attribute setters / inquiries: run the normal handler
    }
}

// ---- File output ----------------------------------------------------------
// Object layout: 1 = catalog, 2 = pages, 3..(2+P) = the P pattern objects,
// then two objects (page + contents) per page.  Pattern /PpK names are stable
// (K = registry index) so the names emitted into the content during drawing
// match the page /Resources here.
static void write_pattern(pdfdev *d, FILE *f, int idx) {
    pdfpat *pat = &d->pats[idx];
    uint32_t c = vdi_pen_rgba(pat->color);
    pdfpage tmp = {0};
    pg_fmt(&tmp, "%.4g %.4g %.4g rg\n",
           ((c >> 24) & 0xFF) / 255.0, ((c >> 16) & 0xFF) / 255.0, ((c >> 8) & 0xFF) / 255.0);
    for (int my = 0; my < 16; my++) {                   // set bits -> 1pt cells
        uint16_t bits = pat->mask[my];
        for (int mx = 0; mx < 16; mx++)
            if ((bits >> mx) & 1) pg_fmt(&tmp, "%d %d 1 1 re ", mx, 15 - my);
    }
    pg_str(&tmp, "\nf\n");
    fprintf(f, "%d 0 obj\n<< /Type /Pattern /PatternType 1 /PaintType 1"
               " /TilingType 1 /BBox [0 0 16 16] /XStep 16 /YStep 16"
               " /Matrix [1 0 0 1 0 0] /Resources << >> /Length %zu >>\nstream\n",
            3 + idx, tmp.len);
    fwrite(tmp.data, 1, tmp.len, f);
    fprintf(f, "endstream\nendobj\n");
    free(tmp.data);
}

static void pdf_write_file(pdfdev *d) {
    FILE *f = d->f;
    int n = 0;
    for (pdfpage *p = d->pages; p; p = p->next) n++;
    int P = d->npats;
    int total = 2 + P + 2 * n;
    long *off = calloc((size_t)total + 1, sizeof(long));

    fprintf(f, "%%PDF-1.4\n");
    off[1] = ftell(f);
    fprintf(f, "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");
    off[2] = ftell(f);
    fprintf(f, "2 0 obj\n<< /Type /Pages /Count %d /Kids [", n);
    for (int i = 0; i < n; i++) fprintf(f, "%s%d 0 R", i ? " " : "", 3 + P + 2 * i);
    fprintf(f, "] >>\nendobj\n");

    for (int i = 0; i < P; i++) { off[3 + i] = ftell(f); write_pattern(d, f, i); }

    int i = 0;
    for (pdfpage *p = d->pages; p; p = p->next, i++) {
        int pageobj = 3 + P + 2 * i, contobj = 4 + P + 2 * i;
        off[pageobj] = ftell(f);
        fprintf(f, "%d 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 %d %d]"
                   " /Contents %d 0 R /Resources << ", pageobj,
                d->page_pt_w, d->page_pt_h, contobj);
        if (P > 0) {
            fprintf(f, "/Pattern << ");
            for (int k = 0; k < P; k++) fprintf(f, "/Pp%d %d 0 R ", k, 3 + k);
            fprintf(f, ">> ");
        }
        fprintf(f, ">> >>\nendobj\n");
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
