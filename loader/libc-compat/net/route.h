/* net/route.h — just the RTF_* route flags toybox netstat prints. XTOS has one
 * netif and a synthesized /OS/proc/net/route; there is no rtentry ioctl API. */
#ifndef _XT_COMPAT_NET_ROUTE_H
#define _XT_COMPAT_NET_ROUTE_H

#define RTF_UP        0x0001
#define RTF_GATEWAY   0x0002
#define RTF_HOST      0x0004
#define RTF_REINSTATE 0x0008
#define RTF_DYNAMIC   0x0010
#define RTF_MODIFIED  0x0020
#define RTF_REJECT    0x0200

#endif
