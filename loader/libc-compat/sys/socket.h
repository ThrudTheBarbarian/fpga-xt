/* libc-compat: sys/socket.h — full declaration surface so toybox's lib/net.c
 * COMPILES; there is no network stack, the object is excluded from the final
 * link (tools/build-toybox.sh objects.list). Nothing implements these. */
#ifndef _XT_COMPAT_SYS_SOCKET_H
#define _XT_COMPAT_SYS_SOCKET_H

#include <sys/types.h>

typedef unsigned int socklen_t;
typedef unsigned short sa_family_t;

struct sockaddr {
    sa_family_t sa_family;
    char        sa_data[14];
};

struct sockaddr_storage {
    sa_family_t ss_family;
    char        __ss_pad[126];
};

struct msghdr {
    void      *msg_name;
    socklen_t  msg_namelen;
    void      *msg_iov;
    int        msg_iovlen;
    void      *msg_control;
    socklen_t  msg_controllen;
    int        msg_flags;
};

#define AF_UNSPEC 0
#define AF_UNIX   1
#define AF_LOCAL  1
#define AF_INET   2
#define AF_INET6  10
#define PF_UNSPEC AF_UNSPEC
#define PF_INET   AF_INET

#define SOCK_STREAM    1
#define SOCK_DGRAM     2
#define SOCK_RAW       3
#define SOCK_RDM       4
#define SOCK_SEQPACKET 5
#define SOCK_CLOEXEC   02000000

#define SOL_SOCKET   1
#define SO_REUSEADDR 2
#define SO_ERROR     4
#define SO_BROADCAST 6
#define SO_SNDBUF    7
#define SO_RCVBUF    8
#define SO_KEEPALIVE 9
#define SO_LINGER    13
#define SO_PEERCRED  17
#define SO_RCVTIMEO  20
#define SO_SNDTIMEO  21

#define SHUT_RD   0
#define SHUT_WR   1
#define SHUT_RDWR 2

#define MSG_OOB       1
#define MSG_PEEK      2
#define MSG_DONTWAIT  0x40
#define MSG_NOSIGNAL  0x4000

#ifdef __cplusplus
extern "C" {
#endif
int socket(int domain, int type, int protocol);
int bind(int fd, const struct sockaddr *addr, socklen_t len);
int connect(int fd, const struct sockaddr *addr, socklen_t len);
int listen(int fd, int backlog);
int accept(int fd, struct sockaddr *addr, socklen_t *len);
int shutdown(int fd, int how);
int setsockopt(int fd, int level, int opt, const void *val, socklen_t len);
int getsockopt(int fd, int level, int opt, void *val, socklen_t *len);
int getsockname(int fd, struct sockaddr *addr, socklen_t *len);
int getpeername(int fd, struct sockaddr *addr, socklen_t *len);
ssize_t send(int fd, const void *buf, size_t len, int flags);
ssize_t recv(int fd, void *buf, size_t len, int flags);
ssize_t sendto(int fd, const void *buf, size_t len, int flags,
               const struct sockaddr *addr, socklen_t alen);
ssize_t recvfrom(int fd, void *buf, size_t len, int flags,
                 struct sockaddr *addr, socklen_t *alen);
ssize_t sendmsg(int fd, const struct msghdr *msg, int flags);
ssize_t recvmsg(int fd, struct msghdr *msg, int flags);
int socketpair(int domain, int type, int protocol, int sv[2]);
#ifdef __cplusplus
}
#endif

#endif
