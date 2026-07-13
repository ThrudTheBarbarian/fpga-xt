/*
 * gemd.h — gemd's internal shape. Nothing outside gem/gemd/ includes this: a client sees
 * the wire (gemproto.h) and nothing else.
 *
 * gemd is THE WINDOW SERVER (RESPONSIBILITIES.md §3): one process, the only one that
 * presents to the framebuffer, and the one that must NEVER BLOCK — it will hold the grab.
 * Everything here is built around that: one poll loop over the listen fd and every client
 * channel, no thread per client, no read that can stall on a silent peer.
 */
#ifndef GEMD_H
#define GEMD_H

#include <stdint.h>
#include "gfx.h"
#include "gemproto.h"

#define GEMD_MAXW    32       /* windows, SYSTEM-wide (it is the server's list now, not an app's) */
#define GEMD_MAXCL   24       /* clients; NFD=32 per process is the real ceiling above this */

/* A window. gemd owns this — the client knows its handle and its own pixels, nothing else
 * (§5: "a client does not know where its window is on screen, what is above it, or whether
 * it is visible at all"). */
typedef struct {
    int       used;
    int       wh;             /* window handle (1-based; 0 = the menu strip, §10) */
    int       kind;           /* GEM_W_* mask */
    int       x, y;           /* on-screen position of the window's top-left */
    int       w, h;           /* EXTENT — what the window currently is */
    int       cap_w, cap_h;   /* CAPACITY — what is allocated. STRIDE == cap_w (§12). */
    int       surf_id;        /* shm id. The name of the surface, everywhere. */
    uint32_t  surf_gen;       /* stale-damage discard (§11) */
    uint32_t *px;             /* gemd's mapping of it */
    int       client;         /* owning client slot */
} gwin;

/* ---- surface.c ---- */
int  gemd_surf_create(gwin *win, int w, int h, int scr_w, int scr_h);  /* 0 = ok */
void gemd_surf_drop(gwin *win);      /* gemd drops ITS ref (§11); the client may still hold one */

/* ---- composite.c ----
 * The inner blit goes through a BACKEND (§14). Phase 1's is the CPU; phase 2's is
 * /dev/blitter, and it must be a backend swap, not a rewrite of the compositor. */
typedef struct {
    const char *name;
    void (*fill_rect)(const gfx_surface *dst, int x, int y, int w, int h, uint32_t rgba);
    void (*blit_rect)(const gfx_surface *dst, int dx, int dy,
                      const gfx_surface *src, int sx, int sy, int w, int h);
    void (*present)(void);
} gemd_backend;

extern const gemd_backend gemd_backend_cpu;     /* phase 1. Phase 2: gemd_backend_blitter. */

void gemd_comp_init(const gfx_surface *plane, uint32_t bg, const gemd_backend *be);
/* Recomposite one SCREEN rect from the backing stores, in z-order, and present it. This is
 * the ONLY thing that puts a pixel on the display, and it needs nothing from any client —
 * which is the whole point of the per-window backing store (§3). */
void gemd_comp_rect(int x, int y, int w, int h, gwin **z, int nz);

/* ---- server.c ---- */
int  gemd_run(void);
#endif /* GEMD_H */
