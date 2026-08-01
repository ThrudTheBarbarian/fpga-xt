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
    p->skctl = 0;
    p->serout_full = 0;
    p->init = 0;
}

static void raise(pokey_timer *p, uint8_t bit)
{
    if (!(p->irqen & bit)) return;             /* masked: no request at all */
    p->irqst = (uint8_t)(p->irqst & ~bit);     /* active low */
    p->irq = 1;
}

/* Fire channel `ch`, which has just underflowed. */
/* Which timer clocks the serial shift register.  pokey_serclock names all
 * three cases: SKCTL $23 is "timer 4 as serial output clock", $63 is "timer 2",
 * and $03 is the external clock, where it says the shift register "should never
 * load".  So bit 5 selects timer-clocked over external, and bit 6 picks which
 * timer.  Returns -1 for external, else the channel index. */
static int ser_clock_ch(const pokey_timer *p)
{
    if (!(p->skctl & 0x20)) return -1;
    return (p->skctl & 0x40) ? 1 : 3;
}

/* One serial bit time has elapsed. */
static void ser_tick(pokey_timer *p)
{
    if (p->ser_bits) {
        if (--p->ser_bits != 0) return;
        p->seroc = 1;
        if (p->irqen & POKEY_IRQ_SEROC) p->irq = 1;
        /* fall through: a byte already waiting in SEROUT is taken on THIS tick,
         * not the next.  Waiting cost one whole serial period, which
         * pokey_serclock sees as 42 where it wants 40. */
    }
    if (p->serout_full) {                  /* take the byte from SEROUT */
        p->serout_full = 0;
        p->seroc = 0;
        /* TWENTY timer underflows, not ten: the timer produces the serial
         * clock's edges, so a bit time is two underflows.  pokey_serclock pins
         * it — with timer 3+4 at 456 cycles it expects a VCOUNT delta of 40,
         * i.e. 80 scanlines, i.e. 9120 cycles, i.e. 20 periods for one byte. */
        p->ser_bits = 20;
        raise(p, POKEY_IRQ_SEROR);         /* SEROUT is free again */
    }
}

static void underflow(pokey_timer *p, int ch)
{
    if (ch == ser_clock_ch(p)) ser_tick(p);
    /* a linked pair reloads its own low half, so only the unlinked case
     * reloads here */

    /* a linked pair's counter IS the low channel's, so reload that one */
    if (ch == 1 && (p->audctl & 0x10))      reload(p, 0);
    else if (ch == 3 && (p->audctl & 0x08)) reload(p, 2);
    else                                    reload(p, ch);
    switch (ch) {
    case 0: raise(p, POKEY_IRQ_TIMER1); break;
    case 1: raise(p, POKEY_IRQ_TIMER2); break;
    case 3: raise(p, POKEY_IRQ_TIMER4); break;
    default: break;                            /* channel 3 has no interrupt */
    }
}

void pokey_timer_skctl(pokey_timer *p, uint8_t val)
{
    uint8_t now = (val & 0x03) == 0;
    p->skctl = val;
    if (now) {
        /* SKCTL's init state RESETS the serial port: the shift register is
         * cleared and the output reports itself complete.  The tests write
         * skctl = 0 for exactly this and say so — "reset serial port to force
         * output complete" — and without it a transmission still in flight from
         * an earlier sub-test leaves SEROC deasserted for good. */
        p->ser_bits = 0;
        p->serout_full = 0;
        p->seroc = 1;
    }
    if (p->init && !now)                       /* released: reload the channels */
        for (int i = 0; i < 4; i++) reload(p, i);
    p->init = now;
}

void pokey_timer_tick(pokey_timer *p)
{
    if (p->init) return;                       /* held in init */

    /* Channels 1 and 3 can be clocked straight off the machine clock instead of
     * the base divider — the only way to get a period shorter than a base tick,
     * and what pokey_timergranularity measures.  A LINKED pair can be fast too:
     * pokey_serclock sets AUDCTL $78, which links both pairs AND puts both on
     * 1.79 MHz, then says "set timer 1+2 to 228 cycles, timer 3+4 to 456".
     *
     * A linked pair counts as ONE divider off the low channel's clock, and the
     * event belongs to the HIGH channel: that is what raises its interrupt and
     * clocks the serial port. */
    int fast1   = (p->audctl & 0x40) != 0;
    int fast3   = (p->audctl & 0x20) != 0;
    int linked1 = (p->audctl & 0x10) != 0;
    int linked3 = (p->audctl & 0x08) != 0;

    if (fast1 && --p->cnt[0] <= 0) underflow(p, linked1 ? 1 : 0);
    if (fast3 && --p->cnt[2] <= 0) underflow(p, linked3 ? 3 : 2);

    if ((p->cycles++ + POKEY_BASE_PHASE) % (unsigned long)base_period(p) != 0)
        return;

    if (!fast1) {
        if (--p->cnt[0] <= 0) underflow(p, linked1 ? 1 : 0);
        if (!linked1 && --p->cnt[1] <= 0) underflow(p, 1);
    } else if (!linked1) {
        if (--p->cnt[1] <= 0) underflow(p, 1);
    }

    if (!fast3) {
        if (--p->cnt[2] <= 0) underflow(p, linked3 ? 3 : 2);
        if (!linked3 && --p->cnt[3] <= 0) underflow(p, 3);
    } else if (!linked3) {
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
        /* SEROUT is a HOLDING register.  The byte only reaches the shift
         * register on a serial clock tick, which is why pokey_serclock can load
         * it with the clock stopped and still see SEROC asserted. */
        p->serout_full = 1;
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
