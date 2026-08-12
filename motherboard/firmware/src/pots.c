/* pots.c — eight paddle pots, read the way the real machine does.
 *
 * An Atari paddle is not an ADC input: it is a 1 MOhm pot charging a capacitor,
 * and the machine counts scanlines until the voltage crosses a threshold.  We
 * do the same — discharge the cap by driving the pin low, release it to a
 * floating input, and time how long it takes the RC to climb through the GPIO
 * Schmitt threshold.  The count maps onto POKEY's 0..228.
 *
 * Sampled on a timer event, not by input capture.  Input capture is not
 * available anyway — PC8/PC9 (fan) expose exactly one timer function each, both
 * on TIM3, and PB0/PB1's only other timer option is TIM1_CH2N/CH3N, which are
 * complementary outputs with no capture path (DocID026289 Rev 7, Table 8).  But
 * a periodic sample is the better fit regardless: one TIM2 tick reads all eight
 * pots at once from a single IDR, so they share a time base exactly, and the
 * cadence is immune to whatever the main loop is doing.  That last property is
 * what matters once USB host is running — main-loop polling would let enumeration
 * and HID transfers jitter straight into paddle values.
 *
 * All eight pins are on GPIOB, so discharge (one BSRR write) and release (one
 * MODER write) are simultaneous for every pot — they share a common t0.
 */
#include "pots.h"

#include "board.h"

#define DISCHARGE_US    500U                /* pin drives ~25 ohm; plenty */
#define POT_MAX         228U                /* POKEY full scale */

/* Sample rate.  A full-scale charge is ~33 ms with the stock 1 MOhm x 47 nF, so
 * 20 kHz gives ~660 steps across the range — comfortably finer than the 228
 * POKEY levels, with room to spare if the cap is ever shrunk.  The ISR is a
 * couple of dozen cycles, so this costs well under 1% of the core. */
#define TICK_HZ         20000U
#define US_PER_TICK     (1000000U / TICK_HZ)
#define DISCHARGE_TICKS (DISCHARGE_US / US_PER_TICK)

static const uint8_t s_pin[POT_COUNT] = {
    [POT_ILL_A] = PIN_ILL_POTA, [POT_ILL_B] = PIN_ILL_POTB,
    [POT_IL_A]  = PIN_IL_POTA,  [POT_IL_B]  = PIN_IL_POTB,
    [POT_IR_A]  = PIN_IR_POTA,  [POT_IR_B]  = PIN_IR_POTB,
    [POT_IRR_A] = PIN_IRR_POTA, [POT_IRR_B] = PIN_IRR_POTB,
};

enum { ST_DISCHARGE, ST_CHARGE };

static volatile int      s_state;
static volatile uint32_t s_ticks;           /* ticks since entering the state */
static volatile uint32_t s_pending;         /* pin-mask still charging */
static volatile uint32_t s_us[POT_COUNT];   /* last completed measurement */
static volatile uint8_t  s_value[POT_COUNT];
/* Endpoints derived from the documented network rather than guessed: the
 * carrier fits 1K series + 47 nF per pot line, the pot is 1 MOhm, and the wiper
 * rail is **+5 V** (DE-9 pin 7) — see docs/Zynq/zynq-parameters.md.  Charging
 * toward 5 V, the 3.3 V-domain Schmitt threshold (~1.8 V) is crossed at
 * t = RC * ln(5 / (5 - 1.8)) ~= 0.45 RC.
 *
 *   pot at 0:    RC = 1K    * 47nF = 47 us   -> ~21 us
 *   pot at max:  RC = 1M+1K * 47nF = 47 ms   -> ~21 ms
 *
 * An earlier 0..33000 assumed the line charged toward 3.3 V, which it does not.
 * Still worth confirming against a real paddle with `pot cal`. */
static uint32_t s_cal_min_us = 21;
static uint32_t s_cal_max_us = 21000;
static volatile uint32_t s_frames;

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
    s_ticks = 0;

    /* TIM2 free-runs at TICK_HZ purely as an event source — no channel, no
     * pin, so it does not compete with the fan for TIM3. */
    RCC->APB1ENR |= RCC_APB1ENR_TIM2;
    TIM2->PSC = 0;
    TIM2->ARR = (APB1_TIMER_HZ / TICK_HZ) - 1U;
    TIM2->EGR = TIM_EGR_UG;
    TIM2->SR  = 0;
    TIM2->DIER |= TIM_DIER_UIE;
    TIM2->CR1 |= TIM_CR1_CEN;

    /* Below the fan and console interrupts: a late paddle tick costs
     * resolution, whereas a late USB tick costs an enumeration. */
    nvic_priority(IRQ_TIM2, 10);
    nvic_enable(IRQ_TIM2);
}

static uint8_t to_pokey(uint32_t us)
{
    uint32_t lo = s_cal_min_us;
    uint32_t hi = s_cal_max_us;

    if (hi <= lo || us >= hi)
        return POT_MAX;
    if (us <= lo)
        return 0;
    return (uint8_t)(((us - lo) * POT_MAX) / (hi - lo));
}

/* One TIM2 tick.  Everything the measurement needs happens here, so the sample
 * cadence does not depend on the main loop being free. */
void tim2_handler(void)
{
    if (!(TIM2->SR & TIM_SR_UIF))
        return;
    TIM2->SR = ~TIM_SR_UIF;

    s_ticks++;

    if (s_state == ST_DISCHARGE) {
        if (s_ticks < DISCHARGE_TICKS)
            return;
        release();
        s_ticks   = 0;
        s_pending = POT_MASK;
        s_state   = ST_CHARGE;
        return;
    }

    /* ST_CHARGE: one IDR read services every pot still climbing, so all eight
     * are measured against the same t0 and the same tick. */
    uint32_t crossed = s_pending & GPIO_POTS->IDR;
    uint32_t elapsed = s_ticks * US_PER_TICK;

    if (crossed) {
        for (int i = 0; i < POT_COUNT; i++) {
            if (crossed & (1UL << s_pin[i])) {
                s_us[i]    = elapsed;
                s_value[i] = to_pokey(elapsed);
            }
        }
        s_pending &= ~crossed;
    }

    /* A disconnected pot never crosses; time out at full scale rather than
     * stretching the sweep waiting for it. */
    if (s_pending && elapsed < s_cal_max_us + s_cal_max_us / 8U)
        return;

    for (int i = 0; i < POT_COUNT; i++) {
        if (s_pending & (1UL << s_pin[i])) {
            s_us[i]    = elapsed;
            s_value[i] = POT_MAX;
        }
    }

    s_frames++;
    drive_low();
    s_ticks = 0;
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
    return s_us[pot];
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
