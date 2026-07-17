/*
 * gemd.h — gemd's internal shape. Nothing outside gem/gemd/ includes this: a client sees the
 * wire (gemproto.h) and its own AES, and nothing else.
 *
 * gemd is THE WINDOW SERVER (RESPONSIBILITIES.md §3): one process, the only one that presents
 * to the framebuffer, and the one that must NEVER BLOCK — it will hold the grab. Everything
 * here is built around that: one poll loop over the listen fd and every client channel, no
 * thread per client, no read that can stall on a silent peer.
 *
 * Note what is NOT here any more (M2): a window list. gemd does not keep one beside the AES's —
 * gemd IS the process where the AES's list runs, in server mode. Chrome, z-order and
 * compositing are `gem/aes/window.c`, unchanged, and a client's wind_create is a message that
 * lands on the very function it used to call directly.
 */
#ifndef GEMD_H
#define GEMD_H

#include <stdint.h>
#include "gfx.h"
#include "theme.h"
#include "gemproto.h"
#include "gemclient.h"      /* the codec is shared: gemd speaks the same wire it hands clients */
#include "aes/aes.h"
#include "vdi/vdi.h"

#define GEMD_MAXCL   24     /* clients. NFD = 32 per process is the real ceiling above this. */
#define GEMD_MAXW    64     /* == MAXW in aes/window.c: the window list is SYSTEM-WIDE now */

#define GEMD_INPUT_DEV "/OS/dev/input"   /* input as an FD, so it joins the one poll (M4). A
                                          * blocking SYS_input could not: gemd would have to
                                          * choose between waiting on input and waiting on its
                                          * clients, and a window server may never block (§3). */

/* A window's backing store. ORDINARY CACHED shm (§14) — deliberately NOT plv and NOT
 * XT_SHM_CONTIG: plv is uncached, and a *software* VDI writing to uncached memory is the worst
 * of both worlds. Backing stores move to plv when the VDI's blitter backend moves, and not one
 * commit before: the two are a single change, and doing it early buys nothing but slowness. */
typedef struct {
    int       id;           /* shm id. THE NAME OF THE SURFACE, everywhere (§13.1). */
    uint32_t  gen;          /* generation: stale-damage discard (§11) */
    int       cap_w, cap_h; /* CAPACITY. The stride is cap_w — NOT the extent width (§12). */
    uint32_t *px;           /* gemd's mapping */
    int       contig;       /* XT_SHM_CONTIG (plv): engine-compositable. 0 = pooled
                             * fallback (plv budget ran out) — CPU composite only. */
} gsurface;

/* surface.c */
int  gemd_surf_create(gsurface *s, int w, int h, int scr_w, int scr_h);   /* 0 = ok */
void gemd_surf_drop(gsurface *s);   /* gemd drops ITS ref (§11); the client may still hold one */

/* surface.c: the chrome art. Read-only, and §5 explicitly allows both sides to load it. */
const theme *gemd_theme(void);

/* server.c */
int  gemd_run(void);
void gemd_log(const char *fmt, ...);           /* "[gemd] ..." to the kernel log (dmesg) — no
                                                * trailing newline; console printf is blocking
                                                * serial time and is reserved for fatal launch */
void gemd_send_to(int ci, const gem_msg *m);   /* advisory: a dying client must never kill gemd */
int  gemd_resize_surface(int hd);              /* §12 capacity: grow the extent, or make a new
                                                * surface when capacity is exceeded. 0 = ok. */

/* route.c — input. gemd owns the pointer; a client is told only what it is entitled to. */
void gemd_route(int type, const aes_event *ev);
void gemd_flush_msgs(void);                    /* AES messages (WM_*) -> the owning client */
void gemd_forget_window(int hd);               /* it closed / its client died: drop any focus */

#endif /* GEMD_H */
