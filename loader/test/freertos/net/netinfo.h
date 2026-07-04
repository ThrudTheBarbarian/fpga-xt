/* netinfo.h — a plain snapshot of the (single) network interface, so procfs
 * and the ifconfig ioctl path can read the address/MAC/flags without lwIP
 * types leaking into their translation units. Provider: net.c. */
#ifndef XT_NETINFO_H
#define XT_NETINFO_H

#include <stdint.h>

/* IFF_* flag subset (Linux values) reported in .flags */
#define XT_IFF_UP        0x0001
#define XT_IFF_BROADCAST 0x0002
#define XT_IFF_LOOPBACK  0x0008
#define XT_IFF_RUNNING   0x0040
#define XT_IFF_MULTICAST 0x1000

struct xt_ifinfo {
    char     name[8];              /* "e0" */
    uint8_t  mac[6];
    uint32_t ip, netmask, gw;      /* network-order-as-LE-int (matches /proc/net) */
    uint32_t mtu, flags;
    int      link_up, speed_mbps;
};

/* fill *out from the default netif; returns 1 if the interface exists, 0 if
 * lwIP hasn't brought it up yet (out is zeroed in that case). */
int xt_netif_info(struct xt_ifinfo *out);

#endif
