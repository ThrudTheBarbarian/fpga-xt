/* compat/stm32f4xx.h — the small corner of ST's CMSIS device header that
 * TinyUSB's dwc2 port actually reaches for.
 *
 * `dwc2_stm32.h` does `#include "stm32f4xx.h"` and then uses about a dozen
 * symbols from it.  Vendoring ST's real header would drag in ~15k lines of
 * register definitions we already have our own (better documented) versions of
 * in stm32f411.h, and two competing definitions of every peripheral is a worse
 * problem than a shim.  So this file provides exactly what the port needs and
 * nothing else.
 *
 * Deliberately absent:
 *   USB_OTG_HS_PERIPH_BASE   the F411 has no high-speed core, and leaving it
 *                            undefined is how dwc2_stm32.h decides that
 *   RCC_AHB1LPENR_*          gates low-power-mode ULPI workarounds for H7/F7
 *   USB_HS_PHYC              external HS PHY, not present
 */
#ifndef COMPAT_STM32F4XX_H
#define COMPAT_STM32F4XX_H

#include <stdint.h>

/* ------------------------------------------------------------------ USB ---*/

#define USB_OTG_FS_PERIPH_BASE      0x50000000UL
#define USB_OTG_FS_MAX_IN_ENDPOINTS 4U          /* F411 OTG-FS, RM0383 §22 */

/* ------------------------------------------------------------------ NVIC ---
 * Only OTG_FS matters here, but IRQn_Type has to be a real enum because the
 * port casts to it.
 */
typedef enum {
    NonMaskableInt_IRQn = -14,
    HardFault_IRQn      = -13,
    SVCall_IRQn         = -5,
    PendSV_IRQn         = -2,
    SysTick_IRQn        = -1,
    OTG_FS_IRQn         = 67,
} IRQn_Type;

#define NVIC_ISER   ((volatile uint32_t *)0xE000E100UL)
#define NVIC_ICER   ((volatile uint32_t *)0xE000E180UL)
#define NVIC_IPR    ((volatile uint8_t  *)0xE000E400UL)

static inline void NVIC_EnableIRQ(IRQn_Type irq)
{
    NVIC_ISER[((uint32_t)irq) >> 5] = 1UL << (((uint32_t)irq) & 31UL);
}

static inline void NVIC_DisableIRQ(IRQn_Type irq)
{
    NVIC_ICER[((uint32_t)irq) >> 5] = 1UL << (((uint32_t)irq) & 31UL);
    __asm__ volatile ("dsb 0xF" ::: "memory");
    __asm__ volatile ("isb 0xF" ::: "memory");
}

static inline void NVIC_SetPriority(IRQn_Type irq, uint32_t prio)
{
    if ((int32_t)irq >= 0)
        NVIC_IPR[(uint32_t)irq] = (uint8_t)(prio << 4);  /* 4 bits implemented */
}

/* --------------------------------------------------------- core intrinsics -*/

#ifndef __NOP
#define __NOP()     __asm__ volatile ("nop")
#endif
#ifndef __DSB
#define __DSB()     __asm__ volatile ("dsb 0xF" ::: "memory")
#endif
#ifndef __ISB
#define __ISB()     __asm__ volatile ("isb 0xF" ::: "memory")
#endif

/* Used by dwc2_remote_wakeup_delay(); defined in usb.c. */
extern uint32_t SystemCoreClock;

#endif /* COMPAT_STM32F4XX_H */
