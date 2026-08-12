/* freqcount.c — a frequency counter on PA0, for bringing up other people's clocks.
 *
 * TIM5 is a 32-bit counter clocked from its own TI1 input rather than the
 * internal clock, so it simply tallies edges on PA0.  Gate that over a known
 * interval and the count is the frequency.  At 24 MHz over 100 ms that is 2.4M
 * edges — comfortable in 32 bits, and resolution is 10 Hz.
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

#define GATE_MS     100U
#define FREQ_PIN    0                       /* PA0 = TIM5_CH1, AF2 */

/* SMCR fields */
#define SMCR_SMS_EXT_CLK1   (7UL << 0)      /* external clock mode 1 */
#define SMCR_TS_TI1FP1      (5UL << 4)

void freqcount_init(void)
{
    RCC->AHB1ENR |= RCC_AHB1ENR_GPIOA;
    RCC->APB1ENR |= RCC_APB1ENR_TIM5;

    gpio_af(GPIOA, FREQ_PIN, AF_TIM3_TIM5);
    gpio_pull(GPIOA, FREQ_PIN, GPIO_PULL_NONE);

    TIM5->PSC   = 0;
    TIM5->ARR   = 0xFFFFFFFFUL;
    TIM5->CCMR1 = (1UL << 0);               /* CC1S = 01: IC1 mapped to TI1 */
    TIM5->CCER  = 0;                        /* rising edge, not inverted    */
    TIM5->SMCR  = SMCR_TS_TI1FP1 | SMCR_SMS_EXT_CLK1;
    TIM5->EGR   = TIM_EGR_UG;
    TIM5->CR1  |= TIM_CR1_CEN;
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

    gpio_af(GPIOA, FREQ_PIN, AF_TIM3_TIM5);
    gpio_pull(GPIOA, FREQ_PIN, GPIO_PULL_DOWN);
    clock_delay_us(10);

    before = TIM5->CNT;
    for (unsigned i = 0; i < edges; i++) {
        gpio_pull(GPIOA, FREQ_PIN, GPIO_PULL_UP);
        clock_delay_us(3);
        gpio_pull(GPIOA, FREQ_PIN, GPIO_PULL_DOWN);
        clock_delay_us(3);
    }
    after = TIM5->CNT;

    /* leave it floating so it does not load whatever gets probed next */
    gpio_pull(GPIOA, FREQ_PIN, GPIO_PULL_NONE);
    return after - before;
}

uint32_t freqcount_measure(void)
{
    /* re-arm: the gpio command can have left PA0 as a plain output */
    gpio_af(GPIOA, FREQ_PIN, AF_TIM3_TIM5);
    gpio_pull(GPIOA, FREQ_PIN, GPIO_PULL_NONE);

    uint32_t start_cnt = TIM5->CNT;
    uint32_t start_ms  = clock_millis();

    while ((uint32_t)(clock_millis() - start_ms) < GATE_MS)
        ;

    uint32_t edges = TIM5->CNT - start_cnt;
    uint32_t ms    = clock_millis() - start_ms;

    if (ms == 0)
        return 0;
    return edges * (1000U / ms);            /* GATE_MS divides 1000 exactly */
}
