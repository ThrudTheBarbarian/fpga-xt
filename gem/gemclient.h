/*
 * gemclient.h — the client half of the GEM transport (gemclient.c).
 *
 * This is the seam an app sits on in phase 1. In M2+ the AES (wind_create, wind_open,
 * evnt_multi) grows a client mode and calls these underneath, keeping its EXACT signatures
 * — RESPONSIBILITIES.md §5: "if an AES call ever grows a new parameter for gemd's benefit,
 * the layering has gone wrong."
 */
#ifndef GEM_CLIENT_H
#define GEM_CLIENT_H

#include "gfx.h"
#include "gemproto.h"

typedef struct {
    int         wh;             /* window handle */
    int         w, h;           /* extent */
    int         cap_w, cap_h;   /* capacity — surf.stride == cap_w (§12) */
    int         surf_id;        /* the handle. An app never needs to look at this. */
    uint32_t    surf_gen;
    gfx_surface surf;           /* the mapped backing store: open a VDI workstation on it */
} gem_window;

int  gem_connect(void);         /* -> channel fd (<0: gemd is not running) */
int  gem_wind_create(int fd, int kind, int x, int y, int w, int h, gem_window *out);
void gem_damage(int fd, const gem_window *win, int x, int y, int w, int h);  /* SURFACE coords */
void gem_wind_close(int fd, gem_window *win);

#endif /* GEM_CLIENT_H */
