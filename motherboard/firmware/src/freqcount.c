/* freqcount.c — a frequency counter on a joystick port, for bringing up other
 * people's clocks.
 *
 * TIM4 is clocked from its own TI1 input rather than the internal clock, so it
 * simply tallies edges on PD12.  Gate that over a known interval and the count
 * is the frequency.
 *
 * PD12 is deliberate: it is IRR_RT, which lands on **pin 4 of joystick port
 * IRR** with ground on pin 8 of the same DE-9.  So anything on the board can be
 * measured by poking a wire into a connector — no soldering to a 0.5 mm-pitch
 * LQFP lead, which is otherwise the only way to reach a free pin on this part.
 * The port is restored to a joystick input as soon as the measurement ends.
 *
 * TIM4 is 16-bit, so the gate is sized to keep 24 MHz inside 65535 counts.
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
#define FREQ_PIN    PIN_IRR_RT              /* PD12 = TIM4_CH1, AF2 */
#define FREQ_PORT   GPIO_JOY_DIR

/* SMCR fields */
#define SMCR_SMS_EXT_CLK1   (7UL << 0)      /* external clock mode 1 */
#define SMCR_TS_TI1FP1      (5UL << 4)

void freqcount_init(void)
{
    RCC->AHB1ENR |= RCC_AHB1ENR_GPIOD;
    RCC->APB1ENR |= RCC_APB1ENR_TIM4;

    TIM4->PSC   = 0;
    TIM4->ARR   = 0xFFFFU;
    TIM4->CCMR1 = (1UL << 0);               /* CC1S = 01: IC1 mapped to TI1 */
    TIM4->CCER  = 0;                        /* rising edge, not inverted    */
    TIM4->SMCR  = SMCR_TS_TI1FP1 | SMCR_SMS_EXT_CLK1;
    TIM4->EGR   = TIM_EGR_UG;
    TIM4->CR1  |= TIM_CR1_CEN;
}

/* Claim PD12 from the joystick port for the duration of a measurement. */
static void claim_pin(void)
{
    gpio_af(FREQ_PORT, FREQ_PIN, AF_TIM3_TIM5);
    gpio_pull(FREQ_PORT, FREQ_PIN, GPIO_PULL_NONE);
}

static void release_pin(void)
{
    gpio_mode(FREQ_PORT, FREQ_PIN, GPIO_MODE_IN);
    gpio_pull(FREQ_PORT, FREQ_PIN, GPIO_PULL_UP);   /* joystick idle */
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
    uint32_t before, after;

    claim_pin();
    gpio_pull(FREQ_PORT, FREQ_PIN, GPIO_PULL_DOWN);
    clock_delay_us(10);

    before = TIM4->CNT;
    for (unsigned i = 0; i < edges; i++) {
        gpio_pull(FREQ_PORT, FREQ_PIN, GPIO_PULL_UP);
        clock_delay_us(3);
        gpio_pull(FREQ_PORT, FREQ_PIN, GPIO_PULL_DOWN);
        clock_delay_us(3);
    }
    after = (uint16_t)TIM4->CNT;

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
    uint16_t c0    = (uint16_t)TIM4->CNT;

    while ((clock_cycles() - t0) < gate)
        ;

    uint16_t c1    = (uint16_t)TIM4->CNT;
    uint32_t took  = clock_cycles() - t0;

    release_pin();

    uint32_t edges = (uint16_t)(c1 - c0);
    return (uint32_t)(((uint64_t)edges * SYSCLK_HZ) / took);
}
