/* busybox-compat: net/if.h — no network interfaces on XTOS; libbb's
 * networking helpers compile into lib.a but are never linked. */
#ifndef _BB_COMPAT_NET_IF_H
#define _BB_COMPAT_NET_IF_H

#define IF_NAMESIZE 16
#define IFNAMSIZ    IF_NAMESIZE

#ifdef __cplusplus
extern "C"
#endif
unsigned if_nametoindex(const char *name);

#endif
