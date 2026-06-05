// vdi/core.c — VDI workstation table, pen palette, clipped primitives, the
// dispatcher, and the shared C-binding scratch.  The individual opcodes live in
// vdi/<call>.c; this file is the shared spine they hang off.

#include "vdi/vdi.h"
#include "vdi/internal.h"
#include <stddef.h>
#include <string.h>

// ---- Workstations ---------------------------------------------------------
static vdi_ws   ws_tab[VDI_MAX_WS];
static uint32_t pen_tab[256];

vdi_ws *vdi_ws_of(int handle) {
    if (handle < 1 || handle > VDI_MAX_WS) return NULL;
    vdi_ws *w = &ws_tab[handle - 1];
    return w->used ? w : NULL;
}
int vdi_ws_alloc(void) {
    for (int i = 1; i < VDI_MAX_WS; i++) if (!ws_tab[i].used) {   // slot 0 = physical
        memset(&ws_tab[i], 0, sizeof(ws_tab[i]));
        ws_tab[i].used = 1; ws_tab[i].line_color = 1;
        ws_tab[i].line_width = 1; ws_tab[i].line_type = 1;
        ws_tab[i].fill_color = 1; ws_tab[i].text_color = 1; ws_tab[i].fill_interior = 1;
        ws_tab[i].fill_style = 1; ws_tab[i].fill_perimeter = 1;
        ws_tab[i].marker_type = 3; ws_tab[i].marker_height = 11; ws_tab[i].marker_color = 1;
        ws_tab[i].wr_mode = VDI_MD_REPLACE;
        ws_tab[i].text_font_id = 1; ws_tab[i].text_valign = VDI_TA_TOP;
        return i + 1;
    }
    return 0;
}
void vdi_ws_free(int handle) {
    vdi_ws *w = vdi_ws_of(handle);
    if (w && (w - ws_tab) != 0) w->used = 0;
}

// Effective clip rect: ws clip ∩ surface, inclusive.
void vdi_ws_clip(const vdi_ws *w, int *x0, int *y0, int *x1, int *y1) {
    *x0 = 0; *y0 = 0; *x1 = w->target->w - 1; *y1 = w->target->h - 1;
    if (w->clip_on) {
        if (w->cx0 > *x0) *x0 = w->cx0;
        if (w->cy0 > *y0) *y0 = w->cy0;
        if (w->cx1 < *x1) *x1 = w->cx1;
        if (w->cy1 < *y1) *y1 = w->cy1;
    }
}

// ---- Pen palette ----------------------------------------------------------
static void pen_init(void) {
    static const uint32_t vdi16[16] = {
        GFX_RGB(0xff,0xff,0xff), GFX_RGB(0x00,0x00,0x00),   // 0 white, 1 black
        GFX_RGB(0xff,0x00,0x00), GFX_RGB(0x00,0xff,0x00),   // 2 red,   3 green
        GFX_RGB(0x00,0x00,0xff), GFX_RGB(0x00,0xff,0xff),   // 4 blue,  5 cyan
        GFX_RGB(0xff,0xff,0x00), GFX_RGB(0xff,0x00,0xff),   // 6 yellow,7 magenta
        GFX_RGB(0xc0,0xc0,0xc0), GFX_RGB(0x80,0x80,0x80),   // 8 ltgrey,9 grey
        GFX_RGB(0x80,0x00,0x00), GFX_RGB(0x00,0x80,0x00),   // 10 dkred, 11 dkgrn
        GFX_RGB(0x00,0x00,0x80), GFX_RGB(0x00,0x80,0x80),   // 12 dkblue,13 dkcyan
        GFX_RGB(0x80,0x80,0x00), GFX_RGB(0x80,0x00,0x80),   // 14 dkyel, 15 dkmag
    };
    for (int i = 0; i < 256; i++) pen_tab[i] = (i < 16) ? vdi16[i] : GFX_RGB(0,0,0);
}
uint32_t vdi_pen_rgba(int pen) { return pen_tab[pen & 0xFF]; }
void vdi_set_pen(int index, uint32_t rgba) { pen_tab[index & 0xFF] = rgba; }

// Fill pattern/hatch masks live in patterns.c (vdi_fill_mask).

// ---- Clipped primitives ---------------------------------------------------
void vdi_fill_rect(const vdi_ws *w, int x0, int y0, int x1, int y1, int pen) {
    if (x0 > x1) { int t = x0; x0 = x1; x1 = t; }
    if (y0 > y1) { int t = y0; y0 = y1; y1 = t; }
    int cx0, cy0, cx1, cy1; vdi_ws_clip(w, &cx0, &cy0, &cx1, &cy1);
    if (x0 < cx0) x0 = cx0; if (y0 < cy0) y0 = cy0;
    if (x1 > cx1) x1 = cx1; if (y1 > cy1) y1 = cy1;
    if (x0 > x1 || y0 > y1) return;
    uint32_t ink = pen_tab[pen & 0xFF];
    int mode = w->wr_mode;
    if (mode == VDI_MD_ERASE) return;                  // solid = all foreground
    if (mode != VDI_MD_XOR) { gfx_fill_rect(w->target, x0, y0, x1-x0+1, y1-y0+1, ink); return; }
    gfx_surface *s = w->target;
    uint32_t x = ink & 0xFFFFFF00u;
    for (int y = y0; y <= y1; y++) {
        uint32_t *row = s->px + (size_t)y * s->stride;
        for (int i = x0; i <= x1; i++) row[i] ^= x;
    }
}

void vdi_fill_rect_masked(const vdi_ws *w, int x0, int y0, int x1, int y1,
                          int pen, const uint16_t *mask) {
    if (!mask) { vdi_fill_rect(w, x0, y0, x1, y1, pen); return; }
    if (x0 > x1) { int t = x0; x0 = x1; x1 = t; }
    if (y0 > y1) { int t = y0; y0 = y1; y1 = t; }
    int cx0, cy0, cx1, cy1; vdi_ws_clip(w, &cx0, &cy0, &cx1, &cy1);
    if (x0 < cx0) x0 = cx0; if (y0 < cy0) y0 = cy0;
    if (x1 > cx1) x1 = cx1; if (y1 > cy1) y1 = cy1;
    if (x0 > x1 || y0 > y1) return;
    uint32_t ink = pen_tab[pen & 0xFF], ground = pen_tab[0];
    int mode = w->wr_mode;
    gfx_surface *s = w->target;
    for (int y = y0; y <= y1; y++) {
        uint16_t bits = mask[y & 15];
        uint32_t *row = s->px + (size_t)y * s->stride;
        for (int x = x0; x <= x1; x++)
            row[x] = vdi_wrmix(mode, row[x], ink, ground, (bits >> (x & 15)) & 1);
    }
}

// Scanline fill of a polygon (even-odd), clipped, with an optional 16x16 mask.
void vdi_fill_poly(const vdi_ws *w, const int16_t *xy, int n, int pen, const uint16_t *mask) {
    if (n < 3) return;
    int cx0, cy0, cx1, cy1; vdi_ws_clip(w, &cx0, &cy0, &cx1, &cy1);
    int ymin = cy1, ymax = cy0;
    for (int i = 0; i < n; i++) { int y = xy[2*i+1]; if (y < ymin) ymin = y; if (y > ymax) ymax = y; }
    if (ymin < cy0) ymin = cy0; if (ymax > cy1) ymax = cy1;
    uint32_t ink = pen_tab[pen & 0xFF], ground = pen_tab[0];
    int mode = w->wr_mode;
    gfx_surface *s = w->target;
    int xs[128];
    for (int y = ymin; y <= ymax; y++) {
        int ni = 0;
        for (int i = 0; i < n; i++) {
            int j = (i + 1) % n;
            int y0 = xy[2*i+1], y1 = xy[2*j+1], x0 = xy[2*i], x1 = xy[2*j];
            if ((y0 <= y && y1 > y) || (y1 <= y && y0 > y)) {       // half-open edge rule
                int xi = x0 + (int)((long)(y - y0) * (x1 - x0) / (y1 - y0));
                if (ni < 128) xs[ni++] = xi;
            }
        }
        for (int a = 0; a < ni - 1; a++)                            // sort intersections
            for (int b = a + 1; b < ni; b++) if (xs[b] < xs[a]) { int t = xs[a]; xs[a] = xs[b]; xs[b] = t; }
        for (int k = 0; k + 1 < ni; k += 2) {
            int xa = xs[k], xb = xs[k+1];
            if (xa < cx0) xa = cx0; if (xb > cx1) xb = cx1;
            uint16_t bits = mask ? mask[y & 15] : 0xFFFF;
            uint32_t *row = s->px + (size_t)y * s->stride;
            for (int x = xa; x <= xb; x++)
                row[x] = vdi_wrmix(mode, row[x], ink, ground, (bits >> (x & 15)) & 1);
        }
    }
}

// Connect points with clipped line segments; closed joins the last back to the first.
void vdi_polyline(const vdi_ws *w, const int16_t *xy, int n, int pen, int closed) {
    for (int i = 0; i + 1 < n; i++)
        vdi_line(w, xy[2*i], xy[2*i+1], xy[2*i+2], xy[2*i+3], pen);
    if (closed && n > 2)
        vdi_line(w, xy[2*(n-1)], xy[2*n-1], xy[0], xy[1], pen);
}

void vdi_rect_outline(const vdi_ws *w, int x0, int y0, int x1, int y1, int pen) {
    if (x0 > x1) { int t = x0; x0 = x1; x1 = t; }
    if (y0 > y1) { int t = y0; y0 = y1; y1 = t; }
    vdi_line(w, x0, y0, x1, y0, pen);   // top
    vdi_line(w, x0, y1, x1, y1, pen);   // bottom
    vdi_line(w, x0, y0, x0, y1, pen);   // left
    vdi_line(w, x1, y0, x1, y1, pen);   // right
}
static int cs_code(int x, int y, int cx0, int cy0, int cx1, int cy1) {
    int c = 0;
    if (x < cx0) c |= 1; else if (x > cx1) c |= 2;
    if (y < cy0) c |= 4; else if (y > cy1) c |= 8;
    return c;
}

// vsl_type 1..6 as a 16-bit dash pattern (bit per pixel along the line).
static uint16_t line_pattern(int type) {
    switch (type) {
        case 2:  return 0xFFF0;     // long dash
        case 3:  return 0x8888;     // dotted
        case 4:  return 0xFC30;     // dash-dot
        case 5:  return 0xF0F0;     // dashed
        case 6:  return 0xE4E4;     // dash-dot-dot
        default: return 0xFFFF;     // solid
    }
}

// Stamp a round pen of diameter `width` at (cx,cy), clipped.  A round (not
// square) brush gives the same perpendicular thickness in every direction —
// a square one is ~1.41x thicker along diagonals.  The disc is centred on a
// half-pixel for even widths so the on-axis span is exactly `width`.  Compare
// is in doubled integers: (2dx-oc)^2 + (2dy-oc)^2 <= width^2.
static void brush(gfx_surface *s, int cx, int cy, int width, uint32_t rgba, int mode,
                  int x0c, int y0c, int x1c, int y1c) {
    int oc = (width & 1) ? 0 : 1, w2 = width * width, R = width / 2 + 1;
    for (int dy = -R; dy <= R; dy++) {
        int y = cy + dy; if (y < y0c || y > y1c || y < 0 || y >= s->h) continue;
        int ty = 2 * dy - oc; ty *= ty;
        if (ty > w2) continue;
        uint32_t *row = s->px + (size_t)y * s->stride;
        for (int dx = -R; dx <= R; dx++) {
            int tx = 2 * dx - oc;
            if (tx * tx + ty > w2) continue;
            int x = cx + dx; if (x < x0c || x > x1c || x < 0 || x >= s->w) continue;
            row[x] = vdi_wrmix(mode, row[x], rgba, 0, 1);   // line = solid foreground
        }
    }
}

void vdi_line(const vdi_ws *w, int x0, int y0, int x1, int y1, int pen) {
    int cx0, cy0, cx1, cy1; vdi_ws_clip(w, &cx0, &cy0, &cx1, &cy1);
    int c0 = cs_code(x0, y0, cx0, cy0, cx1, cy1);
    int c1 = cs_code(x1, y1, cx0, cy0, cx1, cy1);
    for (;;) {
        if (!(c0 | c1)) break;
        if (c0 & c1) return;
        int co = c0 ? c0 : c1, x = 0, y = 0;
        if (co & 8)      { x = x0 + (x1 - x0) * (cy1 - y0) / (y1 - y0); y = cy1; }
        else if (co & 4) { x = x0 + (x1 - x0) * (cy0 - y0) / (y1 - y0); y = cy0; }
        else if (co & 2) { y = y0 + (y1 - y0) * (cx1 - x0) / (x1 - x0); x = cx1; }
        else             { y = y0 + (y1 - y0) * (cx0 - x0) / (x1 - x0); x = cx0; }
        if (co == c0) { x0 = x; y0 = y; c0 = cs_code(x0, y0, cx0, cy0, cx1, cy1); }
        else          { x1 = x; y1 = y; c1 = cs_code(x1, y1, cx0, cy0, cx1, cy1); }
    }
    // Rasterise (Bresenham) so we can apply width + dash ourselves.
    uint32_t rgba = pen_tab[pen & 0xFF];
    int width = w->line_width < 1 ? 1 : w->line_width;
    uint16_t pat = line_pattern(w->line_type);
    int dx = x1 > x0 ? x1 - x0 : x0 - x1, sx = x0 < x1 ? 1 : -1;
    int dy = y1 > y0 ? y0 - y1 : y1 - y0, sy = y0 < y1 ? 1 : -1;   // dy negative
    int err = dx + dy, d = 0, mode = w->wr_mode;
    for (;;) {
        if (pat & (1u << (d & 15))) brush(w->target, x0, y0, width, rgba, mode, cx0, cy0, cx1, cy1);
        if (x0 == x1 && y0 == y1) break;
        int e2 = 2 * err;
        if (e2 >= dy) { err += dy; x0 += sx; }
        if (e2 <= dx) { err += dx; y0 += sy; }
        d++;
    }
}

// ---- MFDB -----------------------------------------------------------------
void mfdb_from_surface(MFDB *m, gfx_surface *s) {
    m->addr = s->px; m->w = (int16_t)s->w; m->h = (int16_t)s->h; m->stride = (int16_t)s->stride;
}
const MFDB *g_cpyfm_src, *g_cpyfm_dst;
gfx_surface vdi_mfdb_surf(const MFDB *m, const vdi_ws *w) {
    if (!m || !m->addr) return *w->target;
    gfx_surface s = { m->w, m->h, m->stride, m->addr };
    return s;
}

// ---- Init + dispatch ------------------------------------------------------
void vdi_init(gfx_surface *default_target) {
    memset(ws_tab, 0, sizeof(ws_tab));
    pen_init();
    ws_tab[0].used = 1; ws_tab[0].target = default_target;     // handle 1 = physical
    ws_tab[0].line_color = 1; ws_tab[0].line_width = 1; ws_tab[0].line_type = 1;
    ws_tab[0].fill_color = 1; ws_tab[0].text_color = 1; ws_tab[0].fill_interior = 1;
    ws_tab[0].fill_style = 1; ws_tab[0].fill_perimeter = 1;
    ws_tab[0].marker_type = 3; ws_tab[0].marker_height = 11; ws_tab[0].marker_color = 1;
    ws_tab[0].wr_mode = VDI_MD_REPLACE;
    ws_tab[0].text_font_id = 1; ws_tab[0].text_valign = VDI_TA_TOP;
}

font_face *g_default_face;
void vdi_set_face(font_face *face) { g_default_face = face; }

gfx_surface *vdi_screen_target(void) { return ws_tab[0].target; }   // the desktop surface

// Fill a v_opnwk / v_opnvwk work_out capability array (intout[0..44] +
// ptsout[0..11]).  Key field: intout[13] = number of simultaneous colours
// (>= 2 => a colour device); the true-colour flag is reported by vq_extnd.
void vdi_fill_caps(int16_t *io, int16_t *po) {
    for (int i = 0; i < 45; i++) io[i] = 0;
    for (int i = 0; i < 12; i++) po[i] = 0;
    gfx_surface *s = vdi_screen_target();
    int mx = s ? s->w - 1 : 0, my = s ? s->h - 1 : 0;
    io[0] = (int16_t)mx; io[1] = (int16_t)my;        // addressable extent
    io[3] = 278; io[4] = 278;                        // pixel size (microns, nominal)
    io[6] = 6;                                       // line types
    io[10] = 1;                                      // font faces (the default)
    io[11] = 24; io[12] = 12;                        // fill patterns, hatches
    io[13] = 256;                                    // simultaneous colours (>= 2)
    io[14] = 10;                                     // number of GDPs
    static const int16_t gdp_id[10] = { 1,2,3,4,5,6,7,8,9,10 };
    static const int16_t gdp_at[10] = { 3,0,3,3,3,0,3,0,3,2 }; // fill/polyline/.../text
    for (int i = 0; i < 10; i++) { io[15+i] = gdp_id[i]; io[25+i] = gdp_at[i]; }
    io[35] = 1;                                      // colour capable
    io[36] = 1;                                      // text rotation capable
    io[37] = 1;                                      // fill-area capable
    io[39] = 256;                                    // colours available
    io[40] = io[41] = io[42] = io[43] = 1;           // locator/valuator/choice/string
    io[44] = 2;                                      // workstation type: input+output
    po[0] = (int16_t)mx; po[1] = (int16_t)my;
}

char g_device_file[256];
void vdi_set_device_file(const char *path) {
    if (!path) { g_device_file[0] = '\0'; return; }
    size_t i = 0; for (; path[i] && i < sizeof(g_device_file) - 1; i++) g_device_file[i] = path[i];
    g_device_file[i] = '\0';
}

// The sized font a workstation draws text with: its selected face (vst_font, or
// the system default) at its selected size (vst_height/vst_point, or default).
font *vdi_ws_font(const vdi_ws *w) {
    font_face *face = w->text_face ? w->text_face : g_default_face;
    if (!face) return NULL;
    int px = w->text_px > 0 ? w->text_px : VDI_TEXT_PX_DEFAULT;
    return font_at(face, px);
}

void vdi_call(vdi_pb *pb) {
    // A metafile workstation records every call instead of drawing (close still
    // goes through so it can finalise the file).
    vdi_ws *mw = vdi_ws_of(pb->contrl[6]);
    if (mw && mw->device >= VDI_DEV_META_LO && mw->device <= VDI_DEV_META_HI
           && pb->contrl[0] != VDI_CLOSE_WK) {
        metafile_record(mw, pb);
        return;
    }
    switch (pb->contrl[0]) {
        case VDI_OPEN_WK:     op_open_wk(pb);    break;
        case VDI_CLOSE_WK:    op_close_wk(pb);   break;
        case VDI_CLRWK:       op_clrwk(pb);      break;
        case VDI_UPDWK:       op_updwk(pb);      break;
        case VDI_OPNVWK:      op_opnvwk(pb);     break;
        case VDI_CLSVWK:      op_clsvwk(pb);     break;
        case VDI_VQ_EXTND:    op_vq_extnd(pb);   break;
        case VDI_SWR_MODE:    op_swr_mode(pb);   break;
        case VDI_SL_COLOR:    op_sl_color(pb);   break;
        case VDI_SL_TYPE:     op_sl_type(pb);    break;
        case VDI_SL_WIDTH:    op_sl_width(pb);   break;
        case VDI_ST_COLOR:    op_st_color(pb);   break;
        case VDI_ST_HEIGHT:   op_st_height(pb);  break;
        case VDI_ST_POINT:    op_st_point(pb);   break;
        case VDI_ST_FONT:     op_st_font(pb);    break;
        case VDI_QT_NAME:     op_qt_name(pb);    break;
        case VDI_ST_ROTATION: op_st_rotation(pb);break;
        case VDI_ST_EFFECTS:  op_st_effects(pb); break;
        case VDI_ST_ALIGN:    op_st_alignment(pb);break;
        case VDI_LOAD_FONTS:  op_load_fonts(pb); break;
        case VDI_UNLOAD_FONTS:op_unload_fonts(pb);break;
        case VDI_VS_COLOR:    op_vs_color(pb);   break;
        case VDI_SF_COLOR:    op_sf_color(pb);   break;
        case VDI_SF_INTERIOR: op_sf_interior(pb);break;
        case VDI_SF_STYLE:    op_sf_style(pb);   break;
        case VDI_SF_UDPAT:    op_sf_udpat(pb);   break;
        case VDI_SF_PERIM:    op_sf_perimeter(pb);break;
        case VDI_CLIP:        op_clip(pb);       break;
        case VDI_PLINE:       op_pline(pb);      break;
        case VDI_PMARKER:     op_pmarker(pb);    break;
        case VDI_SM_TYPE:     op_sm_type(pb);    break;
        case VDI_SM_HEIGHT:   op_sm_height(pb);  break;
        case VDI_SM_COLOR:    op_sm_color(pb);   break;
        case VDI_FILLAREA:    op_fillarea(pb);   break;
        case VDI_CELLARRAY:   op_cellarray(pb);  break;
        case VDI_CONTOURFILL: op_contourfill(pb);break;
        case VDI_GTEXT:       op_gtext(pb);      break;
        case VDI_RECFL:       op_fillrect(pb);   break;
        case VDI_CPYFM:       op_cpyfm(pb);      break;
        case VDI_GDP:         op_gdp(pb);        break;  // v_bar + circle/ellipse/arc/...
        default: break;       // unimplemented opcode -> no-op
    }
}

// ---- Shared C-binding scratch ---------------------------------------------
int16_t g_contrl[16], g_intin[128], g_ptsin[256], g_intout[128], g_ptsout[256];
vdi_pb  g_pb = { g_contrl, g_intin, g_ptsin, g_intout, g_ptsout };

void vdi_emit(int op, int sub, int handle, int npts, int nint) {
    g_contrl[0] = (int16_t)op;   g_contrl[1] = (int16_t)npts;
    g_contrl[3] = (int16_t)nint; g_contrl[5] = (int16_t)sub;
    g_contrl[6] = (int16_t)handle;
    vdi_call(&g_pb);
}
