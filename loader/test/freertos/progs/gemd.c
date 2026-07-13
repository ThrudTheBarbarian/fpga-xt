/*
 * /bin/gemd — THE WINDOW SERVER. One process; the only one that presents to the
 * framebuffer (Rocks/doc/RESPONSIBILITIES.md §3).
 *
 * Deliberately thin: everything is in libGEM.so's server half (gem/gemd/), because that is
 * the same library an app links for its client half — one library, two modes (§5). In M2+
 * this becomes aes_init() + gemd_run(); today the AES has no server mode yet, so it is just
 * the loop.
 *
 * Run it, then run a client from anywhere — an ssh session, a boot script, another app. The
 * two are strangers: they rendezvous through the "gem" service (SYS_svc_register /
 * SYS_svc_connect), which is exactly the primitive XTOS did not have, and without which a
 * window server and its clients literally could not reach each other.
 */
#include "gemd/gemd.h"
#include "usys.h"

void _app_entry(int argc, char **argv)
{
    (void)argc; (void)argv;
    sys_exit(gemd_run());
}
