/* sshd.c — /bin/sshd: the XTOS SSH-server front end.
 *
 * Dropbear's own server forks a child per connection to run the session; XTOS has no
 * fork. So instead of dropbear's accept+fork loop, this tiny launcher binds the listen
 * port, accepts, and SYS_spawn_fd's `dropbear -i` (inetd mode) with the connection socket
 * wired to the child's stdin/stdout/stderr — one dropbear process per connection, spawned
 * not forked. Modelled on httpd.c (bare usys, no libc/toybox).
 *
 *   sshd [port] [hostkeyfile]      (defaults: 22, /OS/etc/dropbear/ed25519_host_key)
 */
#include "usys.h"

static void wrs(int fd, const char *s) { int n = 0; while (s[n]) n++; sys_write(fd, s, (unsigned)n); }
static int  atoin(const char *s) { int v = 0; while (*s >= '0' && *s <= '9') v = v*10 + (*s++ - '0'); return v; }

void _app_entry(int argc, char **argv)
{
    int port = (argc > 1) ? atoin(argv[1]) : 22;
    if (port <= 0) port = 22;
    const char *keyfile = (argc > 2) ? argv[2] : "/OS/etc/dropbear/ed25519_host_key";
    const char *authdir = (argc > 3) ? argv[3] : 0;   /* dropbear -D: authorized_keys dir */

    int ls = (int)sys_socket(XT_SOCK_TCP);
    if (ls < 0) { wrs(2, "sshd: socket failed\n"); sys_exit(1); }
    if (sys_bind(ls, 0 /* INADDR_ANY */, (unsigned)port) != 0) {
        wrs(2, "sshd: bind failed (port busy?)\n"); sys_exit(1);
    }
    if (sys_listen(ls, 4) != 0) { wrs(2, "sshd: listen failed\n"); sys_exit(1); }
    wrs(1, "sshd: listening for ssh\n");

    for (;;) {
        unsigned peer[2];
        int cfd = (int)sys_accept(ls, peer);
        if (cfd < 0) continue;
        wrs(2, "sshd: connection -> dropbear -i\n");
        /* hand the connection to a fresh dropbear in inetd mode: the socket becomes the
         * child's fd 0 (dropbear uses one fd for both directions). fds[3]=0: inherit no
         * other parent fds. */
        char *av[8]; int ac = 0;
        av[ac++] = "dropbear"; av[ac++] = "-i"; av[ac++] = "-r"; av[ac++] = (char *)keyfile;
        if (authdir) { av[ac++] = "-D"; av[ac++] = (char *)authdir; }
        av[ac] = 0;
        int fds[4] = { cfd, cfd, cfd, 0 };
        if (sys_spawn_fd("/bin/dropbear", av, fds, 0) < 0)
            wrs(2, "sshd: spawn dropbear failed\n");
        sys_close(cfd);          /* the child owns the socket now */
    }
}
