/* busybox-compat: sys/un.h — no unix sockets on XTOS; types only */
#ifndef _BB_COMPAT_SYS_UN_H
#define _BB_COMPAT_SYS_UN_H

#include <sys/socket.h>

struct sockaddr_un {
    sa_family_t sun_family;
    char        sun_path[108];
};

#endif
