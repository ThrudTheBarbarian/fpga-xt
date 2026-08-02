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
#ifndef AUDF_PIPE
#define AUDF_PIPE 2
#endif
#ifndef POKEY_TIMER_H
#define POKEY_TIMER_H

#include <stdint.h>

#define POKEY_IRQ_TIMER1 0x01
#define POKEY_IRQ_TIMER2 0x02
#define POKEY_IRQ_TIMER4 0x04
/* Serial output complete.  Unlike the timer bits this is a LEVEL, not a latched
 * event: it reads as asserted in IRQST whenever no transmission is in progress,
 * even with IRQEN's bit clear.  pokey_seroc says so in as many words — "SEROC is
 * special and should be set even when disabled" — and then re-enables it to
 * check that doing so fires an interrupt immediately. */
#define POKEY_IRQ_SEROC  0x08
/* Serial output data required: the shift register has taken the byte, so SEROUT
 * is free again.  pokey_serclock enables just this one and checks it NEVER
 * fires with the clock stopped. */
#define POKEY_IRQ_SEROR  0x10

typedef struct {
    uint8_t  audf[4];      /* $D200/2/4/6 */
    uint8_t  audctl;       /* $D208 */
    uint8_t  irqen;        /* $D20E write */
    uint8_t  irqst;        /* $D20E read, ACTIVE LOW */
    uint8_t irq_arm;       /* countdown: the /IRQ line catching up with the
                            * IRQST status bit — see raise() in the .c */
    unsigned long chain;   /* the ONE divider chain both base clocks tap.  A tick
                            * for period P happens when chain % P == 0, so the
                            * 64 kHz and 15 kHz taps keep a fixed relationship
                            * instead of being independent counters.  STIMER does
                            * not touch it; only the SKCTL release does, because
                            * init holds the chain. */
    int      cnt[4];       /* the four dividers */
    uint8_t  audf_d[4][AUDF_PIPE]; /* AUDF delay line: a reload uses the value as
                                    * it stood AUDF_PIPE ticks ago, because the
                                    * counter captures it before the underflow */
    uint8_t  audf_lo_d[2][AUDF_PIPE]; /* the same line for a linked pair's LOW
                                       * half, whose capture window follows ITS
                                       * counter rather than the pair's */
    int      lo_el[2];     /* the low half counting UP, so its period can be
                            * compared against a LIVE (delayed) AUDF — see
                            * LO_UPCOUNT in the .c */
    int      lo_first[2];  /* still on the first period after STIMER */
    int      locnt[2];     /* a LINKED pair's LOW half, which keeps its own
                            * period and raises its own interrupt — see
                            * LINK_TWO_COUNTERS in the .c */
    int      hi_lag[2];    /* ticks still owed before a linked pair's INTERRUPT
                            * edge, which is not the same event as its
                            * serial-clock edge — see SPLIT_PAIR_EDGE */
    uint8_t  irq;          /* the /IRQ line to the CPU */
    uint8_t  init;         /* SKCTL[1:0] == 0: dividers held */
    uint8_t  skctl;        /* $D20F: bits 6-4 select the serial clocking mode */
    uint8_t  serout_full;  /* SEROUT holds a byte waiting for the shift register */
    uint8_t  seroc;        /* serial output COMPLETE — a property of the SHIFT
                            * register, not of SEROUT.  Loading SEROUT while the
                            * clock is stopped leaves this asserted, because the
                            * byte never reaches the shift register at all. */
    uint8_t  serout_val;   /* the byte sitting in SEROUT */
    uint8_t  ser_byte;     /* the byte in the shift register, for two-tone mode */
    int      ser_bits;     /* bits left to shift out: start + 8 data + stop */
    uint8_t  st_lag[8];            /* status-bit countdown, per IRQ bit */
    /* The pair's FIRST interrupt after STIMER runs on its own countdown — see
     * underflow() and pokey_timer.c's header on the two edges. */
    int      hi_first[2];
    int      hi_first_per[2];      /* what hi_first was armed with, so a mid-count
                                    * AUDF rewrite can work out how far it got */
    uint8_t  hi_first_armed[2];
    uint8_t  hi_skip[2];
    uint8_t  hi_age[2];            /* cycles since the pair reloaded */
    uint8_t  lo_age[2];            /* cycles since the low half reloaded */
    uint8_t  ch_age[4];            /* cycles since an UNLINKED channel reloaded */
    uint8_t  ch_first[4];          /* still in the FIRST period after STIMER */
    int      tt_resync;            /* ticks until timer 2's two-tone resync
                                    * reaches timer 1 -- see TWOTONE_RESYNC */
    uint8_t  st_armed[8];          /* was this in-flight status bit ENABLED at any
                                    * point during its flight?  An enable arms
                                    * one; a disable never disarms it */
    unsigned long long ticks;      /* free-running tick count, for probes */
    unsigned long long stimer_at;  /* tick of the last STIMER write */
} pokey_timer;

extern int pokey_timer_probe;

void    pokey_timer_reset(pokey_timer *p);
/* SKCTL's init state ($D20F bits 1:0 == 0) holds the base clock divider as well
 * as the poly counters, and RELEASING it restarts the divider from zero.
 * pokey_inittiming measures the first 15 kHz interrupt from the SKCTL write, not
 * from STIMER, so without this the phase is wherever it happened to be. */
void    pokey_timer_skctl(pokey_timer *p, uint8_t val);
void    pokey_timer_tick(pokey_timer *p);          /* one machine cycle */
void    pokey_timer_write(pokey_timer *p, uint16_t addr, uint8_t val);
uint8_t pokey_timer_irqst(const pokey_timer *p);
uint8_t pokey_timer_irqst_probe(const pokey_timer *p);

#endif /* POKEY_TIMER_H */
