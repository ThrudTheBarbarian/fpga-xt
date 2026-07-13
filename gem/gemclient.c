/*
 * gemclient.c — the client half of the GEM transport.
 *
 * The split it enforces (RESPONSIBILITIES.md §5, and it is the whole design):
 *
 *   - CONTROL crosses the channel: window ops, damage rects. Tiny, and it is the only thing
 *     gemd ever hears from an app.
 *   - PIXELS never do. The app draws into its OWN backing store with its own VDI, at full
 *     speed, with ZERO IPC — then posts one damage rect saying "this rect of my surface is
 *     new". gemd is never told *why* it changed, and it never draws an app's content.
 *
 * TRANSPORT ONLY, and NOT an app-facing API: an app sees the AES (wind_create, wind_open,
 * wind_content, …), whose signatures do not change one character under gemd. gem/aes/window.c
 * calls into here; nothing else should. In M1 gemtext called this directly — that was
 * scaffolding for one client, and M2 removed it.
 */
#include <string.h>
#include "gemclient.h"
#include "usys.h"

/* How long gem_connect() will WAIT for the "gem" service to appear. Default 0: fail at
 * once, which is what makes appl_init() fall back to single-process GEM when there is no
 * gemd (§5). A program that is started ALONGSIDE gemd -- the desktop, out of 99-Desktop --
 * raises this, because the two race at boot and the loser must not lose.
 *
 * This is deliberately the CLIENT's problem and not gemd's: gemd does not spawn the
 * desktop and must never know what a desktop is (§2, §4). The boot script starts both;
 * whoever comes up second just waits. */
static int g_wait_ms;
void gem_connect_set_wait(int ms) { g_wait_ms = ms; }

int gem_connect(void)
{
    int waited = 0;
    for (;;) {
        int fd = sys_svc_connect(GEM_SERVICE);
        if (fd >= 0) return fd;                /* connected */
        if (waited >= g_wait_ms) return fd;    /* gave up: no gemd -> caller runs local */
        sys_nanosleep(50000);                  /* usec: 50 ms */
        waited += 50;
    }
}

/* A failed write means gemd is dying. It is not fatal HERE: the next read returns EOF, and EOF
 * is the one true death signal (a channel must never have SIGPIPE semantics). */
int gem_send(int fd, const gem_msg *m)
{
    return (sys_write(fd, m, (unsigned)GEM_MSG_SZ) == GEM_MSG_SZ) ? 0 : -1;
}

int gem_recv(int fd, gem_msg *m)
{
    char *p = (char *)m;
    int got = 0;
    while (got < GEM_MSG_SZ) {                 /* a channel is a byte stream: a record can split */
        long r = sys_read(fd, p + got, (unsigned)(GEM_MSG_SZ - got));
        if (r <= 0) return -1;                 /* EOF: gemd is gone. Nothing works after this. */
        got += (int)r;
    }
    return 0;
}

int gem_await(int fd, int op, gem_msg *m)
{
    for (;;) {
        if (gem_recv(fd, m) != 0) return -1;
        if (m->w[0] == op) return 0;
        if (m->w[0] == GEM_WIND_ERROR) return -1;
        /* anything else is DISCARDED — see the header: honest for M2, a queue at M4 */
    }
}

uint32_t *gem_surf_map(int surf_id)
{
    /* The surface is XT_SHM_OWNED and gemd granted it to US — against the pid the KERNEL reports
     * for this channel, not one we claimed in a message. No other client can map it. */
    return (uint32_t *)sys_shm_map(surf_id);
}

void gem_surf_unmap(int fd, int surf_id)
{
    if (surf_id < 0) return;
    sys_shm_unmap(surf_id);                    /* our ref. gemd holds its own, so a composite in
                                                * flight stays valid (§11: refcount, no handshake) */
    gem_msg m;
    memset(&m, 0, sizeof m);
    m.w[0] = GEM_SURF_DROP;
    m.u[0] = (uint32_t)surf_id;
    gem_send(fd, &m);
}

void gem_damage_rect(int fd, int wh, int surf_id, uint32_t surf_gen, int x, int y, int w, int h)
{
    gem_msg m;
    memset(&m, 0, sizeof m);
    m.w[0] = GEM_DAMAGE;
    m.w[1] = (int16_t)wh;
    m.w[2] = (int16_t)x; m.w[3] = (int16_t)y;
    m.w[4] = (int16_t)w; m.w[5] = (int16_t)h;
    m.u[0] = (uint32_t)surf_id;
    m.u[1] = surf_gen;
    m.u[2] = 0;      /* retire_seq — set in ONE place so no caller can forget it. Dead in phase 1
                      * (§14); phase 2's queued blitter makes "I posted damage" stop meaning "my
                      * pixels are in memory", and adding the field then breaks every client. */
    gem_send(fd, &m);
}
