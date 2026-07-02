/* busybox-compat: glibc byteswap.h for newlib (platform.h wants bswap_*) */
#ifndef _BB_COMPAT_BYTESWAP_H
#define _BB_COMPAT_BYTESWAP_H
#define bswap_16(x) __builtin_bswap16(x)
#define bswap_32(x) __builtin_bswap32(x)
#define bswap_64(x) __builtin_bswap64(x)
#endif
