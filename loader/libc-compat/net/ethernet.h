/* net/ethernet.h — minimal Ethernet definitions for toybox net tools. */
#ifndef _XT_COMPAT_NET_ETHERNET_H
#define _XT_COMPAT_NET_ETHERNET_H

#include <stdint.h>

#define ETH_ALEN     6
#define ETHER_ADDR_LEN 6

struct ether_addr { uint8_t ether_addr_octet[ETH_ALEN]; };

#endif
