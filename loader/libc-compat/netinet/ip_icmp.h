/* netinet/ip_icmp.h — the ICMP echo header toybox ping builds by hand. */
#ifndef _XT_COMPAT_NETINET_IP_ICMP_H
#define _XT_COMPAT_NETINET_IP_ICMP_H

#include <stdint.h>

#define ICMP_ECHO       8
#define ICMP_ECHOREPLY  0

struct icmphdr {
    uint8_t  type;
    uint8_t  code;
    uint16_t checksum;
    union {
        struct { uint16_t id; uint16_t sequence; } echo;
        uint32_t gateway;
        struct { uint16_t unused_pad; uint16_t mtu; } frag;
    } un;
};

#endif
