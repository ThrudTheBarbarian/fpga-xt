/* joystick.c — four Atari controller ports.
 *
 * The layout is a gift from the board: all sixteen direction lines are on
 * GPIOD in port order, so one IDR read samples every controller at the same
 * instant — no skew between the up and left of a diagonal, which is exactly
 * the artefact that makes a scanned joystick feel wrong.  The four fire
 * buttons sit together in the top nibble of GPIOE.
 *
 * Switches are to ground with internal pull-ups, so a closed contact reads 0;
 * everything below works in "pressed = 1" and inverts on the way in.
 */
#include "joystick.h"
#include "board.h"

#define DEBOUNCE_SAMPLES    3               /* at 1 kHz polling => 3 ms */

/* schematic bit positions within the GPIOD word, per port */
static const struct {
    uint8_t up, down, left, right, btn;
} s_map[JOY_PORTS] = {
    [JOY_ILL] = { PIN_ILL_UP, PIN_ILL_DN, PIN_ILL_LT, PIN_ILL_RT, PIN_ILL_BTN },
    [JOY_IL]  = { PIN_IL_UP,  PIN_IL_DN,  PIN_IL_LT,  PIN_IL_RT,  PIN_IL_BTN  },
    [JOY_IR]  = { PIN_IR_UP,  PIN_IR_DN,  PIN_IR_LT,  PIN_IR_RT,  PIN_IR_BTN  },
    [JOY_IRR] = { PIN_IRR_UP, PIN_IRR_DN, PIN_IRR_LT, PIN_IRR_RT, PIN_IRR_BTN },
};

static uint8_t  s_state[JOY_PORTS];
static uint32_t s_candidate;
static uint32_t s_stable;
static uint8_t  s_count;

void joystick_init(void)
{
    RCC->AHB1ENR |= RCC_AHB1ENR_GPIOD | RCC_AHB1ENR_GPIOE;

    for (unsigned i = 0; i < 16; i++) {
        gpio_mode(GPIO_JOY_DIR, i, GPIO_MODE_IN);
        gpio_pull(GPIO_JOY_DIR, i, GPIO_PULL_UP);
    }
    for (unsigned i = 12; i < 16; i++) {
        gpio_mode(GPIO_JOY_BTN, i, GPIO_MODE_IN);
        gpio_pull(GPIO_JOY_BTN, i, GPIO_PULL_UP);
    }

    /* start from "nothing pressed" rather than whatever the first read says */
    s_candidate = s_stable = 0xFFFFFFFFUL;
    s_count     = 0;
}

/* one 20-bit sample: directions in bits 0..15, buttons in 16..19 */
static uint32_t sample(void)
{
    uint32_t dirs = GPIO_JOY_DIR->IDR & JOY_DIR_MASK;
    uint32_t btns = (GPIO_JOY_BTN->IDR & JOY_BTN_MASK) >> 12;

    return dirs | (btns << 16);
}

void joystick_poll(void)
{
    uint32_t raw = sample();

    if (raw != s_candidate) {
        s_candidate = raw;
        s_count     = 0;
        return;
    }
    if (s_count < DEBOUNCE_SAMPLES && ++s_count < DEBOUNCE_SAMPLES)
        return;
    if (s_stable == s_candidate)
        return;

    s_stable = s_candidate;

    for (int p = 0; p < JOY_PORTS; p++) {
        uint32_t d = s_stable;
        uint8_t  v = 0;

        if (!((d >> s_map[p].up)    & 1U)) v |= JOY_UP;
        if (!((d >> s_map[p].down)  & 1U)) v |= JOY_DOWN;
        if (!((d >> s_map[p].left)  & 1U)) v |= JOY_LEFT;
        if (!((d >> s_map[p].right) & 1U)) v |= JOY_RIGHT;
        if (!((d >> (16 + (s_map[p].btn - 12))) & 1U)) v |= JOY_FIRE;

        s_state[p] = v;
    }
}

uint8_t joystick_state(int port)
{
    if (port < 0 || port >= JOY_PORTS)
        return 0;
    return s_state[port];
}

uint16_t joystick_raw_dirs(void)
{
    return (uint16_t)(GPIO_JOY_DIR->IDR & JOY_DIR_MASK);
}

uint16_t joystick_raw_btns(void)
{
    return (uint16_t)((GPIO_JOY_BTN->IDR & JOY_BTN_MASK) >> 12);
}
