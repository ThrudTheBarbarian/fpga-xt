/*
 * gemd/server.c — the window server's main loop.
 *
 * ONE poll() over the listen fd and every client channel (RESPONSIBILITIES.md §3: gemd
 * holds the grab, so it must NEVER BLOCK; §9: it must never assume a client is alive,
 * responsive or well-behaved). Specifically:
 *
 *  - No thread per client, and no read that can stall. poll() says a channel is readable,
 *    we do exactly ONE read of whatever is there and accumulate into that client's own
 *    buffer until a whole 32-byte record has arrived. A client that writes five bytes and
 *    then goes silent forever costs gemd five bytes of buffer, not a wedged server.
 *  - A write to a client is NEVER fatal. A client that dies mid-reply must not kill gemd —
 *    the error is noted and the channel is dropped on its EOF, like any other death.
 *  - Client death is CHANNEL EOF, not SIGCHLD. §9 says SIGCHLD and §9 is wrong here:
 *    SIGCHLD only reaches the PARENT, and gemd is the parent of neither the boot-script
 *    desktop nor an ssh-launched app. EOF fires for everyone.
 *
 * On EOF we drop that client's windows, drop gemd's ref on each surface (§11 — the id is
 * reclaimed, which is the whole reason sys_shm_unmap was built), and recomposite the
 * screen rects they occupied. No ghost windows, no leaked shm.
 */
#include <stdio.h>
#include <string.h>
#include "gemd.h"
#include "usys.h"

#define GEMD_BG  GFX_RGB(0x20, 0x40, 0x70)     /* the fallback colour, and ONLY a colour (§4) */

typedef struct {
    int      used;
    int      fd;
    int      pid;                    /* from the KERNEL (SYS_chan_peer) — the client cannot lie */
    char     in[GEM_MSG_SZ];         /* partial record accumulator: see the no-stall rule above */
    int      inlen;
} gclient;

static gclient      g_cl[GEMD_MAXCL];
static gwin         g_win[GEMD_MAXW];
static int          g_nextwh = 1;
static gfx_surface  g_plane;

/* z-order: bottom-to-top, by index into g_win. W_BOTTOM inserts at the bottom (§4) — a
 * restarted desktop must land UNDER the apps that outlived it, not swallow the session. */
static int g_z[GEMD_MAXW], g_nz;

static void z_insert(int wi)
{
    int at = g_nz;                                     /* default: on top */
    if (g_win[wi].kind & GEM_W_BOTTOM) at = 0;
    for (int i = g_nz; i > at; i--) g_z[i] = g_z[i - 1];
    g_z[at] = wi;
    g_nz++;
}

static void z_remove(int wi)
{
    for (int i = 0; i < g_nz; i++)
        if (g_z[i] == wi) {
            for (int k = i + 1; k < g_nz; k++) g_z[k - 1] = g_z[k];
            g_nz--;
            return;
        }
}

/* the z-ordered window list the compositor walks */
static int z_list(gwin **out)
{
    int n = 0;
    for (int i = 0; i < g_nz; i++) if (g_win[g_z[i]].used) out[n++] = &g_win[g_z[i]];
    return n;
}

static void repaint(int x, int y, int w, int h)
{
    gwin *z[GEMD_MAXW];
    gemd_comp_rect(x, y, w, h, z, z_list(z));
}

/* A write to a client is advisory. If it fails the client is dying; its EOF will arrive and
 * the ordinary death path will clean up. It must NEVER take gemd down with it. */
static void reply(gclient *c, const gem_msg *m)
{
    long n = sys_write(c->fd, m, (unsigned)GEM_MSG_SZ);
    if (n != GEM_MSG_SZ)
        printf("gemd: write to pid %d failed (%ld) — it is dying; EOF will clean up\n", c->pid, n);
}

/* ---- requests ------------------------------------------------------------------------ */

static void do_wind_create(gclient *c, int ci, const gem_msg *m)
{
    gem_msg r;
    memset(&r, 0, sizeof r);

    int wi = -1;
    for (int i = 0; i < GEMD_MAXW; i++) if (!g_win[i].used) { wi = i; break; }
    if (wi < 0) { r.w[0] = GEM_WIND_ERROR; r.w[1] = 1; reply(c, &r); return; }

    gwin *win = &g_win[wi];
    memset(win, 0, sizeof *win);
    win->surf_id = -1;
    win->kind = m->w[1];
    win->x = m->w[2]; win->y = m->w[3];

    if (gemd_surf_create(win, m->w[4], m->w[5], g_plane.w, g_plane.h) != 0) {
        r.w[0] = GEM_WIND_ERROR; r.w[1] = 2; reply(c, &r);
        return;                                        /* win stays unused */
    }
    /* clamp the window onto the screen (§9: a client's geometry is a request too) */
    if (win->x < 0) win->x = 0;
    if (win->y < 0) win->y = 0;
    if (win->x + win->w > g_plane.w) win->x = g_plane.w - win->w;
    if (win->y + win->h > g_plane.h) win->y = g_plane.h - win->h;

    /* THE CAPABILITY. The surface is XT_SHM_OWNED, so nobody can map it until its owner
     * says so — and gemd grants it to the pid the KERNEL reports for this channel, not to
     * one the client claims in a message. */
    if (sys_shm_grant(win->surf_id, c->pid) != 0) {
        printf("gemd: shm_grant(%d -> pid %d) FAILED\n", win->surf_id, c->pid);
        gemd_surf_drop(win);
        r.w[0] = GEM_WIND_ERROR; r.w[1] = 3; reply(c, &r);
        return;
    }

    win->used = 1;
    win->wh = g_nextwh++;
    win->client = ci;
    z_insert(wi);

    r.w[0] = GEM_WIND_CREATED;
    r.w[1] = (int16_t)win->wh;
    r.w[2] = (int16_t)win->cap_w;                      /* STRIDE == capacity width (§12) */
    r.w[3] = (int16_t)win->cap_h;
    r.u[0] = (uint32_t)win->surf_id;                   /* a handle. Never an address. */
    r.u[1] = win->surf_gen;
    reply(c, &r);

    printf("gemd: wind_create wh=%d pid=%d %dx%d @ %d,%d -> surf %d gen %u cap %dx%d\n",
           win->wh, c->pid, win->w, win->h, win->x, win->y,
           win->surf_id, win->surf_gen, win->cap_w, win->cap_h);
}

static gwin *win_of(int ci, int wh)
{
    for (int i = 0; i < GEMD_MAXW; i++)
        if (g_win[i].used && g_win[i].wh == wh && g_win[i].client == ci) return &g_win[i];
    return 0;                       /* not this client's window: ignore, never trust a handle */
}

static void do_damage(int ci, const gem_msg *m)
{
    gwin *win = win_of(ci, m->w[1]);
    if (!win) return;
    if ((int)m->u[0] != win->surf_id || m->u[1] != win->surf_gen) return;   /* stale (§11) */
    /* m->u[2] is retire_seq: DEAD IN PHASE 1 (§14). Drawing is synchronous, so the pixels
     * are already in memory. Phase 2 compares it against the blitter's retired seq. */

    int x = m->w[2], y = m->w[3], w = m->w[4], h = m->w[5];   /* SURFACE coords */
    if (x < 0) { w += x; x = 0; }                             /* clamp: a request, not an
                                                               * instruction (§9) */
    if (y < 0) { h += y; y = 0; }
    if (x + w > win->w) w = win->w - x;
    if (y + h > win->h) h = win->h - y;
    if (w <= 0 || h <= 0) return;

    repaint(win->x + x, win->y + y, w, h);                    /* -> screen coords */
}

/* ---- client lifecycle ----------------------------------------------------------------- */

static void drop_client(int ci)
{
    gclient *c = &g_cl[ci];
    int rx0 = g_plane.w, ry0 = g_plane.h, rx1 = 0, ry1 = 0, any = 0;

    for (int i = 0; i < GEMD_MAXW; i++) {
        if (!g_win[i].used || g_win[i].client != ci) continue;
        if (g_win[i].x < rx0) rx0 = g_win[i].x;
        if (g_win[i].y < ry0) ry0 = g_win[i].y;
        if (g_win[i].x + g_win[i].w > rx1) rx1 = g_win[i].x + g_win[i].w;
        if (g_win[i].y + g_win[i].h > ry1) ry1 = g_win[i].y + g_win[i].h;
        any = 1;
        printf("gemd: pid %d gone — dropping wh=%d, surface %d\n", c->pid, g_win[i].wh,
               g_win[i].surf_id);
        z_remove(i);
        gemd_surf_drop(&g_win[i]);      /* gemd's ref. The dead client's went with it, so this
                                         * is the last one: the pages AND THE ID are reclaimed
                                         * (§11 — the whole reason sys_shm_unmap exists). */
        g_win[i].used = 0;
    }
    sys_close(c->fd);
    memset(c, 0, sizeof *c);

    if (any) repaint(rx0, ry0, rx1 - rx0, ry1 - ry0);   /* the window disappears. No client asked. */
}

/* Drain what is readable and dispatch every COMPLETE record. Never blocks: poll said there
 * was something, one read takes it, and a partial record just waits in the accumulator. */
static void client_readable(int ci)
{
    gclient *c = &g_cl[ci];
    char buf[GEM_MSG_SZ * 4];
    long n = sys_read(c->fd, buf, sizeof buf);
    if (n <= 0) { drop_client(ci); return; }            /* EOF: the peer is gone (§9) */

    for (long i = 0; i < n; i++) {
        c->in[c->inlen++] = buf[i];
        if (c->inlen < GEM_MSG_SZ) continue;
        gem_msg m;
        memcpy(&m, c->in, sizeof m);
        c->inlen = 0;
        switch (m.w[0]) {
        case GEM_WIND_CREATE: do_wind_create(c, ci, &m); break;
        case GEM_DAMAGE:      do_damage(ci, &m);         break;
        case GEM_SURF_DROP:   break;    /* the client unmapped it; its ref is already gone. gemd
                                         * keeps its own until the window closes (§11). */
        default:
            printf("gemd: pid %d sent op %d — ignored\n", c->pid, m.w[0]);
            break;
        }
    }
}

/* ---- the loop -------------------------------------------------------------------------- */

int gemd_run(void)
{
    struct os_fbinfo fb;
    if (sys_fb_info(&fb) != 0) { printf("gemd: no display plane\n"); return 1; }
    g_plane.w = fb.w; g_plane.h = fb.h; g_plane.stride = fb.stride;
    g_plane.px = (uint32_t *)fb.addr;

    /* gemd OWNS the plane, and the plane must never be un-owned (§3): clear it to the
     * fallback colour before anything else can be on screen. */
    gemd_comp_init(&g_plane, GEMD_BG, &gemd_backend_cpu);

    int lfd = sys_svc_register(GEM_SERVICE);
    if (lfd < 0) { printf("gemd: svc_register(\"%s\") -> %d (already running?)\n",
                          GEM_SERVICE, lfd); return 1; }
    printf("gemd: up — plane %dx%d stride %d, service \"%s\" on fd %d, backend %s\n",
           fb.w, fb.h, fb.stride, GEM_SERVICE, lfd, gemd_backend_cpu.name);
    fflush(stdout);

    for (;;) {
        struct xt_pollfd pf[1 + GEMD_MAXCL];
        int map[GEMD_MAXCL], np = 0;

        pf[0].fd = lfd; pf[0].events = XT_POLLIN; pf[0].revents = 0;
        for (int i = 0; i < GEMD_MAXCL; i++) {
            if (!g_cl[i].used) continue;
            pf[1 + np].fd = g_cl[i].fd; pf[1 + np].events = XT_POLLIN; pf[1 + np].revents = 0;
            map[np++] = i;
        }

        int r = sys_poll(pf, 1 + np, -1);              /* ONE wait. All clients. Never one at a time. */
        if (r < 0) {
            if (r == -4) continue;                     /* -EINTR: a signal, not a failure */
            printf("gemd: poll -> %d\n", r);
            return 1;
        }

        if (pf[0].revents & XT_POLLIN) {
            int cfd = sys_svc_accept(lfd);
            if (cfd >= 0) {
                int ci = -1;
                for (int i = 0; i < GEMD_MAXCL; i++) if (!g_cl[i].used) { ci = i; break; }
                if (ci < 0) { sys_close(cfd); printf("gemd: too many clients\n"); }
                else {
                    memset(&g_cl[ci], 0, sizeof g_cl[ci]);
                    g_cl[ci].used = 1;
                    g_cl[ci].fd  = cfd;
                    g_cl[ci].pid = sys_chan_peer(cfd);  /* the kernel's word, not the client's */
                    printf("gemd: client pid %d connected (fd %d)\n", g_cl[ci].pid, cfd);
                }
            }
        }

        for (int i = 0; i < np; i++)
            if (pf[1 + i].revents & (XT_POLLIN | XT_POLLHUP | XT_POLLERR))
                client_readable(map[i]);

        fflush(stdout);
    }
}
