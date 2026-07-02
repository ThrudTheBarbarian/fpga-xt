/* libc-compat: arpa/inet.h — byte-order helpers + decls so toybox's
 * lib/net.c compiles; no network stack, the object never links. */
#ifndef _XT_COMPAT_ARPA_INET_H
#define _XT_COMPAT_ARPA_INET_H

#include <stdint.h>
#include <netinet/in.h>

#define htons(x) __builtin_bswap16((uint16_t)(x))
#define ntohs(x) __builtin_bswap16((uint16_t)(x))
#define htonl(x) __builtin_bswap32((uint32_t)(x))
#define ntohl(x) __builtin_bswap32((uint32_t)(x))

#ifdef __cplusplus
extern "C" {
#endif
const char *inet_ntop(int af, const void *src, char *dst, socklen_t size);
int inet_pton(int af, const char *src, void *dst);
in_addr_t inet_addr(const char *cp);
char *inet_ntoa(struct in_addr in);
#ifdef __cplusplus
}
#endif

#endif
