#include "pokey_timer.h"

/* Where the free-running base divider sits relative to the machine-cycle count.
 * A real POKEY shares its master clock with ANTIC, so this phase is fixed by
 * power-on alignment; pokey_inittiming measures it. */
#ifndef POKEY_BASE_PHASE
#define POKEY_BASE_PHASE 0
#endif

/* Base-clock periods in machine cycles: 1.79 MHz / 28 is the 64 kHz clock,
 * / 114 the 15 kHz one (which is also exactly one scanline). */
#define BASE_64K  28
#define BASE_15K 114

static int base_period(const pokey_timer *p)
{
    return (p->audctl & 0x01) ? BASE_15K : BASE_64K;
}

/* A divider counts AUDF+1 of its input ticks.  Linked pairs count
 * (hi<<8 | lo) + 1 of the LOW channel's input. */
static int period_of(const pokey_timer *p, int ch)
{
    /* The divider reloads with AUDF+1 of its input ticks — except off the 1.79
     * MHz clock, where the extra pipeline stages make it AUDF+4 unlinked and
     * +7 for a 16-bit pair.  pokey_timertiming catches the difference directly:
     * with +1 the timer "triggered too early". */
    int fast1 = (p->audctl & 0x40) != 0;
    int fast3 = (p->audctl & 0x20) != 0;

    if (ch == 0 && (p->audctl & 0x10))          /* 1+2 linked, 1 is the low half */
        return ((p->audf[1] << 8) | p->audf[0]) + (fast1 ? 7 : 1);
    if (ch == 2 && (p->audctl & 0x08))          /* 3+4 linked */
        return ((p->audf[3] << 8) | p->audf[2]) + (fast3 ? 7 : 1);
    if (ch == 0 && fast1) return p->audf[0] + 4;
    if (ch == 2 && fast3) return p->audf[2] + 4;
    return p->audf[ch] + 1;
}

static void reload(pokey_timer *p, int ch)
{
    p->cnt[ch] = period_of(p, ch);
}

void pokey_timer_reset(pokey_timer *p)
{
    for (int i = 0; i < 4; i++) { p->audf[i] = 0; p->cnt[i] = 1; }
    p->audctl = 0;
    p->irqen  = 0;
    p->irqst  = 0xFF;      /* active low: nothing pending */
    p->cycles = 0;
    p->irq = 0;
    p->seroc = 1;
    p->ser_bits = 0;
    p->init = 0;
}

static void raise(pokey_timer *p, uint8_t bit)
{
    if (!(p->irqen & bit)) return;             /* masked: no request at all */
    p->irqst = (uint8_t)(p->irqst & ~bit);     /* active low */
    p->irq = 1;
}

/* Fire channel `ch`, which has just underflowed. */
static void underflow(pokey_timer *p, int ch)
{
    reload(p, ch);
    switch (ch) {
    case 0: raise(p, POKEY_IRQ_TIMER1); break;
    case 1:
        raise(p, POKEY_IRQ_TIMER2);
        /* timer 2 is the serial output clock */
        if (p->ser_bits && --p->ser_bits == 0) {
            p->seroc = 1;
            if (p->irqen & POKEY_IRQ_SEROC) p->irq = 1;
        }
        break;
    case 3: raise(p, POKEY_IRQ_TIMER4); break;
    default: break;                            /* channel 3 has no interrupt */
    }
}

void pokey_timer_skctl(pokey_timer *p, uint8_t val)
{
    uint8_t now = (val & 0x03) == 0;
    if (p->init && !now)                       /* released: reload the channels */
        for (int i = 0; i < 4; i++) reload(p, i);
    p->init = now;
}

void pokey_timer_tick(pokey_timer *p)
{
    if (p->init) return;                       /* held in init */

    /* Channels 1 and 3 can be clocked straight off the machine clock; that is
     * the only way to get a divider shorter than the 64 kHz base tick, and it
     * is what pokey_timergranularity measures. */
    int fast1 = (p->audctl & 0x40) != 0;
    int fast3 = (p->audctl & 0x20) != 0;

    if (fast1 && !(p->audctl & 0x10) && --p->cnt[0] <= 0) underflow(p, 0);
    if (fast3 && !(p->audctl & 0x08) && --p->cnt[2] <= 0) underflow(p, 2);

    if ((p->cycles++ + POKEY_BASE_PHASE) % (unsigned long)base_period(p) != 0)
        return;

    /* A linked pair is driven as one counter off the LOW channel's clock, and
     * only the HIGH channel's underflow raises the interrupt. */
    if (p->audctl & 0x10) {                    /* 1+2 */
        if (--p->cnt[0] <= 0) { reload(p, 0); raise(p, POKEY_IRQ_TIMER2); }
    } else {
        if (!fast1 && --p->cnt[0] <= 0) underflow(p, 0);
        if (--p->cnt[1] <= 0) underflow(p, 1);
    }

    if (p->audctl & 0x08) {                    /* 3+4 */
        if (--p->cnt[2] <= 0) { reload(p, 2); raise(p, POKEY_IRQ_TIMER4); }
    } else {
        if (!fast3 && --p->cnt[2] <= 0) underflow(p, 2);
        if (--p->cnt[3] <= 0) underflow(p, 3);
    }
}

void pokey_timer_write(pokey_timer *p, uint16_t addr, uint8_t val)
{
    switch (addr & 0x0F) {
    case 0x00: p->audf[0] = val; break;
    case 0x02: p->audf[1] = val; break;
    case 0x04: p->audf[2] = val; break;
    case 0x06: p->audf[3] = val; break;
    case 0x08: p->audctl = val; break;
    case 0x09:
        /* STIMER reloads the four CHANNEL counters but does NOT touch the base
         * clock divider, which free-runs.  pokey_inittiming shows why: with
         * AUDF = 0 it measures the first interrupt at 86 cycles on the 15 kHz
         * clock and 83 on the 64 kHz one — only three apart, though the periods
         * differ by 86.  So the delay is not a period at all; it is however far
         * the free-running divider happened to be from its next tick, which the
         * test makes deterministic by syncing with two WSYNCs first. */
        for (int i = 0; i < 4; i++) reload(p, i);
        break;
    case 0x0D:
        /* Loading SEROUT starts a transmission, so the output is no longer
         * complete: pokey_sertiming writes it and immediately requires IRQST's
         * SEROC bit to read HIGH.  Ten bit times go out — start, eight data,
         * stop — clocked by timer 2. */
        p->seroc = 0;
        p->ser_bits = 10;
        break;
    case 0x0E:
        /* IRQEN both masks and CLEARS: a bit written as zero drops any request
         * already standing, which is how a handler acknowledges. */
        p->irqen = val;
        p->irqst = (uint8_t)(p->irqst | ~val);
        if ((uint8_t)~p->irqst == 0) p->irq = 0;
        /* Enabling SEROC while the level stands fires immediately — and it must
         * be decided AFTER the clear above, or the clear undoes it. */
        if ((val & POKEY_IRQ_SEROC) && p->seroc) p->irq = 1;
        break;
    default: break;
    }
}

uint8_t pokey_timer_irqst(const pokey_timer *p)
{
    /* SEROC is a level and ignores the mask: while nothing is being transmitted
     * the output has "long completed", so its bit reads low whatever IRQEN says;
     * once SEROUT is loaded it reads high until the last bit is out. */
    if (p->seroc) return (uint8_t)(p->irqst & ~POKEY_IRQ_SEROC);
    return (uint8_t)(p->irqst | POKEY_IRQ_SEROC);
}
