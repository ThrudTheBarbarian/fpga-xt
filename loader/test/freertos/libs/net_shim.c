/* net_shim.c — BSD sockets for PL0 programs over the XTOS socket syscalls
 * (block 0x320). IPv4 only; the kernel speaks (be32 ip, host-order port), this
 * layer owns struct sockaddr. Socket fds are ordinary fds — read/write/close/
 * poll work on them — so `nc host port | tar x` pipelines behave.
 *
 * Name resolution order (getaddrinfo/gethostbyname): numeric a.b.c.d, then
 * /OS/etc/hosts ("ip name [alias...]" lines, # comments), then the kernel's
 * DNS (SYS_resolve -> lwIP, servers from DHCP or /OS/etc/resolv.conf). */
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <errno.h>
#include <sys/socket.h>
#include <sys/uio.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <ifaddrs.h>
#include "usys.h"

/* ---- inet_* ----------------------------------------------------------------- */
int inet_aton(const char *s, struct in_addr *out)
{
    unsigned b[4], i = 0, v = 0, seen = 0;
    for (;; s++) {
        if (*s >= '0' && *s <= '9') { v = v * 10 + (unsigned)(*s - '0'); seen = 1; if (v > 255) return 0; }
        else if (*s == '.' || *s == 0) {
            if (!seen || i >= 4) return 0;
            b[i++] = v; v = 0; seen = 0;
            if (*s == 0) break;
        } else return 0;
    }
    if (i != 4) return 0;
    out->s_addr = (in_addr_t)(b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24));  /* be32 in memory */
    return 1;
}

in_addr_t inet_addr(const char *s)
{
    struct in_addr a;
    return inet_aton(s, &a) ? a.s_addr : INADDR_NONE;
}

char *inet_ntoa(struct in_addr in)
{
    static char b[16];
    unsigned v = in.s_addr;
    snprintf(b, sizeof b, "%u.%u.%u.%u", v & 255, (v >> 8) & 255, (v >> 16) & 255, (v >> 24) & 255);
    return b;
}

const char *inet_ntop(int af, const void *src, char *dst, socklen_t size)
{
    if (af != AF_INET) return 0;
    struct in_addr a; memcpy(&a, src, 4);
    char *s = inet_ntoa(a);
    if (strlen(s) + 1 > size) return 0;
    strcpy(dst, s);
    return dst;
}

int inet_pton(int af, const char *src, void *dst)
{
    if (af != AF_INET) return -1;
    struct in_addr a;
    if (!inet_aton(src, &a)) return 0;
    memcpy(dst, &a, 4);
    return 1;
}

/* ---- the socket calls -------------------------------------------------------- */
static int sin_of(const struct sockaddr *sa, unsigned *ip_be, unsigned *port)
{
    const struct sockaddr_in *in = (const struct sockaddr_in *)sa;
    if (!sa || in->sin_family != AF_INET) { errno = EAFNOSUPPORT; return -1; }
    *ip_be = in->sin_addr.s_addr;
    *port  = ntohs(in->sin_port);
    return 0;
}

int socket(int domain, int type, int protocol)
{
    if (domain != AF_INET) { errno = EAFNOSUPPORT; return -1; }
    int st = type & 0xFF, t;
    if (protocol == IPPROTO_ICMP || st == SOCK_RAW)  /* ping: DGRAM/RAW + ICMP */
        t = XT_SOCK_RAW;
    else
        t = (st == SOCK_DGRAM) ? XT_SOCK_UDP : XT_SOCK_TCP;
    long fd = sys_socket(t);
    if (fd < 0) { errno = EMFILE; return -1; }
    return (int)fd;
}

int connect(int fd, const struct sockaddr *sa, socklen_t len)
{
    (void)len;
    unsigned ip, port;
    if (sin_of(sa, &ip, &port)) return -1;
    if (sys_connect(fd, ip, port) != 0) { errno = ECONNREFUSED; return -1; }
    return 0;
}

int bind(int fd, const struct sockaddr *sa, socklen_t len)
{
    (void)len;
    unsigned ip, port;
    if (sin_of(sa, &ip, &port)) return -1;
    if (sys_bind(fd, ip, port) != 0) { errno = EADDRINUSE; return -1; }
    return 0;
}

int listen(int fd, int backlog)
{
    if (sys_listen(fd, backlog) != 0) { errno = EOPNOTSUPP; return -1; }
    return 0;
}

int accept(int fd, struct sockaddr *sa, socklen_t *len)
{
    unsigned peer[2] = { 0, 0 };
    long nfd = sys_accept(fd, peer);
    if (nfd < 0) { errno = EINVAL; return -1; }
    if (sa && len && *len >= sizeof(struct sockaddr_in)) {
        struct sockaddr_in *in = (struct sockaddr_in *)sa;
        memset(in, 0, sizeof *in);
        in->sin_family = AF_INET;
        in->sin_addr.s_addr = peer[0];
        in->sin_port = htons((uint16_t)peer[1]);
        *len = sizeof *in;
    }
    return (int)nfd;
}

ssize_t send(int fd, const void *buf, size_t n, int flags)
{ (void)flags; return (ssize_t)sys_write(fd, buf, (unsigned)n); }
ssize_t recv(int fd, void *buf, size_t n, int flags)
{ (void)flags; return (ssize_t)sys_read(fd, buf, (unsigned)n); }
/* connected sockets only: the addr args are advisory here */
ssize_t sendto(int fd, const void *buf, size_t n, int flags,
               const struct sockaddr *sa, socklen_t len)
{
    if (sa && len) { unsigned ip, port; if (!sin_of(sa, &ip, &port)) sys_connect(fd, ip, port); }
    (void)flags;
    return (ssize_t)sys_write(fd, buf, (unsigned)n);
}
/* fill *sa (if provided) from the (ip,port) a datagram recv reported */
static void set_srcaddr(struct sockaddr *sa, socklen_t *len, unsigned ip, unsigned port)
{
    if (!sa) return;
    struct sockaddr_in *in = (struct sockaddr_in *)sa;
    memset(in, 0, sizeof *in);
    in->sin_family = AF_INET;
    in->sin_addr.s_addr = ip;
    in->sin_port = htons((uint16_t)port);
    if (len) *len = sizeof *in;
}
ssize_t recvfrom(int fd, void *buf, size_t n, int flags, struct sockaddr *sa, socklen_t *len)
{
    (void)flags;
    unsigned a[3] = { (unsigned)n, 0, 0 };
    long r = sys_recvfrom(fd, buf, a);
    if (r >= 0) set_srcaddr(sa, len, a[1], a[2]);
    return (ssize_t)r;
}
/* single-iov datagram recv (ping). No ancillary data: msg_controllen -> 0, so
 * the IP_TTL cmsg is absent and callers show ttl 0. */
ssize_t recvmsg(int fd, struct msghdr *msg, int flags)
{
    (void)flags;
    if (!msg || !msg->msg_iov || msg->msg_iovlen < 1) { errno = EINVAL; return -1; }
    struct iovec *iov = (struct iovec *)msg->msg_iov;
    unsigned a[3] = { (unsigned)iov[0].iov_len, 0, 0 };
    long r = sys_recvfrom(fd, iov[0].iov_base, a);
    if (r < 0) return -1;
    if (msg->msg_name && msg->msg_namelen >= (socklen_t)sizeof(struct sockaddr_in))
        set_srcaddr((struct sockaddr *)msg->msg_name, &msg->msg_namelen, a[1], a[2]);
    else if (msg->msg_name) msg->msg_namelen = 0;
    msg->msg_controllen = 0;
    msg->msg_flags = 0;
    return (ssize_t)r;
}

int setsockopt(int fd, int level, int opt, const void *val, socklen_t len)
{ (void)fd; (void)level; (void)opt; (void)val; (void)len; return 0; }
int getsockopt(int fd, int level, int opt, void *val, socklen_t *len)
{
    (void)fd; (void)level;
    if (opt == SO_ERROR && val && len && *len >= 4) { *(int *)val = 0; *len = 4; return 0; }
    errno = ENOPROTOOPT;
    return -1;
}
int shutdown(int fd, int how) { (void)fd; (void)how; return 0; }
/* peer/local endpoint of a kernel socket (XT_SIOCGPEER/XT_SIOCGNAME -> u32[2]
 * {ip_be32, port}); dropbear logs the result ("Child connection from a.b.c.d"). */
static int sock_endpoint(int fd, unsigned req, struct sockaddr *sa, socklen_t *len)
{
    if (!sa || !len || *len < (socklen_t)sizeof(struct sockaddr_in)) { errno = EINVAL; return -1; }
    struct sockaddr_in *sin = (struct sockaddr_in *)sa;
    memset(sin, 0, sizeof *sin);
    sin->sin_family = AF_INET;
    unsigned e[2] = { 0, 0 };
    if (sys_ioctl(fd, req, e) == 0) {           /* on failure leave 0.0.0.0:0 */
        sin->sin_addr.s_addr = e[0];            /* kernel hands it back big-endian */
        sin->sin_port = htons((unsigned short)e[1]);
    }
    *len = sizeof *sin;
    return 0;
}
int getpeername(int fd, struct sockaddr *sa, socklen_t *len)
{ return sock_endpoint(fd, XT_SIOCGPEER, sa, len); }
int getsockname(int fd, struct sockaddr *sa, socklen_t *len)
{ return sock_endpoint(fd, XT_SIOCGNAME, sa, len); }

/* ---- name resolution --------------------------------------------------------- */
/* /OS/etc/hosts: "a.b.c.d  name [alias...]" */
static int hosts_lookup(const char *name, struct in_addr *out)
{
    FILE *f = fopen("/OS/etc/hosts", "r");
    if (!f) return 0;
    char line[160];
    int hit = 0;
    while (!hit && fgets(line, sizeof line, f)) {
        char *h = strchr(line, '#');
        if (h) *h = 0;
        char *tok = strtok(line, " \t\r\n");
        if (!tok) continue;
        struct in_addr a;
        if (!inet_aton(tok, &a)) continue;
        while ((tok = strtok(NULL, " \t\r\n")))
            if (!strcasecmp(tok, name)) { *out = a; hit = 1; break; }
    }
    fclose(f);
    return hit;
}

static int resolve4(const char *name, struct in_addr *out)
{
    if (inet_aton(name, out)) return 0;
    if (hosts_lookup(name, out)) return 0;
    unsigned ip = 0;
    if (sys_resolve(name, &ip) == 0) { out->s_addr = ip; return 0; }
    return -1;
}

int getaddrinfo(const char *node, const char *service,
                const struct addrinfo *hints, struct addrinfo **res)
{
    struct in_addr a = { 0 };
    if (node) { if (resolve4(node, &a)) return EAI_NONAME; }
    else a.s_addr = (hints && (hints->ai_flags & AI_PASSIVE)) ? INADDR_ANY : htonl(INADDR_LOOPBACK);

    int port = service ? atoi(service) : 0;
    struct {
        struct addrinfo ai;
        struct sockaddr_in sin;
    } *blob = calloc(1, sizeof *blob);
    if (!blob) return EAI_MEMORY;
    blob->sin.sin_family = AF_INET;
    blob->sin.sin_port   = htons((uint16_t)port);
    blob->sin.sin_addr   = a;
    blob->ai.ai_family   = AF_INET;
    blob->ai.ai_socktype = hints && hints->ai_socktype ? hints->ai_socktype : SOCK_STREAM;
    blob->ai.ai_protocol = 0;
    blob->ai.ai_addrlen  = sizeof(struct sockaddr_in);
    blob->ai.ai_addr     = (struct sockaddr *)&blob->sin;
    *res = &blob->ai;
    return 0;
}

void freeaddrinfo(struct addrinfo *res) { free(res); }

const char *gai_strerror(int e)
{
    return e == EAI_NONAME ? "name not known" : e == EAI_MEMORY ? "out of memory" : "resolver error";
}

int h_errno;                                  /* legacy resolver error (gethostbyname) */
const char *hstrerror(int e) { (void)e; return "resolver error"; }

/* no /etc/services db: port-name lookups return NULL, so netstat/nc fall back
 * to numeric ports (which is what we want on a headless box anyway) */
struct servent *getservbyport(int port, const char *proto) { (void)port; (void)proto; return 0; }

/* interface enumeration is via /OS/proc/net + SIOCGIF* (ifconfig), not this
 * BSD API; ping only calls it for a named -I source, which we don't support. */
int  getifaddrs(struct ifaddrs **ifap) { if (ifap) *ifap = 0; errno = ENOSYS; return -1; }
void freeifaddrs(struct ifaddrs *ifa)  { (void)ifa; }

/* no reverse DNS: always the numeric form (as if NI_NUMERICHOST|NI_NUMERICSERV) */
int getnameinfo(const struct sockaddr *sa, socklen_t salen, char *host, socklen_t hostlen,
                char *serv, socklen_t servlen, int flags)
{
    (void)salen; (void)flags;
    if (!sa) return EAI_FAIL;
    if (host && hostlen) {
        if (sa->sa_family == AF_INET6) {
            if (!inet_ntop(AF_INET6, &((const struct sockaddr_in6 *)sa)->sin6_addr, host, hostlen))
                return EAI_FAIL;
        } else if (!inet_ntop(AF_INET, &((const struct sockaddr_in *)sa)->sin_addr, host, hostlen))
            return EAI_FAIL;
    }
    if (serv && servlen) {
        unsigned p = ntohs(sa->sa_family == AF_INET6
                           ? ((const struct sockaddr_in6 *)sa)->sin6_port
                           : ((const struct sockaddr_in *)sa)->sin_port);
        char t[8]; int k = 0, i;
        do { t[k++] = (char)('0' + p % 10); p /= 10; } while (p);
        for (i = 0; k && i < (int)servlen - 1; ) serv[i++] = t[--k];
        serv[i] = 0;
    }
    return 0;
}
void herror(const char *s) { if (s && *s) { fprintf(stderr, "%s: ", s); } fprintf(stderr, "resolver error\n"); }

struct hostent *gethostbyname(const char *name)
{
    static struct hostent he;
    static struct in_addr addr;
    static char *addrs[2];
    static char *aliases[1];
    if (resolve4(name, &addr)) return 0;
    addrs[0] = (char *)&addr; addrs[1] = 0; aliases[0] = 0;
    he.h_name = (char *)name; he.h_aliases = aliases;
    he.h_addrtype = AF_INET; he.h_length = 4; he.h_addr_list = addrs;
    return &he;
}
