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
#ifdef GEM_HOST
#include <sys/time.h>      /* hostgem: POSIX clock, see gemd_us */
#endif
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
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
    gsurface menu;                   /* §10: this app's OWN strip surface (id -1 = never asked).
                                      * gemd composites the FOCUSED app's; a switch is a
                                      * compositing decision, not a conversation. */
    long long last_recv;             /* §9 liveness: when the client last said ANYTHING */
} gclient;

static gclient     g_cl[GEMD_MAXCL];
static gfx_surface g_plane;          /* what the VDI draws into: the CACHED back-buffer when the
                                      * kernel provides one (SYS_fb_wallpaper), else the plane */
static struct os_fbinfo g_scan;      /* the REAL plane — uncached, because the compositor scans
                                      * it. Written only by gemd_present, in rows, never read. */
static int         g_scan_on;        /* back-buffer mode: present copies rects to the plane */
static int         g_blitfd = -1;    /* /dev/blitter: the present is the ENGINE's when the
                                      * device is there (433 MB/s vs ~200 for CPU uncached
                                      * stores), the CPU's otherwise (qemu). One failed submit
                                      * disables it for the boot: slower, never wrong. */

/* THE PRESENT (aes_flush_rect lands here, via the overlay hook). This split is not a nicety —
 * it was a 3-SECOND window redraw, observed on the board. The plane is NON-CACHEABLE (the HW
 * compositor scans it), and the VDI's software rendering read-modify-writes nearly every pixel
 * it touches: FreeType blends, 9-slice edges, pattern fills. Every one of those reads was an
 * uncached DDR round-trip. §14 called drawing into the plane "the worst of both worlds" and
 * this is what it costs. So the VDI renders into the kernel's CACHED back-buffer
 * (SYS_fb_wallpaper — a dedicated 16 MB PL0-RW cacheable region, no heap cost), and this copy
 * — cached reads, sequential uncached writes, nothing else — is the only thing that ever
 * touches the plane. */
/* µs clock — NOT profiler-only: the §9 liveness clock (last_recv) runs on it. */
static long long gemd_us(void)
{
#ifdef GEM_HOST
    /* hostgem: the shim answers this trap by calling macOS gettimeofday, whose struct timeval is
     * 16 bytes — four more than the XTOS layout below.  Ask POSIX directly rather than hand a
     * 12-byte buffer to a 16-byte writer. */
    struct timeval htv; gettimeofday(&htv, 0);
    return (long long)htv.tv_sec * 1000000ll + htv.tv_usec;
#else
    unsigned tv[3];
    __syscall(SYS_gettimeofday, (long)tv, 0, 0);
    return (long long)tv[0] * 1000000ll + tv[2];
#endif
}
#ifdef INSTRUMENTATION
/* Drag-lag profiler: where does a resize-drag millisecond actually go? Accumulates
 * per-stage microseconds and counts, klogs one line per second while active. Debug
 * data only — compiled away (with its per-present gettimeofday pairs) unless the
 * build says INSTRUMENT=1, so dmesg stays quiet in normal use. */
static struct { long long blit, fence, cpu; int presents, damages, sizes, motions; long long last; } g_prof;
static void prof_dump(void)
{
    long long now = gemd_us();
    if (g_prof.last == 0) { g_prof.last = now; return; }
    if (now - g_prof.last < 1000000ll) return;
    if (g_prof.presents || g_prof.damages || g_prof.sizes) {
        char b[160];
        int n = snprintf(b, sizeof b,
            "[gemd] 1s: %d motions %d presents (blit %dms fence %dms cpu %dms) %d damages %d resizes\n",
            g_prof.motions, g_prof.presents, (int)(g_prof.blit/1000), (int)(g_prof.fence/1000),
            (int)(g_prof.cpu/1000), g_prof.damages, g_prof.sizes);
        sys_klog(b, (unsigned)n);
    }
    memset(&g_prof, 0, sizeof g_prof);
    g_prof.last = now;
}
#define PROF_NOW()      gemd_us()
#define PROF_ADD(f, v)  (g_prof.f += (v))
#define PROF_INC(f)     (g_prof.f++)
#else
static void prof_dump(void) {}
#define PROF_NOW()      0
#define PROF_ADD(f, v)  ((void)(v))
#define PROF_INC(f)     ((void)0)
#endif

/* ---- §10: the menu strip -------------------------------------------------------------- */
/* The focused client's strip surface composites into the reserved top band; no menu (or no
 * focus) composites the band's own background. Registered as the AES's menu-redraw hook, so
 * wind_redraw_area paints it whenever a damage rect reaches the band — the same path that
 * painted the local-mode bar. */
int gemd_focus_client(void);                 /* route.c: the focused window's client, or -1 */
static void menu_strip_redraw(void)
{
    int sh = aes_top_reserve(); if (sh <= 0) return;
    /* the MENU OWNER (§10): the focused app if it has a bar, else the desktop (bottom window)
     * — classic GEM shows the desktop's menu whenever no app is active. */
    int ci = gemd_focus_client();
    if (!(ci >= 0 && g_cl[ci].used && g_cl[ci].menu.id >= 0)) ci = wind_bottom_client();
    gfx_surface *d = &g_plane;
    if (ci >= 0 && g_cl[ci].used && g_cl[ci].menu.id >= 0 && g_cl[ci].menu.px) {
        gfx_surface src; memset(&src, 0, sizeof src);
        src.px = g_cl[ci].menu.px; src.w = g_cl[ci].menu.cap_w;
        src.h  = sh;               src.stride = g_cl[ci].menu.cap_w;
        gfx_blit(d, 0, 0, &src, 0, 0, d->w, sh);
    } else {
        for (int y = 0; y < sh; y++) {       /* no menu owner: the band is gemd's, flat */
            uint32_t *row = d->px + (size_t)y * d->stride;
            for (int x = 0; x < d->w; x++) row[x] = GFX_RGB(0xF4, 0xF5, 0xF7);
        }
    }
}
static void do_menu_bar(gclient *c, int ci)
{
    int sh = aes_top_reserve(); if (sh <= 0) sh = AES_MENUBAR_H;
    if (c->menu.id < 0) {                    /* once per client (§10): idempotent re-ask */
        if (gemd_surf_create(&c->menu, g_plane.w, sh, g_plane.w, g_plane.h) != 0) return;
        if (sys_shm_grant(c->menu.id, c->pid) != 0) { gemd_surf_drop(&c->menu); c->menu.id = -1; return; }
    }
    gem_msg r; memset(&r, 0, sizeof r);
    r.w[0] = GEM_MSG_MENU_SURF; r.u[0] = (uint32_t)c->menu.id; r.u[1] = c->menu.gen;
    r.w[2] = (int16_t)g_plane.w; r.w[3] = (int16_t)sh; r.w[4] = (int16_t)c->menu.cap_w;
    gem_send(c->fd, &r);
    (void)ci;
}

long long gemd_us_pub(void){ return gemd_us(); }
long long gemd_client_last_recv(int ci){ return (ci>=0&&ci<GEMD_MAXCL&&g_cl[ci].used)?g_cl[ci].last_recv:0; }
int gemd_client_has_menu(int ci){ return ci>=0&&ci<GEMD_MAXCL&&g_cl[ci].used&&g_cl[ci].menu.id>=0; }

static void gemd_present(int x, int y, int w, int h)
{
    if (!g_scan_on) return;
    if (x < 0) { w += x; x = 0; }
    if (y < 0) { h += y; y = 0; }
    if (x + w > g_plane.w) w = g_plane.w - x;
    if (y + h > g_plane.h) h = g_plane.h - y;
    if (w <= 0 || h <= 0) return;

    if (g_blitfd >= 0) {
        /* THE ENGINE PRESENTS: COPY, wallpaper -> plane, same rect both sides. The
         * driver cleans the cached source rows itself. Rounded out to even x/width —
         * BLOCK_BLIT refuses odd source X — which for a present only re-copies a column
         * that is identical anyway. SYNCHRONOUS for now: the very next composite may
         * redraw this back-buffer rect, and the engine must have finished READING it
         * (still ~2x the CPU copy; async + in-flight-rect tracking is the follow-up).
         * BANDED, 128 rows per fenced submit (the fetch-starvation rule, see
         * gemd_compose_blit): the present rides the scan-out fetcher's DDRC port, and a
         * monolithic near-screen present holds it long enough to OVERRUN the display —
         * board-observed at plain wind_open, before any drag. The inter-band fences are
         * the fetcher's refill gaps. */
        int bx = x & ~1, bw = (w + (x - bx) + 1) & ~1;
        long long t0 = PROF_NOW();
        int ok = 1;
        for (int band = 0; band < h && ok; band += 128) {
            int bh = h - band > 128 ? 128 : h - band;
            struct xt_blit_cmd c; memset(&c, 0, sizeof c);
            c.op = XT_BLIT_COPY;
            c.dst_id = XT_BLIT_SURF_PLANE; c.src_id = XT_BLIT_SURF_WALLPAPER;
            c.dx = (uint16_t)bx; c.dy = (uint16_t)(y + band);
            c.dw = (uint16_t)bw; c.dh = (uint16_t)bh;
            c.sx = (uint16_t)bx; c.sy = (uint16_t)(y + band);
            long seq = sys_write(g_blitfd, &c, sizeof c);
            unsigned want = (unsigned)seq;
            if (seq < 0 || sys_ioctl(g_blitfd, XT_BLIT_WAIT, &want) != 0) ok = 0;
        }
        if (ok) {
            PROF_ADD(blit, PROF_NOW() - t0);
            PROF_INC(presents);
            return;
        }
        gemd_log("blitter present failed — CPU present from here on");
        sys_close(g_blitfd); g_blitfd = -1;      /* never wedge the present on a sick engine */
    }

    long long tc = PROF_NOW();
    const uint32_t *src = g_plane.px + (size_t)y * g_plane.stride + x;
    uint32_t *dst = (uint32_t *)g_scan.addr + (size_t)y * g_scan.stride + x;
    for (int yy = 0; yy < h; yy++) {
        memcpy(dst, src, (size_t)w * 4);
        src += g_plane.stride; dst += g_scan.stride;
    }
    sys_fb_present();                            /* dsb: the compositor scans DDR */
    PROF_ADD(cpu, PROF_NOW() - tc); PROF_INC(presents);
}
static gsurface    g_surf[GEMD_MAXW];   /* the backing store per WINDOW HANDLE. gemd keeps its own
                                         * ref and its own capacity numbers: §12's resize is
                                         * "does the new extent still fit?", and only gemd knows. */

/* ---- M7: the ENGINE COMPOSITE ------------------------------------------------------------
 * draw_content's inner blit (client surface -> back-buffer) through /dev/blitter instead of
 * the CPU: 777 MB/s FC vs ~190 memcpy, and the CPU freed during drags. The AES calls the
 * aes_set_compose_blit hook below for every opaque content blit; ANY refusal (-1) falls back
 * to the software gfx_blit — qemu, a pooled (non-plv) surface, an odd rect that cannot be
 * split, a failed submit: slower, never wrong. Surfaces are declared (id -> stride) at
 * attach; coherency is the DRIVER's (cached src rows cleaned, cached dst rows
 * clean+invalidated around the engine write — vm.c/blitter.c, the M7 protocol). */
static void gemd_surf_declare(const gsurface *s)
{
    if (g_blitfd < 0 || s->id < 0 || !s->contig) return;
    struct xt_blit_surf d = { s->id, (uint32_t)s->cap_w * 4u };
    if (sys_ioctl(g_blitfd, XT_BLIT_DECLARE, &d) != 0)
        gemd_log("blit declare surf %d failed — CPU composite for it", s->id);
}

static int gemd_compose_blit(int surf_id, int dx, int dy, int sx, int sy, int w, int h)
{
    if (g_blitfd < 0 || !g_scan_on || surf_id < 0) return -1;
    if ((long)w * h < 4096) return -1;               /* syscall+fence beats memcpy only past
                                                      * a few thousand pixels: small = CPU */
    /* THE FETCH-STARVATION RULE (board-found, 2026-07-17): the blitter (HP1) and the
     * scan-out fetcher (HP0) share a DDRC port, and QoS pins are tied off in fabric —
     * a sustained FC stream simply out-arbitrates the display. A live resize drag
     * composites the union rect PER MOTION (~21/s x ~16 MB); with the engine that
     * monopolized the port and the desktop fetch OVERRAN — line-segment "ghost" rows,
     * and enough sustained starvation to stale-lock the monitor. Drag frames are
     * throwaway: composite them on the CPU (its traffic rides the CPU/L2 port), and
     * keep the engine for settled frames. */
    if (wind_drag_sizing()) return -1;
    const gsurface *s = 0;
    for (int i = 1; i < GEMD_MAXW; i++)
        if (g_surf[i].id == surf_id) { s = &g_surf[i]; break; }
    if (!s || !s->contig) return -1;                 /* pooled fallback surface: CPU */

    /* BLOCK_BLIT needs src/dst X of EQUAL parity (no barrel shift in the RTL: a
     * mismatch emits half-beat-shifted garbage — seen as one frame of "ghosted"
     * halftone rows when a mid-drag resize put the work origin on an odd X; clamp_win's
     * even-snap only runs on settled positions). The mismatch is invariant under equal
     * advance, so it cannot be fixed with edge columns: CPU-composite that frame. */
    if ((sx ^ dx) & 1) return -1;
    /* And an EVEN source X: CPU-copy an odd leading/trailing column rather than
     * widening — the damage clip is a hard boundary, one pixel outside it can belong
     * to a window HIGHER in the z-order. The columns' cache lines are flushed by the
     * driver's dst clean+invalidate (they share lines with the engine rect's edges),
     * so coherency holds for them too. */
    gfx_surface ss; memset(&ss, 0, sizeof ss);
    ss.px = s->px; ss.w = s->cap_w; ss.h = s->cap_h; ss.stride = s->cap_w;
    if (sx & 1) {
        gfx_blit(&g_plane, dx, dy, &ss, sx, sy, 1, h);
        sx++; dx++; w--;
    }
    if (w > 0 && (w & 1)) {
        gfx_blit(&g_plane, dx + w - 1, dy, &ss, sx + w - 1, sy, 1, h);
        w--;
    }
    if (w <= 0) return 0;                            /* the edge columns were the whole rect */

    /* BANDED, 128 rows per submit: a monolithic near-screen blit holds the shared DDRC
     * port for ~10 ms — 150+ scanlines of fetch starvation. Each band is synchronous in
     * the driver (fence + dst cache maintenance), so the inter-band gaps are real port
     * idle the fetcher refills in. Cost when small: nothing (one band). */
    for (int band = 0; band < h; band += 128) {
        int bh = h - band > 128 ? 128 : h - band;
        struct xt_blit_cmd c; memset(&c, 0, sizeof c);
        c.op = XT_BLIT_COPY;
        c.dst_id = XT_BLIT_SURF_WALLPAPER; c.src_id = surf_id;
        c.dx = (uint16_t)dx; c.dy = (uint16_t)(dy + band);
        c.dw = (uint16_t)w;  c.dh = (uint16_t)bh;
        c.sx = (uint16_t)sx; c.sy = (uint16_t)(sy + band);
        long seq = sys_write(g_blitfd, &c, sizeof c);    /* cached dst: the DRIVER fences +
                                                          * invalidates before returning */
        if (seq < 0) return -1;                          /* CPU redoes the whole rect: the
                                                          * bands already written are simply
                                                          * rewritten identical — harmless */
        unsigned want = (unsigned)seq;                   /* belt: a lost fence would hand the
                                                          * present stale back-buffer rows */
        if (sys_ioctl(g_blitfd, XT_BLIT_WAIT, &want) != 0) return -1;
    }
    return 0;
}
static int         g_ifd = -1;          /* /OS/dev/input — an fd, so it joins the ONE poll (M4) */

/* [gemd] to the kernel log (dmesg). gemd's stdout is the boot console, and console writes
 * are BLOCKING SERIAL TIME (route.c learned this per-motion); the ring is where operational
 * messages belong. Only fatal at-launch errors still printf — the shell that started gemd
 * should see WHY it exited. Callers pass no trailing newline; the ring line gets one here. */
void gemd_log(const char *fmt, ...)
{
    char b[192];
    int n = snprintf(b, sizeof b, "[gemd] ");
    va_list ap;
    va_start(ap, fmt);
    n += vsnprintf(b + n, sizeof b - (size_t)n, fmt, ap);
    va_end(ap);
    if (n > (int)sizeof b - 2) n = (int)sizeof b - 2;
    b[n++] = '\n';
    sys_klog(b, (unsigned)n);
}

/* A write to a client is advisory. If it fails the client is dying; its EOF will arrive and the
 * ordinary death path will clean up. It must NEVER take gemd down with it. */
static void reply(gclient *c, const gem_msg *m)
{
    if (gem_send(c->fd, m) != 0)
        gemd_log("write to pid %d failed — it is dying; EOF will clean up", c->pid);
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

static void set_rect(gclient *c, int hd, int x, int y, int w, int h);   /* below, with WIND_SET */

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
    { int tr=aes_top_reserve();                           /* the SCREEN work area, for the client's
                                                           * wind_get(0) — dialog centring (§16) */
      r.w[2]=0; r.w[3]=(int16_t)tr; r.w[4]=(int16_t)g_plane.w; r.w[5]=(int16_t)(g_plane.h-tr); }
    reply(c, &r);
    gemd_log("wind_create wh=%d pid=%d kind=0x%x %dx%d @ %d,%d",
             hd, c->pid, m->w[1], m->w[4], m->w[5], m->w[2], m->w[3]);
}

static void do_wind_open(gclient *c, int ci, const gem_msg *m)
{
    int hd = m->w[1];
    if (wind_client_of(hd) != ci) return;                 /* not this client's window: ignore */

    /* Already open: the classic "wind_open again resizes in place" idiom, and a second
     * handshake would ORPHAN the surface below (overwritten, never dropped). It is a geometry
     * request, so it takes the geometry-request path — same clamp, same replies. */
    if (g_surf[hd].id >= 0) { set_rect(c, hd, m->w[2], m->w[3], m->w[4], m->w[5]); return; }

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
        gemd_log("shm_grant(%d -> pid %d) FAILED", s.id, c->pid);
        gemd_surf_drop(&s); wind_error(c, 3); return;
    }
    g_surf[hd] = s;
    gemd_surf_declare(&s);                                /* M7: engine-compositable from now on */
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

    gemd_log("wind_open wh=%d pid=%d work %dx%d -> surf %d gen %u cap %dx%d (stride %d)",
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

    PROF_INC(damages);
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
    /* NEVER conjure a surface for a window that has not opened.  Both open
     * handshakes (do_wind_open here, wind_open client-side) test "has a
     * surface" to mean "already open" — a surface created by a pre-open
     * geometry change (e.g. WF_CONTENTSIZE from a listing tall enough to
     * reserve the scrollbar) makes them silently skip the real open, and the
     * window exists invisible, forever.  Pre-open the chrome/scroll model
     * still updates; do_wind_open sizes the FIRST surface from the resulting
     * work area, so nothing is lost by declining here. */
    if (s->id < 0) return 0;
    /* THE DRAG CAPACITY POLICY. A grow drag crosses a §12 capacity quantum every ~64px, and a
     * realloc per crossing means a FRESH surface (pixels gone -> forced full repaint) a dozen
     * times per drag — the mid-drag redraw artifacts, board-observed. While the sizer drag is
     * LIVE, allocate ONCE and generously (screen-size capacity, the cap anyway); when it ends,
     * shrink-fit back to the quantum in ONE realloc — the "one update on release". */
    int drag = wind_drag_sizing();
    static int was_sizing;
    int drag_ended = was_sizing && !drag;
    was_sizing = drag;
    int need = (s->id < 0 || ww > s->cap_w || wh > s->cap_h);
    if (!need && drag_ended) {
        int fw = ww + GEM_CAP_QUANTUM - 1; fw -= fw % GEM_CAP_QUANTUM;
        int fh = wh + GEM_CAP_QUANTUM - 1; fh -= fh % GEM_CAP_QUANTUM;
        if (fw > g_plane.w) fw = g_plane.w;
        if (fh > g_plane.h) fh = g_plane.h;
        need = (s->cap_w > fw || s->cap_h > fh);                /* oversized: give the shm back */
    }
    if (need) {
        long long gp_t0 = gem_prof_now();                       /* TEMP profiler: the realloc leg */
        gsurface ns;
        int aw = drag ? g_plane.w : ww, ah = drag ? g_plane.h : wh;
        if (gemd_surf_create(&ns, aw, ah, g_plane.w, g_plane.h) != 0) return -1;
        if (sys_shm_grant(ns.id, c->pid) != 0) { gemd_surf_drop(&ns); return -1; }
        /* CONTENT-PRESERVING swap: a fresh surface is uninitialized shm (BLACK), and gemd
         * composites it before the client's repaint lands — the black window flash at every
         * realloc, board-observed. Copy the old intersection across; the follow-up full
         * repaint then paints identical pixels and the swap is invisible. */
        if (s->id >= 0 && s->px && ns.px) {
            int cw = s->cap_w < ns.cap_w ? s->cap_w : ns.cap_w;
            int ch = s->cap_h < ns.cap_h ? s->cap_h : ns.cap_h;
            for (int y = 0; y < ch; y++)
                memcpy(ns.px + (size_t)y * ns.cap_w, s->px + (size_t)y * s->cap_w,
                       (size_t)cw * 4);
        }
        gemd_surf_drop(s);                                      /* our ref; the client drops its own */
        *s = ns;
        gemd_surf_declare(s);                                   /* M7: fresh id, fresh stride */
        gem_prof_add(GEM_PROF_ALLOC, gem_prof_now() - gp_t0, 0);
        /* log ONLY the reallocation (rare, notable); the per-motion within-capacity case says
         * nothing. */
        gemd_log("resize wh=%d work %dx%d -> NEW surf %d cap %dx%d%s",
                 hd, ww, wh, s->id, s->cap_w, s->cap_h,
                 drag ? " (drag: screen-cap once)" : drag_ended ? " (drag end: shrink-fit)" : "");
    }
    wind_attach_surface(hd, s->id, s->gen, s->px, ww, wh, s->cap_w, ci);
    PROF_INC(sizes);

    gem_msg r; memset(&r, 0, sizeof r);
    r.w[0] = GEM_MSG_SIZED; r.w[1] = (int16_t)hd;
    r.w[2] = (int16_t)ww;      r.w[3] = (int16_t)wh;
    r.w[4] = (int16_t)s->cap_w; r.w[5] = (int16_t)s->cap_h;
    r.u[0] = (uint32_t)s->id;   r.u[1] = s->gen;
    r.u[2] = (uint32_t)wind_scroll_x(hd);   /* the resize CLAMPED the scroll server-side; a
                                             * client left with a stale copy blits by a wrong
                                             * delta on its next scroll (stale bands, board) */
    r.u[3] = (uint32_t)wind_scroll_y(hd);
    reply(c, &r);
    return 0;
}

/* A RECT IS A REQUEST (§9/M5) — the Fit button, and any client that wants a different window
 * geometry. The client asked; it did not instruct. Clamp with the SAME rules as a sizer drag
 * (WIND_MIN_* here, clamp_win inside the AES's own wind_set), apply through the very function a
 * single-process app used to call, and send back the truth: MSG_MOVED with the clamped rect,
 * then the §12 surface dance (gemd_resize_surface -> MSG_SIZED) when the work area changed.
 * The client changed nothing locally on the way out — what it learns, it learns from these. */
static void set_rect(gclient *c, int hd, int x, int y, int w, int h)
{
    if (w < WIND_MIN_W) w = WIND_MIN_W;
    if (h < WIND_MIN_H) h = WIND_MIN_H;
    int ow, oh;
    wind_work_size(hd, &ow, &oh);
    wind_set(hd, WF_CURRXYWH, x, y, w, h);        /* the AES: clamp_win + repaint old ∪ new */

    int fx, fy, fw, fh;
    wind_rect_of(hd, &fx, &fy, &fw, &fh);         /* what the window actually IS now */
    gem_msg r; memset(&r, 0, sizeof r);
    r.w[0] = GEM_MSG_MOVED; r.w[1] = (int16_t)hd;
    r.w[2] = (int16_t)fx; r.w[3] = (int16_t)fy; r.w[4] = (int16_t)fw; r.w[5] = (int16_t)fh;
    reply(c, &r);

    int nw, nh;
    wind_work_size(hd, &nw, &nh);
    if (nw != ow || nh != oh) gemd_resize_surface(hd);   /* §12; it sends MSG_SIZED itself */
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
    case WF_CURRXYWH:                               /* geometry is a model field too (M5) */
        set_rect(c, hd, m->w[3], m->w[4], m->w[5], m->w[6]);
        break;
    case WF_PINTOP:                                 /* the app's info-strip height: gemd paints
                                                     * the borders beside it in the bar colour */
        wind_pin_top(hd, (int)m->u[0]);
        return;
    case WF_CONTENTSIZE: {
        /* The scroll model arrives (M5). Repaint ONLY what changed: apps report content size
         * from inside their draw callback, so this lands after nearly EVERY damage post — a
         * full-window recomposite here would double the cost of every paint. The bar
         * appearing/vanishing changes the WORK AREA (the column is reserved from it): that is
         * a surface resize, and the §12 dance tells the client. */
        int ow, oh; wind_work_size(hd, &ow, &oh);
        int osx = wind_scroll_x(hd), osy = wind_scroll_y(hd);
        int ox, oy2, ocw, och, othy, othh;
        int on0 = wind_vsb_col(hd, &ox, &oy2, &ocw, &och, &othy, &othh);
        wind_content_size(hd, (int)m->u[0], (int)m->u[1]);
        int nx, ny, ncw, nch, nthy, nthh;
        int on1 = wind_vsb_col(hd, &nx, &ny, &ncw, &nch, &nthy, &nthh);
        int nw, nh; wind_work_size(hd, &nw, &nh);
        if (nw != ow || nh != oh) gemd_resize_surface(hd);       /* MSG_SIZED carries the scroll */
        else if (wind_scroll_x(hd) != osx || wind_scroll_y(hd) != osy) {
            /* shrinking content CLAMPED the scroll with no resize: the client must hear it,
             * or its stale copy makes the next scroll blit by a wrong delta (stale bands) */
            gem_msg r; memset(&r, 0, sizeof r);
            r.w[0] = GEM_MSG_VSLID; r.w[1] = (int16_t)hd;
            r.u[0] = (uint32_t)wind_scroll_x(hd); r.u[1] = (uint32_t)wind_scroll_y(hd);
            reply(c, &r);
        }
        if (on0 != on1)      wind_redraw_area(on0?ox:nx, on0?oy2:ny, on0?ocw:ncw, on0?och:nch);
        else if (on1 && (nthy != othy || nthh != othh))
                             wind_redraw_area(nx, ny, ncw, nch);
        break;
    }
    case WF_SCROLL: {
        /* A scroll request: clamp, and ANSWER ONLY DISAGREEMENT. The client already moved its
         * own copy (optimistically, with the same clamp) — echoing agreement back would cost a
         * blit-and-repaint for nothing on the other side. */
        int sx = wind_scroll_x(hd), sy = wind_scroll_y(hd);
        wind_set_scroll(hd, (int)m->u[0], (int)m->u[1]);
        int nsx = wind_scroll_x(hd), nsy = wind_scroll_y(hd);
        if (nsx != (int)m->u[0] || nsy != (int)m->u[1]) {   /* clamped: the client is wrong */
            gem_msg r; memset(&r, 0, sizeof r);
            r.w[0] = GEM_MSG_VSLID; r.w[1] = (int16_t)hd;
            r.u[0] = (uint32_t)nsx; r.u[1] = (uint32_t)nsy;
            reply(c, &r);
        }
        if (nsx != sx || nsy != sy) {                       /* the thumb moved: repaint the bar */
            int bx, by, bw2, bh2;
            if (wind_vsb_col(hd, &bx, &by, &bw2, &bh2, 0, 0)) wind_redraw_area(bx, by, bw2, bh2);
        }
        break;
    }
    default:
        gemd_log("pid %d set field %d — not a chrome field, ignored", c->pid, field);
        break;
    }
}

/* ---- M6: HW planes bound to windows (Route A) --------------------------------------------
 * gemd owns plane placement (Rule 1). A client asks with GEM_WIND_PLANE {wh, plane_id, scale};
 * gemd records the bind (wind_plane_link — draw_content then composites that window's work
 * area as an ALPHA=0 HOLE) and keeps the plane's screen rect tracking the work area through
 * the plane-sync hook, which the AES runs after EVERY composite — every geometry, z-order and
 * visibility change ends in wind_redraw_area, so there is no mutation path to miss. The kernel
 * (SYS_plane_window) owns the compositor arrangement: the first active plane flips CMPCFG to
 * Route A (desktop plane on top, alpha-enabled), the last park restores the reset one. */
#define GEMD_NPLANES 4                    /* ids 1..3; the kernel refuses ones that don't exist */
static struct {
    int hd, scale;                        /* the bind (hd 0 = free) */
    int sx, sy, sw, sh, sscale, sen;      /* last state SENT to the kernel: a composite that
                                           * moved nothing costs one comparison, not a syscall */
} g_pl[GEMD_NPLANES];

static void plane_send(int p, int x, int y, int w, int h, int scale, int en)
{
    if (g_pl[p].sx == x && g_pl[p].sy == y && g_pl[p].sw == w && g_pl[p].sh == h &&
        g_pl[p].sscale == scale && g_pl[p].sen == en) return;
    if (sys_plane_window(p, x, y, w, h, scale, en) != 0) return;   /* unknown plane: stay unsent */
    g_pl[p].sx = x; g_pl[p].sy = y; g_pl[p].sw = w; g_pl[p].sh = h;
    g_pl[p].sscale = scale; g_pl[p].sen = en;
}

static void gemd_plane_sync(void)                 /* the aes_set_plane_sync hook */
{
    for (int p = 1; p < GEMD_NPLANES; p++) {
        if (!g_pl[p].hd) continue;
        int ox, oy, ww, wh;
        wind_work_origin(g_pl[p].hd, &ox, &oy);
        wind_work_size(g_pl[p].hd, &ww, &wh);
        plane_send(p, ox, oy, ww, wh, g_pl[p].scale, ww > 0 && wh > 0);
    }
}

static void plane_unbind(int p)
{
    if (!g_pl[p].hd) return;
    wind_plane_link(g_pl[p].hd, 0);
    g_pl[p].hd = 0;
    plane_send(p, 0, 0, 0, 0, 1, 0);              /* park it off-screen; the kernel restores the
                                                   * reset compositor arrangement after the last */
}

static void do_wind_plane(gclient *c, int ci, const gem_msg *m)
{
    int hd = m->w[1], p = m->w[2], scale = m->w[3];
    if (wind_client_of(hd) != ci) return;                    /* not this client's window: ignore */
    if (p == 0) {                                            /* unbind, then composite the work
                                                              * area back to ordinary content */
        for (int i = 1; i < GEMD_NPLANES; i++)
            if (g_pl[i].hd == hd) plane_unbind(i);
        wind_redraw_win(hd);
        return;
    }
    if (p < 1 || p >= GEMD_NPLANES) { wind_error(c, 4); return; }
    if (g_pl[p].hd && g_pl[p].hd != hd) {                    /* one window per plane; re-binding
                                                              * the SAME window updates the scale */
        gemd_log("plane %d is wh=%d's — pid %d refused", p, g_pl[p].hd, c->pid);
        wind_error(c, 4); return;
    }
    g_pl[p].hd = hd; g_pl[p].scale = scale;
    wind_plane_link(hd, p);
    gemd_log("wh=%d shows plane %d (scale %d, pid %d)", hd, p, scale, c->pid);
    wind_redraw_win(hd);       /* punch the hole; the plane-sync hook then places the plane */
}

/* ---- client lifecycle ------------------------------------------------------------------- */

static void drop_window(int hd)
{
    if (hd < 1 || hd >= GEMD_MAXW) return;
    gemd_forget_window(hd);                      /* it cannot hold the focus while it is gone */
    for (int p = 1; p < GEMD_NPLANES; p++)       /* M6: a bound plane parks BEFORE the vacated
                                                  * rect recomposites (close and client death) */
        if (g_pl[p].hd == hd) plane_unbind(p);
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
        gemd_log("pid %d gone — dropping wh=%d, surface %d",
                 c->pid, hd, wind_surface_of(hd));
        drop_window(hd);
    }
    sys_close(c->fd);
    if (c->menu.id >= 0) gemd_surf_drop(&c->menu);      /* §10: the strip dies with the app */
    gemd_grab_client_gone(ci);                           /* §9: EOF releases any grab */
    memset(c, 0, sizeof *c);
    c->menu.id = -1;
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
        c->last_recv = gemd_us();               /* §9: any message = the pipe is draining */
        switch (m.w[0]) {
        case GEM_MENU_BAR:    do_menu_bar(c, ci);        break;
        case GEM_MENU_DAMAGE: {
            extern int gemd_menu_client(void);
            int sh = aes_top_reserve();
            if (sh > 0 && gemd_menu_client() == ci)      /* the MENU OWNER's strip shows (§10):
                                                          * the desktop owns it when unfocused */
                wind_redraw_area(m.w[2], 0, m.w[4], sh);
            break;
        }
        case GEM_GRAB:        gemd_set_grab(ci, m.w[2]); break;
        case GEM_WIND_CREATE: do_wind_create(c, ci, &m); break;
        case GEM_WIND_OPEN:   do_wind_open(c, ci, &m);   break;
        case GEM_WIND_PLANE:  do_wind_plane(c, ci, &m);  break;
        case GEM_WIND_SET:    do_wind_set(c, ci, &m);    break;
        case GEM_DAMAGE:      do_damage(ci, &m);         break;
        case GEM_WIND_CLOSE:  if (wind_client_of(m.w[1]) == ci) drop_window(m.w[1]); break;
        case GEM_WIND_DELETE: break;                     /* CLOSE already deleted it */
        case GEM_SURF_DROP:   break;                     /* the client dropped ITS ref; gemd keeps
                                                          * its own until the window closes (§11) */
        default:
            gemd_log("pid %d sent op %d — ignored", c->pid, m.w[0]);
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
    if (ci < 0) { sys_close(cfd); gemd_log("too many clients"); return; }
    memset(&g_cl[ci], 0, sizeof g_cl[ci]);
    g_cl[ci].used = 1;
    g_cl[ci].menu.id = -1;
    g_cl[ci].last_recv = gemd_us();
    g_cl[ci].fd   = cfd;
    g_cl[ci].pid  = sys_chan_peer(cfd);        /* the kernel's word, not the client's */
    gemd_log("client pid %d connected (fd %d)", g_cl[ci].pid, cfd);
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
        /* Flush the AES's message pipe EVERY LAP, not only at the end of gemd_route: a modal
         * frame loop (a thumb drag) waits through here, and what it posts per motion must go
         * out per motion — that is the whole of "the scroll is live". */
        gemd_flush_msgs();
        prof_dump();                                 /* drag-lag profiler (INSTRUMENTATION-only) */
        gem_prof_dump("srv");                        /* draw profiler (INSTRUMENTATION-only) */
        if (g_iqi < g_iqn) {                      /* a burst still in hand from the last read */
            struct os_event oe = g_iq[g_iqi++];
            memset(ev, 0, sizeof *ev);
            ev->type = oe.type; ev->mx = oe.mx; ev->my = oe.my;
            ev->button = oe.button; ev->key = oe.key; ev->shift = oe.shift;
            ev->wheel = oe.wheel;
            if (ev->type == OS_EV_TIMER || ev->type == OS_EV_NONE) continue;   /* not an event */
            if (ev->type == OS_EV_MOTION) PROF_INC(motions);  /* input-cadence probe */
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
            gemd_log("poll -> %d — shutting down", r);
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

    /* RENDER CACHED, PRESENT UNCACHED (see gemd_present). The kernel's wallpaper region is a
     * dedicated cacheable back-buffer with no heap cost; the plane itself is only ever the
     * TARGET of a present. If the kernel has no back-buffer, draw direct as before — slower,
     * never wrong. */
    struct os_fbinfo wp;
    if (sys_fb_wallpaper(&wp) == 0 && wp.addr && wp.w == fb.w && wp.h == fb.h) {
        g_scan = fb; g_scan_on = 1;
        g_plane.w = wp.w; g_plane.h = wp.h; g_plane.stride = wp.stride;
        g_plane.px = (uint32_t *)wp.addr;
        /* the ENGINE does the present when the device exists (433 vs ~200 MB/s, and the
         * driver owns the cache-clean); a missing device or a failed submit falls back
         * to the CPU rows — qemu never has the engine, and must never need it.
         * /OS/etc/gemd-noengine = the chicken bit: don't open the engine AT ALL, so the
         * ENTIRE display path (composite + present) is CPU — the clean A/B for anything
         * suspected of being the blitter's fault (fetch-overrun hunts, FC bugs). */
        { int nofd = (int)sys_open("/OS/etc/gemd-noengine", 0);
          if (nofd >= 0) { sys_close(nofd); g_blitfd = -1;
                           gemd_log("engine DISABLED (/OS/etc/gemd-noengine) — CPU composite + present"); }
          else g_blitfd = (int)sys_open("/dev/blitter", 2); }
        gemd_log("present via %s", g_blitfd >= 0 ? "/dev/blitter" : "CPU rows");
#ifdef INSTRUMENTATION
        /* membench: memcpy 1MB along each edge of the {shm, malloc} x {backbuf} square and
         * klog it. VERDICT (board, 2026-07-15): all edges ~5.5ms/MB — attributes uniform,
         * no Device mapping; the composite's 550ns/px was the chrome's SCALED VR_OVER
         * through the generic transfer_bits loop, since specialized. Kept as the boot-time
         * canary for mapping-attribute regressions. */
        {
            enum { MB = 1024 * 1024 };
            int bid = sys_shm_create(MB, 0);
            uint32_t *shmp = bid >= 0 ? (uint32_t *)sys_shm_map(bid) : 0;
            uint32_t *heap = (uint32_t *)malloc(MB);
            uint32_t *bb   = g_plane.px;
            if (shmp && heap) {
                struct { const char *nm; void *d; const void *s; } tc[] = {
                    { "shm->bb",    bb,   shmp },
                    { "heap->bb",   bb,   heap },
                    { "shm->heap",  heap, shmp },
                    { "bb->heap",   heap, bb   },
                    { "heap->heap", heap, heap },
                };
                memset(shmp, 0x5A, MB); memset(heap, 0xA5, MB);      /* fault + warm both */
                char line[160]; int off = 0;
                off += snprintf(line + off, sizeof line - (size_t)off, "[gemd] membench 1MB:");
                for (unsigned i = 0; i < sizeof tc / sizeof tc[0]; i++) {
                    long long t0 = gem_prof_now();
                    memcpy(tc[i].d, tc[i].s, MB);
                    long long dt = gem_prof_now() - t0;
                    off += snprintf(line + off, sizeof line - (size_t)off,
                                    " %s %dus", tc[i].nm, (int)dt);
                }
                off += snprintf(line + off, sizeof line - (size_t)off, "\n");
                sys_klog(line, (unsigned)off);
            }
            if (heap) free(heap);
            if (shmp) sys_shm_unmap(bid);
        }
#endif // INSTRUMENTATION
    } else {
        g_plane.w = fb.w; g_plane.h = fb.h; g_plane.stride = fb.stride;
        g_plane.px = (uint32_t *)fb.addr;
    }

    /* gemd is the ONLY process that presents to the framebuffer (Rule 1), so it is the only one
     * that opens a workstation on the plane. The AES draws chrome through it and blits each
     * client's backing store into the work area. */
    aes_server_mode();
    wind_set_overlay(NULL, NULL, NULL, gemd_present);   /* aes_flush_rect -> the present. NULL
                                                         * begin: drags keep the classic
                                                         * redraw-per-motion path for now. */
    aes_set_plane_sync(gemd_plane_sync);                /* M6: bound HW planes follow their
                                                         * windows, re-checked per composite */
    if (g_blitfd >= 0)
        aes_set_compose_blit(gemd_compose_blit);        /* M7: opaque content blits go to the
                                                         * engine; refusals fall back to CPU.
                                                         * (The /OS/etc/gemd-noengine chicken bit
                                                         * left g_blitfd at -1 above.) */
    vdi_init(&g_plane);
    // THE FONT LIVES IN TWO PLACES, because we boot from two. The SD card stages it at
    // /OS/fonts (loader/Makefile: $(SDSTAGE)/OS/fonts), but the romfs — which is all we have
    // under qemu, where there is no SD card — mounts it at /System/fonts. Try the card, then
    // fall back, exactly as desktop.c already does (desktop.c:2359).
    //
    // Without the fallback gemd comes up on qemu with no font at all, and since chrome is
    // gemd's now (§11), that means EVERY window title on the system is blank — including the
    // titles of apps that are working perfectly.
    vdi_set_font_dir("/OS/fonts");
    font_face *face = vdi_load_system_font();
    if (!face) face = font_face_open("/System/fonts/AovelSansRounded.ttf");
    if (!face) gemd_log("system font load FAILED — titles will be blank");
    else       vdi_set_face(face);

    int vh = v_opnvwk(&g_plane);
    if (vh <= 0) { printf("gemd: v_opnvwk FAILED\n"); return 1; }

    const theme *th = gemd_theme();      /* chrome art. Read-only: §5 says both sides may load it */
    aes_init(vh, th);
    wind_set_desktop(GEMD_BG);           /* the fallback colour: the plane is never un-owned (§3) */
    aes_reserve_top(AES_MENUBAR_H);
    aes_set_menu_redraw(menu_strip_redraw);      /* §10: the band composites the FOCUS app's strip */      /* the menu STRIP's space, reserved before the menu
                                          * exists (§10 is M4b, still owed): the fuller and the
                                          * clamps must not put a window where the bar is going
                                          * to be. W_BOTTOM windows still span it — wallpaper
                                          * runs under the bar, and the bar draws over it. */

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
    if (g_ifd < 0) gemd_log("%s -> %d — NOTHING WILL BE CLICKABLE", GEMD_INPUT_DEV, g_ifd);
    aes_set_events(gemd_events);         /* and the AES's frame drags wait through it too */

    gemd_log("up — plane %dx%d stride %d, service \"%s\" fd %d, input fd %d, theme %s",
             fb.w, fb.h, fb.stride, GEM_SERVICE, g_lfd, g_ifd,
             th ? "loaded" : "MISSING (no chrome art)");

    for (;;) {
        aes_event ev;
        int t = gemd_events(&ev, -1);    /* one wait: clients, connections and input alike */
        if (t == AES_QUIT) return 1;
        gemd_route(t, &ev);              /* hit-test, chrome, focus, forward (route.c) */
        fflush(stdout);
    }
}
