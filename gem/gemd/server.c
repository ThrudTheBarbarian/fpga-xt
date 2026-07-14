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
    char str[GEM_STR_MAX + 1];       /* a chrome string being assembled from its chunks (§11).
                                      * PER CLIENT, so a half-sent title is never another
                                      * client's problem. */
} gclient;

static gclient     g_cl[GEMD_MAXCL];
static gfx_surface g_plane;
static gsurface    g_surf[GEMD_MAXW];   /* the backing store per WINDOW HANDLE. gemd keeps its own
                                         * ref and its own capacity numbers: §12's resize is
                                         * "does the new extent still fit?", and only gemd knows. */
static int         g_ifd = -1;          /* /OS/dev/input — an fd, so it joins the ONE poll (M4) */

/* A write to a client is advisory. If it fails the client is dying; its EOF will arrive and the
 * ordinary death path will clean up. It must NEVER take gemd down with it. */
static void reply(gclient *c, const gem_msg *m)
{
    if (gem_send(c->fd, m) != 0)
        printf("gemd: write to pid %d failed — it is dying; EOF will clean up\n", c->pid);
}

void gemd_send_to(int ci, const gem_msg *m)
{
    if (ci < 0 || ci >= GEMD_MAXCL || !g_cl[ci].used) return;
    reply(&g_cl[ci], m);
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
    if (hd <= 0 || hd >= GEMD_MAXW) { wind_error(c, 1); return; }
    memset(&g_surf[hd], 0, sizeof g_surf[hd]);
    g_surf[hd].id = -1;                                   /* NOT 0: 0 is a real shm id */
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

    if (hd < 1 || hd >= GEMD_MAXW) { wind_error(c, 2); return; }
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
    g_surf[hd] = s;
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

/* THE RESIZE (§12), on the back of the AES's sizer drag. The capacity is the extent rounded up
 * to a 64px grid, so almost every resize lands INSIDE the surface we already have:
 *
 *   fits  -> change the extent. Same id, same pages, same mapping, NOTHING to remap on either
 *            side — the client just starts drawing a bigger top-left sub-rect of the same buffer.
 *            That is the whole reason stride is the CAPACITY width and not the extent width: if
 *            stride tracked the visible width, growing a window by one pixel would move every row.
 *   does not fit -> a new surface, granted to the same client. The old one is dropped; the client
 *            still holds a ref to it until it unmaps, so a composite in flight stays valid (§11).
 */
int gemd_resize_surface(int hd)
{
    if (hd < 1 || hd >= GEMD_MAXW) return -1;
    int ci = wind_client_of(hd);
    if (ci < 0 || ci >= GEMD_MAXCL || !g_cl[ci].used) return -1;
    gclient *c = &g_cl[ci];

    int ww, wh;
    wind_work_size(hd, &ww, &wh);
    if (ww <= 0 || wh <= 0) return -1;

    gsurface *s = &g_surf[hd];
    if (s->id < 0 || ww > s->cap_w || wh > s->cap_h) {          /* capacity exceeded: a new one */
        gsurface ns;
        if (gemd_surf_create(&ns, ww, wh, g_plane.w, g_plane.h) != 0) return -1;
        if (sys_shm_grant(ns.id, c->pid) != 0) { gemd_surf_drop(&ns); return -1; }
        gemd_surf_drop(s);                                      /* our ref; the client drops its own */
        *s = ns;
    }
    wind_attach_surface(hd, s->id, s->gen, s->px, ww, wh, s->cap_w, ci);
    printf("gemd: resize wh=%d work %dx%d -> surf %d cap %dx%d (%s)\n", hd, ww, wh,
           s->id, s->cap_w, s->cap_h,
           "same id = it fitted the capacity; a new id = it did not");

    gem_msg r; memset(&r, 0, sizeof r);
    r.w[0] = GEM_MSG_SIZED; r.w[1] = (int16_t)hd;
    r.w[2] = (int16_t)ww;      r.w[3] = (int16_t)wh;
    r.w[4] = (int16_t)s->cap_w; r.w[5] = (int16_t)s->cap_h;
    r.u[0] = (uint32_t)s->id;   r.u[1] = s->gen;
    reply(c, &r);
    return 0;
}

/* THE DECLARATIVE CHROME MODEL ARRIVES (§11). The client tells us what its window IS — a name, a
 * subtitle, a proxy icon, a modified flag, a list of title-button glyphs — and from here on the
 * chrome is OURS: we hold the model, so we repaint the title bar on a drag, on a reveal, on a
 * theme change, and with the owner WEDGED. Nothing here calls back into a client, and nothing
 * here can.
 *
 * Strings arrive in chunks (a fixed record cannot hold a path). They are accumulated in the
 * CLIENT'S OWN scratch buffer — one client's half-sent title cannot disturb another's — and
 * committed to the AES when the terminating chunk lands. */
static void do_wind_set(gclient *c, int ci, const gem_msg *m)
{
    int hd = m->w[1], field = m->w[2];
    if (wind_client_of(hd) != ci) return;

    switch (field) {
    case WF_NAME: case WF_INFO: case WF_SUBTITLE: case WF_ICON: {
        int cap = (int)sizeof c->str - 1;
        int off = m->w[3];
        if (off < 0 || off >= cap) return;                  /* a lying offset buys nothing */
        int n = cap - off; if (n > GEM_STR_CHUNK) n = GEM_STR_CHUNK;
        memcpy(c->str + off, (const char *)&m->w[4], (size_t)n);
        c->str[cap] = 0;
        int done = (off + n >= cap);                        /* the buffer is full: that is the end */
        for (int i = 0; i < n && !done; i++) if (!c->str[off + i]) done = 1;
        if (!done) return;                                  /* more chunks to come */
        wind_set(hd, field, WIND_PTR_HI(c->str), WIND_PTR_LO(c->str), 0, 0);
        break;
    }
    case WF_TITLEFLAGS:
        wind_set(hd, field, m->w[3], 0, 0, 0);
        break;
    case WF_TITLEBTNS: {
        int n = m->w[3]; if (n < 0) n = 0; if (n > WIND_MAXTB) n = WIND_MAXTB;
        int g[WIND_MAXTB];
        for (int i = 0; i < n; i++) g[i] = (int)m->u[i];
        wind_set(hd, field, WIND_PTR_HI(g), WIND_PTR_LO(g), n, 0);
        break;
    }
    default:
        printf("gemd: pid %d set field %d — not a chrome field, ignored\n", c->pid, field);
        break;
    }
}

/* ---- client lifecycle ------------------------------------------------------------------- */

static void drop_window(int hd)
{
    if (hd < 1 || hd >= GEMD_MAXW) return;
    gemd_forget_window(hd);                      /* it cannot hold the focus while it is gone */
    wind_close(hd);                              /* AES: out of the z-order, and RECOMPOSITE the
                                                  * rect it vacated — the window disappears, and
                                                  * no client was asked anything (§3) */
    gemd_surf_drop(&g_surf[hd]);                 /* gemd's ref. A dead client's went with it, so
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
        case GEM_WIND_SET:    do_wind_set(c, ci, &m);    break;
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

static int g_lfd = -1;                /* the "gem" service listen fd */

static void accept_client(void)
{
    int cfd = sys_svc_accept(g_lfd);
    if (cfd < 0) return;
    int ci = -1;
    for (int i = 0; i < GEMD_MAXCL; i++) if (!g_cl[i].used) { ci = i; break; }
    if (ci < 0) { sys_close(cfd); printf("gemd: too many clients\n"); return; }
    memset(&g_cl[ci], 0, sizeof g_cl[ci]);
    g_cl[ci].used = 1;
    g_cl[ci].fd   = cfd;
    g_cl[ci].pid  = sys_chan_peer(cfd);        /* the kernel's word, not the client's */
    printf("gemd: client pid %d connected (fd %d)\n", g_cl[ci].pid, cfd);
}

/* THE ONE WAIT. The listen fd, every client channel, and the input device — in a single poll().
 * No special case for input, no second thread, and nothing that can wedge: gemd holds the grab,
 * so it must never block on any one source (§3).
 *
 * This is ALSO the AES's event source (aes_set_events), and that is what makes the chrome work:
 * wind_handle_click's drag and resize loops wait through aes_wait_idle, which lands here — so
 * while a window is being dragged gemd is STILL accepting connections, still reading client
 * messages, and still compositing damage from other clients. The modal loop is modal for the
 * pointer, not for the server.
 */
static struct os_event g_iq[8];       /* one read() can bring several events; hand them out one
                                       * at a time, because aes_wait returns one at a time */
static int g_iqn, g_iqi;

/* NEVER read the input fd unless poll() said it is readable: the read BLOCKS (a device read that
 * returned 0 would mean EOF, so it cannot "return nothing"), and a blocking read before the poll
 * is a gemd that never accepts a client — it would sit in read() waiting for a mouse. */
static int gemd_events(aes_event *ev, int timeout_ms)
{
    for (;;) {
        if (g_iqi < g_iqn) {                      /* a burst still in hand from the last read */
            struct os_event oe = g_iq[g_iqi++];
            memset(ev, 0, sizeof *ev);
            ev->type = oe.type; ev->mx = oe.mx; ev->my = oe.my;
            ev->button = oe.button; ev->key = oe.key; ev->shift = oe.shift;
            if (ev->type == OS_EV_TIMER || ev->type == OS_EV_NONE) continue;   /* not an event */
            return ev->type;                      /* OS_EV_* == AES_* by construction (xtsys.h) */
        }

        struct xt_pollfd pf[2 + GEMD_MAXCL];
        int map[GEMD_MAXCL], np = 0, ii;

        pf[0].fd = g_lfd; pf[0].events = XT_POLLIN; pf[0].revents = 0;
        for (int i = 0; i < GEMD_MAXCL; i++) {
            if (!g_cl[i].used) continue;
            pf[1 + np].fd = g_cl[i].fd; pf[1 + np].events = XT_POLLIN; pf[1 + np].revents = 0;
            map[np++] = i;
        }
        ii = 1 + np;
        pf[ii].fd = g_ifd; pf[ii].events = XT_POLLIN; pf[ii].revents = 0;

        int r = sys_poll(pf, ii + (g_ifd >= 0 ? 1 : 0), timeout_ms);
        if (r < 0) {
            if (r == -4) continue;                /* -EINTR: a signal, not a failure */
            printf("gemd: poll -> %d\n", r);
            memset(ev, 0, sizeof *ev); ev->type = AES_QUIT; return AES_QUIT;
        }
        if (r == 0) { memset(ev, 0, sizeof *ev); ev->type = AES_TIMER; return AES_TIMER; }

        if (pf[0].revents & XT_POLLIN) accept_client();
        for (int i = 0; i < np; i++)
            if (pf[1 + i].revents & (XT_POLLIN | XT_POLLHUP | XT_POLLERR))
                client_readable(map[i]);
        if (g_ifd >= 0 && (pf[ii].revents & XT_POLLIN)) {   /* readable: the read cannot block now */
            long n = sys_read(g_ifd, g_iq, sizeof g_iq);
            if (n >= (long)sizeof(struct os_event)) {
                g_iqn = (int)(n / (long)sizeof(struct os_event));
                g_iqi = 0;                                  /* handed out at the top of the next lap */
            }
        }
        fflush(stdout);
    }
}

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

    /* THE ONLY SANCTIONED FULL-SCREEN REPAINT IN THE WHOLE STACK, and it is the FIRST FRAME:
     * gemd has just come up, the plane holds whatever the bootloader left, and there is no
     * previous frame for a damage rect to be relative to. It happens exactly once per boot.
     *
     * Everything else repaints old ∪ new. On the A9 gemd composites in SOFTWARE, so a full-plane
     * repaint is ~8 MB of pixel work you can watch fill down the screen — and it does not merely
     * look bad: one of them once outran DCLICK_MS and made double-click stop working. If you are
     * about to add a second wind_redraw(), you need a documented reason and the user's agreement
     * BEFORE it lands. */
    wind_redraw();

    for (int i = 1; i < GEMD_MAXW; i++) g_surf[i].id = -1;    /* 0 is a REAL shm id; -1 is "none" */

    g_lfd = sys_svc_register(GEM_SERVICE);
    if (g_lfd < 0) { printf("gemd: svc_register(\"%s\") -> %d (already running?)\n",
                            GEM_SERVICE, g_lfd); return 1; }

    /* INPUT IS AN FD (M4). Not SYS_input — that blocks, and a server that blocks on input cannot
     * hear its clients. The kernel publishes events on a device and knows nothing about window
     * servers (§2); gemd is simply the process that opened it. */
    g_ifd = (int)sys_open(GEMD_INPUT_DEV, 0 /*O_RDONLY*/);
    if (g_ifd < 0) printf("gemd: %s -> %d — NOTHING WILL BE CLICKABLE\n", GEMD_INPUT_DEV, g_ifd);
    aes_set_events(gemd_events);         /* and the AES's frame drags wait through it too */

    printf("gemd: up — plane %dx%d stride %d, service \"%s\" fd %d, input fd %d, theme %s\n",
           fb.w, fb.h, fb.stride, GEM_SERVICE, g_lfd, g_ifd,
           th ? "loaded" : "MISSING (no chrome art)");
    fflush(stdout);

    for (;;) {
        aes_event ev;
        int t = gemd_events(&ev, -1);    /* one wait: clients, connections and input alike */
        if (t == AES_QUIT) return 1;
        gemd_route(t, &ev);              /* hit-test, chrome, focus, forward (route.c) */
        fflush(stdout);
    }
}
