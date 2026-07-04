/* net/if.h — interface flags + the struct ifreq/ifconf ABI toybox ifconfig
 * uses. XTOS has one Ethernet netif; the SIOCGIF* ioctls (sys/ioctl.h) are
 * serviced kernel-side from the lwIP netif. Layout is the Linux 32-bit one
 * (16-byte name + 16-byte union) — the kernel handler mirrors it exactly. */
#ifndef _XT_COMPAT_NET_IF_H
#define _XT_COMPAT_NET_IF_H

#include <sys/socket.h>

#define IF_NAMESIZE 16
#define IFNAMSIZ    IF_NAMESIZE

/* interface flags */
#define IFF_UP          0x0001
#define IFF_BROADCAST   0x0002
#define IFF_DEBUG       0x0004
#define IFF_LOOPBACK    0x0008
#define IFF_POINTOPOINT 0x0010
#define IFF_NOTRAILERS  0x0020
#define IFF_RUNNING     0x0040
#define IFF_NOARP       0x0080
#define IFF_PROMISC     0x0100
#define IFF_ALLMULTI    0x0200
#define IFF_MASTER      0x0400
#define IFF_SLAVE       0x0800
#define IFF_MULTICAST   0x1000
#define IFF_PORTSEL     0x2000
#define IFF_AUTOMEDIA   0x4000
#define IFF_DYNAMIC     0x8000

struct ifmap {
    unsigned long  mem_start, mem_end;
    unsigned short base_addr;
    unsigned char  irq, dma, port;
};

struct ifreq {
    char ifr_name[IFNAMSIZ];
    union {
        struct sockaddr ifr_addr;
        struct sockaddr ifr_dstaddr;
        struct sockaddr ifr_broadaddr;
        struct sockaddr ifr_netmask;
        struct sockaddr ifr_hwaddr;
        short           ifr_flags;
        int             ifr_ifindex;
        int             ifr_metric;
        int             ifr_mtu;
        struct ifmap    ifr_map;
        char            ifr_slave[IFNAMSIZ];
        char            ifr_newname[IFNAMSIZ];
        char           *ifr_data;
        short           ifr_qlen;
    } ifr_ifru;
};
#define ifr_addr      ifr_ifru.ifr_addr
#define ifr_dstaddr   ifr_ifru.ifr_dstaddr
#define ifr_broadaddr ifr_ifru.ifr_broadaddr
#define ifr_netmask   ifr_ifru.ifr_netmask
#define ifr_hwaddr    ifr_ifru.ifr_hwaddr
#define ifr_flags     ifr_ifru.ifr_flags
#define ifr_ifindex   ifr_ifru.ifr_ifindex
#define ifr_metric    ifr_ifru.ifr_metric
#define ifr_mtu       ifr_ifru.ifr_mtu
#define ifr_map       ifr_ifru.ifr_map
#define ifr_slave     ifr_ifru.ifr_slave
#define ifr_newname   ifr_ifru.ifr_newname
#define ifr_data      ifr_ifru.ifr_data
#define ifr_qlen      ifr_ifru.ifr_qlen

struct ifconf {
    int ifc_len;
    union {
        char        *ifc_buf;
        struct ifreq *ifc_req;
    } ifc_ifcu;
};
#define ifc_buf ifc_ifcu.ifc_buf
#define ifc_req ifc_ifcu.ifc_req

#ifdef __cplusplus
extern "C"
#endif
unsigned if_nametoindex(const char *name);

#endif
