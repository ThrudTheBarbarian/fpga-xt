/* XTOS dropbear-port sys/endian.h — byte-order helpers Dropbear's chachapoly/poly1305
 * use (htole64/le64toh...). The Zynq A9 runs little-endian, so the LE conversions are
 * identity and the BE ones are byte swaps. Provided as macros so no symbol is needed. */
#ifndef XTSTUB_sys_endian_h
#define XTSTUB_sys_endian_h

#include <stdint.h>

static inline uint16_t __xt_bswap16(uint16_t x) { return (uint16_t)((x >> 8) | (x << 8)); }
static inline uint32_t __xt_bswap32(uint32_t x) { return __builtin_bswap32(x); }
static inline uint64_t __xt_bswap64(uint64_t x) { return __builtin_bswap64(x); }

/* little-endian host: LE conversions are no-ops, BE conversions swap */
#define htole16(x) ((uint16_t)(x))
#define htole32(x) ((uint32_t)(x))
#define htole64(x) ((uint64_t)(x))
#define le16toh(x) ((uint16_t)(x))
#define le32toh(x) ((uint32_t)(x))
#define le64toh(x) ((uint64_t)(x))
#define htobe16(x) __xt_bswap16(x)
#define htobe32(x) __xt_bswap32(x)
#define htobe64(x) __xt_bswap64(x)
#define be16toh(x) __xt_bswap16(x)
#define be32toh(x) __xt_bswap32(x)
#define be64toh(x) __xt_bswap64(x)

#endif
