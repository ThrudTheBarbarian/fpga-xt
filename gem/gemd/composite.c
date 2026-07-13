/*
 * gemd/composite.c — the only code in the system that puts a pixel on the display.
 *
 * Rule 1 (RESPONSIBILITIES.md §1): ONLY gemd TOUCHES THE SCREEN.
 *
 * A repaint has exactly two triggers and they must not be confused (§3):
 *   - CONTENT changed — only the client can know; it draws into its own backing store and
 *     posts a damage rect. gemd is told "these pixels changed", never "I inserted text".
 *   - GEOMETRY changed (moved, topped, revealed, a window died) — only gemd can know, and
 *     it recomposites from the backing stores WITHOUT ASKING ANY CLIENT ANYTHING. That is
 *     what the per-window backing store buys, and every other promise leans on it.
 * Both land here, as a screen rect to recomposite.
 *
 * THE INNER BLIT GOES THROUGH A BACKEND (§14). Phase 1's is the CPU — a streaming write of
 * the damaged bytes into the (uncached) plane, which is the one thing uncached memory is
 * good at. Phase 2 swaps in a /dev/blitter backend. If the compositor reached into the
 * pixels directly, phase 2 would be a rewrite rather than a backend.
 */
#include <stddef.h>
#include "gemd.h"
#include "usys.h"

/* ---- the phase-1 backend: the CPU ---------------------------------------------------- */

static void cpu_fill_rect(const gfx_surface *dst, int x, int y, int w, int h, uint32_t rgba)
{
    for (int row = 0; row < h; row++) {
        uint32_t *p = dst->px + (size_t)(y + row) * dst->stride + x;   /* STRIDE, not w */
        for (int i = 0; i < w; i++) p[i] = rgba;
    }
}

static void cpu_blit_rect(const gfx_surface *dst, int dx, int dy,
                          const gfx_surface *src, int sx, int sy, int w, int h)
{
    for (int row = 0; row < h; row++) {
        const uint32_t *s = src->px + (size_t)(sy + row) * src->stride + sx;
        uint32_t       *d = dst->px + (size_t)(dy + row) * dst->stride + dx;
        for (int i = 0; i < w; i++) d[i] = s[i];
    }
}

/* The plane is Normal NON-cacheable, so the writes above are already in DDR and the
 * compositor scans them: present is a barrier, not a cache flush. */
static void cpu_present(void) { sys_fb_present(); }

const gemd_backend gemd_backend_cpu = { "cpu", cpu_fill_rect, cpu_blit_rect, cpu_present };

/* ---- the compositor ------------------------------------------------------------------ */

static gfx_surface          g_plane;
static uint32_t             g_bg;       /* the FALLBACK COLOUR, and only a colour: the
                                         * wallpaper is content and belongs to desktop.so (§4) */
static const gemd_backend  *g_be = &gemd_backend_cpu;

void gemd_comp_init(const gfx_surface *plane, uint32_t bg, const gemd_backend *be)
{
    g_plane = *plane;
    g_bg    = bg;
    g_be    = be ? be : &gemd_backend_cpu;
    g_be->fill_rect(&g_plane, 0, 0, g_plane.w, g_plane.h, g_bg);   /* the plane is never un-owned */
    g_be->present();
}

/* Recomposite one screen rect: the fallback colour, then every window that intersects it,
 * in z-order, clipped to the rect. Present once. */
void gemd_comp_rect(int rx, int ry, int rw, int rh, gwin **z, int nz)
{
    if (rx < 0) { rw += rx; rx = 0; }
    if (ry < 0) { rh += ry; ry = 0; }
    if (rx + rw > g_plane.w) rw = g_plane.w - rx;
    if (ry + rh > g_plane.h) rh = g_plane.h - ry;
    if (rw <= 0 || rh <= 0) return;

    g_be->fill_rect(&g_plane, rx, ry, rw, rh, g_bg);

    for (int i = 0; i < nz; i++) {
        gwin *win = z[i];
        if (!win->used || !win->px) continue;

        /* intersect the window's on-screen extent with the damage rect */
        int x0 = win->x > rx ? win->x : rx;
        int y0 = win->y > ry ? win->y : ry;
        int x1 = (win->x + win->w) < (rx + rw) ? (win->x + win->w) : (rx + rw);
        int y1 = (win->y + win->h) < (ry + rh) ? (win->y + win->h) : (ry + rh);
        if (x1 <= x0 || y1 <= y0) continue;

        /* The surface's stride is its CAPACITY width and the window uses the TOP-LEFT
         * extent sub-rect (§12) — so the source row pitch is cap_w and the source origin
         * is the window-local offset of the intersection. Getting this wrong is invisible
         * while capacity == extent and catastrophic the moment it isn't. */
        gfx_surface src = { win->w, win->h, win->cap_w, win->px };
        g_be->blit_rect(&g_plane, x0, y0, &src, x0 - win->x, y0 - win->y, x1 - x0, y1 - y0);
    }
    g_be->present();
}
