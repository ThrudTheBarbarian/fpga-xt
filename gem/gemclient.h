/*
 * gemclient.h — the client half of the GEM transport (gemclient.c).
 *
 * TRANSPORT ONLY: a message in, a message out. It is deliberately dumb, and it is NOT the API
 * an app sees. An app sees the AES — `wind_create`, `wind_open`, `wind_content`, … — whose
 * signatures do not change one character between single-process GEM and gemd (§5):
 *
 *   "if an AES call ever grows a new parameter for gemd's benefit, the layering has gone wrong"
 *
 * The AES's client mode (gem/aes/window.c) calls into here. Nothing else should. In M1 an app
 * (gemtext) DID call this directly — that was scaffolding, and M2 removed it.
 */
#ifndef GEM_CLIENT_H
#define GEM_CLIENT_H

#include "gfx.h"
#include "gemproto.h"

int  gem_connect(void);                       /* -> channel fd (<0: gemd is not running) */
int  gem_send(int fd, const gem_msg *m);      /* 0 = ok. A failed write is NEVER fatal */
int  gem_recv(int fd, gem_msg *m);            /* 0 = ok, -1 = EOF: gemd is gone */

/* Block until a message of type `op` arrives. Anything else that arrives first is DISCARDED.
 * That is honest for M2 — the only unsolicited message is MSG_REDRAW and every request is
 * answered immediately — but it is a real limitation, not an oversight: when evnt_multi becomes
 * the pump (M4) this has to become a queue. */
int  gem_await(int fd, int op, gem_msg *m);

/* Map/unmap a surface gemd granted us by id (§11: the client holds one ref and gemd the other;
 * either may drop it while both are alive). */
uint32_t *gem_surf_map(int surf_id);
void      gem_surf_unmap(int fd, int surf_id);   /* drop our ref + tell gemd (SURF_DROP) */

/* DAMAGE, in SURFACE coordinates. retire_seq is set to 0 HERE, in one place, so that no caller
 * can forget it (§14: dead in phase 1, and a protocol break if it is ever missing). */
void gem_damage_rect(int fd, int wh, int surf_id, uint32_t surf_gen, int x, int y, int w, int h);

#endif /* GEM_CLIENT_H */
