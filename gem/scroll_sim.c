/* scroll_sim.c — HOST reproduction rig for the client-side scroll blit (M5).
 *
 * The board shows stale 1-2px horizontal slivers in a window's backing store after a live
 * thumb drag (fbgrab-verified: the residue survives a recomposite, so it is in the SURFACE,
 * not the plane). This isolates the exact pixel pipeline — the same VDI, the same nested
 * clips, the same blit + exposed-strip repaint as window.c's client_scrolled — and compares
 * every step against a full fresh render at the same offset. Any differing pixel is the bug,
 * found on the Mac in milliseconds instead of on the board in reboots.
 *
 *   make scrollsim   ->  PASS/FAIL + the first differing rows
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "gfx.h"
#include "vdi/vdi.h"
#include "font.h"

#define W    550
#define H    508            /* work area */
#define PIN  24             /* pinned status bar */
#define VH   (H - PIN)      /* the scrolling band */
#define CONTENT_H 2900

static gfx_surface *g_s;
static int g_vh;                    /* set per pass: the live surface's ws, or the referee's */

/* Deterministic "browser content": white bg, a rect + a text label per 130px row, all at
 * absolute content positions shifted up by sy. Text matters: the board residue is glyph
 * bottoms, and glyphs exercise the AA/clip edges that plain fills do not. */
static void draw_content(int sy)
{
    int16_t bg[4] = { 0, 0, W - 1, H - 1 };
    vsf_color(g_vh, 0); vsf_interior(g_vh, VDI_FIS_SOLID); vsf_perimeter(g_vh, 0);
    vr_recfl(g_vh, bg);
    vst_color(g_vh, 1);
    vst_height(g_vh, 14, 0, 0, 0, 0);
    for (int row = 0; row * 130 < CONTENT_H; row++) {
        int y = 14 + row * 130 - sy;
        if (y + 96 <= 0 || y >= H) continue;
        vsf_color(g_vh, 1);
        int16_t r[4] = { 40, (int16_t)y, 88, (int16_t)(y + 64) };
        if (r[3] >= 0 && r[1] <= H - 1) vr_recfl(g_vh, r);
        char lbl[32]; snprintf(lbl, sizeof lbl, "file-%d.xex", row);
        v_gtext(g_vh, 36, y + 66, lbl);
        v_gtext(g_vh, 180, y + 30, "dots live in glyph bottoms");
    }
    /* the pinned bar, drawn unshifted (clipped away during strip paints) */
    vsf_color(g_vh, 248);
    int16_t sb[4] = { 0, VH, W - 1, H - 1 };
    vr_recfl(g_vh, sb);
    v_gtext(g_vh, 8, VH + 16, "150 items, 150 files");
}

/* window.c client_paint, minus the wire: clip to the rect, run the callback, restore. */
static void paint_rect(int x, int y, int w, int h, int sy)
{
    if (x < 0) { w += x; x = 0; }
    if (y < 0) { h += y; y = 0; }
    if (x + w > W) w = W - x;
    if (y + h > H) h = H - y;
    if (w <= 0 || h <= 0) return;
    int16_t clip[4] = { (int16_t)x, (int16_t)y, (int16_t)(x + w - 1), (int16_t)(y + h - 1) };
    vs_clip(g_vh, 1, clip);
    draw_content(sy);
    vs_clip(g_vh, 0, clip);
}

/* window.c client_scrolled's blit + strip, verbatim logic. */
static void scroll_step(int old_sy, int new_sy)
{
    int dy = new_sy - old_sy;
    int ady = dy < 0 ? -dy : dy;
    if (!dy) return;
    if (ady >= VH) { paint_rect(0, 0, W, H, new_sy); return; }
    uint32_t *px = g_s->px; int st = g_s->stride, keep = VH - ady;
    if (dy > 0) for (int yy = 0;        yy < keep; yy++) memcpy(px + (size_t)yy * st,         px + (size_t)(yy + dy) * st, (size_t)W * 4);
    else        for (int yy = keep - 1; yy >= 0;  yy--) memcpy(px + (size_t)(yy + ady) * st, px + (size_t)yy * st,        (size_t)W * 4);
    paint_rect(0, dy > 0 ? keep : 0, W, ady, new_sy);
}

static int diff_rows(const gfx_surface *a, const gfx_surface *b, int upto, int report)
{
    int bad = 0;
    for (int y = 0; y < upto; y++) {
        if (memcmp(a->px + (size_t)y * a->stride, b->px + (size_t)y * b->stride, (size_t)W * 4)) {
            if (report && bad < 6) {
                int x0 = -1, x1 = -1;
                for (int x = 0; x < W; x++)
                    if (a->px[(size_t)y * a->stride + x] != b->px[(size_t)y * b->stride + x]) {
                        if (x0 < 0) x0 = x;
                        x1 = x;
                    }
                printf("  row %4d differs, x %d..%d\n", y, x0, x1);
            }
            bad++;
        }
    }
    return bad;
}

int main(void)
{
    g_s = gfx_surface_alloc(W + 90, H);         /* stride != width, like a real gemd surface */
    g_s->w = W;                                 /* extent < capacity: the §12 shape */
    gfx_surface *ref = gfx_surface_alloc(W + 90, H);
    ref->w = W;
    vdi_init(g_s);
    font_face *f = font_face_open("fonts/AovelSansRounded.ttf");
    if (!f) { printf("scroll_sim: no font (run from gem/)\n"); return 2; }
    vdi_set_face(f);
    int live_vh = v_opnvwk(g_s);                /* one ws per surface, like real windows */
    int ref_vh  = v_opnvwk(ref);
    g_vh = live_vh;

    /* the drag: a random walk of absolute offsets, like a stream of MSG_VSLIDs */
    unsigned seed = 12345;
    int sy = 0;
    paint_rect(0, 0, W, H, sy);                 /* first paint */
    int total_bad = 0;
    for (int step = 0; step < 400; step++) {
        seed = seed * 1103515245 + 12345;
        int dy = (int)(seed >> 16) % 120 - 50;  /* mostly small, both directions */
        int ny = sy + dy;
        int maxs = CONTENT_H - H;
        if (ny < 0) ny = 0;
        if (ny > maxs) ny = maxs;
        if (ny == sy) continue;
        scroll_step(sy, ny);
        sy = ny;
        paint_rect(0, VH, W, PIN, sy);          /* the app's WM_VSLID bar repaint, interleaved */
        if (step % 37 == 0) paint_rect(0, 0, W, H, sy);   /* an occasional full repaint (SIZED) */

        /* referee: a full fresh render at this offset must match the scrolling band */
        g_vh = ref_vh;
        paint_rect(0, 0, W, H, sy);
        g_vh = live_vh;
        int bad = diff_rows(g_s, ref, VH, total_bad == 0);
        if (bad && !total_bad) printf("step %d (sy %d, dy %+d): %d differing rows\n", step, sy, dy, bad);
        total_bad += bad;
    }
    printf(total_bad ? "scroll_sim: FAIL (%d differing rows total)\n"
                     : "scroll_sim: PASS%.0d\n", total_bad);
    return total_bad != 0;
}
