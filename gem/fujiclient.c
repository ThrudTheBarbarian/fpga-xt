// fujiclient.c — tiny line client for fujinetd (see fujiclient.h).
// Protocol: send command lines, read reply lines ("+ok ..." / "-err msg",
// lists end with ".", fetch streams "+progress <done> <total>").  Each
// connection gets its own receive buffer (claimed by fuji_connect, released
// by fuji_close), so the desktop can hold several requests in flight — one
// per browser window — and pump them independently via fuji_poll_line.
//
// On the A9 (XT_TARGET) the socket surface is net_shim: recv() is sys_read,
// which returns the raw negative errno (-11 = would-block) instead of
// -1/errno, and non-blocking mode is set with sys_ioctl(XT_FIONBIO) rather
// than fcntl — no posix_shim dependency.

#include "fujiclient.h"
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#ifdef XT_TARGET
#include "usys.h"                 /* sys_ioctl + XT_FIONBIO (via xtsys.h) */
#else
#include <fcntl.h>
#include <errno.h>
#endif

#define FUJID_DEFAULT_PORT 16385
#define FUJI_MAXCH 8              /* concurrent connections (one per browser) */

typedef struct { int fd; size_t have, used; char buf[1024]; } fuji_chan;
static fuji_chan g_ch[FUJI_MAXCH];
static int g_ch_init;

static fuji_chan *chan_of(int fd) {
    if (!g_ch_init) { for (int i = 0; i < FUJI_MAXCH; i++) g_ch[i].fd = -1; g_ch_init = 1; }
    for (int i = 0; i < FUJI_MAXCH; i++) if (g_ch[i].fd == fd) return &g_ch[i];
    return NULL;
}
static fuji_chan *chan_claim(int fd) {
    fuji_chan *c = chan_of(fd);                       /* stale entry (fd reuse) */
    if (!c) c = chan_of(-1);                          /* else a free slot */
    if (!c) return NULL;
    c->fd = fd; c->have = c->used = 0;
    return c;
}
/* one buffered line into buf (NUL-terminated, newline stripped; long lines
 * are truncated but consumed whole); 1 = got one, 0 = none complete yet */
static int chan_line(fuji_chan *c, char *buf, int cap) {
    char *nl = memchr(c->buf + c->used, '\n', c->have - c->used);
    if (!nl) return 0;
    size_t n = (size_t)(nl - (c->buf + c->used));
    if (n >= (size_t)cap) n = (size_t)cap - 1;
    memcpy(buf, c->buf + c->used, n);
    buf[n] = 0;
    c->used = (size_t)(nl - c->buf) + 1;
    return 1;
}
static void chan_compact(fuji_chan *c) {
    if (c->used) { memmove(c->buf, c->buf + c->used, c->have - c->used); c->have -= c->used; c->used = 0; }
    if (c->have == sizeof c->buf) c->have = 0;        /* oversize line: drop and resync */
}

int fuji_connect(void) {
    uint16_t port = FUJID_DEFAULT_PORT;
    const char *env = getenv("FUJID_PORT");
    if (env && atoi(env) > 0) port = (uint16_t)atoi(env);
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_in sa;
    memset(&sa, 0, sizeof sa);
    sa.sin_family = AF_INET;
    sa.sin_port = htons(port);
    sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(fd, (struct sockaddr *)&sa, sizeof sa) < 0) { close(fd); return -1; }
    if (!chan_claim(fd)) { close(fd); return -1; }
    return fd;
}

int fuji_cmd(int fd, const char *fmt, ...) {
    char line[640];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(line, sizeof line - 1, fmt, ap);
    va_end(ap);
    if (n < 0 || n > (int)sizeof line - 2) return -1;
    line[n] = '\n';
    return send(fd, line, (size_t)n + 1, 0) == n + 1 ? 0 : -1;
}

// One reply line into buf, BLOCKING until it arrives (the fd must still be
// in its default blocking mode).
int fuji_readline(int fd, char *buf, int cap) {
    fuji_chan *c = chan_of(fd);
    if (!c) return -1;
    for (;;) {
        if (chan_line(c, buf, cap)) return 1;
        chan_compact(c);
        ssize_t k = recv(fd, c->buf + c->have, sizeof c->buf - c->have, 0);
        if (k == 0) return 0;
        if (k < 0) return -1;
        c->have += (size_t)k;
    }
}

// Make the fd non-blocking (for fuji_poll_line pumping).
int fuji_set_nonblock(int fd) {
#ifdef XT_TARGET
    int one = 1;
    return sys_ioctl(fd, XT_FIONBIO, &one) < 0 ? -1 : 0;
#else
    int fl = fcntl(fd, F_GETFL, 0);
    if (fl < 0) return -1;
    return fcntl(fd, F_SETFL, fl | O_NONBLOCK) < 0 ? -1 : 0;
#endif
}

// One reply line into buf WITHOUT blocking: drain whatever is available,
// then 1 = a complete line copied out, 0 = no complete line yet (would
// block), -1 = EOF / error.
int fuji_poll_line(int fd, char *buf, int cap) {
    fuji_chan *c = chan_of(fd);
    if (!c) return -1;
    for (;;) {
        if (chan_line(c, buf, cap)) return 1;
        chan_compact(c);
        ssize_t k = recv(fd, c->buf + c->have, sizeof c->buf - c->have, 0);
        if (k > 0) { c->have += (size_t)k; continue; }
        if (k == 0) return -1;                        /* EOF: reply can't complete */
#ifdef XT_TARGET
        if (k == -11) return 0;                       /* raw -EAGAIN from sys_read */
#else
        if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) return 0;
#endif
        return -1;
    }
}

void fuji_close(int fd) {
    if (fd < 0) return;
    fuji_chan *c = chan_of(fd);
    if (c) c->fd = -1;
    close(fd);
}
