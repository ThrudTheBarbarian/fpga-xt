/*
 * pokey_timer.h — POKEY's four frequency dividers and their interrupts.
 *
 * POKEY stays in HARDWARE in the shipping design; this exists because a whole
 * cluster of ACID800 tests cannot run without it (pokey_timerirq,
 * pokey_timertiming, pokey_timergranularity, pokey_irqtiming, pokey_addrmirror
 * and more).  It is the DIVIDER and IRQ path only — no audio.
 *
 * Structure, all of which the tests probe:
 *
 *  - a base clock of 64 kHz or 15 kHz, selected by AUDCTL bit 0.  At the 1.79
 *    MHz machine clock those are one tick every 28 and every 114 cycles.
 *  - channels 1 and 3 can instead run straight off 1.79 MHz (AUDCTL bits 6 and
 *    5), which is what makes single-cycle timer resolution possible.
 *  - channels can be LINKED into 16-bit pairs — 2+1 by AUDCTL bit 4, 4+3 by
 *    bit 3 — where the low channel's underflow clocks the high one.
 *  - IRQEN/IRQST share address $D20E.  IRQST reads back ACTIVE-LOW, and a bit
 *    written to zero in IRQEN both masks and CLEARS the corresponding request.
 *  - STIMER ($D209) resets all four dividers together.
 */
#ifndef POKEY_TIMER_H
#define POKEY_TIMER_H

#include <stdint.h>

#define POKEY_IRQ_TIMER1 0x01
#define POKEY_IRQ_TIMER2 0x02
#define POKEY_IRQ_TIMER4 0x04

typedef struct {
    uint8_t  audf[4];      /* $D200/2/4/6 */
    uint8_t  audctl;       /* $D208 */
    uint8_t  irqen;        /* $D20E write */
    uint8_t  irqst;        /* $D20E read, ACTIVE LOW */
    unsigned long cycles;  /* free-running machine-cycle counter.  The base
                            * divider is a TAP off this, not something STIMER
                            * reloads, so a tick's phase is fixed by the absolute
                            * cycle and the delay to the FIRST interrupt after
                            * STIMER is a phase rather than a period. */
    int      cnt[4];       /* the four dividers */
    uint8_t  irq;          /* the /IRQ line to the CPU */
    uint8_t  init;         /* SKCTL[1:0] == 0: dividers held */
} pokey_timer;

void    pokey_timer_reset(pokey_timer *p);
/* SKCTL's init state ($D20F bits 1:0 == 0) holds the base clock divider as well
 * as the poly counters, and RELEASING it restarts the divider from zero.
 * pokey_inittiming measures the first 15 kHz interrupt from the SKCTL write, not
 * from STIMER, so without this the phase is wherever it happened to be. */
void    pokey_timer_skctl(pokey_timer *p, uint8_t val);
void    pokey_timer_tick(pokey_timer *p);          /* one machine cycle */
void    pokey_timer_write(pokey_timer *p, uint16_t addr, uint8_t val);
uint8_t pokey_timer_irqst(const pokey_timer *p);

#endif /* POKEY_TIMER_H */
