/*
 * libfujinet — POSIX/BSD TCP transport for the TNFS core.
 *
 * For TCP-only servers (the spec makes UDP mandatory, TCP optional, but
 * several public servers are reachable only over TCP). The transport
 * delivers raw stream bytes; message reassembly is done by the core
 * (transport.stream = 1). Connect is non-blocking with a 4 s deadline
 * so unreachable hosts fail fast.
 */

#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <netdb.h>

#include <fujinet/tnfs.h>

#define TCP_CONNECT_TIMEOUT_MS 4000

typedef struct {
    int fd;
} tcp_ctx;

static int tcp_send(void *vctx, const void *buf, size_t len)
{
    tcp_ctx *ctx = vctx;
    const uint8_t *p = buf;
    while (len > 0) {
        ssize_t n = send(ctx->fd, p, len, 0);
        if (n <= 0)
            return TNFS_ERR_TRANSPORT;
        p += n;
        len -= (size_t)n;
    }
    return 0;
}

static int tcp_recv(void *vctx, void *buf, size_t cap, int timeout_ms)
{
    tcp_ctx *ctx = vctx;
    struct pollfd pfd = { .fd = ctx->fd, .events = POLLIN };

    int pr = poll(&pfd, 1, timeout_ms);
    if (pr == 0)
        return TNFS_ERR_TIMEOUT;
    if (pr < 0)
        return TNFS_ERR_TRANSPORT;

    ssize_t n = recv(ctx->fd, buf, cap, 0);
    if (n <= 0)
        return TNFS_ERR_TRANSPORT;      /* 0 = peer closed */
    return (int)n;
}

static void tcp_close(void *vctx)
{
    tcp_ctx *ctx = vctx;
    if (ctx) {
        close(ctx->fd);
        free(ctx);
    }
}

static int connect_deadline(int fd, const struct sockaddr *sa, socklen_t salen)
{
    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);

    int rc = connect(fd, sa, salen);
    if (rc < 0) {
        if (errno == EINPROGRESS) {
            struct pollfd pfd = { .fd = fd, .events = POLLOUT };
            if (poll(&pfd, 1, TCP_CONNECT_TIMEOUT_MS) <= 0)
                return -1;
            int err = 0;
            socklen_t elen = sizeof err;
            if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &elen) < 0 || err)
                return -1;
        } else {
            return -1;
        }
    }
    fcntl(fd, F_SETFL, flags);
    return 0;
}

int tnfs_tcp_transport(tnfs_transport *out, const char *host, uint16_t port)
{
    struct addrinfo hints, *res = NULL;
    char portstr[8];

    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    snprintf(portstr, sizeof portstr, "%u", port ? port : TNFS_PORT);

    int gai = getaddrinfo(host, portstr, &hints, &res);
    if (gai != 0 || !res)
        return TNFS_ERR_TRANSPORT;

    int fd = -1;
    struct addrinfo *ai;
    for (ai = res; ai; ai = ai->ai_next) {
        fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (fd < 0)
            continue;
        if (connect_deadline(fd, ai->ai_addr, ai->ai_addrlen) == 0)
            break;
        close(fd);
        fd = -1;
    }
    freeaddrinfo(res);
    if (fd < 0)
        return TNFS_ERR_TRANSPORT;

    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);

    tcp_ctx *ctx = calloc(1, sizeof *ctx);
    if (!ctx) {
        close(fd);
        return TNFS_ERR_TRANSPORT;
    }
    ctx->fd = fd;

    out->send = tcp_send;
    out->recv = tcp_recv;
    out->close = tcp_close;
    out->ctx = ctx;
    out->stream = 1;
    return 0;
}
