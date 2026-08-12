/* joystick.h — see joystick.c */
#ifndef JOYSTICK_H
#define JOYSTICK_H

#include <stdint.h>

/* Port order matches the schematic net prefixes, left to right across the
 * board: ILL, IL, IR, IRR. */
enum {
    JOY_ILL = 0,
    JOY_IL,
    JOY_IR,
    JOY_IRR,
    JOY_PORTS
};

/* Atari PIA PORTA bit order for one port: bit0 up, 1 down, 2 left, 3 right.
 * Active high here (pressed = 1); the FPGA side inverts to the 6502's
 * active-low convention. */
#define JOY_UP      0x01
#define JOY_DOWN    0x02
#define JOY_LEFT    0x04
#define JOY_RIGHT   0x08
#define JOY_FIRE    0x10

void     joystick_init(void);
void     joystick_poll(void);                   /* call at least every 4 ms */
uint8_t  joystick_state(int port);              /* debounced, JOY_* bits */
uint16_t joystick_raw_dirs(void);               /* GPIOD IDR, for diagnostics */
uint16_t joystick_raw_btns(void);

#endif /* JOYSTICK_H */
