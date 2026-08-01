#include "pokey_timer.h"

/* Where the free-running base divider sits relative to the machine-cycle count.
 * A real POKEY shares its master clock with ANTIC, so this phase is fixed by
 * power-on alignment; pokey_inittiming measures it. */
#ifndef POKEY_BASE_PHASE
#define POKEY_BASE_PHASE 0
#endif

/* Base-clock periods in machine cycles: 1.79 MHz / 28 is the 64 kHz clock,
 * / 114 the 15 kHz one (which is also exactly one scanline). */
#ifndef LINK_FAST
#define LINK_FAST 7
#endif
/* A LINKED pair is TWO counters, not one.  pokey_timertiming checks the halves
 * separately and its boundaries are decisive: the LOW half's interrupt fires at
 * exactly the same time linked as unlinked (both 19/20 with AUDF1 = 16), and the
 * HIGH half's three cycles later — and its 16-bit-hi row requires bit 1 still SET
 * at 22 while bit 0 has ALREADY cleared, so both interrupts are live at once.
 *
 * The pair counter here already produces the HIGH half's time correctly:
 * LINK_FAST 7 is the unlinked fast period's 4 plus that same 3 of propagation.
 * What was missing is the low half's own interrupt, so this adds a counter for
 * it rather than restructuring the divider. */
/* The low half's FIRST period after STIMER is the unlinked one (AUDF1 + 4, plus
 * LO_EXTRA); every period after it is the LINKED one, AUDF1 + LINK_FAST.  Swept
 * directly: with AUDF1 = 16 only a reload of 23 satisfies pokey_timertiming's
 * 16-bit lo loop #2, and 23 is AUDF1 + 7 exactly.  A true $FF borrow-chain
 * reload (259) fires far too late, so the low half is NOT a plain 16-bit low
 * byte. */
/* A linked pair's INTERRUPT edge lags its SERIAL-CLOCK edge.  pokey_timertiming
 * and pokey_sertiming sit in the SAME timer configuration — both AUDF2 = 0, both
 * fast, both linked — and want different timing; the only thing that differs is
 * which edge they watch.  The lag applies to EVERY pair underflow, not just the
 * first after STIMER. */
#ifndef PAIR_IRQ_LAG
#define PAIR_IRQ_LAG 4
#endif
#ifndef LO_EXTRA
#define LO_EXTRA 4
#endif
#ifndef LINK_EXTRA
#define LINK_EXTRA 0
#endif
#ifndef LINK_TWO_COUNTERS
#define LINK_TWO_COUNTERS 1
#endif
#ifndef STIMER_EXTRA
#define STIMER_EXTRA 4
#endif
#define BASE_64K  28
#ifndef BASE_64K_LEAD
#define BASE_64K_LEAD 2
#endif
#ifndef BASE_15K_LEAD
#define BASE_15K_LEAD 0
#endif
#define BASE_15K 114

static int base_period(const pokey_timer *p)
{
    return (p->audctl & 0x01) ? BASE_15K : BASE_64K;
}

/* A divider counts AUDF+1 of its input ticks.  Linked pairs count
 * (hi<<8 | lo) + 1 of the LOW channel's input. */
/* The AUDF a reload will use.  MEASURED, not modelled: pokey_timertiming's
 * STIMER write lands on machine cycle 62 and AUDF1 = 16 puts the first underflow
 * at 62 + 24 = 86; its "+22c" write lands at 84 and must take effect, its "+23c"
 * write lands at 85 and must not.  So the value is captured TWO cycles before
 * the underflow — expressed as a delay line, never as a freeze, because a
 * channel with AUDF = 0 has a period of one and a freeze would stick for ever. */
static uint8_t af(const pokey_timer *p, int ch)
{
    return AUDF_PIPE ? p->audf_d[ch][AUDF_PIPE - 1] : p->audf[ch];
}

static int period_of(const pokey_timer *p, int ch)
{
    /* The divider reloads with AUDF+1 of its input ticks — except off the 1.79
     * MHz clock, where the extra pipeline stages make it AUDF+4 unlinked and
     * +7 for a 16-bit pair.  pokey_timertiming catches the difference directly:
     * with +1 the timer "triggered too early". */
    int fast1 = (p->audctl & 0x40) != 0;
    int fast3 = (p->audctl & 0x20) != 0;

    if (ch == 0 && (p->audctl & 0x10))          /* 1+2 linked, 1 is the low half */
        return ((af(p, 1) << 8) | af(p, 0)) + (fast1 ? LINK_FAST : 1);
    if (ch == 2 && (p->audctl & 0x08))          /* 3+4 linked */
        return ((af(p, 3) << 8) | af(p, 2)) + (fast3 ? LINK_FAST : 1);
    if (ch == 0 && fast1) return af(p, 0) + 4;
    if (ch == 2 && fast3) return af(p, 2) + 4;
    return af(p, ch) + 1;
}

/* Prime the capture path when the counter is far enough from its underflow that
 * the delay could not have mattered. */
static void audf_prime(pokey_timer *p, int ch)
{
    if (p->cnt[ch] > AUDF_PIPE)
        for (int k = 0; k < AUDF_PIPE; k++) p->audf_d[ch][k] = p->audf[ch];
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
    p->chain = BASE_64K;
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
/* Take a byte from SEROUT into the shift register, if there is one and the
 * register is free.  Deliberately SEPARATE from advancing a bit time: the two
 * happen together on a clock tick, but loading SEROUT triggers only this one,
 * and doing it by calling the tick routine disturbs the shift clock's phase. */
static void ser_take(pokey_timer *p)
{
    if (!p->serout_full || p->ser_bits) return;
    p->serout_full = 0;
    p->ser_byte = p->serout_val;
    p->seroc = 0;
    /* TWENTY timer underflows, not ten: the timer produces the serial clock's
     * edges, so a bit time is two underflows.  pokey_serclock pins it — with
     * timer 3+4 at 456 cycles it expects a VCOUNT delta of 40, i.e. 80
     * scanlines, i.e. 9120 cycles, i.e. 20 periods for one byte. */
    p->ser_bits = 20;
}

/* One serial bit time. */
static void ser_tick(pokey_timer *p)
{
    if (p->ser_bits && --p->ser_bits == 0) {
        p->seroc = 1;
        if (p->irqen & POKEY_IRQ_SEROC) p->irq = 1;
    }
    /* a byte already waiting is taken on THIS tick, not the next */
    ser_take(p);
}

/* The serial output line's current level: 0 is a SPACE, 1 a MARK.  Twenty ticks
 * carry ten bit times — start (always 0), eight data bits LSB first, then stop
 * (always 1) — and an idle line sits at mark. */
static int ser_out_bit(const pokey_timer *p)
{
    if (!p->ser_bits) return 1;                /* idle: mark */
    int i = (20 - p->ser_bits) / 2;
    if (i == 0) return 0;                      /* start bit */
    if (i >= 9) return 1;                      /* stop bit */
    return (p->ser_byte >> (i - 1)) & 1;
}

/* Two-tone mode (SKCTL bit 3) keys the output between two tones, and holds
 * timer 2 while the line is a MARK.  pokey_twotone transmits $fc, whose start
 * bit and two low data bits give three spaces followed by three marks, and
 * requires timer 2 to produce 28..49 interrupts across the spaces but fewer
 * than 19 across the marks.  Free-running gives 48 in both. */
static int timer2_held(const pokey_timer *p)
{
    return (p->skctl & 0x08) && ser_out_bit(p);
}

/* Asynchronous receive mode holds timers 3 AND 4 in RESET: POKEY is waiting for
 * a start bit, and the bit-time divider must begin its count FROM that edge, so
 * the counters are not merely stopped — they are reloaded for as long as the
 * mode is on.  pokey_asyncrecv enables it with SKCTL $13 and requires timer 4's
 * IRQ to stay silent, saying so outright ("we shouldn't, since POKEY is waiting
 * for a start bit"), and then proves the RESET separately: with 3+4 linked at
 * 456 cycles it turns the mode on mid-count and off again two lines later, and
 * requires the next interrupt a full period after the mode ended rather than
 * where the interrupted count would have put it.  Merely suppressing the
 * underflow leaves the counter past zero and fires immediately on release,
 * which is how this failed (sub-case 3). */
static int timer34_held(const pokey_timer *p)
{
    return (p->skctl & 0x10) != 0;
}

static void underflow(pokey_timer *p, int ch)
{
    if (ch == 1 && timer2_held(p)) return;

    if (ch == ser_clock_ch(p)) ser_tick(p);
    /* a linked pair reloads its own low half, so only the unlinked case
     * reloads here */

    /* a linked pair's counter IS the low channel's, so reload that one.  The
     * pair's reload does NOT restart its low half — tried, and it puts
     * pokey_timertiming's 16-bit lo back to failing loop #1; the low half keeps
     * its own phase. */
    if (ch == 1 && (p->audctl & 0x10))      reload(p, 0);
    else if (ch == 3 && (p->audctl & 0x08)) reload(p, 2);
    else                                    reload(p, ch);
    /* A linked pair's INTERRUPT edge and its SERIAL-CLOCK edge are not the same
     * event.  pokey_timertiming and pokey_sertiming sit in the SAME timer
     * configuration — both AUDF2 = 0, both fast, both linked — and want
     * different timing, and the only thing that differs is which edge they
     * watch.  So the serial tick above is immediate and the interrupt can owe a
     * lag, which is where the STIMER first-period extra lives for the pair. */
    int pair   = (ch == 1) ? 0 : 1;
    int linked = (ch == 1) ? (p->audctl & 0x10) : (p->audctl & 0x08);
    if (PAIR_IRQ_LAG && linked && (ch == 1 || ch == 3)) {
        p->hi_lag[pair] = PAIR_IRQ_LAG;
        return;
    }
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
    if (p->init && !now) {
        /* The divider chain FREE-RUNS through the release — it is not reloaded.
         * Measured directly: pokey_sertiming's 195-cycle delay spans 217 MACHINE
         * cycles once refresh is counted, and its one-cycle boundary therefore
         * needs 218 left on the divider at the SEROUT write.  Free-running gives
         * exactly 218; reloading a full period gives 224 and reloading
         * period-28 gives 196, and both fail. */
        /* The release restarts the BASE divider but leaves the channel counters
         * alone.  That distinction is what satisfies both tests: pokey_sertiming
         * clocks its channel at 1.79 MHz, so its counter is not fed by the base
         * divider at all and free-runs to the measured 218; pokey_inittiming
         * clocks its channel off the 15 kHz base, so the release DOES set its
         * phase — and it wants the first tick 86 machine cycles later, which is
         * 114 - 28, one 64 kHz period in. */
        /* Releasing init restarts the chain at ONE 64 kHz period in, and both
         * taps follow from that single number:
         *   64 kHz — 28 % 28 == 0, so the next tick is a full 28 away.
         *     pokey_inittiming's own arithmetic says so: "84 - 28*2 = 28" with
         *     AUDF1 = 2, i.e. the third tick, 84 cycles after the write.
         *   15 kHz — 28 % 114 == 28, so the next tick is 114 - 28 = 86 away,
         *     which is exactly what the same test wants for that clock.
         * Two independent expectations from one constant. */
        p->chain = BASE_64K;
    }
    p->init = now;
}

void pokey_timer_tick(pokey_timer *p)
{
    if (p->init) return;                       /* held in init */

    for (int i = 0; i < 4; i++) {
        for (int k = AUDF_PIPE - 1; k > 0; k--) p->audf_d[i][k] = p->audf_d[i][k - 1];
        if (AUDF_PIPE) p->audf_d[i][0] = p->audf[i];
    }

    /* An interrupt edge the pair still owes from an earlier underflow. */
    for (int i = 0; i < 2; i++)
        if (p->hi_lag[i] && --p->hi_lag[i] == 0)
            raise(p, i == 0 ? POKEY_IRQ_TIMER2 : POKEY_IRQ_TIMER4);

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

    int held34  = timer34_held(p);
    if (held34) { reload(p, 2); reload(p, 3); }

    if (LINK_TWO_COUNTERS && linked1 && fast1 && --p->locnt[0] <= 0) {
        p->locnt[0] = p->audf[0] + LINK_FAST;
        raise(p, POKEY_IRQ_TIMER1);
    }
    if (fast1 && --p->cnt[0] <= 0) underflow(p, linked1 ? 1 : 0);
    if (!held34 && fast3 && --p->cnt[2] <= 0) underflow(p, linked3 ? 3 : 2);

    /* The 64 kHz tap LEADS the 15 kHz one by two machine cycles out of the
     * SKCTL release.  pokey_inittiming measures both from the same release and
     * its own arithmetic gives 86-87 cycles to the first 15 kHz tick and 26-27
     * to the first 64 kHz one, which no single phase on one chain can produce:
     * a residue that puts 15 kHz at 86 puts 64 kHz at 28.  Two cycles is the
     * gap, and it is only visible because the test anchors both to the same
     * event. */
    ++p->chain;
    if ((p->chain + (base_period(p) == BASE_64K ? BASE_64K_LEAD : BASE_15K_LEAD))
        % (unsigned long)base_period(p) != 0)
        return;

    if (LINK_TWO_COUNTERS && linked1 && !fast1 && --p->locnt[0] <= 0) {
        p->locnt[0] = p->audf[0] + 1;
        raise(p, POKEY_IRQ_TIMER1);
    }
    if (!fast1) {
        if (--p->cnt[0] <= 0) underflow(p, linked1 ? 1 : 0);
        if (!linked1 && --p->cnt[1] <= 0) underflow(p, 1);
    } else if (!linked1) {
        if (--p->cnt[1] <= 0) underflow(p, 1);
    }

    if (held34) {
        /* nothing: the counters were reloaded above and stay there */
    } else if (!fast3) {
        if (--p->cnt[2] <= 0) underflow(p, linked3 ? 3 : 2);
        if (!linked3 && --p->cnt[3] <= 0) underflow(p, 3);
    } else if (!linked3) {
        if (--p->cnt[3] <= 0) underflow(p, 3);
    }
}

void pokey_timer_write(pokey_timer *p, uint16_t addr, uint8_t val)
{
    switch (addr & 0x0F) {
    /* An AUDF write while the counter is still far from its underflow primes the
     * capture path directly: the delay only matters for a write that arrives
     * inside the capture window.  Without this the FIRST period after a fresh
     * AUDF write would use whatever the line held, which the ptimer gate — which
     * starts from reset — catches immediately. */
    case 0x00: p->audf[0] = val; audf_prime(p, 0); break;
    case 0x02: p->audf[1] = val; audf_prime(p, 1); break;
    case 0x04: p->audf[2] = val; audf_prime(p, 2); break;
    case 0x06: p->audf[3] = val; audf_prime(p, 3); break;
    case 0x08: p->audctl = val; break;
    case 0x09:
        /* STIMER reloads the four CHANNEL counters but does NOT touch the base
         * clock divider, which free-runs.  pokey_inittiming shows why: with
         * AUDF = 0 it measures the first interrupt at 86 cycles on the 15 kHz
         * clock and 83 on the 64 kHz one — only three apart, though the periods
         * differ by 86.  So the delay is not a period at all; it is however far
         * the free-running divider happened to be from its next tick, which the
         * test makes deterministic by syncing with two WSYNCs first. */
        /* STIMER is an explicit "load now", so it primes the capture path too —
         * otherwise the first period after it would use whatever the delay line
         * happened to hold. */
        for (int i = 0; i < 4; i++)
            for (int k = 0; k < AUDF_PIPE; k++) p->audf_d[i][k] = p->audf[i];
        for (int i = 0; i < 4; i++) reload(p, i);
        p->locnt[0] = p->audf[0] + ((p->audctl & 0x40) ? 4 : 1) + LO_EXTRA;
        p->locnt[1] = p->audf[2] + ((p->audctl & 0x20) ? 4 : 1) + LO_EXTRA;
        p->hi_lag[0] = p->hi_lag[1] = 0;
        /* EXPERIMENT: the first period after STIMER runs long.  pokey_timertiming
         * tabulates it: with AUDF1 = 0 on the 1.79 MHz clock the first interrupt
         * lands 7-8 cycles after the STIMER write and the second 11-12, so the
         * PERIOD is 4 (= AUDF + 4, which we already have) but the first one is
         * three or four cycles longer. */
        {
            int linked1 = (p->audctl & 0x10) != 0;
            int linked3 = (p->audctl & 0x08) != 0;
            int fast1   = (p->audctl & 0x40) != 0;
            int fast3   = (p->audctl & 0x20) != 0;
            for (int i = 0; i < 4; i++) {
                int inpair = (i <= 1) ? linked1 : linked3;
                int fast   = (i <= 1) ? fast1   : fast3;
                /* The extra was scoped to UNLINKED channels while a pair was
                 * modelled as one divider — the only thing that fired, so it had
                 * to carry the whole delay.  With the pair's LOW half counting
                 * separately both halves take it, which is what puts them three
                 * cycles apart instead of one ahead of the other. */
                if (fast) p->cnt[i] += inpair ? LINK_EXTRA : STIMER_EXTRA;
            }
        }
        break;
    case 0x0D:
        /* SEROUT is a HOLDING register.  The byte only reaches the shift
         * register on a serial clock tick, which is why pokey_serclock can load
         * it with the clock stopped and still see SEROC asserted. */
        p->serout_full = 1;
        p->serout_val  = val;
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
    /* BOTH serial output bits are LEVELS, not latched events, and both ignore
     * the mask in IRQST:
     *   SEROC (bit 3) — the SHIFT register is idle;
     *   SEROR (bit 4) — SEROUT is empty and can take another byte.
     * That is what reconciles the two tests.  pokey_serclock enables SEROR while
     * SEROUT is already empty and expects it pending at once; it also loads
     * SEROUT with the clock stopped and expects SEROR to stay HIGH, because the
     * byte is still sitting there.  pokey_sertiming loads SEROUT with the clock
     * running and expects SEROC HIGH immediately, the register having taken it. */
    uint8_t v = p->irqst;
    v = (uint8_t)(p->seroc       ? (v & ~POKEY_IRQ_SEROC) : (v | POKEY_IRQ_SEROC));
    v = (uint8_t)(p->serout_full ? (v |  POKEY_IRQ_SEROR) : (v & ~POKEY_IRQ_SEROR));
    return v;
}
