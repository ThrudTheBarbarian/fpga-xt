/*
 * dropbear_glue.c — the small libc surface the Dropbear SSH server needs beyond the
 * toybox posix/net shim. Linked into dropbear.so only. Everything here is either a thin
 * wrapper over a facility we already have (select over poll) or a single-user no-op
 * (root owns the world, no resource limits, permissions decorative). The two substantial
 * pieces — /dev/urandom entropy and the /dev/ptmx pty — are kernel devices, not symbols,
 * and live elsewhere.
 */
#include <sys/select.h>
#include <sys/resource.h>
#include <sys/time.h>
#include <poll.h>
#include <errno.h>
#include <unistd.h>
#include <string.h>
#include <sys/types.h>
#include <netdb.h>

/* select() over the shim's poll(): Dropbear's main loop multiplexes the listen/session
 * socket fds through select. Translate the fd_sets to pollfds, poll, translate back. */
int select(int nfds, fd_set *rd, fd_set *wr, fd_set *ex, struct timeval *tv)
{
    struct pollfd pfds[FD_SETSIZE];
    int map[FD_SETSIZE];
    int n = 0;
    for (int fd = 0; fd < nfds && fd < FD_SETSIZE; fd++) {
        short ev = 0;
        if (rd && FD_ISSET(fd, rd)) ev |= POLLIN;
        if (wr && FD_ISSET(fd, wr)) ev |= POLLOUT;
        if (ex && FD_ISSET(fd, ex)) ev |= POLLPRI;
        if (!ev) continue;
        pfds[n].fd = fd; pfds[n].events = ev; pfds[n].revents = 0; map[n] = fd; n++;
    }
    int timeout = -1;
    if (tv) timeout = (int)(tv->tv_sec * 1000 + tv->tv_usec / 1000);

    int r = poll(pfds, n, timeout);

    if (rd) FD_ZERO(rd);
    if (wr) FD_ZERO(wr);
    if (ex) FD_ZERO(ex);
    if (r <= 0) return r;                        /* timeout (0) or error (-1) */

    int count = 0;                               /* POSIX: total bits set across all sets */
    for (int i = 0; i < n; i++) {
        int fd = map[i];
        if (rd && (pfds[i].revents & (POLLIN | POLLHUP | POLLERR))) { FD_SET(fd, rd); count++; }
        if (wr && (pfds[i].revents & POLLOUT))                      { FD_SET(fd, wr); count++; }
        if (ex && (pfds[i].revents & POLLPRI))                      { FD_SET(fd, ex); count++; }
    }
    return count;
}

/* ---- single-user no-ops (XTOS is root; ownership/limits/priv-drop are decorative) ---- */
int chown(const char *path, uid_t o, gid_t g)   { (void)path; (void)o; (void)g; return 0; }
int setegid(gid_t g)                            { (void)g; return 0; }
int seteuid(uid_t u)                            { (void)u; return 0; }
int utimes(const char *p, const struct timeval t[2]) { (void)p; (void)t; return 0; }

int getrlimit(int res, struct rlimit *rl)
{
    (void)res;
    if (rl) { rl->rlim_cur = rl->rlim_max = RLIM_INFINITY; }
    return 0;
}
int setrlimit(int res, const struct rlimit *rl) { (void)res; (void)rl; return 0; }

/* no reverse DNS / service db — Dropbear only uses these for log niceties */
struct hostent *gethostbyaddr(const void *addr, socklen_t len, int type)
{ (void)addr; (void)len; (void)type; h_errno = HOST_NOT_FOUND; return 0; }
struct servent *getservbyname(const char *name, const char *proto)
{ (void)name; (void)proto; return 0; }
