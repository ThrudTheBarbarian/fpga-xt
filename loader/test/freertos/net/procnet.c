/* procnet.c — /OS/proc/net/* generators for netstat/ifconfig. Walks lwIP's
 * own PCB lists (tcp_active/listen/tw/bound, udp_pcbs) under the tcpip core
 * lock and formats them in the Linux /proc/net layout the toybox parsers
 * expect. Called from vfs_procfs.c (fs-task context) via xt_procnet().
 *
 * Address hex is the network-order 32-bit value as a little-endian int —
 * exactly what /proc/net uses, so the value round-trips through the parser's
 * inet_ntop() unchanged (no byte-swap here). Ports print in host order. */
#include "lwip/opt.h"
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

int xt_procnet(const char *leaf, char *buf, int cap)
{
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
const char *const xt_procnet_leaves[] = { "tcp", "udp", "raw", "route", "dev", "unix", 0 };
