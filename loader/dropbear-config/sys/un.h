/* XTOS dropbear-port stub: sys/un.h — Unix-domain address family.
 * The XTOS ssh server listens on TCP only; this exists so the (unused) unix-socket
 * paths in dbutil.c compile. Minimal struct + PF_UNIX alias. */
#ifndef XTSTUB_sys_un_h
#define XTSTUB_sys_un_h

#include <sys/socket.h>   /* sa_family_t */

struct sockaddr_un {
    sa_family_t sun_family;
    char        sun_path[108];
};

#ifndef PF_UNIX
#define PF_UNIX AF_UNIX
#endif

#endif
