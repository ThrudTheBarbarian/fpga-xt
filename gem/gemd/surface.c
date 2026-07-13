/*
 * gemd/surface.c — window backing stores.
 *
 * A surface is ORDINARY CACHED shm (RESPONSIBILITIES.md §14). It is deliberately NOT plv
 * and NOT XT_SHM_CONTIG: plv is uncached, and a *software* VDI writing to uncached memory
 * is the worst of both worlds — the full uncached penalty and none of the hardware speed.
 * Backing stores move to plv when the VDI's blitter backend moves, and not one commit
 * before. The two are a single change.
 *
 * They ARE created XT_SHM_OWNED, so the id is a capability: gemd grants exactly the client
 * that asked for the window (SYS_shm_grant, against the pid the KERNEL reports for the
 * channel — SYS_chan_peer), and no other client can map it even knowing the number.
 */
#include <string.h>
#include "gemd.h"
#include "usys.h"

static uint32_t g_gen = 1;          /* surface generation: monotonic, never reused (§11) */

static int round_up(int v, int q) { return ((v + q - 1) / q) * q; }

/* CAPACITY, not extent (§12): the extent rounded up to a 64px grid, capped at the screen.
 * Resize within capacity is then free — change w/h, no realloc, no copy, no remap, no new
 * id. Quantise, do NOT multiply: 1.5x on both axes is 2.25x the memory, and for a
 * full-screen window it asks for 18.7 MB of capacity no window can ever use. */
int gemd_surf_create(gwin *win, int w, int h, int scr_w, int scr_h)
{
    if (w <= 0 || h <= 0) return -1;
    int cap_w = round_up(w, GEM_CAP_QUANTUM), cap_h = round_up(h, GEM_CAP_QUANTUM);
    if (cap_w > scr_w) cap_w = scr_w;
    if (cap_h > scr_h) cap_h = scr_h;
    if (w > cap_w) w = cap_w;
    if (h > cap_h) h = cap_h;

    unsigned bytes = (unsigned)cap_w * (unsigned)cap_h * 4u;
    int id = sys_shm_create(bytes, XT_SHM_OWNED);
    if (id < 0) return -1;

    uint32_t *px = (uint32_t *)sys_shm_map(id);      /* gemd's ref — the one that outlives the
                                                      * client and keeps the pixels valid (§11) */
    if (!px) return -1;                              /* nref never reached 1: the id frees itself
                                                      * only at the last drop, so nothing to undo */
    win->surf_id  = id;
    win->surf_gen = g_gen++;
    win->cap_w = cap_w; win->cap_h = cap_h;
    win->w = w; win->h = h;
    win->px = px;
    return 0;
}

/* gemd drops ITS ref. The client may still hold one — and if it is mid-draw, that is fine:
 * it finishes, harmlessly, into memory nobody will composite (§11 — refcount, do not
 * handshake). The object is freed when the count reaches zero and not before. */
void gemd_surf_drop(gwin *win)
{
    if (win->surf_id >= 0 && win->px) sys_shm_unmap(win->surf_id);
    win->px = 0;
    win->surf_id = -1;
}
