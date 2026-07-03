/* net.c — bring lwIP up on GEM0: tcpip thread, DHCP, and a poll task that
 * drains the (interrupt-less) MAC and watches the link. Started from
 * shell_task after the SD mounts; fully passive if there's no PHY/link/DHCP
 * (qemu's user-mode net answers DHCP itself, so the same path works there).
 * Prints one line when the address arrives:  [net] up 192.168.x.y  */
#include "lwip/tcpip.h"
#include "lwip/netif.h"
#include "lwip/dhcp.h"
#include "FreeRTOS.h"
#include "task.h"

extern void puts0(const char *);
extern void putu(unsigned);

err_t xemacpsif_init(struct netif *nif);
int   xemacpsif_poll(struct netif *nif);
int   xemacpsif_link_poll(void);
void  tftpd_init(void);

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
    dhcp_start(&g_nif);
    UNLOCK_TCPIP_CORE();

    tftpd_init();

    int ticks = 0;
    for (;;) {                                           /* the RX pump */
        xemacpsif_poll(&g_nif);
        if (++ticks >= 500) {                            /* link watch, every ~500 ms */
            ticks = 0;
            int sp = xemacpsif_link_poll();
            if (sp) { puts0("[net] link "); putu((unsigned)sp); puts0(" Mb/s\n"); }
        }
        vTaskDelay(1);                                   /* 1 tick (1 ms) */
    }
}

void net_init(void)
{
    xTaskCreate(net_task, "net", 1024, 0, 2, 0);
}
