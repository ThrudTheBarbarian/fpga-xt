#include "pokey_timer.h"

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
    p->base_div = BASE_64K;
    p->irq = 0;
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
    case 1: raise(p, POKEY_IRQ_TIMER2); break;
    case 3: raise(p, POKEY_IRQ_TIMER4); break;
    default: break;                            /* channel 3 has no interrupt */
    }
}

void pokey_timer_tick(pokey_timer *p)
{
    /* Channels 1 and 3 can be clocked straight off the machine clock; that is
     * the only way to get a divider shorter than the 64 kHz base tick, and it
     * is what pokey_timergranularity measures. */
    int fast1 = (p->audctl & 0x40) != 0;
    int fast3 = (p->audctl & 0x20) != 0;

    if (fast1 && !(p->audctl & 0x10) && --p->cnt[0] <= 0) underflow(p, 0);
    if (fast3 && !(p->audctl & 0x08) && --p->cnt[2] <= 0) underflow(p, 2);

    if (--p->base_div > 0)
        return;
    p->base_div = base_period(p);

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
    case 0x09:                                 /* STIMER resets all dividers */
        for (int i = 0; i < 4; i++) reload(p, i);
        p->base_div = base_period(p);
        break;
    case 0x0E:
        /* IRQEN both masks and CLEARS: a bit written as zero drops any request
         * already standing, which is how a handler acknowledges. */
        p->irqen = val;
        p->irqst = (uint8_t)(p->irqst | ~val);
        if ((uint8_t)~p->irqst == 0) p->irq = 0;
        break;
    default: break;
    }
}

uint8_t pokey_timer_irqst(const pokey_timer *p) { return p->irqst; }
