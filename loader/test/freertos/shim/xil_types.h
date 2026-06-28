/* Minimal stand-in for the Xilinx BSP xil_types.h — just the typedefs/macros
 * the vendored FreeRTOS port references. We provide our own GIC/timer glue
 * (zynq.c + bsp_shim.c), so the BSP proper is not needed. */
#ifndef XIL_TYPES_H
#define XIL_TYPES_H

#include <stdint.h>
#include <stddef.h>

typedef uint8_t  u8;
typedef uint16_t u16;
typedef uint32_t u32;
typedef uint64_t u64;
typedef int8_t   s8;
typedef int16_t  s16;
typedef int32_t  s32;
typedef int64_t  s64;
typedef uintptr_t UINTPTR;
typedef intptr_t  INTPTR;
typedef s32 XStatus;
typedef void (*XInterruptHandler)(void *);

#ifndef TRUE
#define TRUE  1U
#endif
#ifndef FALSE
#define FALSE 0U
#endif
#ifndef NULL
#define NULL ((void *)0)
#endif

#define XST_SUCCESS 0L
#define XST_FAILURE 1L

#endif /* XIL_TYPES_H */
