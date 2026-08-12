/* clock.c — PLL bring-up and the millisecond time base.
 *
 * 8 MHz HSE (Y1) -> /M 4 -> 2 MHz -> xN 192 -> 384 MHz VCO
 *                -> /P 4 -> 96 MHz SYSCLK
 *                -> /Q 8 -> 48 MHz OTG-FS
 *
 * 96 MHz, not the 100 MHz maximum: 100 has no divisor giving a legal 48 MHz
 * USB clock, and USB host is the whole point of this MCU.
 */
#include "clock.h"
#include "board.h"

static volatile uint32_t s_millis;
static uint32_t          s_reset_cause;
static int               s_on_hse;

/* PLLCFGR field packing, RM0383 §6.3.2 */
#define PLL_M(m)        ((uint32_t)(m) & 0x3F)
#define PLL_N(n)        (((uint32_t)(n) & 0x1FF) << 6)
#define PLL_P_DIV4      (1UL << 16)             /* 00=/2 01=/4 10=/6 11=/8 */
#define PLL_SRC_HSE     (1UL << 22)
#define PLL_Q(q)        (((uint32_t)(q) & 0xF) << 24)

#define CFGR_PPRE1_DIV2 (4UL << 10)
#define CFGR_PPRE2_DIV1 (0UL << 13)

/* long enough for a cold crystal to start, short enough not to look hung */
#define HSE_TIMEOUT     100000UL

void clock_init(void)
{
    /* latch and clear the reset cause before anything else disturbs it */
    s_reset_cause  = RCC->CSR;
    RCC->CSR      |= RCC_CSR_RMVF;

    RCC->APB1ENR |= RCC_APB1ENR_PWR;
    PWR->CR      |= PWR_CR_VOS_SCALE1;          /* scale 1 required above 84 MHz */

    RCC->CR |= RCC_CR_HSEON;
    uint32_t spin = HSE_TIMEOUT;
    while (!(RCC->CR & RCC_CR_HSERDY) && --spin)
        ;

    s_on_hse = (spin != 0);
    if (s_on_hse) {
        /* 8 MHz / 4 = 2 MHz reference */
        RCC->PLLCFGR = PLL_M(4) | PLL_N(192) | PLL_P_DIV4 | PLL_SRC_HSE | PLL_Q(8);
    } else {
        /* No crystal: keep running off the 16 MHz HSI so the console still
         * comes up and the REPL can report the failure.  USB will not be
         * spec-compliant on HSI, so usb_init() refuses to start (see usb.c). */
        RCC->CR &= ~RCC_CR_HSEON;
        RCC->PLLCFGR = PLL_M(8) | PLL_N(192) | PLL_P_DIV4 | PLL_Q(8);
    }

    RCC->CR |= RCC_CR_PLLON;
    while (!(RCC->CR & RCC_CR_PLLRDY))
        ;

    /* wait states before raising the clock, never after */
    FLASH->ACR = FLASH_ACR_LATENCY(3) | FLASH_ACR_PRFTEN |
                 FLASH_ACR_ICEN | FLASH_ACR_DCEN;

    RCC->CFGR = (RCC->CFGR & ~(0xFFUL << 4)) | CFGR_PPRE1_DIV2 | CFGR_PPRE2_DIV1;

    RCC->CFGR = (RCC->CFGR & ~RCC_CFGR_SW_MASK) | RCC_CFGR_SW_PLL;
    while ((RCC->CFGR & RCC_CFGR_SWS_MASK) != RCC_CFGR_SWS_PLL)
        ;

    /* 1 kHz tick */
    SYSTICK->LOAD = (SYSCLK_HZ / 1000UL) - 1UL;
    SYSTICK->VAL  = 0;
    SYSTICK->CTRL = 7;                          /* clksource=AHB, tickint, enable */

    /* free-running cycle counter — the time base for the paddle RC reads */
    DEMCR    |= (1UL << 24);                    /* TRCENA */
    DWT_CYCCNT = 0;
    DWT_CTRL |= 1UL;                            /* CYCCNTENA */

    /* Keep the debug clocks running through WFI.  Without this the first wfi()
     * — in clock_delay_ms(), or the park loop after a fault — gates the debug
     * domain and the probe loses the target mid-session ("SWD scan failed",
     * recoverable only by connecting under reset).  The extra sleep current is
     * irrelevant on a mains-powered motherboard. */
    DBGMCU_CR |= DBGMCU_CR_SLEEP | DBGMCU_CR_STOP | DBGMCU_CR_STANDBY;
}

void systick_handler(void)
{
    s_millis++;
}

uint32_t clock_millis(void)
{
    return s_millis;
}

uint32_t clock_cycles(void)
{
    return DWT_CYCCNT;
}

void clock_delay_us(uint32_t us)
{
    uint32_t start = DWT_CYCCNT;
    uint32_t want  = us * (SYSCLK_HZ / 1000000UL);
    while ((DWT_CYCCNT - start) < want)
        ;
}

void clock_delay_ms(uint32_t ms)
{
    uint32_t start = s_millis;
    while ((uint32_t)(s_millis - start) < ms)
        wfi();
}

/* MCO1 on PA8 = PLLCLK / 4 = exactly 24 MHz.
 *
 * That is the USB2514B's reference frequency, and PA8 is otherwise unused — so
 * if the hub's crystal is missing or wrong, one wire from PA8 to the crystal's
 * XTALIN pad clocks the hub from our PLL instead.  Accuracy is set by the 8 MHz
 * crystal (+/-10 ppm), far inside the hub's +/-350 ppm requirement.
 *
 * Left enabled by default: PA8 goes nowhere on an unmodified board, so this
 * costs nothing, and it means the wire is all that is needed.
 */
void clock_mco_24mhz(int on)
{
    RCC->AHB1ENR |= RCC_AHB1ENR_GPIOA;

    if (!on) {
        gpio_mode(GPIOA, 8, GPIO_MODE_IN);
        return;
    }

    /* MCO1 = PLL (0b11 << 21), MCO1PRE = /4 (0b110 << 24) */
    RCC->CFGR = (RCC->CFGR & ~((3UL << 21) | (7UL << 24))) |
                (3UL << 21) | (6UL << 24);

    /* Medium speed on purpose: driving the hub's 18 pF load cap with the
     * fastest edges would draw ~30 mA peaks for no benefit at 24 MHz. */
    gpio_af(GPIOA, 8, 0);                       /* MCO1 is AF0 */
    gpio_speed(GPIOA, 8, GPIO_SPEED_MED);
    gpio_pull(GPIOA, 8, GPIO_PULL_NONE);
}

int clock_mco_enabled(void)
{
    return ((RCC->CFGR >> 21) & 3UL) == 3UL &&
           ((GPIOA->MODER >> 16) & 3UL) == GPIO_MODE_AF;
}

uint32_t clock_reset_cause(void)
{
    return s_reset_cause;
}

int clock_on_hse(void)
{
    return s_on_hse;
}

const char *clock_reset_cause_str(void)
{
    uint32_t c = s_reset_cause;
    if (c & RCC_CSR_LPWRRSTF) return "low-power";
    if (c & RCC_CSR_WWDGRSTF) return "window-watchdog";
    if (c & RCC_CSR_IWDGRSTF) return "independent-watchdog";
    if (c & RCC_CSR_SFTRSTF)  return "software";
    if (c & RCC_CSR_PORRSTF)  return "power-on";
    if (c & RCC_CSR_PINRSTF)  return "nrst-pin";
    if (c & RCC_CSR_BORRSTF)  return "brown-out";
    return "unknown";
}

void clock_reboot(void)
{
    dsb();
    SCB->AIRCR = SCB_AIRCR_SYSRESETREQ;
    dsb();
    for (;;)
        ;
}
