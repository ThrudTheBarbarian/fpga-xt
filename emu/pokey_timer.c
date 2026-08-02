#include "pokey_timer.h"
#include <stdio.h>

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
#ifndef LO_UPCOUNT
#define LO_UPCOUNT 0
#endif
#ifndef PAIR_IRQ_LAG
#define PAIR_IRQ_LAG 3
#endif
#ifndef LO_EXTRA
#define LO_EXTRA 0
#endif
#ifndef LINK_EXTRA
#define LINK_EXTRA 0
#endif
#ifndef LINK_TWO_COUNTERS
#define LINK_TWO_COUNTERS 1
#endif
#ifndef STIMER_EXTRA
#define STIMER_EXTRA 0
#endif
#define BASE_64K  28
#define BASE_15K 114
/* BOTH taps lead the chain by the same two cycles.  They were once split — 2
 * for 64 kHz and 0 for 15 kHz — because pokey_inittiming's two 15 kHz
 * measurements could not be reconciled without it, and the split was absorbing
 * an error that was really in IRQ_LINE_LAG below.  With that modelled, one
 * number does both clocks. */
#ifndef BASE_LEAD
#define BASE_LEAD 2
#endif

/* How many machine cycles the /IRQ LINE to the CPU lags the IRQST STATUS BIT.
 * pokey_inittiming measures the same underflow BOTH ways — a NOP sled, which
 * times when the CPU acknowledges, and a pair of IRQST reads one machine cycle
 * apart, which times when the flag becomes readable — and no single tap phase
 * satisfies both: the sled wants the underflow two cycles later than the
 * bracket does.  They are not the same instant.  One cycle of line lag plus a
 * uniform tap lead of two satisfies every assertion in the test, and takes
 * pokey_irqtiming with it. */
#ifndef IRQ_LINE_LAG
#define IRQ_LINE_LAG 1
#endif

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
/* How long the low half's reload value stays open to a late AUDF write, in
 * cycles after the underflow.  Measured, not chosen -- see audf_prime. */
#ifndef LO_LATCH_LAG
#define LO_LATCH_LAG 2
#endif

/* The same window for a linked pair's HIGH half -- see audf_prime. */
#ifndef HI_LATCH_LAG
#define HI_LATCH_LAG 3
#endif

static void audf_prime(pokey_timer *p, int ch)
{
    if (p->cnt[ch] > AUDF_PIPE)
        for (int k = 0; k < AUDF_PIPE; k++) p->audf_d[ch][k] = p->audf[ch];
    /* the low half of a linked pair runs its own counter, so its window is its
     * own too.
     *
     * ...but a write cannot reach BACK into a period the counter has already
     * loaded.  pokey_timertiming's "earliest AUDF1 write to be too late" writes
     * AUDF1 two cycles after an underflow and requires the period already
     * running to keep the OLD value: back-filling the whole delay line let that
     * write lengthen a period it should not have touched, and the underflow
     * landed at +43 where the test wants +41. */
    if ((ch == 0 || ch == 2) && p->locnt[ch / 2] > AUDF_PIPE)
        for (int k = 0; k < AUDF_PIPE; k++) p->audf_lo_d[ch / 2][k] = p->audf[ch];

    /* THE RELOAD VALUE LATCHES ONE CYCLE AFTER THE UNDERFLOW, not at it.
     * pokey_timertiming brackets the boundary from both sides in consecutive
     * sub-tests: with the underflow at +21, a write at +22 must still lengthen
     * the period and a write at +23 must not.  Reloading at the underflow makes
     * +22 too late; letting a mid-count rewrite land (the up-counting model)
     * makes +23 too early.  Only a latch that stays open for exactly one more
     * cycle satisfies both. */
    if ((ch == 0 || ch == 2) && p->lo_age[ch / 2] < LO_LATCH_LAG)
        p->locnt[ch / 2] = p->audf[ch] + LINK_FAST - p->lo_age[ch / 2];

    /* ...and the HIGH half of a linked pair has the same shape with its own
     * width.  pokey_timertiming states both boundaries in prose: an AUDF2 write
     * up to 18 cycles past STIMER still lengthens the period already loaded --
     * bit 2 then asserts at 300 (4 + 20 + 276) -- and at 19 cycles it does not,
     * leaving 44 (4 + 20 + 20).  The pair reloads at +20, so the window admits
     * an age of 2 and rejects 3. */
    if ((ch == 1 || ch == 3)) {
        int pair = (ch == 1) ? 0 : 1;
        int lo   = 2 * pair;
        int linked = (ch == 1) ? (p->audctl & 0x10) : (p->audctl & 0x08);
        if (linked && p->hi_age[pair] < HI_LATCH_LAG) {
            int fast = (ch == 1) ? (p->audctl & 0x40) : (p->audctl & 0x20);
            int per  = ((p->audf[ch] << 8) | p->audf[lo]) + (fast ? LINK_FAST : 1);
            p->cnt[lo] = per - p->hi_age[pair];
        }
    }
}

/* AUDF for a linked pair's LOW half, through its own delay line. */
static uint8_t af_lo(const pokey_timer *p, int pair)
{
    return AUDF_PIPE ? p->audf_lo_d[pair][AUDF_PIPE - 1] : p->audf[2 * pair];
}

static void reload(pokey_timer *p, int ch)
{
    p->cnt[ch] = period_of(p, ch);
}

void pokey_timer_reset(pokey_timer *p)
{
    /* The reload-latch ages and the deferred status bits are STATE, and reset
     * initialises field by field rather than zeroing the struct -- so anything
     * added here has to be cleared here too.  A stack-allocated pokey_timer
     * (which is what the ptimer gate uses, where the ACID harness has a zeroed
     * static) otherwise starts with garbage ages that fire a latch immediately
     * and garbage countdowns that clear IRQST bits nothing ever set. */
    for (int i = 0; i < 8; i++) p->st_lag[i] = 0;
    p->hi_age[0] = p->hi_age[1] = 0;
    p->lo_age[0] = p->lo_age[1] = 0;
    p->ticks = p->stimer_at = 0;
    for (int i = 0; i < 4; i++) { p->audf[i] = 0; p->cnt[i] = 1; }
    p->audctl = 0;
    p->irqen  = 0;
    p->irqst  = 0xFF;      /* active low: nothing pending */
    p->irq_arm = 0;
    p->chain = BASE_64K;
    p->irq = 0;
    p->seroc = 1;
    p->ser_bits = 0;
    p->skctl = 0;
    p->serout_full = 0;
    p->init = 0;
}

/* The STATUS BIT and the /IRQ LINE are not the same instant.  pokey_inittiming
 * measures the same underflow twice — once through a NOP sled, which times when
 * the CPU ACKNOWLEDGES the interrupt, and once through a pair of IRQST reads one
 * machine cycle apart, which times when the FLAG becomes readable — and the two
 * cannot be satisfied by one tap phase: the sled wants the underflow two cycles
 * later than the bracket does.  So IRQST is set at the underflow and the line to
 * the CPU follows IRQ_LINE_LAG cycles behind it. */
/* Measurement hook: the CYCLE each timer-1 underflow becomes readable, against
 * the STIMER write that started it.  pokey_timertiming states its expectations
 * in exactly those terms (its table at .lst 274-277) and no amount of squinting
 * at reload constants settles an off-by-one that the tick/read order can also
 * produce -- so measure it. */
int pokey_timer_probe;

/* How long the STATUS bit lags the underflow that set it.  Measured -- see
 * raise().  Zero restores the old "set at the underflow" model. */
#ifndef ACK_CANCELS_INFLIGHT
#define ACK_CANCELS_INFLIGHT 0
#endif

#ifndef IRQST_LAG
#define IRQST_LAG 4
#endif

/* Is the channel behind this IRQ bit clocked off 1.79 MHz? */
static int fast_for_bit(const pokey_timer *p, uint8_t bit)
{
    if (bit & POKEY_IRQ_TIMER4) return (p->audctl & 0x20) != 0;
    return (p->audctl & 0x40) != 0;            /* timers 1 and 2 */
}

static int bit_index(uint8_t bit)
{
    for (int i = 0; i < 8; i++) if (bit & (1u << i)) return i;
    return 0;
}

static void raise(pokey_timer *p, uint8_t bit)
{
    /* Reported either way, and SAID SO: a raise that IRQEN masks sets no status
     * bit at all, and a probe that does not distinguish the two invites reading
     * a masked underflow as a fired one. */
    if (pokey_timer_probe)
        fprintf(stderr, "  T%d underflow at +%llu (irqen $%02X)%s\n",
                bit == POKEY_IRQ_TIMER1 ? 1 : bit == POKEY_IRQ_TIMER2 ? 2 :
                bit == POKEY_IRQ_TIMER4 ? 4 : 0,
                (unsigned long long)(p->ticks - p->stimer_at), p->irqen,
                (p->irqen & bit) ? "" : "  [MASKED]");

    if (!(p->irqen & bit)) return;             /* masked: no request at all */
    /* THE UNDERFLOW AND THE READABLE STATUS BIT ARE FOUR CYCLES APART.
     * pokey_timertiming tabulates the same timer twice, and the two tables
     * differ by exactly that on every row they share.  Its STIMER-preemption
     * table measures the UNDERFLOW directly, by strobing STIMER until the timer
     * stops firing: AUDF1=0 underflows at 4 and AUDF1=8 at 12, i.e. AUDF + 4
     * with nothing added for the first period.  Its IRQST table measures when
     * the BIT can be read: AUDF1=0 at 8 and AUDF1=16 at 24, four later than the
     * underflow in both cases.
     *
     * Modelling that gap as a longer FIRST PERIOD (the old STIMER_EXTRA) put it
     * in the counter, where it also delayed the underflow the preemption test
     * strobes against — and no value could then satisfy both tables. */
    /* ...and it is a property of the 1.79 MHz TAP, not of every channel.  The
     * tables that measure it are all fast-clocked, and the extra pipeline
     * stages that make a fast period AUDF+4 are the same ones that delay the
     * interrupt.  A base-clocked channel takes neither: pokey_inittiming times
     * its acknowledge on the 15 kHz clock and wants it exactly where it always
     * was.  BOTH the status bit and the /IRQ line take the lag together, which
     * is what keeps a fast channel's acknowledge in place while its underflow
     * moves four cycles earlier. */
    int lag = fast_for_bit(p, bit) ? IRQST_LAG : 0;
    if (lag) p->st_lag[bit_index(bit)] = (uint8_t)lag;
    else     p->irqst = (uint8_t)(p->irqst & ~bit);
    if (IRQ_LINE_LAG + lag) p->irq_arm = (uint8_t)(IRQ_LINE_LAG + lag);
    else                    p->irq = 1;
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
    if (ch == 1 && (p->audctl & 0x10))      { reload(p, 0); p->hi_age[0] = 0; }
    else if (ch == 3 && (p->audctl & 0x08)) { reload(p, 2); p->hi_age[1] = 0; }
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
    p->ticks++;
    for (int i = 0; i < 8; i++)
        if (p->st_lag[i] && --p->st_lag[i] == 0) {
            p->irqst = (uint8_t)(p->irqst & ~(1u << i));
            /* The cycle the BIT BECOMES READABLE, which is what every IRQST
             * bracket in pokey_timertiming actually measures.  Deriving it by
             * adding a lag to the raise by hand is how the last premise went
             * wrong. */
            if (pokey_timer_probe)
                fprintf(stderr, "    -> IRQST bit %d readable at +%llu\n", i,
                        (unsigned long long)(p->ticks - p->stimer_at));
        }
    if (p->hi_age[0] < 255) p->hi_age[0]++;
    if (p->hi_age[1] < 255) p->hi_age[1]++;
    if (p->init) return;                       /* held in init */

    /* the line catching up with the status bit — see raise() */
    if (p->irq_arm && --p->irq_arm == 0) p->irq = 1;

    for (int i = 0; i < 4; i++) {
        for (int k = AUDF_PIPE - 1; k > 0; k--) p->audf_d[i][k] = p->audf_d[i][k - 1];
        if (AUDF_PIPE) p->audf_d[i][0] = p->audf[i];
    }
    for (int i = 0; i < 2; i++) {
        for (int k = AUDF_PIPE - 1; k > 0; k--)
            p->audf_lo_d[i][k] = p->audf_lo_d[i][k - 1];
        if (AUDF_PIPE) p->audf_lo_d[i][0] = p->audf[2 * i];
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

    if (LINK_TWO_COUNTERS && linked1 && fast1) {
        if (LO_UPCOUNT) {
            /* Counting UP and comparing against the DELAYED AUDF each tick is
             * what makes a mid-count rewrite land: the period is decided near
             * its END, not fixed at its start.  Reloading a down-counter at the
             * underflow captures the value two cycles before the WRONG
             * underflow — the one just finishing, not the one about to start. */
            int target = p->lo_first[0] ? af_lo(p, 0) + 4 + LO_EXTRA
                                        : af_lo(p, 0) + LINK_FAST;
            if (++p->lo_el[0] >= target) {
                p->lo_el[0] = 0;
                p->lo_first[0] = 0;
                raise(p, POKEY_IRQ_TIMER1);
            }
        } else if (--p->locnt[0] <= 0) {
            p->locnt[0] = af_lo(p, 0) + LINK_FAST;
            p->lo_age[0] = 0;               /* the latch is still open, just */
            raise(p, POKEY_IRQ_TIMER1);
        } else if (p->lo_age[0] < 255) {
            p->lo_age[0]++;
        }
    }
    if (fast1 && --p->cnt[0] <= 0) underflow(p, linked1 ? 1 : 0);
    if (!held34 && fast3 && --p->cnt[2] <= 0) underflow(p, linked3 ? 3 : 2);

    /* Both taps lead the chain by BASE_LEAD out of the SKCTL release, which
     * with the chain restarting at 28 puts the first 64 kHz tick 26 machine
     * cycles later and the first 15 kHz one 112 — and the /IRQ line one behind
     * each.  pokey_inittiming anchors both clocks to the same release, so it
     * measures the pair together. */
    ++p->chain;
    if ((p->chain + BASE_LEAD) % (unsigned long)base_period(p) != 0)
        return;

    if (LINK_TWO_COUNTERS && linked1 && !fast1 && --p->locnt[0] <= 0) {
        p->locnt[0] = af_lo(p, 0) + 1;
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
        p->stimer_at = p->ticks;
        if (pokey_timer_probe)
            fprintf(stderr, "  STIMER at tick %llu (audctl $%02X audf %d/%d)\n",
                    (unsigned long long)p->ticks, p->audctl,
                    p->audf[0], p->audf[1]);
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
        for (int i = 0; i < 2; i++)
            for (int k = 0; k < AUDF_PIPE; k++) p->audf_lo_d[i][k] = p->audf[2 * i];
        for (int i = 0; i < 4; i++) reload(p, i);
        p->locnt[0] = p->audf[0] + ((p->audctl & 0x40) ? 4 : 1) + LO_EXTRA;
        p->lo_el[0] = p->lo_el[1] = 0;
        p->lo_first[0] = p->lo_first[1] = 1;
        p->locnt[1] = p->audf[2] + ((p->audctl & 0x20) ? 4 : 1) + LO_EXTRA;
        if (pokey_timer_probe)
            fprintf(stderr, "    STIMER loads cnt[0]=%d locnt[0]=%d\n",
                    p->cnt[0], p->locnt[0]);
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
        /* A bit written as zero drops a request that has not become readable
         * yet as well as one that has: the status bit is delayed, not queued
         * somewhere IRQEN cannot reach. */
        /* Does an acknowledge reach a request that has ALREADY UNDERFLOWED but
         * whose status bit has not surfaced yet?  The delayed bit is a pulse in
         * flight, not something queued where IRQEN can see it -- so on this
         * reading it arrives regardless and sets the latch after the write. */
        if (ACK_CANCELS_INFLIGHT)
            for (int i = 0; i < 8; i++)
                if (!(val & (1u << i))) p->st_lag[i] = 0;
        p->irqst = (uint8_t)(p->irqst | ~val);
        /* nothing pending any more.  Written as a comparison against $FF
         * rather than `(uint8_t)~irqst == 0`: that form is correct but reads as
         * a bug, and gcc warns about it on the cross-build. */
        if (p->irqst == 0xFF) { p->irq = 0; p->irq_arm = 0; }
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
