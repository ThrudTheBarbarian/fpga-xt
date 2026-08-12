/* stm32f411.h — minimal register map for the STM32F411VET6 I/O companion.
 *
 * Deliberately hand-rolled rather than pulling in ST's CMSIS device header:
 * we need a few dozen peripherals, not 15k lines, and this keeps the firmware
 * dependency-free (see motherboard/README.md).  Add peripherals here as they
 * are needed; every offset is from RM0383 (F411 reference manual).
 */
#ifndef STM32F411_H
#define STM32F411_H

#include <stdint.h>

#define __IO volatile

/* ------------------------------------------------------------------ cortex */

typedef struct {
    __IO uint32_t CPUID;
    __IO uint32_t ICSR;
    __IO uint32_t VTOR;
    __IO uint32_t AIRCR;
    __IO uint32_t SCR;
    __IO uint32_t CCR;
    __IO uint32_t SHPR[3];
    __IO uint32_t SHCSR;
    __IO uint32_t CFSR;
    __IO uint32_t HFSR;
    __IO uint32_t DFSR;
    __IO uint32_t MMFAR;
    __IO uint32_t BFAR;
} scb_t;

typedef struct {
    __IO uint32_t CTRL;
    __IO uint32_t LOAD;
    __IO uint32_t VAL;
    __IO uint32_t CALIB;
} systick_t;

typedef struct {
    __IO uint32_t ISER[8];
    uint32_t      _pad0[24];
    __IO uint32_t ICER[8];
    uint32_t      _pad1[24];
    __IO uint32_t ISPR[8];
    uint32_t      _pad2[24];
    __IO uint32_t ICPR[8];
    uint32_t      _pad3[24];
    __IO uint32_t IABR[8];
    uint32_t      _pad4[56];
    __IO uint8_t  IPR[240];
} nvic_t;

#define SCB     ((scb_t     *)0xE000ED00UL)
#define SYSTICK ((systick_t *)0xE000E010UL)
#define NVIC    ((nvic_t    *)0xE000E100UL)
#define CPACR   (*(__IO uint32_t *)0xE000ED88UL)
#define DEMCR   (*(__IO uint32_t *)0xE000EDFCUL)
#define DWT_CTRL   (*(__IO uint32_t *)0xE0001000UL)
#define DWT_CYCCNT (*(__IO uint32_t *)0xE0001004UL)
#define DBGMCU_IDCODE (*(__IO uint32_t *)0xE0042000UL)
#define DBGMCU_CR     (*(__IO uint32_t *)0xE0042004UL)
#define DHCSR      (*(__IO uint32_t *)0xE000EDF0UL)

#define DBGMCU_CR_SLEEP     (1UL << 0)
#define DBGMCU_CR_STOP      (1UL << 1)
#define DBGMCU_CR_STANDBY   (1UL << 2)

/* True when a debugger owns the core.  Worth asking before executing BKPT:
 * with no debugger enabled a breakpoint escalates to a HardFault instead of
 * halting, which turns a park loop into an infinite fault loop. */
static inline int debugger_attached(void)
{
    return (DHCSR & 1UL) != 0UL;            /* C_DEBUGEN */
}

#define SCB_AIRCR_SYSRESETREQ   (0x5FAUL << 16 | 1UL << 2)

/* ------------------------------------------------------------- unique id ---
 * RM0383 §24.1: 96-bit device id and flash size, both in system memory.
 */
#define UID_BASE            0x1FFF7A10UL
#define FLASH_SIZE_KB       (*(__IO uint16_t *)0x1FFF7A22UL)

/* ------------------------------------------------------------------- RCC ---*/

typedef struct {
    __IO uint32_t CR;
    __IO uint32_t PLLCFGR;
    __IO uint32_t CFGR;
    __IO uint32_t CIR;
    __IO uint32_t AHB1RSTR;
    __IO uint32_t AHB2RSTR;
    uint32_t      _pad0[2];
    __IO uint32_t APB1RSTR;
    __IO uint32_t APB2RSTR;
    uint32_t      _pad1[2];
    __IO uint32_t AHB1ENR;
    __IO uint32_t AHB2ENR;
    uint32_t      _pad2[2];
    __IO uint32_t APB1ENR;
    __IO uint32_t APB2ENR;
    uint32_t      _pad3[2];
    __IO uint32_t AHB1LPENR;
    __IO uint32_t AHB2LPENR;
    uint32_t      _pad4[2];
    __IO uint32_t APB1LPENR;
    __IO uint32_t APB2LPENR;
    uint32_t      _pad5[2];
    __IO uint32_t BDCR;
    __IO uint32_t CSR;
    uint32_t      _pad6[2];
    __IO uint32_t SSCGR;
    __IO uint32_t PLLI2SCFGR;
    uint32_t      _pad7;
    __IO uint32_t DCKCFGR;
} rcc_t;

#define RCC ((rcc_t *)0x40023800UL)

#define RCC_CR_HSION            (1UL << 0)
#define RCC_CR_HSIRDY           (1UL << 1)
#define RCC_CR_HSEON            (1UL << 16)
#define RCC_CR_HSERDY           (1UL << 17)
#define RCC_CR_HSEBYP           (1UL << 18)
#define RCC_CR_CSSON            (1UL << 19)
#define RCC_CR_PLLON            (1UL << 24)
#define RCC_CR_PLLRDY           (1UL << 25)

#define RCC_CFGR_SW_MASK        (3UL << 0)
#define RCC_CFGR_SW_PLL         (2UL << 0)
#define RCC_CFGR_SWS_MASK       (3UL << 2)
#define RCC_CFGR_SWS_PLL        (2UL << 2)

/* AHB1ENR */
#define RCC_AHB1ENR_GPIOA       (1UL << 0)
#define RCC_AHB1ENR_GPIOB       (1UL << 1)
#define RCC_AHB1ENR_GPIOC       (1UL << 2)
#define RCC_AHB1ENR_GPIOD       (1UL << 3)
#define RCC_AHB1ENR_GPIOE       (1UL << 4)
#define RCC_AHB1ENR_GPIOH       (1UL << 7)
#define RCC_AHB1ENR_CRC         (1UL << 12)
#define RCC_AHB1ENR_DMA1        (1UL << 21)
#define RCC_AHB1ENR_DMA2        (1UL << 22)
/* AHB2ENR */
#define RCC_AHB2ENR_OTGFS       (1UL << 7)
/* APB1ENR */
#define RCC_APB1ENR_TIM2        (1UL << 0)
#define RCC_APB1ENR_TIM3        (1UL << 1)
#define RCC_APB1ENR_TIM4        (1UL << 2)
#define RCC_APB1ENR_TIM5        (1UL << 3)
#define RCC_APB1ENR_WWDG        (1UL << 11)
#define RCC_APB1ENR_SPI2        (1UL << 14)
#define RCC_APB1ENR_SPI3        (1UL << 15)
#define RCC_APB1ENR_USART2      (1UL << 17)
#define RCC_APB1ENR_I2C1        (1UL << 21)
#define RCC_APB1ENR_PWR         (1UL << 28)
/* APB2ENR */
#define RCC_APB2ENR_TIM1        (1UL << 0)
#define RCC_APB2ENR_USART1      (1UL << 4)
#define RCC_APB2ENR_USART6      (1UL << 5)
#define RCC_APB2ENR_ADC1        (1UL << 8)
#define RCC_APB2ENR_SDIO        (1UL << 11)
#define RCC_APB2ENR_SPI1        (1UL << 12)
#define RCC_APB2ENR_SYSCFG      (1UL << 14)
#define RCC_APB2ENR_TIM9        (1UL << 16)
#define RCC_APB2ENR_TIM10       (1UL << 17)
#define RCC_APB2ENR_TIM11       (1UL << 18)

/* RCC_CSR reset-cause flags (top byte) */
#define RCC_CSR_RMVF            (1UL << 24)
#define RCC_CSR_BORRSTF         (1UL << 25)
#define RCC_CSR_PINRSTF         (1UL << 26)
#define RCC_CSR_PORRSTF         (1UL << 27)
#define RCC_CSR_SFTRSTF         (1UL << 28)
#define RCC_CSR_IWDGRSTF        (1UL << 29)
#define RCC_CSR_WWDGRSTF        (1UL << 30)
#define RCC_CSR_LPWRRSTF        (1UL << 31)

/* ------------------------------------------------------------------- PWR ---*/

typedef struct {
    __IO uint32_t CR;
    __IO uint32_t CSR;
} pwr_t;

#define PWR ((pwr_t *)0x40007000UL)

#define PWR_CR_VOS_SCALE1       (3UL << 14)
#define PWR_CSR_VOSRDY          (1UL << 14)

/* ----------------------------------------------------------------- FLASH ---*/

typedef struct {
    __IO uint32_t ACR;
    __IO uint32_t KEYR;
    __IO uint32_t OPTKEYR;
    __IO uint32_t SR;
    __IO uint32_t CR;
    __IO uint32_t OPTCR;
} flash_t;

#define FLASH ((flash_t *)0x40023C00UL)

#define FLASH_ACR_LATENCY(n)    ((uint32_t)(n) & 0xF)
#define FLASH_ACR_PRFTEN        (1UL << 8)
#define FLASH_ACR_ICEN          (1UL << 9)
#define FLASH_ACR_DCEN          (1UL << 10)

/* ------------------------------------------------------------------ GPIO ---*/

typedef struct {
    __IO uint32_t MODER;
    __IO uint32_t OTYPER;
    __IO uint32_t OSPEEDR;
    __IO uint32_t PUPDR;
    __IO uint32_t IDR;
    __IO uint32_t ODR;
    __IO uint32_t BSRR;
    __IO uint32_t LCKR;
    __IO uint32_t AFR[2];
} gpio_t;

#define GPIOA ((gpio_t *)0x40020000UL)
#define GPIOB ((gpio_t *)0x40020400UL)
#define GPIOC ((gpio_t *)0x40020800UL)
#define GPIOD ((gpio_t *)0x40020C00UL)
#define GPIOE ((gpio_t *)0x40021000UL)
#define GPIOH ((gpio_t *)0x40021C00UL)

/* MODER field values */
#define GPIO_MODE_IN            0U
#define GPIO_MODE_OUT           1U
#define GPIO_MODE_AF            2U
#define GPIO_MODE_ANALOG        3U
/* PUPDR field values */
#define GPIO_PULL_NONE          0U
#define GPIO_PULL_UP            1U
#define GPIO_PULL_DOWN          2U
/* OSPEEDR field values */
#define GPIO_SPEED_LOW          0U
#define GPIO_SPEED_MED          1U
#define GPIO_SPEED_FAST         2U
#define GPIO_SPEED_HIGH         3U

/* ---------------------------------------------------------------- SYSCFG ---*/

typedef struct {
    __IO uint32_t MEMRMP;
    __IO uint32_t PMC;
    __IO uint32_t EXTICR[4];
    uint32_t      _pad[2];
    __IO uint32_t CMPCR;
} syscfg_t;

#define SYSCFG ((syscfg_t *)0x40013800UL)

/* ------------------------------------------------------------------ EXTI ---*/

typedef struct {
    __IO uint32_t IMR;
    __IO uint32_t EMR;
    __IO uint32_t RTSR;
    __IO uint32_t FTSR;
    __IO uint32_t SWIER;
    __IO uint32_t PR;
} exti_t;

#define EXTI ((exti_t *)0x40013C00UL)

/* ----------------------------------------------------------------- USART ---*/

typedef struct {
    __IO uint32_t SR;
    __IO uint32_t DR;
    __IO uint32_t BRR;
    __IO uint32_t CR1;
    __IO uint32_t CR2;
    __IO uint32_t CR3;
    __IO uint32_t GTPR;
} usart_t;

#define USART1 ((usart_t *)0x40011000UL)
#define USART2 ((usart_t *)0x40004400UL)
#define USART6 ((usart_t *)0x40011400UL)

#define USART_SR_PE             (1UL << 0)
#define USART_SR_FE             (1UL << 1)
#define USART_SR_NE             (1UL << 2)
#define USART_SR_ORE            (1UL << 3)
#define USART_SR_IDLE           (1UL << 4)
#define USART_SR_RXNE           (1UL << 5)
#define USART_SR_TC             (1UL << 6)
#define USART_SR_TXE            (1UL << 7)

#define USART_CR1_RE            (1UL << 2)
#define USART_CR1_TE            (1UL << 3)
#define USART_CR1_RXNEIE        (1UL << 5)
#define USART_CR1_TCIE          (1UL << 6)
#define USART_CR1_TXEIE         (1UL << 7)
#define USART_CR1_PS            (1UL << 9)
#define USART_CR1_PCE           (1UL << 10)
#define USART_CR1_M             (1UL << 12)
#define USART_CR1_UE            (1UL << 13)

/* ------------------------------------------------------------------- SPI ---*/

typedef struct {
    __IO uint32_t CR1;
    __IO uint32_t CR2;
    __IO uint32_t SR;
    __IO uint32_t DR;
    __IO uint32_t CRCPR;
    __IO uint32_t RXCRCR;
    __IO uint32_t TXCRCR;
    __IO uint32_t I2SCFGR;
    __IO uint32_t I2SPR;
} spi_t;

#define SPI1 ((spi_t *)0x40013000UL)

#define SPI_CR1_CPHA            (1UL << 0)
#define SPI_CR1_CPOL            (1UL << 1)
#define SPI_CR1_MSTR            (1UL << 2)
#define SPI_CR1_SPE             (1UL << 6)
#define SPI_CR1_LSBFIRST        (1UL << 7)
#define SPI_CR1_SSI             (1UL << 8)
#define SPI_CR1_SSM             (1UL << 9)
#define SPI_CR1_DFF             (1UL << 11)

#define SPI_CR2_RXNEIE          (1UL << 6)
#define SPI_CR2_TXEIE          (1UL << 7)

#define SPI_SR_RXNE             (1UL << 0)
#define SPI_SR_TXE              (1UL << 1)
#define SPI_SR_OVR              (1UL << 6)
#define SPI_SR_BSY              (1UL << 7)

/* ------------------------------------------------------------------- TIM ---
 * Layout is common enough across TIM1..TIM5 for our uses; the advanced-timer
 * extras (BDTR) only exist on TIM1 and are simply unused elsewhere.
 */
typedef struct {
    __IO uint32_t CR1;
    __IO uint32_t CR2;
    __IO uint32_t SMCR;
    __IO uint32_t DIER;
    __IO uint32_t SR;
    __IO uint32_t EGR;
    __IO uint32_t CCMR1;
    __IO uint32_t CCMR2;
    __IO uint32_t CCER;
    __IO uint32_t CNT;
    __IO uint32_t PSC;
    __IO uint32_t ARR;
    __IO uint32_t RCR;
    __IO uint32_t CCR[4];
    __IO uint32_t BDTR;
    __IO uint32_t DCR;
    __IO uint32_t DMAR;
    __IO uint32_t OR;
} tim_t;

#define TIM1 ((tim_t *)0x40010000UL)
#define TIM2 ((tim_t *)0x40000000UL)
#define TIM3 ((tim_t *)0x40000400UL)
#define TIM4 ((tim_t *)0x40000800UL)
#define TIM5 ((tim_t *)0x40000C00UL)

#define TIM_CR1_CEN             (1UL << 0)
#define TIM_CR1_ARPE            (1UL << 7)
#define TIM_EGR_UG              (1UL << 0)
#define TIM_CCER_CC3E           (1UL << 8)
#define TIM_CCMR2_OC3M_PWM1     (6UL << 4)
#define TIM_CCMR2_OC3PE         (1UL << 3)

/* ------------------------------------------------------------------ IRQn ---*/

typedef enum {
    IRQ_EXTI0       = 6,
    IRQ_EXTI1       = 7,
    IRQ_EXTI9_5     = 23,
    IRQ_TIM2        = 28,
    IRQ_TIM3        = 29,
    IRQ_TIM4        = 30,
    IRQ_SPI1        = 35,
    IRQ_USART1      = 37,
    IRQ_USART2      = 38,
    IRQ_EXTI15_10   = 40,
    IRQ_TIM5        = 50,
    IRQ_OTG_FS      = 67,
    IRQ_USART6      = 71,
} irqn_t;

static inline void nvic_enable(irqn_t irq)
{
    NVIC->ISER[(uint32_t)irq >> 5] = 1UL << ((uint32_t)irq & 31);
}

static inline void nvic_disable(irqn_t irq)
{
    NVIC->ICER[(uint32_t)irq >> 5] = 1UL << ((uint32_t)irq & 31);
}

static inline void nvic_priority(irqn_t irq, uint8_t prio)
{
    NVIC->IPR[(uint32_t)irq] = (uint8_t)(prio << 4);   /* 4 bits implemented */
}

/* --------------------------------------------------------------- barriers --*/

static inline void dsb(void) { __asm__ volatile ("dsb 0xF" ::: "memory"); }
static inline void isb(void) { __asm__ volatile ("isb 0xF" ::: "memory"); }
static inline void wfi(void) { __asm__ volatile ("wfi"); }
static inline void nop(void) { __asm__ volatile ("nop"); }

static inline uint32_t irq_save(void)
{
    uint32_t pm;
    __asm__ volatile ("mrs %0, primask; cpsid i" : "=r" (pm) :: "memory");
    return pm;
}

static inline void irq_restore(uint32_t pm)
{
    __asm__ volatile ("msr primask, %0" :: "r" (pm) : "memory");
}

#endif /* STM32F411_H */
