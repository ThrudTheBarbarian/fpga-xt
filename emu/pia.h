/*
 * pia.h — the 6520 PIA at $D300.
 *
 * Two 8-bit ports, each with a DATA DIRECTION register that shares its address
 * with the port itself: PACTL/PBCTL bit 2 selects which one $D300/$D301 reaches.
 * That aliasing is the whole of pia_basic's "crosstalk" checks — it writes the
 * direction register, flips the control bit, writes the output register, flips
 * back, and requires the direction register to have kept its own value.
 *
 * A bit set in the direction register makes that pin an OUTPUT, so a read
 * returns the output latch for those bits and the external line for the rest.
 * With no peripherals attached the joystick lines idle high.
 */
#ifndef PIA_H
#define PIA_H

#include <stdint.h>

typedef struct {
    uint8_t out[2];    /* output latches, A and B */
    uint8_t ddr[2];    /* direction: 1 = output */
    uint8_t ctl[2];    /* PACTL, PBCTL */
    uint8_t in[2];     /* external lines; idle high with nothing plugged in */
    uint8_t irq;       /* the /IRQ line to the CPU */
} pia;

void    pia_reset(pia *p);
uint8_t pia_read(pia *p, uint16_t addr);
void    pia_write(pia *p, uint16_t addr, uint8_t val);

#endif /* PIA_H */
