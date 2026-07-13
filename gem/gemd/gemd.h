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

/* A window's backing store. ORDINARY CACHED shm (§14) — deliberately NOT plv and NOT
 * XT_SHM_CONTIG: plv is uncached, and a *software* VDI writing to uncached memory is the worst
 * of both worlds. Backing stores move to plv when the VDI's blitter backend moves, and not one
 * commit before: the two are a single change, and doing it early buys nothing but slowness. */
typedef struct {
    int       id;           /* shm id. THE NAME OF THE SURFACE, everywhere (§13.1). */
    uint32_t  gen;          /* generation: stale-damage discard (§11) */
    int       cap_w, cap_h; /* CAPACITY. The stride is cap_w — NOT the extent width (§12). */
    uint32_t *px;           /* gemd's mapping */
} gsurface;

/* surface.c */
int  gemd_surf_create(gsurface *s, int w, int h, int scr_w, int scr_h);   /* 0 = ok */
void gemd_surf_drop(gsurface *s);   /* gemd drops ITS ref (§11); the client may still hold one */

/* surface.c: the chrome art. Read-only, and §5 explicitly allows both sides to load it. */
const theme *gemd_theme(void);

/* server.c */
int  gemd_run(void);

#endif /* GEMD_H */
