/*
 * libfujinet — POSIX/BSD UDP transport for the TNFS core.
 *
 * Host-side (macOS/Linux) implementation of tnfs_transport: a connected
 * UDP socket with poll()-based receive timeout. The XTOS port replaces
 * this file with one built on the net_shim BSD socket API (which is
 * close enough that most of this compiles there unchanged).
 */

#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <unistd.h>
#include <poll.h>
#include <sys/socket.h>
#include <netdb.h>

#include <fujinet/tnfs.h>

typedef struct {
    int fd;
} udp_ctx;

static int udp_send(void *vctx, const void *buf, size_t len)
{
    udp_ctx *ctx = vctx;
    ssize_t n = send(ctx->fd, buf, len, 0);
    return (n == (ssize_t)len) ? 0 : TNFS_ERR_TRANSPORT;
}

static int udp_recv(void *vctx, void *buf, size_t cap, int timeout_ms)
{
    udp_ctx *ctx = vctx;
    struct pollfd pfd = { .fd = ctx->fd, .events = POLLIN };

    int pr = poll(&pfd, 1, timeout_ms);
    if (pr == 0)
        return TNFS_ERR_TIMEOUT;
    if (pr < 0)
        return TNFS_ERR_TRANSPORT;

    ssize_t n = recv(ctx->fd, buf, cap, 0);
    if (n < 0)
        return TNFS_ERR_TRANSPORT;
    return (int)n;
}

static void udp_close(void *vctx)
{
    udp_ctx *ctx = vctx;
    if (ctx) {
        close(ctx->fd);
        free(ctx);
    }
}

int tnfs_udp_transport(tnfs_transport *out, const char *host, uint16_t port)
{
    struct addrinfo hints, *res = NULL;
    char portstr[8];

    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_DGRAM;
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
        if (connect(fd, ai->ai_addr, ai->ai_addrlen) == 0)
            break;
        close(fd);
        fd = -1;
    }
    freeaddrinfo(res);
    if (fd < 0)
        return TNFS_ERR_TRANSPORT;

    udp_ctx *ctx = calloc(1, sizeof *ctx);
    if (!ctx) {
        close(fd);
        return TNFS_ERR_TRANSPORT;
    }
    ctx->fd = fd;

    out->send = udp_send;
    out->recv = udp_recv;
    out->close = udp_close;
    out->ctx = ctx;
    out->stream = 0;
    return 0;
}
