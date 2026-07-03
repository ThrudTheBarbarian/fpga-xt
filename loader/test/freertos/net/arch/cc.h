/* arch/cc.h — lwIP compiler/platform glue for the XTOS loader (-nostdlib,
 * arm-none-eabi, little-endian A9). Diagnostics go to the UART via puts0;
 * LWIP_DEBUG stays off so the printf-style diag macro is never expanded. */
#ifndef XT_LWIP_ARCH_CC_H
#define XT_LWIP_ARCH_CC_H

#define BYTE_ORDER LITTLE_ENDIAN

#define LWIP_NO_INTTYPES_H 1
#define X8_F  "02x"
#define U16_F "u"
#define S16_F "d"
#define X16_F "x"
#define U32_F "u"
#define S32_F "d"
#define X32_F "x"
#define SZT_F "u"

extern void puts0(const char *);
#define LWIP_PLATFORM_DIAG(x)
#define LWIP_PLATFORM_ASSERT(m) do { puts0("[lwip] ASSERT: "); puts0(m); puts0("\n"); for(;;); } while (0)

extern unsigned xt_net_rand(void);
#define LWIP_RAND() ((u32_t)xt_net_rand())

#endif
