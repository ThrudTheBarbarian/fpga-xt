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
#include "FreeRTOS.h"
#include "task.h"

/* kernel whole-file read (frtos_os.c) — for /OS/etc/resolv.conf */
long frtos_net_readfile(const char *path, const void **data);

extern void puts0(const char *);
extern void putu(unsigned);

err_t xemacpsif_init(struct netif *nif);
int   xemacpsif_poll(struct netif *nif);
int   xemacpsif_link_poll(void);
void  xemacpsif_wait(int ms);
void  tftpd_init(void);
void  netcon_init(void);

static struct netif g_nif;
static volatile int g_lwip_ready;

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

static void net_status(struct netif *nif)
{
    if (netif_is_up(nif) && !ip4_addr_isany_val(*netif_ip4_addr(nif))) {
        const ip4_addr_t *a = netif_ip4_addr(nif);
        unsigned ip = lwip_ntohl(ip4_addr_get_u32(a));
        puts0("[net] up ");
        putu((ip >> 24) & 255); puts0(".");
        putu((ip >> 16) & 255); puts0(".");
        putu((ip >> 8) & 255);  puts0(".");
        putu(ip & 255);         puts0("  (tftp ready)\n");
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
        puts0("[net] GEM init failed\n");
        vTaskDelete(0);
        return;
    }
    netif_set_default(&g_nif);
    netif_set_hostname(&g_nif, "xtos");
    netif_set_status_callback(&g_nif, net_status);
    netif_set_up(&g_nif);
    mdns_resp_init();
    mdns_resp_add_netif(&g_nif, "xtos");             /* xtos.local */
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
#ifndef XT_NO_NETCON
    netcon_init();
#endif
#ifndef XT_NO_SNTP
    { extern void sntp_start_cb(void *); tcpip_callback(sntp_start_cb, 0); }
#endif

    TickType_t lastlink = 0;
    for (;;) {                                           /* the RX pump */
        xemacpsif_poll(&g_nif);
        TickType_t now = xTaskGetTickCount();
        if (now - lastlink >= pdMS_TO_TICKS(500)) {      /* link watch, every ~500 ms */
            lastlink = now;
            int sp = xemacpsif_link_poll();
            if (sp) { puts0("[net] link "); putu((unsigned)sp); puts0(" Mb/s\n"); }
        }
        xemacpsif_wait(10);                              /* RX IRQ wakes us instantly;
                                                          * 10 ms safety-net timeout */
    }
}

void net_init(void)
{
    xTaskCreate(net_task, "net", 2048, 0, 2, 0);   /* words = 8 KB: netif/mdns/dns init runs here */
}
