/* net/if_arp.h — just the ARPHRD_* hardware-type constants toybox prints for
 * an interface's link layer. XTOS is Ethernet-only; there is no arp ioctl. */
#ifndef _XT_COMPAT_NET_IF_ARP_H
#define _XT_COMPAT_NET_IF_ARP_H

#include <net/if.h>

#define ARPHRD_ETHER      1
#define ARPHRD_PPP        512
#define ARPHRD_LOOPBACK   772
#define ARPHRD_SIT        776
#define ARPHRD_INFINIBAND 32

#endif
