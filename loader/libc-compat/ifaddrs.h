/* ifaddrs.h — the BSD interface-enumeration API. XTOS exposes interfaces via
 * /OS/proc/net + SIOCGIF* (ifconfig); getifaddrs() is a failing stub so the
 * few tools that reference it (ping -I) still link. */
#ifndef _XT_COMPAT_IFADDRS_H
#define _XT_COMPAT_IFADDRS_H

#include <sys/socket.h>

struct ifaddrs {
    struct ifaddrs *ifa_next;
    char           *ifa_name;
    unsigned int    ifa_flags;
    struct sockaddr *ifa_addr;
    struct sockaddr *ifa_netmask;
    union {
        struct sockaddr *ifu_broadaddr;
        struct sockaddr *ifu_dstaddr;
    } ifa_ifu;
    void           *ifa_data;
};
#define ifa_broadaddr ifa_ifu.ifu_broadaddr
#define ifa_dstaddr   ifa_ifu.ifu_dstaddr

int  getifaddrs(struct ifaddrs **ifap);
void freeifaddrs(struct ifaddrs *ifa);

#endif
