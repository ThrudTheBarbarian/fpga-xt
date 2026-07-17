/*
 * gemd/surface.c — window backing stores, and the chrome art.
 *
 * A surface is CACHED, CONTIGUOUS shm (M7: XT_SHM_CONTIG from plv, whose per-process
 * mappings are cached now — vm.c SEC_SHM_C). RESPONSIBILITIES.md §14's move-together rule
 * is satisfied both ways at once: the VDI still renders through the caches (a software
 * VDI on uncached memory is the worst of both worlds), and the surface is engine-visible
 * (physically contiguous, so /dev/blitter can composite it — the driver owns the
 * clean/invalidate per submit). plv is a BUDGET (128 MB, 1 MB granular): when it runs
 * out, fall back to pooled shm — that surface simply composites on the CPU (contig=0).
 *
 * They ARE created XT_SHM_OWNED, so the id is a CAPABILITY and not merely a name: gemd grants
 * it to exactly the client that asked for the window (SYS_shm_grant, against the pid the KERNEL
 * reports for the channel — SYS_chan_peer), and no other client can map it even knowing the
 * number.
 *
 * A surface is sized to the WORK AREA, not to the window: chrome is gemd's, and a client never
 * sees it (§3). Only the AES can say how big the work area is, so gemd asks it (wind_work_size)
 * rather than modelling the chrome twice.
 */
#include <stdio.h>
#include <string.h>
#include "gemd.h"
#include "usys.h"

static uint32_t g_gen = 1;          /* surface generation: monotonic, never reused (§11) */

static int round_up(int v, int q) { return ((v + q - 1) / q) * q; }

/* CAPACITY, not extent (§12): the extent rounded up to a 64px grid, capped at the screen. A
 * resize within capacity is then free — change w/h; no realloc, no copy, no remap, no new id.
 * Quantise, do NOT multiply: 1.5x on both axes is 2.25x the memory, and for a full-screen
 * window it asks for 18.7 MB of capacity that no window can ever use. */
int gemd_surf_create(gsurface *s, int w, int h, int scr_w, int scr_h)
{
    memset(s, 0, sizeof *s);
    s->id = -1;
    if (w <= 0 || h <= 0) return -1;

    int cap_w = round_up(w, GEM_CAP_QUANTUM), cap_h = round_up(h, GEM_CAP_QUANTUM);
    if (cap_w > scr_w) cap_w = scr_w;
    if (cap_h > scr_h) cap_h = scr_h;
    if (cap_w < w || cap_h < h) return -1;          /* asked for more than the screen holds */

    unsigned bytes = (unsigned)cap_w * (unsigned)cap_h * 4u;
    int contig = 1;
    int id = sys_shm_create(bytes, XT_SHM_OWNED | XT_SHM_CONTIG);
    if (id < 0) { contig = 0; id = sys_shm_create(bytes, XT_SHM_OWNED); }   /* plv budget
                                                     * exhausted: pooled, CPU-composited */
    if (id < 0) return -1;

    uint32_t *px = (uint32_t *)sys_shm_map(id);     /* gemd's ref — the one that OUTLIVES the
                                                     * client and keeps the pixels valid (§11) */
    if (!px) return -1;                             /* nref never reached 1; nothing to undo */

    s->id = id;
    s->gen = g_gen++;
    s->cap_w = cap_w; s->cap_h = cap_h;
    s->px = px;
    s->contig = contig;
    return 0;
}

/* gemd drops ITS ref. The client may still hold one — and if it is mid-draw, that is fine: it
 * finishes, harmlessly, into memory nobody will composite (§11 — refcount, do not handshake).
 * The object is freed when the count reaches zero, and not before. */
void gemd_surf_drop(gsurface *s)
{
    if (s->id >= 0) sys_shm_unmap(s->id);
    s->id = -1;
    s->px = 0;
}

/* ---- the chrome art --------------------------------------------------------------------- */
/* The theme is read-only art, and §5 is explicit that both sides may load it — there is no
 * conflict. gemd needs it because gemd draws the chrome; a client needs it because objc_draw
 * themes its own widgets. Same resolution order as the desktop: the SD theme (user-overridable)
 * first, then the pack bundled in romfs, so gemd still has chrome on a card with no themes. */
static theme g_theme;
static int   g_theme_ok;

static int read_default(const char *dir, char *out, int n)
{
    char p[160]; snprintf(p, sizeof p, "%s/Default", dir);
    FILE *f = fopen(p, "r"); out[0] = 0;
    if (!f) return 0;
    if (!fgets(out, n, f)) out[0] = 0;
    fclose(f);
    for (int i = (int)strlen(out) - 1;
         i >= 0 && (out[i]=='\n'||out[i]=='\r'||out[i]==' '||out[i]=='\t'); i--) out[i] = 0;
    return out[0] != 0;
}

const theme *gemd_theme(void)
{
    if (g_theme_ok) return &g_theme;
    char tn[64], td[160];
    if (read_default("/OS/themes", tn, sizeof tn)) snprintf(td, sizeof td, "/OS/themes/%s/1x", tn);
    else                                          snprintf(td, sizeof td, "/OS/themes/Aristo2/1x");
    if (theme_load(&g_theme, td) != 0 &&
        theme_load(&g_theme, "/System/themes/Aristo2/1x") != 0) return 0;
    g_theme_ok = 1;
    return &g_theme;
}
