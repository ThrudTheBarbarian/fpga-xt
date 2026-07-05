/* sshd.c — /bin/sshd: the XTOS SSH-server front end.
 *
 * The upstream server (Dropbear) forks a child per connection to run the session; XTOS
 * has no fork. So instead of its accept+fork loop, this tiny launcher binds the listen
 * port, accepts, and SYS_spawn_fd's `sshd-session -i` (Dropbear in inetd mode) with the
 * connection socket wired to the child's stdin/stdout/stderr — one session process per
 * connection, spawned not forked. Modelled on httpd.c (bare usys, no libc/toybox).
 *
 *   sshd [port] [hostkeyfile] [authkeysdir]
 *   defaults: 22, /OS/etc/ssh/ed25519_host_key, and authorized keys from
 *   ~/.ssh/authorized_keys (HOME=/media/home) unless authkeysdir overrides.
 */
#include "usys.h"

static void wrs(int fd, const char *s) { int n = 0; while (s[n]) n++; sys_write(fd, s, (unsigned)n); }
static int  atoin(const char *s) { int v = 0; while (*s >= '0' && *s <= '9') v = v*10 + (*s++ - '0'); return v; }

void _app_entry(int argc, char **argv)
{
    int port = (argc > 1) ? atoin(argv[1]) : 22;
    if (port <= 0) port = 22;
    const char *keyfile = (argc > 2) ? argv[2] : "/OS/etc/ssh/ed25519_host_key";
    const char *authdir = (argc > 3) ? argv[3] : 0;   /* -D: authorized_keys dir override;
                                                       * default = ~/.ssh (pw_dir) */

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
        wrs(2, "sshd: connection -> sshd-session\n");
        /* hand the connection to a fresh session process (inetd mode): the socket becomes
         * the child's fd 0 (one fd, both directions). fds[3]=0: inherit no other parent
         * fds. */
        char *av[8]; int ac = 0;
        av[ac++] = "sshd-session"; av[ac++] = "-i"; av[ac++] = "-r"; av[ac++] = (char *)keyfile;
        if (authdir) { av[ac++] = "-D"; av[ac++] = (char *)authdir; }
        av[ac] = 0;
        int fds[4] = { cfd, cfd, cfd, 0 };
        if (sys_spawn_fd("/bin/sshd-session", av, fds, 0) < 0)
            wrs(2, "sshd: spawn sshd-session failed\n");
        sys_close(cfd);          /* the child owns the socket now */
    }
}
