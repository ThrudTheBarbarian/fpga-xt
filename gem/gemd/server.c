/*
 * gemd/server.c — the window server's main loop.
 *
 * M2: THE WINDOW LIST IS THE AES'S, AND IT RUNS IN THIS PROCESS. gemd does not keep a private
 * list beside it — gemd *is* the process where `gem/aes/window.c` runs in SERVER mode. The
 * z-order, the geometry, the chrome (themed frame, title bar, closer, mover, sizer, sliders)
 * and `wind_redraw_area`'s compositing are the AES's own code, unchanged; a client's
 * `wind_create` is now a message that lands on the very same function it used to call directly.
 * That is what makes §5 hold — the AES signatures did not move, only their bodies.
 *
 * gemd adds exactly three things on top:
 *   1. a surface per window, sized to the WORK AREA (chrome is gemd's; a client never sees it);
 *   2. the poll loop below;
 *   3. reaping — a dead client's windows and surfaces go (§9/§11).
 *
 * ONE poll() over the listen fd and every client channel (§3: gemd holds the grab, so it must
 * NEVER block; §9: never assume a client is alive, responsive or well-behaved):
 *   - poll says readable -> ONE read of whatever is there, accumulated into that client's own
 *     buffer until a whole 32-byte record has arrived. A client that writes five bytes and then
 *     goes silent forever costs gemd five bytes of buffer, not a wedged server.
 *   - a write to a client is NEVER fatal. A dying client must not take gemd with it.
 *   - death is CHANNEL EOF, not SIGCHLD. §9 says SIGCHLD and §9 is wrong here: SIGCHLD only
 *     reaches the PARENT, and gemd is the parent of nobody — the boot script starts gemd and
 *     the desktop side by side, and an app is launched from a shell. EOF fires for everyone.
 */
#include <stdio.h>
#include <string.h>
#include "gemd.h"
#include "aes/aes_internal.h"
#include "font.h"
#include "usys.h"

#define GEMD_BG  GFX_RGB(0x20, 0x40, 0x70)     /* the fallback COLOUR, and only a colour (§4):
                                                * the wallpaper is CONTENT, and it belongs to the
                                                * desktop — which is an ordinary client. */
typedef struct {
    int  used;
    int  fd;
    int  pid;                        /* from the KERNEL (SYS_chan_peer) — the client cannot lie */
    char in[GEM_MSG_SZ];             /* partial-record accumulator: see the no-stall rule above */
    int  inlen;
} gclient;

static gclient     g_cl[GEMD_MAXCL];
static gfx_surface g_plane;

/* A write to a client is advisory. If it fails the client is dying; its EOF will arrive and the
 * ordinary death path will clean up. It must NEVER take gemd down with it. */
static void reply(gclient *c, const gem_msg *m)
{
    if (gem_send(c->fd, m) != 0)
        printf("gemd: write to pid %d failed — it is dying; EOF will clean up\n", c->pid);
}

static void wind_error(gclient *c, int reason)
{
    gem_msg r; memset(&r, 0, sizeof r);
    r.w[0] = GEM_WIND_ERROR; r.w[1] = (int16_t)reason;
    reply(c, &r);
}

/* ---- requests ------------------------------------------------------------------------- */

/* The AES allocates the handle and owns the geometry from here on. NO surface yet: the work
 * area is not knowable until the window's final rect is set at OPEN, and the surface is sized
 * to the WORK AREA — the client draws content, never chrome. */
static void do_wind_create(gclient *c, int ci, const gem_msg *m)
{
    int hd = wind_create(m->w[1], m->w[2], m->w[3], m->w[4], m->w[5]);
    if (hd <= 0) { wind_error(c, 1); return; }
    wind_attach_surface(hd, -1, 0, 0, 0, 0, 0, ci);       /* owner recorded; no pixels yet */

    gem_msg r; memset(&r, 0, sizeof r);
    r.w[0] = GEM_WIND_CREATED; r.w[1] = (int16_t)hd;
    reply(c, &r);
    printf("gemd: wind_create wh=%d pid=%d kind=0x%x %dx%d @ %d,%d\n",
           hd, c->pid, m->w[1], m->w[4], m->w[5], m->w[2], m->w[3]);
}

static void do_wind_open(gclient *c, int ci, const gem_msg *m)
{
    int hd = m->w[1];
    if (wind_client_of(hd) != ci) return;                 /* not this client's window: ignore */

    wind_open(hd, m->w[2], m->w[3], m->w[4], m->w[5]);    /* the AES: z-order, clamp, chrome */

    /* ONLY THE AES KNOWS THE WORK AREA. It falls out of the chrome — title height, border, the
     * W_INFO footer, the scrollbar column — which is exactly what gemd owns and what a client
     * must not model. So we ask, and size the surface to the answer. */
    int ww, wh;
    wind_work_size(hd, &ww, &wh);
    if (ww <= 0 || wh <= 0) { wind_error(c, 2); return; }

    gsurface s;
    if (gemd_surf_create(&s, ww, wh, g_plane.w, g_plane.h) != 0) { wind_error(c, 2); return; }

    /* THE CAPABILITY. The surface is XT_SHM_OWNED, so nobody may map it until its owner says so
     * — and we grant it to the pid the KERNEL reports for this channel, never to one the client
     * asserts in a message (that would be a capability handed out on the say-so of the process
     * being granted it). */
    if (sys_shm_grant(s.id, c->pid) != 0) {
        printf("gemd: shm_grant(%d -> pid %d) FAILED\n", s.id, c->pid);
        gemd_surf_drop(&s); wind_error(c, 3); return;
    }
    wind_attach_surface(hd, s.id, s.gen, s.px, ww, wh, s.cap_w, ci);

    gem_msg r; memset(&r, 0, sizeof r);
    r.w[0] = GEM_WIND_SURF; r.w[1] = (int16_t)hd;
    r.w[2] = (int16_t)ww;      r.w[3] = (int16_t)wh;      /* the work area: what the client draws */
    r.w[4] = (int16_t)s.cap_w; r.w[5] = (int16_t)s.cap_h; /* STRIDE == capacity width (§12) */
    r.u[0] = (uint32_t)s.id;                              /* a handle. Never an address (§13.1). */
    r.u[1] = s.gen;
    reply(c, &r);

    /* §3: WM_REDRAW survives for the FIRST PAINT and for resize, and for nothing else. */
    gem_msg rd; memset(&rd, 0, sizeof rd);
    rd.w[0] = GEM_MSG_REDRAW; rd.w[1] = (int16_t)hd;
    rd.w[2] = 0; rd.w[3] = 0; rd.w[4] = (int16_t)ww; rd.w[5] = (int16_t)wh;
    reply(c, &rd);

    printf("gemd: wind_open wh=%d pid=%d work %dx%d -> surf %d gen %u cap %dx%d (stride %d)\n",
           hd, c->pid, ww, wh, s.id, s.gen, s.cap_w, s.cap_h, s.cap_w);
}

/* A client posted damage in SURFACE coordinates. Clamp it (§9: a damage rect is a REQUEST, not
 * an instruction), map it to the screen through the window's work-area origin, and let the AES
 * re-composite that screen rect — chrome, z-order, whatever is above and below it. gemd is told
 * "these pixels changed" and never learns why (§3). */
static void do_damage(int ci, const gem_msg *m)
{
    int hd = m->w[1];
    if (wind_client_of(hd) != ci) return;
    if ((int)m->u[0] != wind_surface_of(hd) || m->u[1] != wind_gen_of(hd)) return;  /* stale (§11) */
    /* m->u[2] is retire_seq: DEAD IN PHASE 1 (§14). Drawing is synchronous, so the client's
     * pixels are already in memory. Phase 2 compares it against the blitter's retired seq. */

    int ww, wh, ox, oy;
    wind_work_size(hd, &ww, &wh);
    wind_work_origin(hd, &ox, &oy);
    int x = m->w[2], y = m->w[3], w = m->w[4], h = m->w[5];
    if (x < 0) { w += x; x = 0; }
    if (y < 0) { h += y; y = 0; }
    if (x + w > ww) w = ww - x;
    if (y + h > wh) h = wh - y;
    if (w <= 0 || h <= 0) return;

    wind_redraw_area(ox + x, oy + y, w, h);      /* the AES composites; draw_one blits the store */
}

static void do_wind_name(int ci, const gem_msg *m)
{
    int hd = m->w[1];
    if (wind_client_of(hd) != ci) return;
    char name[GEM_NAME_MAX + 1];
    memcpy(name, (const char *)&m->w[2], GEM_NAME_MAX);
    name[GEM_NAME_MAX] = 0;                      /* the wire field is fixed-size; a long title is
                                                  * truncated, deliberately (gemproto.h) */
    wind_set_name(hd, name);
}

/* ---- client lifecycle ------------------------------------------------------------------- */

static void drop_window(int hd)
{
    gsurface s;
    s.id = wind_surface_of(hd);
    s.gen = wind_gen_of(hd);
    s.px = (uint32_t *)1;                        /* non-NULL; the drop only needs the id */
    wind_close(hd);                              /* AES: out of the z-order, and RECOMPOSITE the
                                                  * rect it vacated — the window disappears, and
                                                  * no client was asked anything (§3) */
    if (s.id >= 0) gemd_surf_drop(&s);           /* gemd's ref. A dead client's went with it, so
                                                  * this is the LAST one: the pages AND THE ID are
                                                  * reclaimed (§11 — the point of sys_shm_unmap) */
    wind_delete(hd);
}

static void drop_client(int ci)
{
    gclient *c = &g_cl[ci];
    int hd;
    while ((hd = wind_next_of_client(ci, 1)) != 0) {      /* re-scan: drop_window frees the slot */
        printf("gemd: pid %d gone — dropping wh=%d, surface %d\n",
               c->pid, hd, wind_surface_of(hd));
        drop_window(hd);
    }
    sys_close(c->fd);
    memset(c, 0, sizeof *c);
}

/* Drain what is readable and dispatch every COMPLETE record. Never blocks: poll said there was
 * something, one read takes it, and a partial record just waits in the accumulator. */
static void client_readable(int ci)
{
    gclient *c = &g_cl[ci];
    char buf[GEM_MSG_SZ * 4];
    long n = sys_read(c->fd, buf, sizeof buf);
    if (n <= 0) { drop_client(ci); return; }             /* EOF: the peer is gone (§9) */

    for (long i = 0; i < n; i++) {
        c->in[c->inlen++] = buf[i];
        if (c->inlen < GEM_MSG_SZ) continue;
        gem_msg m;
        memcpy(&m, c->in, sizeof m);
        c->inlen = 0;
        switch (m.w[0]) {
        case GEM_WIND_CREATE: do_wind_create(c, ci, &m); break;
        case GEM_WIND_OPEN:   do_wind_open(c, ci, &m);   break;
        case GEM_WIND_NAME:   do_wind_name(ci, &m);      break;
        case GEM_DAMAGE:      do_damage(ci, &m);         break;
        case GEM_WIND_CLOSE:  if (wind_client_of(m.w[1]) == ci) drop_window(m.w[1]); break;
        case GEM_WIND_DELETE: break;                     /* CLOSE already deleted it */
        case GEM_SURF_DROP:   break;                     /* the client dropped ITS ref; gemd keeps
                                                          * its own until the window closes (§11) */
        default:
            printf("gemd: pid %d sent op %d — ignored\n", c->pid, m.w[0]);
            break;
        }
    }
}

/* ---- the loop ---------------------------------------------------------------------------- */

int gemd_run(void)
{
    struct os_fbinfo fb;
    if (sys_fb_info(&fb) != 0) { printf("gemd: no display plane\n"); return 1; }
    g_plane.w = fb.w; g_plane.h = fb.h; g_plane.stride = fb.stride;
    g_plane.px = (uint32_t *)fb.addr;

    /* gemd is the ONLY process that presents to the framebuffer (Rule 1), so it is the only one
     * that opens a workstation on the plane. The AES draws chrome through it and blits each
     * client's backing store into the work area. */
    aes_server_mode();
    vdi_init(&g_plane);
    vdi_set_font_dir("/OS/fonts");
    font_face *face = vdi_load_system_font();
    if (!face) printf("gemd: system font load FAILED — titles will be blank\n");
    else       vdi_set_face(face);

    int vh = v_opnvwk(&g_plane);
    if (vh <= 0) { printf("gemd: v_opnvwk FAILED\n"); return 1; }

    const theme *th = gemd_theme();      /* chrome art. Read-only: §5 says both sides may load it */
    aes_init(vh, th);
    wind_set_desktop(GEMD_BG);           /* the fallback colour: the plane is never un-owned (§3) */
    wind_redraw();

    int lfd = sys_svc_register(GEM_SERVICE);
    if (lfd < 0) { printf("gemd: svc_register(\"%s\") -> %d (already running?)\n",
                          GEM_SERVICE, lfd); return 1; }
    printf("gemd: up — plane %dx%d stride %d, service \"%s\" fd %d, theme %s\n",
           fb.w, fb.h, fb.stride, GEM_SERVICE, lfd, th ? "loaded" : "MISSING (no chrome art)");
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

        int r = sys_poll(pf, 1 + np, -1);          /* ONE wait, all clients. Never one at a time. */
        if (r < 0) {
            if (r == -4) continue;                 /* -EINTR: a signal, not a failure */
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
                    g_cl[ci].fd   = cfd;
                    g_cl[ci].pid  = sys_chan_peer(cfd);   /* the kernel's word, not the client's */
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
