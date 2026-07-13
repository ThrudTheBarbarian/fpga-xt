/*
 * gemclient.c — the client half of the GEM transport: what an app links to talk to gemd.
 *
 * The split it enforces (RESPONSIBILITIES.md §5):
 *   - CONTROL crosses the channel: window ops, damage rects. Tiny, and it is the only
 *     thing gemd ever hears from an app.
 *   - PIXELS never do. The app draws into its OWN backing store with its own VDI, at full
 *     speed, with ZERO IPC — then posts one damage rect saying "this rect is new". gemd is
 *     never told *why*, and it never draws an app's content.
 *
 * An app never sees the surface id, and never a surface ADDRESS: gem_wind_create maps the
 * surface for it and hands back a gfx_surface it can open a workstation on. The id stays
 * on the wire, where §13.1 wants it.
 *
 * Note what a client CANNOT do here, and must never learn to: touch the framebuffer, ask
 * where its window is, or ask whether it is visible. It draws and posts damage. That is all.
 */
#include <string.h>
#include "gemclient.h"
#include "usys.h"

static int read_full(int fd, void *buf, int n)
{
    char *p = (char *)buf;
    int got = 0;
    while (got < n) {
        long r = sys_read(fd, p + got, (unsigned)(n - got));
        if (r <= 0) return -1;                 /* EOF: gemd is gone. Nothing works after this. */
        got += (int)r;
    }
    return 0;
}

int gem_connect(void)
{
    return sys_svc_connect(GEM_SERVICE);       /* -2 = no such service: gemd is not running */
}

int gem_wind_create(int fd, int kind, int x, int y, int w, int h, gem_window *out)
{
    gem_msg m;
    memset(&m, 0, sizeof m);
    m.w[0] = GEM_WIND_CREATE;
    m.w[1] = (int16_t)kind;
    m.w[2] = (int16_t)x; m.w[3] = (int16_t)y;
    m.w[4] = (int16_t)w; m.w[5] = (int16_t)h;
    if (sys_write(fd, &m, GEM_MSG_SZ) != GEM_MSG_SZ) return -1;

    gem_msg r;
    if (read_full(fd, &r, GEM_MSG_SZ) != 0) return -1;
    if (r.w[0] != GEM_WIND_CREATED) return -1;

    memset(out, 0, sizeof *out);
    out->wh       = r.w[1];
    out->cap_w    = r.w[2];
    out->cap_h    = r.w[3];
    out->surf_id  = (int)r.u[0];
    out->surf_gen = r.u[1];
    out->w = w; out->h = h;

    /* The surface is XT_SHM_OWNED and gemd has granted it to US, by the pid the kernel
     * reports for this channel. No other client can map it. */
    uint32_t *px = (uint32_t *)sys_shm_map(out->surf_id);
    if (!px) return -1;

    /* STRIDE IS THE CAPACITY WIDTH, NOT THE EXTENT WIDTH (§12). We draw into the top-left
     * w x h sub-rect, so growing the window within capacity moves no row. */
    out->surf.w      = out->w;
    out->surf.h      = out->h;
    out->surf.stride = out->cap_w;
    out->surf.px     = px;
    return 0;
}

void gem_damage(int fd, const gem_window *win, int x, int y, int w, int h)
{
    gem_msg m;
    memset(&m, 0, sizeof m);
    m.w[0] = GEM_DAMAGE;
    m.w[1] = (int16_t)win->wh;
    m.w[2] = (int16_t)x; m.w[3] = (int16_t)y;
    m.w[4] = (int16_t)w; m.w[5] = (int16_t)h;
    m.u[0] = (uint32_t)win->surf_id;
    m.u[1] = win->surf_gen;
    m.u[2] = 0;              /* retire_seq — DEAD IN PHASE 1 (§14), and it must still be here:
                             * phase 2's queued blitter makes "I posted damage" != "my pixels
                             * are in memory", and adding the field then is a protocol break
                             * across every client. */
    sys_write(fd, &m, GEM_MSG_SZ);
}

void gem_wind_close(int fd, gem_window *win)
{
    if (win->surf_id < 0) return;
    sys_shm_unmap(win->surf_id);         /* the client drops ITS ref (§11); gemd still holds one,
                                          * so a composite in flight stays valid */
    gem_msg m;
    memset(&m, 0, sizeof m);
    m.w[0] = GEM_SURF_DROP;
    m.u[0] = (uint32_t)win->surf_id;
    sys_write(fd, &m, GEM_MSG_SZ);
    win->surf_id = -1;
    win->surf.px = 0;
}
