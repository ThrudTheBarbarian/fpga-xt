/* freqcount.c — a frequency counter on a joystick port, for bringing up other
 * people's clocks.
 *
 * TIM4 is clocked from its own TI1 input rather than the internal clock, so it
 * simply tallies edges on PD12.  Gate that over a known interval and the count
 * is the frequency.
 *
 * Which pin depends on what you can physically reach on an assembled board, so
 * there is a choice.  Each entry is a timer whose CH1 can act as the external
 * clock input, on a pin that goes somewhere probeable:
 *
 *   d12  PD12  TIM4_CH1  joystick port IRR, DE-9 pin 4 (gnd on pin 8)
 *   a0   PA0   TIM5_CH1  unrouted LQFP lead; needs soldering, last resort
 *
 * PE5/TIM9_CH1 looked like a third option (the SIO DIN's vestigial CLK_IN) and
 * is not: TIM9 accepts SMS=111 in SMCR and even raises TIF on the trigger, but
 * the counter never advances — external clock mode 1 is not actually
 * implemented on that timer.  Measured, not assumed.
 *
 * The pin is claimed only for the duration of a measurement and handed straight
 * back, so the port it belongs to keeps working the rest of the time.
 *
 * The timers are 16-bit (TIM4/TIM9), so the gate is sized to keep 24 MHz inside
 * 65535 counts.
 *
 * This exists because a handheld DMM cannot help you here: most cap out around
 * 1 MHz, and their input capacitance loads an oscillator node badly enough to
 * stop it.  A short wire to PA0 is a lighter load than a meter lead, though it
 * is still a load — probe the *driven* side of a crystal (the oscillator's
 * output pin) rather than the high-impedance input side, because that one can
 * usually survive the extra picofarads.
 */
#include "freqcount.h"

#include "board.h"
#include "clock.h"

/* 2 ms holds 24 MHz to 48000 counts — inside TIM4's 16 bits, with headroom to
 * ~32 MHz.  Resolution is 500 Hz, which is ample for "is this clock alive and
 * roughly right". */
#define GATE_MS     2U

struct source {
    const char *name;
    gpio_t     *port;
    uint8_t     pin;
    uint8_t     af;
    tim_t      *tim;
    uint32_t    apb1_bit;               /* 0 => it is an APB2 timer */
    uint32_t    apb2_bit;
    uint8_t     pull_idle;              /* what to restore when released */
    const char *where;
};

static const struct source s_sources[] = {
    { "d12", GPIOD, PIN_IRR_RT, AF_TIM3_TIM5, TIM4, RCC_APB1ENR_TIM4, 0,
      GPIO_PULL_UP,   "joystick IRR, DE-9 pin 4" },
    { "a0",  GPIOA, 0,           AF_TIM3_TIM5, TIM5, RCC_APB1ENR_TIM5, 0,
      GPIO_PULL_NONE, "PA0, unrouted pin" },
};

static const struct source *s_src = &s_sources[0];

#define FREQ_PIN    (s_src->pin)
#define FREQ_PORT   (s_src->port)
#define FREQ_TIM    (s_src->tim)

/* SMCR fields */
#define SMCR_SMS_EXT_CLK1   (7UL << 0)      /* external clock mode 1 */
#define SMCR_TS_TI1FP1      (5UL << 4)

void freqcount_init(void)
{
    RCC->AHB1ENR |= RCC_AHB1ENR_GPIOA | RCC_AHB1ENR_GPIOD | RCC_AHB1ENR_GPIOE;

    if (s_src->apb1_bit)
        RCC->APB1ENR |= s_src->apb1_bit;
    else
        RCC->APB2ENR |= s_src->apb2_bit;

    FREQ_TIM->PSC   = 0;
    FREQ_TIM->ARR   = 0xFFFFU;
    FREQ_TIM->CCMR1 = (1UL << 0);           /* CC1S = 01: IC1 mapped to TI1 */
    FREQ_TIM->CCER  = 0;                    /* rising edge, not inverted    */
    FREQ_TIM->SMCR  = SMCR_TS_TI1FP1 | SMCR_SMS_EXT_CLK1;
    FREQ_TIM->EGR   = TIM_EGR_UG;
    FREQ_TIM->CR1  |= TIM_CR1_CEN;
}

int freqcount_select(const char *name)
{
    for (unsigned i = 0; i < sizeof s_sources / sizeof s_sources[0]; i++) {
        if (name[0] == s_sources[i].name[0] &&
            name[1] == s_sources[i].name[1]) {
            s_src = &s_sources[i];
            freqcount_init();
            return 1;
        }
    }
    return 0;
}

const char *freqcount_pin(void)   { return s_src->name; }
const char *freqcount_where(void) { return s_src->where; }

static void claim_pin(void)
{
    gpio_af(FREQ_PORT, FREQ_PIN, s_src->af);
    gpio_pull(FREQ_PORT, FREQ_PIN, GPIO_PULL_NONE);
}

static void release_pin(void)
{
    gpio_mode(FREQ_PORT, FREQ_PIN, GPIO_MODE_IN);
    gpio_pull(FREQ_PORT, FREQ_PIN, s_src->pull_idle);
}

/* Prove the counter before trusting what it says about someone else's clock.
 *
 * The pin has to stay in AF mode for TIM5 to see it at all — the alternate
 * function input is NOT live while MODER says output, which was measured on
 * this board: driving PA0 as a GPIO output toggles the pad but TIM5 counts
 * nothing.  So the stimulus comes from the internal pull-up/pull-down instead,
 * which still applies in AF mode.  Roughly 40k into a few pF settles in well
 * under a microsecond, so a 3 us dwell is generous.
 */
uint32_t freqcount_selftest(unsigned edges)
{
    uint16_t before, after;

    claim_pin();
    gpio_pull(FREQ_PORT, FREQ_PIN, GPIO_PULL_DOWN);
    clock_delay_us(10);

    before = (uint16_t)FREQ_TIM->CNT;
    for (unsigned i = 0; i < edges; i++) {
        gpio_pull(FREQ_PORT, FREQ_PIN, GPIO_PULL_UP);
        clock_delay_us(3);
        gpio_pull(FREQ_PORT, FREQ_PIN, GPIO_PULL_DOWN);
        clock_delay_us(3);
    }
    after = (uint16_t)FREQ_TIM->CNT;

    release_pin();
    return (uint16_t)(after - before);
}

uint32_t freqcount_measure(void)
{
    claim_pin();

    /* Gate on the cycle counter, not milliseconds: at a 2 ms gate a whole
     * SysTick of jitter would be a 50% error. */
    uint32_t gate  = GATE_MS * (SYSCLK_HZ / 1000UL);
    uint32_t t0    = clock_cycles();
    uint16_t c0    = (uint16_t)FREQ_TIM->CNT;

    while ((clock_cycles() - t0) < gate)
        ;

    uint16_t c1    = (uint16_t)FREQ_TIM->CNT;
    uint32_t took  = clock_cycles() - t0;

    release_pin();

    uint32_t edges = (uint16_t)(c1 - c0);
    return (uint32_t)(((uint64_t)edges * SYSCLK_HZ) / took);
}
