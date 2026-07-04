/* sockets.c — the kernel half of the PL0 socket ABI: thin wrappers over lwIP's
 * netconn API (thread-safe, designed for exactly this bridging). All callers
 * are syscall deferrals (task context), one netconn per socket fd.
 *
 * Blocking calls tick every 200 ms so a SYS_kill / ^C / ^Z lands at the usual
 * boundaries instead of hanging in a dead recv — same discipline as the pipe
 * loops. Addresses cross the ABI as be32 ip + host-order port; only IPv4.
 *
 * Receive buffers a netbuf between reads (a TCP segment rarely matches the
 * caller's read size); send copies via NETCONN_COPY so the caller's buffer is
 * free the moment we return. */
#include "lwip/api.h"
#include "lwip/dns.h"
#include "lwip/prot/ip.h"   /* IP_PROTO_ICMP */
#include "FreeRTOS.h"
#include "task.h"

/* mirrored from frtos_os.c (can't include its internals here) */
typedef int (*xt_sock_tick)(void *proc);   /* returns nonzero when the caller must abort */

typedef struct {
    struct netconn *conn;
    struct netbuf  *rb;         /* partially-consumed receive buffer */
    unsigned        rb_off;
    int             listening;
} xt_sock;

#define MAXSOCK 48         /* listeners + live connections across all procs */
static xt_sock g_socks[MAXSOCK];

static xt_sock *slot_of(int si) { return (si >= 0 && si < MAXSOCK && g_socks[si].conn) ? &g_socks[si] : 0; }

/* -> socket index (NOT an fd — frtos_os wraps it), or -1 */
/* type: 1 = TCP, 2 = UDP, 3 = RAW/ICMP (ping) */
int xt_sock_new(int type)
{
    for (int i = 0; i < MAXSOCK; i++) {
        if (g_socks[i].conn) continue;
        struct netconn *c = (type == 3)
            ? netconn_new_with_proto_and_callback(NETCONN_RAW, IP_PROTO_ICMP, 0)
            : netconn_new(type == 2 ? NETCONN_UDP : NETCONN_TCP);
        if (!c) return -1;
        netconn_set_recvtimeout(c, 200);           /* the kill/stop tick */
        g_socks[i] = (xt_sock){ c, 0, 0, 0 };
        return i;
    }
    return -1;
}

void xt_sock_close(int si)
{
    xt_sock *s = slot_of(si);
    if (!s) return;
    if (s->rb) { netbuf_delete(s->rb); s->rb = 0; }
    netconn_close(s->conn);
    netconn_delete(s->conn);
    s->conn = 0; s->listening = 0;
}

int xt_sock_connect(int si, unsigned ip_be, unsigned port)
{
    xt_sock *s = slot_of(si);
    if (!s) return -1;
    ip_addr_t a;
    ip_addr_set_ip4_u32_val(a, ip_be);
    return netconn_connect(s->conn, &a, (u16_t)port) == ERR_OK ? 0 : -1;
}

int xt_sock_bind(int si, unsigned ip_be, unsigned port)
{
    xt_sock *s = slot_of(si);
    if (!s) return -1;
    ip_addr_t a;
    ip_addr_set_ip4_u32_val(a, ip_be);
    return netconn_bind(s->conn, ip_be ? &a : IP_ANY_TYPE, (u16_t)port) == ERR_OK ? 0 : -1;
}

int xt_sock_listen(int si, int backlog)
{
    xt_sock *s = slot_of(si);
    if (!s) return -1;
    if (netconn_listen_with_backlog(s->conn, (u8_t)(backlog > 0 ? backlog : 4)) != ERR_OK) return -1;
    netconn_set_nonblocking(s->conn, 1);           /* accept polls; blocking accept naps+ticks */
    s->listening = 1;
    return 0;
}

/* accept a pending connection -> new socket index + peer addr. Blocking (ticks
 * for kill/^C/^Z); nonblock=1 returns -2 immediately when none is pending (the
 * select/poll primitive — a multi-port server round-robins non-blocking accepts). */
#define XT_SOCK_WOULDBLOCK (-2)
int xt_sock_accept(int si, unsigned *peer_ip, unsigned *peer_port,
                   xt_sock_tick tick, void *proc, int nonblock)
{
    xt_sock *s = slot_of(si);
    if (!s || !s->listening) return -1;
    struct netconn *nc = 0;
    for (;;) {
        err_t e = netconn_accept(s->conn, &nc);
        if (e == ERR_OK) break;
        if (e != ERR_TIMEOUT && e != ERR_WOULDBLOCK) return -1;
        if (nonblock) return XT_SOCK_WOULDBLOCK;   /* select primitive: none pending */
        if (tick && tick(proc)) return -1;         /* killed/stopped */
        vTaskDelay(pdMS_TO_TICKS(15));             /* the listen conn is nonblocking; nap */
    }
    for (int i = 0; i < MAXSOCK; i++) {
        if (g_socks[i].conn) continue;
        netconn_set_recvtimeout(nc, 200);
        g_socks[i] = (xt_sock){ nc, 0, 0, 0 };
        if (peer_ip || peer_port) {
            ip_addr_t a; u16_t p = 0;
            if (netconn_peer(nc, &a, &p) == ERR_OK) {
                if (peer_ip)   *peer_ip   = ip_addr_get_ip4_u32(&a);
                if (peer_port) *peer_port = p;
            }
        }
        return i;
    }
    netconn_delete(nc);
    return -1;
}

long xt_sock_send(int si, const void *buf, unsigned len)
{
    xt_sock *s = slot_of(si);
    if (!s) return -1;
    u8_t grp = NETCONNTYPE_GROUP(netconn_type(s->conn));
    if (grp == NETCONN_UDP || grp == NETCONN_RAW) {
        struct netbuf *nb = netbuf_new();
        if (!nb || !netbuf_alloc(nb, (u16_t)len)) { if (nb) netbuf_delete(nb); return -1; }
        netbuf_take(nb, buf, (u16_t)len);
        err_t e = netconn_send(s->conn, nb);       /* connected UDP / RAW ICMP -> target */
        netbuf_delete(nb);
        return e == ERR_OK ? (long)len : -1;
    }
    /* non-blocking + retry (like recv): a blocking netconn_write on a big
     * transfer waits for the window inside the netconn op, which mixed with the
     * raw-API netcon flusher contending the core lock could wedge. DONTBLOCK
     * returns ERR_WOULDBLOCK when the send buffer is full; nap and retry so the
     * tcpip thread drains ACKs meanwhile. */
    size_t total = 0;
    while (total < len) {
        size_t done = 0;
        err_t e = netconn_write_partly(s->conn, (const char *)buf + total, len - total,
                                       NETCONN_COPY | NETCONN_DONTBLOCK, &done);
        total += done;
        if (e == ERR_OK || e == ERR_WOULDBLOCK) {
            if (total >= len) break;
            if (done == 0) vTaskDelay(pdMS_TO_TICKS(5));   /* buffer full: let it drain */
            continue;
        }
        return total ? (long)total : -1;                  /* real error (reset/closed) */
    }
    return (long)total;
}

/* blocking read (ticking); 0 = orderly close / EOF */
long xt_sock_recv(int si, void *buf, unsigned len, xt_sock_tick tick, void *proc)
{
    xt_sock *s = slot_of(si);
    if (!s) return -1;
    if (!s->rb) {
        for (;;) {
            err_t e = netconn_recv(s->conn, &s->rb);
            if (e == ERR_OK) { s->rb_off = 0; break; }
            if (e == ERR_CLSD) return 0;                       /* peer closed */
            if (e != ERR_TIMEOUT) return -1;
            if (tick && tick(proc)) return -1;                 /* killed/stopped */
        }
    }
    /* copy out of the (possibly chained) netbuf from rb_off */
    unsigned total = netbuf_len(s->rb);
    unsigned want = total - s->rb_off;
    if (want > len) want = len;
    netbuf_copy_partial(s->rb, buf, (u16_t)want, (u16_t)s->rb_off);
    s->rb_off += want;
    if (s->rb_off >= total) { netbuf_delete(s->rb); s->rb = 0; s->rb_off = 0; }
    return (long)want;
}

/* datagram recv returning the source address (UDP recvfrom / RAW ICMP for ping).
 * One datagram per call (no partial caching). For a RAW socket lwIP delivers the
 * full IP packet, so we skip the IP header — the caller then sees the ICMP/UDP
 * payload at offset 0, matching Linux's SOCK_DGRAM+IPPROTO_ICMP ping sockets. */
long xt_sock_recvfrom(int si, void *buf, unsigned len,
                      unsigned *src_ip, unsigned *src_port, xt_sock_tick tick, void *proc)
{
    xt_sock *s = slot_of(si);
    if (!s) return -1;
    struct netbuf *nb = 0;
    for (;;) {
        err_t e = netconn_recv(s->conn, &nb);
        if (e == ERR_OK) break;
        if (e == ERR_CLSD) return 0;
        if (e != ERR_TIMEOUT) return -1;
        if (tick && tick(proc)) return -1;                 /* killed/stopped */
    }
    if (src_ip)   *src_ip   = ip_addr_get_ip4_u32(netbuf_fromaddr(nb));
    if (src_port) *src_port = netbuf_fromport(nb);
    unsigned skip = 0;
    if (NETCONNTYPE_GROUP(netconn_type(s->conn)) == NETCONN_RAW) {
        u8_t vhl = 0x45;
        netbuf_copy_partial(nb, &vhl, 1, 0);               /* IPv4 version+IHL */
        skip = (unsigned)(vhl & 0x0f) * 4u;
    }
    unsigned total = netbuf_len(nb);
    unsigned want = total > skip ? total - skip : 0;
    if (want > len) want = len;
    if (want) netbuf_copy_partial(nb, buf, (u16_t)want, (u16_t)skip);
    netbuf_delete(nb);
    return (long)want;
}

/* bytes readable without blocking (FIONREAD / the shim's poll) */
long xt_sock_avail(int si)
{
    xt_sock *s = slot_of(si);
    if (!s) return -1;
    unsigned n = s->rb ? (netbuf_len(s->rb) - s->rb_off) : 0;
#if LWIP_SO_RCVBUF
    if (!n) {
        int a = 0;
        SYS_ARCH_GET(((struct netconn *)s->conn)->recv_avail, a);
        if (a > 0) n = (unsigned)a;
    }
#endif
    return (long)n;
}

/* kernel DNS for the shim's getaddrinfo (blocking, lwIP resolver) */
int xt_sock_resolve(const char *name, unsigned *ip_be)
{
    ip_addr_t a;
    if (netconn_gethostbyname(name, &a) != ERR_OK) return -1;
    *ip_be = ip_addr_get_ip4_u32(&a);
    return 0;
}
