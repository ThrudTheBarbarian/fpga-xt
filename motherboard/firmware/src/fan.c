/* fan.c — 4-wire fan: 25 kHz PWM out, tachometer in, PID to a target RPM.
 *
 * PWM is TIM3_CH3 on PC8 (through R67, 220R, to J3 pin 4).  The tachometer on
 * PC9 is counted with EXTI9 rather than TIM3_CH4 input capture — TIM3 is busy
 * generating a 40 us PWM period, so a capture unit on the same timer would see
 * hundreds of overflows per tach pulse.  Edge counting over a fixed window is
 * both simpler and entirely adequate: a fan turns at ~500-3000 RPM, which is
 * 17-100 Hz at the usual two pulses per revolution.
 *
 * Note this is why the paddles do not use TIM3/TIM4 input capture either — see
 * pots.c.  One compare unit cannot serve both PC8 and PB0.
 */
#include "fan.h"

#include "board.h"
#include "clock.h"

#define PWM_HZ          25000U              /* 4-wire fan spec: 21-28 kHz */
#define PWM_TOP         (APB1_TIMER_HZ / PWM_HZ)    /* 3840 at 96 MHz */
#define TACH_PPR        2U                  /* pulses per revolution */
#define UPDATE_MS       250U                /* PID period and tach window */

/* PID gains, Q10 fixed point, all in "per mille of duty per RPM of error".
 *
 * The integrator carries the whole steady-state term, because proportional
 * gain alone cannot: holding 2500 RPM needs ~50% duty, and at any sane Kp the
 * error required to synthesise that from the P term would be thousands of RPM.
 * So the integral is stored directly in Q10 duty units and clamped to the
 * actual output range — which makes anti-windup exact rather than a guess at a
 * magic limit.
 */
#define KP_Q10          102                 /* 0.10 duty per RPM of error */
#define KI_Q10          20                  /* 0.02 duty per RPM per sample */
#define KD_Q10          30                  /* 0.03 duty per RPM per sample */
#define DUTY_MAX        1000
#define INTEGRAL_LIMIT  (DUTY_MAX << 10)

/* A 5 V fan will not start, and its tach will read zero, below roughly a fifth
 * of full duty — and a zero tach reading looks to the loop exactly like a fan
 * that needs more power, so it would chase itself.  Floor the closed-loop
 * output above the stall point. */
#define DUTY_MIN_CLOSED 150

/* Thermal curve.  The Zynq's XADC junction temperature arrives over the SPI
 * link (the A9 pushes it; we cannot ask for it — we are the SPI slave, and a
 * slave cannot initiate).  Below LO the fan sits at a quiet floor; between LO
 * and HI the target ramps linearly; above HI the PID is bypassed entirely and
 * the fan goes to full duty, because at that point airflow matters more than
 * hitting a number.
 */
#define TEMP_LO_C       55U
#define TEMP_HI_C       70U
#define TEMP_RPM_LO     1200U
#define TEMP_RPM_HI     4500U

/* If the A9 stops sending temperatures, assume the worst.  The Zynq locks up
 * without cooling, so a silent sender must mean full speed, not last-known. */
#define TEMP_STALE_MS   10000U

static volatile uint32_t s_tach_edges;
static uint32_t          s_last_update;
static uint32_t          s_rpm;
static int32_t           s_integral;
static int32_t           s_prev_error;
static uint16_t          s_target_rpm;
static uint16_t          s_duty;            /* per mille, 0..1000 */
static int               s_closed_loop;
static volatile uint8_t  s_temp_c;
static volatile uint32_t s_temp_ms;
static int               s_temp_valid;
static int               s_thermal;

static void set_duty_raw(uint16_t per_mille)
{
    if (per_mille > 1000U)
        per_mille = 1000U;
    s_duty      = per_mille;
    TIM3->CCR[2] = (uint32_t)per_mille * PWM_TOP / 1000U;
}

void fan_init(void)
{
    RCC->AHB1ENR |= RCC_AHB1ENR_GPIOC;
    RCC->APB1ENR |= RCC_APB1ENR_TIM3;
    RCC->APB2ENR |= RCC_APB2ENR_SYSCFG;

    /* --- PWM out on PC8 = TIM3_CH3 --- */
    gpio_af(GPIO_FAN, PIN_FAN_PWM, AF_TIM3_TIM5);
    gpio_speed(GPIO_FAN, PIN_FAN_PWM, GPIO_SPEED_MED);

    TIM3->PSC   = 0;
    TIM3->ARR   = PWM_TOP - 1U;
    TIM3->CCMR2 = TIM_CCMR2_OC3M_PWM1 | TIM_CCMR2_OC3PE;
    TIM3->CCER |= TIM_CCER_CC3E;
    TIM3->CR1  |= TIM_CR1_ARPE;
    TIM3->EGR   = TIM_EGR_UG;               /* latch PSC/ARR/CCR */
    TIM3->CR1  |= TIM_CR1_CEN;

    set_duty_raw(1000);                     /* full tilt until told otherwise */

    /* --- tach in on PC9 = EXTI9, falling edge, pulled up ---
     * The tach output is open-collector inside the fan, hence the pull-up the
     * schematic note asks for. */
    gpio_mode(GPIO_FAN, PIN_FAN_TACH, GPIO_MODE_IN);
    gpio_pull(GPIO_FAN, PIN_FAN_TACH, GPIO_PULL_UP);

    SYSCFG->EXTICR[2] = (SYSCFG->EXTICR[2] & ~(0xFUL << 4)) | (2UL << 4);  /* port C */
    EXTI->FTSR |= (1UL << PIN_FAN_TACH);
    EXTI->RTSR &= ~(1UL << PIN_FAN_TACH);
    EXTI->PR    = (1UL << PIN_FAN_TACH);
    EXTI->IMR  |= (1UL << PIN_FAN_TACH);

    nvic_priority(IRQ_EXTI9_5, 12);
    nvic_enable(IRQ_EXTI9_5);

    s_last_update = clock_millis();
    s_target_rpm  = 0;
    s_closed_loop = 0;
}

void exti9_5_handler(void)
{
    if (EXTI->PR & (1UL << PIN_FAN_TACH)) {
        EXTI->PR = (1UL << PIN_FAN_TACH);
        s_tach_edges++;
    }
}

/* Release PC9 so it can be used for something else — notably MCO2, which puts
 * 24 MHz on the fan connector where it is far easier to reach than an LQFP pin.
 * Disabling the EXTI is not optional: 24 MHz into a falling-edge interrupt is
 * 24 million interrupts a second and the CPU would never leave the handler. */
void fan_tach_input(int on)
{
    if (on) {
        gpio_mode(GPIO_FAN, PIN_FAN_TACH, GPIO_MODE_IN);
        gpio_pull(GPIO_FAN, PIN_FAN_TACH, GPIO_PULL_UP);
        EXTI->PR   = (1UL << PIN_FAN_TACH);
        EXTI->IMR |= (1UL << PIN_FAN_TACH);
        return;
    }

    EXTI->IMR &= ~(1UL << PIN_FAN_TACH);
    EXTI->PR   = (1UL << PIN_FAN_TACH);
    gpio_pull(GPIO_FAN, PIN_FAN_TACH, GPIO_PULL_NONE);

    /* The Zynq locks up without active cooling, so losing the tachometer must
     * never mean losing airflow.  PWM on PC8 is untouched by any of this, but
     * the PID would be reading a permanent zero RPM — so pin the fan open loop
     * at full speed rather than leave a closed loop chasing a dead sensor. */
    s_closed_loop = 0;
    set_duty_raw(DUTY_MAX);
}

/* Called from the SPI interrupt when the A9 writes the temperature register.
 * Stores and timestamps only; the curve is evaluated in fan_poll(). */
void fan_set_temperature(uint8_t celsius)
{
    s_temp_c  = celsius;
    s_temp_ms = clock_millis();
}

void fan_set_thermal(int on)
{
    s_thermal = on;
    if (on)
        fan_set_target_rpm(TEMP_RPM_LO);
}

int      fan_thermal(void)     { return s_thermal; }
uint8_t  fan_temperature(void) { return s_temp_c; }
uint32_t fan_temp_age_ms(void)
{
    return s_temp_valid ? (clock_millis() - s_temp_ms) : 0xFFFFFFFFUL;
}

/* temperature -> target RPM, piecewise linear between LO and HI */
static uint16_t curve(uint8_t c)
{
    if (c <= TEMP_LO_C)
        return TEMP_RPM_LO;
    if (c >= TEMP_HI_C)
        return TEMP_RPM_HI;
    return (uint16_t)(TEMP_RPM_LO +
                      ((uint32_t)(c - TEMP_LO_C) * (TEMP_RPM_HI - TEMP_RPM_LO)) /
                      (TEMP_HI_C - TEMP_LO_C));
}

void fan_set_duty(uint16_t per_mille)
{
    s_closed_loop = 0;
    set_duty_raw(per_mille);
}

void fan_set_target_rpm(uint16_t rpm)
{
    s_target_rpm  = rpm;
    s_closed_loop = rpm != 0;

    /* Bumpless transfer: seed the integrator with the duty already being
     * driven, so entering closed loop nudges the fan from where it is rather
     * than slamming it to whatever the proportional term alone suggests. */
    s_integral   = (int32_t)s_duty << 10;
    s_prev_error = 0;
}

void fan_poll(void)
{
    uint32_t now = clock_millis();

    if ((uint32_t)(now - s_last_update) < UPDATE_MS)
        return;

    if (s_thermal) {
        uint32_t age = (uint32_t)(now - s_temp_ms);

        if (!s_temp_valid && s_temp_ms != 0)
            s_temp_valid = 1;

        if (!s_temp_valid || age > TEMP_STALE_MS) {
            /* no temperature, or a stale one: maximum airflow, no argument */
            s_closed_loop = 0;
            set_duty_raw(DUTY_MAX);
        } else if (s_temp_c >= TEMP_HI_C) {
            s_closed_loop = 0;
            set_duty_raw(DUTY_MAX);
        } else {
            uint16_t want = curve(s_temp_c);
            if (!s_closed_loop || want != s_target_rpm)
                fan_set_target_rpm(want);
        }
    }

    uint32_t window = now - s_last_update;
    s_last_update   = now;

    uint32_t pm    = irq_save();
    uint32_t edges = s_tach_edges;
    s_tach_edges   = 0;
    irq_restore(pm);

    /* edges/window(ms) -> RPM, rounded */
    s_rpm = (edges * 60000UL) / (TACH_PPR * window);

    if (!s_closed_loop)
        return;

    int32_t error      = (int32_t)s_target_rpm - (int32_t)s_rpm;
    int32_t derivative = error - s_prev_error;
    s_prev_error       = error;

    /* Integral lives in Q10 duty units, clamped to the output range — so it
     * can never demand more than the actuator can deliver, which is windup
     * prevention by construction rather than by a tuned limit. */
    s_integral += KI_Q10 * error;
    if (s_integral > INTEGRAL_LIMIT)
        s_integral = INTEGRAL_LIMIT;
    else if (s_integral < 0)
        s_integral = 0;

    int32_t out = ((KP_Q10 * error) >> 10) + (s_integral >> 10) +
                  ((KD_Q10 * derivative) >> 10);

    if (out < DUTY_MIN_CLOSED)
        out = DUTY_MIN_CLOSED;
    else if (out > DUTY_MAX)
        out = DUTY_MAX;

    set_duty_raw((uint16_t)out);
}

uint32_t fan_rpm(void)        { return s_rpm; }
uint16_t fan_duty(void)       { return s_duty; }
uint16_t fan_target_rpm(void) { return s_target_rpm; }
int      fan_closed_loop(void){ return s_closed_loop; }
