/* pots.c — eight paddle pots, read the way the real machine does.
 *
 * An Atari paddle is not an ADC input: it is a 1 MOhm pot charging a capacitor,
 * and the machine counts scanlines until the voltage crosses a threshold.  We
 * do the same — discharge the cap by driving the pin low, release it to a
 * floating input, and time how long it takes the RC to climb through the GPIO
 * Schmitt threshold.  The count maps onto POKEY's 0..228.
 *
 * NOT timer input capture.  The obvious mapping (TIM3_CH1..4 on PB4/PB5/PB0/PB1
 * plus TIM4_CH1..4 on PB6..PB9) collides with the fan: PC8/PC9 are TIM3_CH3 and
 * TIM3_CH4, and one compare unit cannot serve two pins.  Polling GPIOB->IDR
 * against the DWT cycle counter needs no timer channels at all, samples all
 * eight pots simultaneously, and still resolves far finer than 228 steps —
 * a full-scale charge is ~33 ms, so one step is ~145 us and the main loop
 * revisits far more often than that.
 *
 * All eight pins are on GPIOB, so discharge (one BSRR write) and release (one
 * MODER write) are simultaneous for every pot — they share a common t0.
 */
#include "pots.h"

#include "board.h"
#include "clock.h"

#define DISCHARGE_US    500U                /* pin drives ~25 ohm; plenty */
#define POT_MAX         228U                /* POKEY full scale */

static const uint8_t s_pin[POT_COUNT] = {
    [POT_ILL_A] = PIN_ILL_POTA, [POT_ILL_B] = PIN_ILL_POTB,
    [POT_IL_A]  = PIN_IL_POTA,  [POT_IL_B]  = PIN_IL_POTB,
    [POT_IR_A]  = PIN_IR_POTA,  [POT_IR_B]  = PIN_IR_POTB,
    [POT_IRR_A] = PIN_IRR_POTA, [POT_IRR_B] = PIN_IRR_POTB,
};

enum { ST_DISCHARGE, ST_CHARGE };

static int      s_state;
static uint32_t s_t0;                       /* DWT cycles at state entry */
static uint32_t s_pending;                  /* pin-mask still charging */
static uint32_t s_cycles[POT_COUNT];        /* last completed measurement */
static uint8_t  s_value[POT_COUNT];
static uint32_t s_cal_min_us = 0;
static uint32_t s_cal_max_us = 33000;
static uint32_t s_frames;

#define US_TO_CYCLES(us)    ((us) * (SYSCLK_HZ / 1000000UL))

static void drive_low(void)
{
    /* MODER: two bits per pin.  Build the mask once — all eight pots live in
     * the low half of GPIOB so a single read-modify-write covers them. */
    uint32_t moder = GPIO_POTS->MODER;

    for (int i = 0; i < POT_COUNT; i++) {
        unsigned p = s_pin[i];
        moder &= ~(3UL << (p * 2));
        moder |=  ((uint32_t)GPIO_MODE_OUT << (p * 2));
    }
    GPIO_POTS->BSRR   = POT_MASK << 16;     /* all low, then switch to output */
    GPIO_POTS->MODER  = moder;
}

static void release(void)
{
    uint32_t moder = GPIO_POTS->MODER;

    for (int i = 0; i < POT_COUNT; i++)
        moder &= ~(3UL << (s_pin[i] * 2));  /* GPIO_MODE_IN == 0 */
    GPIO_POTS->MODER = moder;
}

void pots_init(void)
{
    RCC->AHB1ENR |= RCC_AHB1ENR_GPIOB;

    for (int i = 0; i < POT_COUNT; i++) {
        gpio_pull(GPIO_POTS, s_pin[i], GPIO_PULL_NONE);   /* must not fight the RC */
        gpio_speed(GPIO_POTS, s_pin[i], GPIO_SPEED_LOW);
        s_value[i] = POT_MAX;
    }

    drive_low();
    s_state = ST_DISCHARGE;
    s_t0    = clock_cycles();
}

static uint8_t to_pokey(uint32_t cycles)
{
    uint32_t lo = US_TO_CYCLES(s_cal_min_us);
    uint32_t hi = US_TO_CYCLES(s_cal_max_us);

    if (hi <= lo || cycles >= hi)
        return POT_MAX;
    if (cycles <= lo)
        return 0;
    return (uint8_t)(((cycles - lo) * POT_MAX) / (hi - lo));
}

void pots_poll(void)
{
    uint32_t now = clock_cycles();

    if (s_state == ST_DISCHARGE) {
        if ((now - s_t0) < US_TO_CYCLES(DISCHARGE_US))
            return;
        release();
        s_t0      = clock_cycles();
        s_pending = POT_MASK;
        s_state   = ST_CHARGE;
        return;
    }

    /* ST_CHARGE: one IDR read services every pot still climbing */
    uint32_t idr     = GPIO_POTS->IDR;
    uint32_t crossed = s_pending & idr;
    uint32_t elapsed = now - s_t0;

    if (crossed) {
        for (int i = 0; i < POT_COUNT; i++) {
            uint32_t bit = 1UL << s_pin[i];
            if (crossed & bit) {
                s_cycles[i] = elapsed;
                s_value[i]  = to_pokey(elapsed);
            }
        }
        s_pending &= ~crossed;
    }

    /* A disconnected pot never crosses; time out at full scale rather than
     * hanging the frame waiting for it. */
    if (s_pending && elapsed < US_TO_CYCLES(s_cal_max_us + s_cal_max_us / 8U))
        return;

    for (int i = 0; i < POT_COUNT; i++) {
        if (s_pending & (1UL << s_pin[i])) {
            s_cycles[i] = elapsed;
            s_value[i]  = POT_MAX;
        }
    }

    s_frames++;
    drive_low();
    s_t0    = clock_cycles();
    s_state = ST_DISCHARGE;
}

uint8_t pots_value(int pot)
{
    return (pot < 0 || pot >= POT_COUNT) ? POT_MAX : s_value[pot];
}

uint32_t pots_micros(int pot)
{
    if (pot < 0 || pot >= POT_COUNT)
        return 0;
    return s_cycles[pot] / (SYSCLK_HZ / 1000000UL);
}

uint32_t pots_frames(void)
{
    return s_frames;
}

void pots_calibrate(uint32_t min_us, uint32_t max_us)
{
    if (max_us > min_us) {
        s_cal_min_us = min_us;
        s_cal_max_us = max_us;
    }
}

void pots_calibration(uint32_t *min_us, uint32_t *max_us)
{
    *min_us = s_cal_min_us;
    *max_us = s_cal_max_us;
}
