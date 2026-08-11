/* net.c — bring lwIP up on GEM0: tcpip thread, DHCP, and a poll task that
 * drains the (interrupt-less) MAC and watches the link. Started from
 * shell_task after the SD mounts; fully passive if there's no PHY/link/DHCP
 * (qemu's user-mode net answers DHCP itself, so the same path works there).
 * Prints one line when the address arrives:  [net] up 192.168.x.y  */
#include "lwip/tcpip.h"
#include "lwip/netif.h"
#include <string.h>
#include "lwip/dhcp.h"
#include "lwip/apps/mdns.h"
#include "lwip/apps/sntp.h"
#include "lwip/dns.h"
#include "lwip/igmp.h"
#include "lwip/timeouts.h"
#include "FreeRTOS.h"
#include "task.h"

/* kernel whole-file read (frtos_os.c) — for /OS/etc/resolv.conf */
long frtos_net_readfile(const char *path, const void **data);

extern void klog(const char *);      /* -> /OS/var/log/system.log (not console) */
extern void klog_u(unsigned);

err_t xemacpsif_init(struct netif *nif);
int   xemacpsif_poll(struct netif *nif);
int   xemacpsif_link_poll(void);
int   xemacpsif_speed(void);
void  xemacpsif_wait(int ms);
void  tftpd_init(void);
void  netcon_init(void);

static struct netif g_nif;
static volatile int g_lwip_ready;

/* interface snapshot for procfs (/OS/proc/net/*) + the ifconfig ioctl path */
#include "netinfo.h"
int xt_netif_info(struct xt_ifinfo *out)
{
    memset(out, 0, sizeof *out);
    if (!g_lwip_ready) return 0;
    /* the driver's 2-char name ("e0") is already the full interface name */
    out->name[0] = g_nif.name[0]; out->name[1] = g_nif.name[1]; out->name[2] = 0;
    memcpy(out->mac, g_nif.hwaddr, 6);
    out->ip      = ip4_addr_get_u32(netif_ip4_addr(&g_nif));
    out->netmask = ip4_addr_get_u32(netif_ip4_netmask(&g_nif));
    out->gw      = ip4_addr_get_u32(netif_ip4_gw(&g_nif));
    out->mtu     = g_nif.mtu;
    out->flags   = XT_IFF_UP | XT_IFF_BROADCAST | XT_IFF_MULTICAST |
                   (netif_is_link_up(&g_nif) ? XT_IFF_RUNNING : 0);
    out->link_up = netif_is_link_up(&g_nif);
    out->speed_mbps = xemacpsif_speed();
    return 1;
}

/* xorshift for lwIP (ARP/DHCP jitter — not cryptographic) */
unsigned xt_net_rand(void)
{
    static unsigned s = 0x58544F53u;                     /* "XTOS" */
    s ^= s << 13; s ^= s >> 17; s ^= s << 5;
    return s;
}

static void tcpip_ready(void *arg)
{
    (void)arg;
    g_lwip_ready = 1;
}

/* mDNS keepalive (2026-08-10): xtos.local resolution died repeatedly minutes
 * into a session while unicast stayed perfect — the responder itself was
 * healthy (it answered a UNICAST dig @board -p 5353 mid-wedge), so inbound
 * MULTICAST delivery is what stops, most plausibly an IGMP-snooping switch
 * aging out the 224.0.0.251 registration.  Re-sending the membership
 * reports refreshes the switch; the gratuitous announce additionally
 * repopulates peer caches directly, so names keep resolving even while
 * inbound multicast is being filtered.  Runs on the tcpip thread via a
 * self-re-arming sys_timeout (one MEMP_NUM_SYS_TIMEOUT slot). */
#define MDNS_KEEPALIVE_MS 60000
static void mdns_keepalive(void *arg)
{
    (void)arg;
    if (netif_is_up(&g_nif) && !ip4_addr_isany_val(*netif_ip4_addr(&g_nif))) {
        igmp_report_groups(&g_nif);
        mdns_resp_announce(&g_nif);
    }
    sys_timeout(MDNS_KEEPALIVE_MS, mdns_keepalive, 0);
}

static void net_status(struct netif *nif)
{
    if (netif_is_up(nif) && !ip4_addr_isany_val(*netif_ip4_addr(nif))) {
        const ip4_addr_t *a = netif_ip4_addr(nif);
        unsigned ip = lwip_ntohl(ip4_addr_get_u32(a));
        klog("[net] up ");
        klog_u((ip >> 24) & 255); klog(".");
        klog_u((ip >> 16) & 255); klog(".");
        klog_u((ip >> 8) & 255);  klog(".");
        klog_u(ip & 255);         klog("  (tftp ready)\n");
    }
}

void sntp_start_cb(void *arg)              /* lwIP thread: SNTP fires once DNS arrives */
{
    (void)arg;
    sntp_setoperatingmode(SNTP_OPMODE_POLL);
    sntp_setservername(0, "pool.ntp.org");
    sntp_init();
}

static void net_task(void *arg)
{
    (void)arg;
    tcpip_init(tcpip_ready, 0);
    while (!g_lwip_ready) vTaskDelay(pdMS_TO_TICKS(10));

    LOCK_TCPIP_CORE();
    if (!netif_add(&g_nif, IP4_ADDR_ANY4, IP4_ADDR_ANY4, IP4_ADDR_ANY4,
                   0, xemacpsif_init, tcpip_input)) {
        UNLOCK_TCPIP_CORE();
        klog("[net] GEM init failed\n");
        vTaskDelete(0);
        return;
    }
    netif_set_default(&g_nif);
    netif_set_hostname(&g_nif, "xtos");
    netif_set_status_callback(&g_nif, net_status);
    netif_set_up(&g_nif);
    mdns_resp_init();
    mdns_resp_add_netif(&g_nif, "xtos");             /* xtos.local */
    sys_timeout(MDNS_KEEPALIVE_MS, mdns_keepalive, 0);   /* see the note above */
    dhcp_start(&g_nif);
    /* static DNS from /OS/etc/resolv.conf ("nameserver a.b.c.d" lines) —
     * indices 0..1, so DHCP's DNS (also set here) fills the rest */
    { const char *txt = 0; long n = frtos_net_readfile("/OS/etc/resolv.conf", (const void **)&txt);
      int idx = 0;
      for (long i = 0; txt && i < n && idx < 2; ) {
        while (i < n && (txt[i] == ' ' || txt[i] == '\t' || txt[i] == '\n' || txt[i] == '\r')) i++;
        if (i + 10 < n && txt[i] == 'n' && !memcmp(txt + i, "nameserver", 10)) {
          i += 10; while (i < n && (txt[i] == ' ' || txt[i] == '\t')) i++;
          char ips[20]; int k = 0;
          while (i < n && k < 19 && (txt[i] == '.' || (txt[i] >= '0' && txt[i] <= '9'))) ips[k++] = txt[i++];
          ips[k] = 0;
          ip_addr_t a;
          if (k && ipaddr_aton(ips, &a)) dns_setserver((u8_t)idx++, &a);
        }
        while (i < n && txt[i] != '\n') i++;
      }
    }
    UNLOCK_TCPIP_CORE();

    tftpd_init();
    netcon_init();
    { extern void input_udp_init(void); input_udp_init(); }   /* mouse over UDP :4242 */
    { extern void sntp_start_cb(void *); tcpip_callback(sntp_start_cb, 0); }

    TickType_t lastlink = 0;
    for (;;) {                                           /* the RX pump */
        xemacpsif_poll(&g_nif);
        TickType_t now = xTaskGetTickCount();
        if (now - lastlink >= pdMS_TO_TICKS(500)) {      /* link watch, every ~500 ms */
            lastlink = now;
            int sp = xemacpsif_link_poll();
            if (sp) { klog("[net] link "); klog_u((unsigned)sp); klog(" Mb/s\n"); }
        }
        xemacpsif_wait(10);                              /* RX IRQ wakes us instantly;
                                                          * 10 ms safety-net timeout */
    }
}

/* set once by net_init; sockets.c gates the PL0 socket ABI on it — lwIP's
 * core lock doesn't exist until the stack starts, so touching it before
 * netup is a hard assert (kernel death), not an error return */
static volatile int g_net_started;
int net_is_up(void) { return g_net_started; }

void net_init(void)
{
    /* idempotent: SYS_net_up (the /boot/20-Networking script) may run more than
     * once; the stack starts exactly once per boot */
    if (g_net_started) return;
    g_net_started = 1;
    /* priority 4 — ABOVE PL0 processes (3) and the tcpip thread (4): the GEM RX
     * pump must preempt apps to service the hardware, else a busy/polling process
     * starves receive (packets sit in the MAC until the app blocks). It blocks in
     * xemacpsif_wait when idle, so a high priority costs nothing when there's no
     * traffic. */
    xTaskCreate(net_task, "net", 2048, 0, 4, 0);   /* words = 8 KB: netif/mdns/dns init runs here */
}
