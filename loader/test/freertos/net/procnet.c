/* procnet.c — /OS/proc/net/* generators for netstat/ifconfig. Walks lwIP's
 * own PCB lists (tcp_active/listen/tw/bound, udp_pcbs) under the tcpip core
 * lock and formats them in the Linux /proc/net layout the toybox parsers
 * expect. Called from vfs_procfs.c (fs-task context) via xt_procnet().
 *
 * Address hex is the network-order 32-bit value as a little-endian int —
 * exactly what /proc/net uses, so the value round-trips through the parser's
 * inet_ntop() unchanged (no byte-swap here). Ports print in host order. */
#include "lwip/opt.h"
#include "lwip/stats.h"
#include "lwip/memp.h"
#include "lwip/tcpip.h"
#include "lwip/tcp.h"
#include "lwip/udp.h"
#include "lwip/priv/tcp_priv.h"
#include <stdint.h>
#include <string.h>

/* interface snapshot shared with net.c + the ifconfig ioctl path */
#include "netinfo.h"

/* ---- tiny append formatter (kernel is -nostdlib) -------------------------- */
typedef struct { char *b; int n, cap; } nb;
static void nb_s(nb *o, const char *s) { while (*s && o->n < o->cap - 1) o->b[o->n++] = *s++; o->b[o->n] = 0; }
static void nb_c(nb *o, char c) { if (o->n < o->cap - 1) { o->b[o->n++] = c; o->b[o->n] = 0; } }
static void nb_d(nb *o, unsigned v)
{ char t[12]; int k = 0; do { t[k++] = (char)('0' + v % 10); v /= 10; } while (v); while (k) nb_c(o, t[--k]); }
static void nb_x(nb *o, uint32_t v, int width)   /* zero-padded uppercase hex */
{
    char t[8]; int k = 0;
    do { int d = v & 0xf; t[k++] = (char)(d < 10 ? '0' + d : 'A' + d - 10); v >>= 4; } while (v);
    while (k < width) t[k++] = '0';
    while (k) nb_c(o, t[--k]);
}

/* lwIP tcp_state (0..10) -> Linux /proc/net/tcp state number */
static const unsigned char lin_state[] = {
    /* CLOSED     */ 7,  /* LISTEN      */ 10, /* SYN_SENT   */ 2, /* SYN_RCVD  */ 3,
    /* ESTABLISHED*/ 1,  /* FIN_WAIT_1  */ 4,  /* FIN_WAIT_2 */ 5, /* CLOSE_WAIT*/ 8,
    /* CLOSING    */ 11, /* LAST_ACK    */ 9,  /* TIME_WAIT  */ 6,
};

static const char *TCP_HDR =
    "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n";

static void row(nb *o, int sl, uint32_t la, unsigned lp, uint32_t ra, unsigned rp,
                unsigned st, unsigned inode)
{
    /* "  <sl>: LADDR:LPORT RADDR:RPORT ST TX:RX TR:WHEN RETR UID TMO INODE" */
    nb_c(o, ' '); nb_c(o, ' '); nb_d(o, sl); nb_s(o, ": ");
    nb_x(o, la, 8); nb_c(o, ':'); nb_x(o, lp, 4); nb_c(o, ' ');
    nb_x(o, ra, 8); nb_c(o, ':'); nb_x(o, rp, 4); nb_c(o, ' ');
    nb_x(o, st, 2);
    nb_s(o, " 00000000:00000000 00:00000000 00000000     0        0 ");
    nb_d(o, inode);
    nb_s(o, " 1 0 0 0 0\n");
}

static uint32_t ip_u32(const ip_addr_t *a) { return ip4_addr_get_u32(ip_2_ip4(a)); }

static int gen_tcp(char *buf, int cap)
{
    nb o = { buf, 0, cap };
    nb_s(&o, TCP_HDR);
    int sl = 0;
    LOCK_TCPIP_CORE();
    for (struct tcp_pcb *p = tcp_active_pcbs; p; p = p->next, sl++) {
        unsigned st = (p->state <= TIME_WAIT) ? lin_state[p->state] : 0;
        row(&o, sl, ip_u32(&p->local_ip), p->local_port, ip_u32(&p->remote_ip), p->remote_port,
            st, 10000u + (unsigned)sl);
    }
    for (struct tcp_pcb *p = tcp_tw_pcbs; p; p = p->next, sl++)
        row(&o, sl, ip_u32(&p->local_ip), p->local_port, ip_u32(&p->remote_ip), p->remote_port,
            6, 10000u + (unsigned)sl);
    for (struct tcp_pcb_listen *p = tcp_listen_pcbs.listen_pcbs; p; p = p->next, sl++)
        row(&o, sl, ip_u32(&p->local_ip), p->local_port, 0, 0, 10, 10000u + (unsigned)sl);
    UNLOCK_TCPIP_CORE();
    return o.n;
}

static int gen_udp(char *buf, int cap)
{
    nb o = { buf, 0, cap };
    nb_s(&o, TCP_HDR);
    int sl = 0;
    LOCK_TCPIP_CORE();
    for (struct udp_pcb *p = udp_pcbs; p; p = p->next, sl++)
        row(&o, sl, ip_u32(&p->local_ip), p->local_port, ip_u32(&p->remote_ip), p->remote_port,
            p->remote_port ? 1 : 7, 20000u + (unsigned)sl);
    UNLOCK_TCPIP_CORE();
    return o.n;
}

static int gen_route(char *buf, int cap)
{
    struct xt_ifinfo ni;
    nb o = { buf, 0, cap };
    nb_s(&o, "Iface\tDestination\tGateway \tFlags\tRefCnt\tUse\tMetric\tMask\t\tMTU\tWindow\tIRTT\n");
    if (xt_netif_info(&ni) && ni.ip) {
        /* on-link subnet route: dest = ip & mask, gw = 0, flag U(0x0001) */
        nb_s(&o, ni.name); nb_c(&o, '\t');
        nb_x(&o, ni.ip & ni.netmask, 8); nb_s(&o, "\t00000000\t0001\t0\t0\t0\t");
        nb_x(&o, ni.netmask, 8); nb_s(&o, "\t0\t0\t0\n");
        if (ni.gw) {                     /* default route: dest 0, gw set, flag UG(0x0003) */
            nb_s(&o, ni.name); nb_s(&o, "\t00000000\t");
            nb_x(&o, ni.gw, 8); nb_s(&o, "\t0003\t0\t0\t0\t00000000\t0\t0\t0\n");
        }
    }
    return o.n;
}

static int gen_dev(char *buf, int cap)
{
    struct xt_ifinfo ni;
    nb o = { buf, 0, cap };
    nb_s(&o, "Inter-|   Receive                                                |  Transmit\n"
             " face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed\n");
    if (xt_netif_info(&ni)) {
        /* no per-packet counters are kept — emit the interface with zeros */
        nb_c(&o, ' '); nb_c(&o, ' '); nb_s(&o, ni.name);
        nb_s(&o, ": 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0\n");
    }
    return o.n;
}

/* per-protocol lwIP counters (LWIP_STATS) — cat before/after traffic to see
 * what moves: e.g. icmp.recv/chkerr on a ping, ip.drop, link.recv. */
static void stat_row(nb *o, const char *name, const struct stats_proto *s)
{
    nb_s(o, name);
    nb_s(o, ":\txmit="); nb_d(o, (unsigned)s->xmit);
    nb_s(o, " recv=");  nb_d(o, (unsigned)s->recv);
    nb_s(o, " drop=");  nb_d(o, (unsigned)s->drop);
    nb_s(o, " chkerr=");nb_d(o, (unsigned)s->chkerr);
    nb_s(o, " lenerr=");nb_d(o, (unsigned)s->lenerr);
    nb_s(o, " memerr=");nb_d(o, (unsigned)s->memerr);
    nb_s(o, " rterr="); nb_d(o, (unsigned)s->rterr);
    nb_s(o, " proterr=");nb_d(o, (unsigned)s->proterr);
    nb_s(o, " err=");   nb_d(o, (unsigned)s->err);
    nb_c(o, '\n');
}

static int gen_stats(char *buf, int cap)
{
    nb o = { buf, 0, cap };
    stat_row(&o, "link",   &lwip_stats.link);
    stat_row(&o, "etharp", &lwip_stats.etharp);
    stat_row(&o, "ip",     &lwip_stats.ip);
    stat_row(&o, "icmp",   &lwip_stats.icmp);
    stat_row(&o, "udp",    &lwip_stats.udp);
    stat_row(&o, "tcp",    &lwip_stats.tcp);
    /* heap + pool exhaustion — recv_raw drops a reply silently if it can't get a
     * NETBUF or a PBUF_RAM clone, so a climbing err here == lost ping replies */
    nb_s(&o, "heap:\tused=");   nb_d(&o, (unsigned)lwip_stats.mem.used);
    nb_s(&o, " max=");          nb_d(&o, (unsigned)lwip_stats.mem.max);
    nb_s(&o, " avail=");        nb_d(&o, (unsigned)lwip_stats.mem.avail);
    nb_s(&o, " err=");          nb_d(&o, (unsigned)lwip_stats.mem.err);
    nb_c(&o, '\n');
    { struct stats_mem *nbf = lwip_stats.memp[MEMP_NETBUF];
      struct stats_mem *ppl = lwip_stats.memp[MEMP_PBUF_POOL];
      nb_s(&o, "netbuf:\tused="); nb_d(&o, (unsigned)nbf->used);
      nb_s(&o, " max=");          nb_d(&o, (unsigned)nbf->max);
      nb_s(&o, " err=");          nb_d(&o, (unsigned)nbf->err);
      nb_s(&o, "\npbufpool: used="); nb_d(&o, (unsigned)ppl->used);
      nb_s(&o, " max=");          nb_d(&o, (unsigned)ppl->max);
      nb_s(&o, " err=");          nb_d(&o, (unsigned)ppl->err);
      nb_c(&o, '\n');
    }
    /* raw_input delivery probe (lwIP raw.c) */
    extern unsigned xt_raw_dbg[6];
    nb_s(&o, "rawin:\ticmp_pkts="); nb_d(&o, xt_raw_dbg[0]);
    nb_s(&o, " icmp_pcbs=");        nb_d(&o, xt_raw_dbg[1]);
    nb_s(&o, " matched=");          nb_d(&o, xt_raw_dbg[2]);
    nb_s(&o, " totpcbs=");          nb_d(&o, xt_raw_dbg[3]);
    nb_s(&o, " rawnew=");           nb_d(&o, xt_raw_dbg[4]);
    nb_s(&o, " newgrp=");           nb_d(&o, xt_raw_dbg[5]);
    nb_c(&o, '\n');
    /* socket receive-path probe (see sockets.c) */
    extern unsigned xt_sock_rxdbg[5];
    nb_s(&o, "sockrx:\tavail=");   nb_d(&o, xt_sock_rxdbg[0]);
    nb_s(&o, " avail_hit=");       nb_d(&o, xt_sock_rxdbg[1]);
    nb_s(&o, " recvfrom=");        nb_d(&o, xt_sock_rxdbg[2]);
    nb_s(&o, " got=");             nb_d(&o, xt_sock_rxdbg[3]);
    nb_s(&o, " timeouts=");        nb_d(&o, xt_sock_rxdbg[4]);
    nb_c(&o, '\n');
    return o.n;
}

int xt_procnet(const char *leaf, char *buf, int cap)
{
    if (!strcmp(leaf, "stats")) return gen_stats(buf, cap);
    if (!strcmp(leaf, "tcp"))   return gen_tcp(buf, cap);
    if (!strcmp(leaf, "udp"))   return gen_udp(buf, cap);
    if (!strcmp(leaf, "route")) return gen_route(buf, cap);
    if (!strcmp(leaf, "dev"))   return gen_dev(buf, cap);
    if (!strcmp(leaf, "raw")) { nb o = { buf, 0, cap }; nb_s(&o, TCP_HDR); return o.n; }
    if (!strcmp(leaf, "unix")) {
        nb o = { buf, 0, cap };
        nb_s(&o, "Num       RefCount Protocol Flags    Type St Inode Path\n");
        return o.n;
    }
    return -1;
}

/* the leaves that exist under /OS/proc/net (for readdir + stat) */
const char *const xt_procnet_leaves[] = { "tcp", "udp", "raw", "route", "dev", "unix", "stats", 0 };

/* ---- SIOCGIF* ioctls on a socket fd (read-only ifconfig) ------------------
 * Fills the caller's struct ifreq/ifconf (Linux 32-bit layout: a 16-byte name
 * then a 16-byte union). PL0 shares the address space, so the arg pointer is
 * dereferenced directly. Only the getters ifconfig's display path needs are
 * handled; setters and unknown requests return -1. */
struct k_sockaddr { uint16_t family; uint8_t data[14]; };
struct k_ifreq { char name[16]; union { struct k_sockaddr sa; int16_t flags; int32_t ival; uint8_t raw[16]; } u; };
struct k_ifconf { int32_t len; struct k_ifreq *buf; };

#define K_SIOCGIFCONF    0x8912
#define K_SIOCGIFFLAGS   0x8913
#define K_SIOCGIFADDR    0x8915
#define K_SIOCGIFDSTADDR 0x8917
#define K_SIOCGIFBRDADDR 0x8919
#define K_SIOCGIFNETMASK 0x891b
#define K_SIOCGIFMETRIC  0x891d
#define K_SIOCGIFMTU     0x8921
#define K_SIOCGIFHWADDR  0x8927
#define K_SIOCGIFINDEX   0x8933
#define K_SIOCGIFTXQLEN  0x8942
#define K_SIOCGIFMAP     0x8970
#define K_ARPHRD_ETHER   1
#define K_AF_INET        2

static void set_sin(struct k_ifreq *r, uint32_t ip)   /* sockaddr_in into the union */
{
    memset(&r->u, 0, sizeof r->u);
    *(uint16_t *)&r->u.raw[0] = K_AF_INET;             /* sin_family */
    *(uint32_t *)&r->u.raw[4] = ip;                    /* sin_addr (already net-order-as-LE-int) */
}

int xt_ifreq_ioctl(unsigned req, void *arg)
{
    struct xt_ifinfo ni;
    if (!arg) return -1;

    if (req == K_SIOCGIFCONF) {                        /* enumerate interfaces */
        struct k_ifconf *c = (struct k_ifconf *)arg;
        int cap = c->len / (int)sizeof(struct k_ifreq), n = 0;
        if (cap >= 1 && c->buf && xt_netif_info(&ni)) {
            memset(&c->buf[0], 0, sizeof c->buf[0]);
            memcpy(c->buf[0].name, ni.name, sizeof ni.name);   /* null-padded "e0" */
            set_sin(&c->buf[0], ni.ip);
            n = 1;
        }
        c->len = n * (int)sizeof(struct k_ifreq);
        return 0;
    }

    if (!xt_netif_info(&ni)) return -1;
    struct k_ifreq *r = (struct k_ifreq *)arg;         /* name pre-filled by the caller */
    switch (req) {
    case K_SIOCGIFFLAGS:   r->u.flags = (int16_t)ni.flags; return 0;
    case K_SIOCGIFADDR:    set_sin(r, ni.ip);              return 0;
    case K_SIOCGIFNETMASK: set_sin(r, ni.netmask);         return 0;
    case K_SIOCGIFBRDADDR: set_sin(r, ni.ip | ~ni.netmask); return 0;
    case K_SIOCGIFMTU:     r->u.ival = (int32_t)ni.mtu;    return 0;
    case K_SIOCGIFMETRIC:  r->u.ival = 0;                  return 0;
    case K_SIOCGIFTXQLEN:  r->u.ival = 1000;               return 0;
    case K_SIOCGIFINDEX:   r->u.ival = 1;                  return 0;
    case K_SIOCGIFMAP:     memset(&r->u, 0, sizeof r->u);  return 0;
    case K_SIOCGIFHWADDR:
        memset(&r->u, 0, sizeof r->u);
        r->u.sa.family = K_ARPHRD_ETHER;
        memcpy(r->u.sa.data, ni.mac, 6);
        return 0;
    default: return -1;                                 /* setters / unknown */
    }
}
