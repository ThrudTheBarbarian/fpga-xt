/* sshd.c — /bin/sshd: the XTOS SSH-server front end.
 *
 * The upstream server (Dropbear) forks a child per connection to run the session; XTOS
 * has no fork. So instead of its accept+fork loop, this tiny launcher binds the listen
 * port, accepts, and SYS_spawn_fd's `sshd-session -i` (Dropbear in inetd mode) with the
 * connection socket wired to the child's stdin/stdout/stderr — one session process per
 * connection, spawned not forked. Modelled on httpd.c (bare usys, no libc/toybox).
 *
 *   sshd [port] [hostkeyfile] [authkeysdir] [logfile]
 *   defaults: 22, /OS/etc/ssh/ed25519_host_key, authorized keys from
 *   ~/.ssh/authorized_keys (HOME=/media/home) unless authkeysdir overrides, and
 *   no logfile (messages go to the console).
 *
 * Logging (/boot/22-SecureShell passes /var/log/sshd.log): the file is truncated
 * at startup — one fresh log per boot. Every write APPENDS via its own
 * open(O_APPEND) fd: the launcher's own lines open-write-close, and each
 * session child gets a fresh append fd as its stderr (spawn MOVES file fds, so
 * per-child fds are exactly right). Sessions log sequentially; two sessions
 * ending at the same instant may interleave imperfectly — fine for a log.
 */
#include "usys.h"

#define O_WRONLY 0x0001
#define O_APPEND 0x0008
#define O_CREAT  0x0200
#define O_TRUNC  0x0400

static const char *g_log;   /* logfile path or 0 = console */

static void wrs(int fd, const char *s) { int n = 0; while (s[n]) n++; sys_write(fd, s, (unsigned)n); }
static int  atoin(const char *s) { int v = 0; while (*s >= '0' && *s <= '9') v = v*10 + (*s++ - '0'); return v; }

/* one launcher log line: append to the logfile if configured, else console stderr */
static void logline(const char *s)
{
    if (g_log) {
        int fd = (int)sys_open(g_log, O_WRONLY | O_APPEND);
        if (fd >= 0) { wrs(fd, s); sys_close(fd); return; }
    }
    wrs(2, s);
}

void _app_entry(int argc, char **argv)
{
    int port = (argc > 1) ? atoin(argv[1]) : 22;
    if (port <= 0) port = 22;
    const char *keyfile = (argc > 2) ? argv[2] : "/OS/etc/ssh/ed25519_host_key";
    const char *authdir = (argc > 3) ? argv[3] : 0;   /* -D: authorized_keys dir override;
                                                       * default = ~/.ssh (pw_dir) */
    if (authdir && (!authdir[0] || (authdir[0] == '-' && !authdir[1])))
        authdir = 0;                                  /* "" or "-" = use the default */
    g_log = (argc > 4) ? argv[4] : 0;

    if (g_log) {                        /* new log every boot: truncate, stamp a header */
        int fd = (int)sys_open(g_log, O_WRONLY | O_CREAT | O_TRUNC);
        if (fd < 0) { wrs(2, "sshd: cannot open logfile, logging to console\n"); g_log = 0; }
        else { wrs(fd, "==== sshd: boot ====\n"); sys_close(fd); }
    }

    int ls = (int)sys_socket(XT_SOCK_TCP);
    if (ls < 0) { wrs(2, "sshd: socket failed\n"); sys_exit(1); }
    if (sys_bind(ls, 0 /* INADDR_ANY */, (unsigned)port) != 0) {
        wrs(2, "sshd: bind failed (port busy?)\n"); sys_exit(1);
    }
    if (sys_listen(ls, 4) != 0) { wrs(2, "sshd: listen failed\n"); sys_exit(1); }
    wrs(1, "sshd: listening for ssh\n");
    logline("sshd: listening for ssh\n");

    for (;;) {
        unsigned peer[2];
        int cfd = (int)sys_accept(ls, peer);
        if (cfd < 0) continue;
        logline("sshd: connection -> sshd-session\n");
        /* hand the connection to a fresh session process (inetd mode): the socket becomes
         * the child's fd 0 (one fd, both directions); a fresh append fd on the logfile
         * becomes its stderr (MOVED into the child — dropbear logs land in the file).
         * fds[3]=0: inherit no other parent fds. */
        char *av[8]; int ac = 0;
        av[ac++] = "sshd-session"; av[ac++] = "-i"; av[ac++] = "-r"; av[ac++] = (char *)keyfile;
        if (authdir) { av[ac++] = "-D"; av[ac++] = (char *)authdir; }
        av[ac] = 0;
        int lfd = g_log ? (int)sys_open(g_log, O_WRONLY | O_APPEND) : -1;
        int fds[4] = { cfd, -1, lfd, 0 };
        if (sys_spawn_fd("/bin/sshd-session", av, fds, 0) < 0) {
            logline("sshd: spawn sshd-session failed\n");
            if (lfd >= 0) sys_close(lfd);
        }
        sys_close(cfd);          /* the child owns the socket now */
    }
}
