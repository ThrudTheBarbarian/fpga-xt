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

/* What the SKCTL release restarts the chain at.  EXPERIMENT: the two taps are
 * read off ONE chain, so a restart value moves both -- but not by the same
 * amount, because they wrap at different periods.  With 28 the 64 kHz tap is
 * 26 machine cycles away and the 15 kHz tap 84.  pokey_timertiming's last
 * section needs the 64 kHz tap at 24 while pokey_inittiming pins the 15 kHz one
 * where it is, and (chain + BASE_LEAD) == 4 mod 28 with == 30 mod 114 solves at
 * 144 -- so a restart of 142 moves the 64 kHz tap two earlier and leaves the
 * 15 kHz tap untouched.  142 is BASE_15K + BASE_64K.
 *
 * DISPROVED, kept with its result.  pokey_inittiming pins BOTH taps, from both
 * sides: BASE_LEAD=4 (which moves them together) breaks its 15 kHz count, and
 * CHAIN_RELEASE=142 (which moves only the 64 kHz one) breaks its 64 kHz count.
 * So the base phase is not what is wrong.  pokey_timertiming's last section
 * says in PROSE that the first base tick is 24 cycles after the SKCTL write
 * where ours is 26 -- but that is a comment, and inittiming's are assertions.
 * The five cycles the cancellation test needs have to come from TIMER 1, not
 * from the base clock. */
#ifndef CHAIN_RELEASE
#define CHAIN_RELEASE BASE_64K
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

/* TWO-TONE MODE LENGTHENS EVERY PERIOD BUT THE FIRST.  pokey_timertiming's
 * two-tone section says so in its own header -- "IRQST is set at the same time
 * for the first period after STIMER.  Second and subsequent periods are two
 * cycles longer" -- and then tabulates it:
 *
 *     AUDF1=0    7c/ 8c    13c/14c
 *     AUDF1=8   15c/16c    29c/30c
 *
 * 16 is 4 + 12, the ordinary AUDF + 4 period; 30 is 16 + 14, not 16 + 12. */
#ifndef TWOTONE_EXTRA
#define TWOTONE_EXTRA 2
#endif

/* IN TWO-TONE, TIMER 2'S UNDERFLOW RESYNCS TIMER 1 -- and the reset arrives TWO
 * cycles behind it.  pokey_timertiming's last section schedules timer 1 one,
 * two and three cycles after timer 2 (AUDF1 98/99/100 against AUDF2 3 on the
 * 64 kHz clock) and requires timer 1 to FIRE at +1 and to be CANCELLED at both
 * +2 and +3.  A reset landing with the underflow would cancel all three; one
 * landing two cycles later cancels exactly the last two, provided it is applied
 * before that tick's decrement.
 *
 * Note the third sub-test's failure string reads "did not fire at +3c" while
 * its assertion requires A == 1, which is timer 1 NOT fired.  The assertion is
 * the authority; the string is the author's earlier intent. */
#ifndef TWOTONE_RESYNC
#define TWOTONE_RESYNC 2
#endif

/* EXPERIMENT: with FORCE BREAK as well as two-tone, channel 1's first period
 * after STIMER runs longer.  pokey_timertiming's cancellation section needs
 * timer 1 at AUDF + 9 for its three sub-tests to land 1, 2 and 3 cycles after
 * timer 2 (which the base clock pins at +106).  The plain two-tone sections use
 * SKCTL $0B and require AUDF + 4, so if this is real it belongs to force break,
 * not to two-tone.
 *
 * AT 5 IT PRODUCES EXACTLY THE ORDERING THE SECTION DESCRIBES -- probed, timer 2
 * at +106 and timer 1 at +107, one cycle later, where the default puts timer 1
 * three cycles EARLIER -- and sub-test 1 then FAILS anyway, at 42985 cycles
 * against 43327.  Both underflows happen and both status bits are raised (+110
 * and +111), so what breaks is DELIVERY, not order: the test reads IRQST after
 * a WSYNC and the bits surface too late for that read.  Off until that is
 * understood, because a constant that fixes the order and loses the test is
 * fitting the wrong thing. */
#ifndef TWOTONE_FB_FIRST
#define TWOTONE_FB_FIRST 0
#endif

static int period_of(const pokey_timer *p, int ch)
{
    /* The divider reloads with AUDF+1 of its input ticks — except off the 1.79
     * MHz clock, where the extra pipeline stages make it AUDF+4 unlinked and
     * +7 for a 16-bit pair.  pokey_timertiming catches the difference directly:
     * with +1 the timer "triggered too early". */
    int fast1 = (p->audctl & 0x40) != 0;
    int fast3 = (p->audctl & 0x20) != 0;

    if (ch == 0 && (p->audctl & 0x10))          /* 1+2 linked, 1 is the low half */
        return ((af(p, 1) << 8) | af(p, 0)) + (fast1 ? LINK_FAST : 1)
             + (((p->skctl & 0x08) && !p->ch_first[0]) ? TWOTONE_EXTRA : 0);
    if (ch == 2 && (p->audctl & 0x08))          /* 3+4 linked */
        return ((af(p, 3) << 8) | af(p, 2)) + (fast3 ? LINK_FAST : 1);
    if (ch == 0 && fast1)
        return af(p, 0) + 4
             + (((p->skctl & 0x08) && !p->ch_first[0]) ? TWOTONE_EXTRA : 0)
             + (((p->skctl & 0x88) == 0x88 && p->ch_first[0])
                ? TWOTONE_FB_FIRST : 0);
    if (ch == 2 && fast3) return af(p, 2) + 4;
    return af(p, ch) + 1;
}

/* Prime the capture path when the counter is far enough from its underflow that
 * the delay could not have mattered. */
/* How long the low half's reload value stays open to a late AUDF write, in
 * cycles after the underflow.  Measured, not chosen -- see audf_prime. */
/* A linked pair's INTERRUPT edge runs its own divider beside the counter its
 * SERIAL clock uses -- see underflow() and the STIMER case.  The two constants
 * say the first period after STIMER is AUDF + 5 and every period after it is
 * AUDF + 7, and AUDF + 7 is AUDF + LINK_FAST, the SAME period the serial edge
 * runs: only the FIRST period differs between the two edges. */
#ifndef PAIR_FIRST_IRQ
#define PAIR_FIRST_IRQ 1
#endif
#ifndef PAIR_FIRST_ADD
#define PAIR_FIRST_ADD 5
#endif

#ifndef PAIR_REARM_ADD
#define PAIR_REARM_ADD 7
#endif

#ifndef STIMER_PAIR_ADD
#define STIMER_PAIR_ADD 0
#endif

#ifndef STIMER_PAIR_RAW
#define STIMER_PAIR_RAW 0
#endif

/* Whether a STIMER strobe cancels an underflow raised on the very last tick --
 * see the preemption section in the STIMER case. */
#ifndef STIMER_CANCELS_FRESH
#define STIMER_CANCELS_FRESH 1
#endif

/* DISPROVED, kept with its score.  The two-tone reprogramming sub-test enables
 * IRQEN on the same cycle its second period underflows, which looked like the
 * mask being read when the bit SURFACES rather than at the underflow.  It is
 * not: MASK_AT_SURFACE=1 moves the failure BACKWARDS, from the "+17c should not
 * have succeeded" assertion at 38294 cycles to the "+16c should have succeeded"
 * one at 38066 -- something now fires that must not.  Whatever lets that
 * underflow through is narrower than a blanket deferral of the mask. */
/* A MASKED UNDERFLOW STILL ENTERS THE DELAY, AND AN ENABLE DURING ITS FLIGHT
 * LETS IT SURFACE.  The rule is ASYMMETRIC, and that asymmetry is the point: an
 * ENABLE arms a bit already in flight, a DISABLE never disarms one -- which is
 * ACK_CANCELS_INFLIGHT=0, settled long ago, stated the other way round.
 *
 * pokey_timertiming's two-tone reprogramming section needs both ends of it.  Its
 * second period underflows at +26 with IRQEN at 0 and the enable lands on cycle
 * 26, one cycle later; its third underflows at +40 and the enable lands on cycle
 * 42, THREE cycles later.  So the window is not one cycle -- it is however long
 * the status bit is in flight, IRQST_LAG.
 *
 * Gating the mask at surface time instead (MASK_AT_SURFACE) gets the same two
 * sub-tests and is still wrong: it lets a DISABLE cancel a bit in flight too,
 * which the ptimer gate catches directly ("...by exactly the modelled lag: got
 * -55 want 1") and which costs NINE tests -- 43 pass against 52. */
#ifndef IRQEN_ARMS_INFLIGHT
#define IRQEN_ARMS_INFLIGHT 1
#endif

#ifndef MASK_AT_SURFACE
#define MASK_AT_SURFACE 0
#endif

/* Six, and the test says why in prose: "the deadline timing for writes to AUDF1
 * is the same as unlinked from the END of the loop, presumably due to the late
 * reset from channel 2."  The unlinked window admits ages 0..2 (CH_LATCH_LAG);
 * the low half's admits 0..5, three wider, and those three are the late reset.
 * Measured on the 16-bit lo section: AUDCTL $50, AUDF1 $0D, so the low half
 * underflows at STIMER+17 (13 + 4) and IRQST bit 0 surfaces at +21 = "1 + 20".
 * A write at +22 is age 5 and must lengthen the next period to 22 (readable at
 * +43); a write at +23 is age 6 and must not (readable at +41).  Only 6 admits
 * the one and rejects the other. */
#ifndef LO_LATCH_LAG
#define LO_LATCH_LAG 6
#endif

/* The same window for a linked pair's HIGH half -- see audf_prime. */
#ifndef HI_LATCH_LAG
#define HI_LATCH_LAG 3
#endif

/* ...and the window for the pair's INTERRUPT divider, which is a SECOND counter
 * on the same pair and needs the rewrite routed to it too.  Splitting the two
 * edges without this left every AUDF rewrite reaching only cnt[], so the 16-bit
 * hi section saw its write land on the serial edge and vanish from the
 * interrupt: widening HI_LATCH_LAG to 9 changed nothing at all, which is what
 * says the branch was not the one deciding. */
#ifndef PAIR_LATCH_LAG
#define PAIR_LATCH_LAG 5
#endif
#ifndef PAIR_LATCH_ADJ
#define PAIR_LATCH_ADJ 0
#endif

/* ...and for an UNLINKED channel, which had no window at all.  Same shape, same
 * width, and pokey_timertiming brackets it in four consecutive sub-tests rather
 * than in prose: AUDCTL $40, AUDF1 $10 (period 20), STIMER, then AUDF1 := $12
 * (period 22).  Written 22 cycles after the STIMER write it must lengthen the
 * NEXT period -- IRQST bit 0 first readable at 46 = 4 + 20 + 22, checked from
 * both sides at +45 and +46 -- and written at 23 it must not, leaving
 * 44 = 4 + 20 + 20, again checked at +43 and +44.  The underflow is at +20
 * (IRQST_LAG carries it to the +24 the test's own diagram marks), so the window
 * admits an age of 2 and rejects 3, exactly as the pair's high half does. */
#ifndef CH_LATCH_LAG
#define CH_LATCH_LAG 3
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
    /* An UNLINKED channel keeps its own counter, so it keeps its own window.
     * The delay line above cannot serve this one: it captures the value TWO
     * cycles BEFORE the reload, which was fitted when the first underflow was
     * thought to be at STIMER+24.  IRQST_LAG puts the underflow at +20 and the
     * +24 the test marks is the STATUS BIT, so the write the test requires to
     * land arrives two cycles AFTER the reload, on the far side of the delay
     * line.  Re-latching from the raw AUDF is what reaches it. */
    {
        int linked = (ch == 0) ? (p->audctl & 0x10)
                   : (ch == 2) ? (p->audctl & 0x08)
                   : (ch == 1) ? (p->audctl & 0x10) : (p->audctl & 0x08);
        int fast   = (ch <= 1) ? (p->audctl & 0x40) : (p->audctl & 0x20);
        /* The window is a fixed distance before the NEXT underflow, so when
         * two-tone lengthens the period the window moves out with it.  The
         * two-tone reprogramming sub-tests are the ordinary ones with the
         * deadline shifted by exactly TWOTONE_EXTRA: AUDF1 $08 -> $FF written 16
         * cycles past STIMER must lengthen the next period and written at 17
         * must not, against +22/+23 with no two-tone.  The underflow is at +12
         * either way, so the ages are 4 and 5 where they were 2 and 3.
         *
         * This looked like a no-op when it was first tried, because the sub-test
         * that needs it was passing for the WRONG REASON: its underflow was
         * being masked (see IRQEN_UNMASKS_FRESH), so nothing fired whether the
         * write landed or not.  Fixing the mask is what made it measurable. */
        int lag = CH_LATCH_LAG
                + ((ch == 0 && (p->skctl & 0x08) && !p->ch_first[0])
                   ? TWOTONE_EXTRA : 0);
        if (CH_LATCH_LAG && !linked && p->ch_age[ch] < lag) {
            int per = p->audf[ch] + ((fast && (ch == 0 || ch == 2)) ? 4 : 1)
                    + ((ch == 0 && (p->skctl & 0x08) && !p->ch_first[0])
                       ? TWOTONE_EXTRA : 0);
            p->cnt[ch] = per - p->ch_age[ch];
        }
    }

    /* The pair's INTERRUPT divider takes the rewrite too -- it counts the same
     * period on its own, so a write that reaches cnt[] and not this one changes
     * the serial edge and leaves the interrupt where it was. */
    if (PAIR_FIRST_IRQ) {
        int pair   = ch >> 1;
        int linked = (pair == 0) ? (p->audctl & 0x10) : (p->audctl & 0x08);
        int fast   = (pair == 0) ? (p->audctl & 0x40) : (p->audctl & 0x20);
        if (linked && fast && p->hi_first_armed[pair]) {
            int elapsed = p->hi_first_per[pair] - p->hi_first[pair];
            if (elapsed >= 0 && elapsed < PAIR_LATCH_LAG) {
                int per = ((p->audf[2 * pair + 1] << 8) | p->audf[2 * pair])
                        + PAIR_REARM_ADD;
                p->hi_first[pair]     = per - elapsed + PAIR_LATCH_ADJ;
                p->hi_first_per[pair] = per;
            }
        }
    }

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
    p->ch_age[ch] = 0;
}

void pokey_timer_reset(pokey_timer *p)
{
    /* The reload-latch ages and the deferred status bits are STATE, and reset
     * initialises field by field rather than zeroing the struct -- so anything
     * added here has to be cleared here too.  A stack-allocated pokey_timer
     * (which is what the ptimer gate uses, where the ACID harness has a zeroed
     * static) otherwise starts with garbage ages that fire a latch immediately
     * and garbage countdowns that clear IRQST bits nothing ever set. */
    p->hi_first[0] = p->hi_first[1] = 0;
    p->hi_first_per[0] = p->hi_first_per[1] = 0;
    p->hi_first_armed[0] = p->hi_first_armed[1] = 0;
    p->hi_skip[0] = p->hi_skip[1] = 0;
    for (int i = 0; i < 8; i++) p->st_lag[i] = 0;
    p->hi_age[0] = p->hi_age[1] = 0;
    p->lo_age[0] = p->lo_age[1] = 0;
    for (int i = 0; i < 4; i++) p->ch_age[i] = p->ch_first[i] = 0;
    for (int i = 0; i < 8; i++) p->st_armed[i] = 0;
    p->tt_resync = 0;
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

    /* EXPERIMENT (MASK_AT_SURFACE): is the mask applied at the UNDERFLOW or when
     * the status bit SURFACES four cycles later?  pokey_timertiming's two-tone
     * reprogramming sub-test enables IRQEN on the SAME cycle its second period
     * underflows (+26) and then requires the bit READ at +30 -- so the underflow
     * has to survive a mask that is lifted at the moment it happens. */
    int enabled = (p->irqen & bit) != 0;
    if (!MASK_AT_SURFACE && !enabled && !IRQEN_ARMS_INFLIGHT)
        return;                                          /* masked: no request */
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
    /* With no lag there is no flight to be armed during, so a masked raise on a
     * base-clocked channel is simply lost, exactly as before. */
    if (!enabled && !lag) return;
    if (lag) {
        p->st_lag[bit_index(bit)]   = (uint8_t)lag;
        p->st_armed[bit_index(bit)] = (uint8_t)enabled;
    } else {
        p->irqst = (uint8_t)(p->irqst & ~bit);
    }
    if (!enabled) return;                    /* in flight, but nothing asked yet */
    if (pokey_timer_probe == 2) {
        static int n;
        if (n < 20) { n++;
            fprintf(stderr, "  /IRQ raised by bit $%02X (irqen $%02X irqst $%02X)\n",
                    bit, p->irqen, p->irqst); }
    }
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
    /* FORCE BREAK (SKCTL bit 7) drives the output to SPACE, and in two-tone
     * that is what decides which timer runs: with the bit at 0 timer 2 is not
     * held, which is exactly how pokey_timertiming's last two sections describe
     * themselves -- "with force break activated (resync 1+2 triggered only by
     * timer 2)".  Without this, SKCTL $8B left the line idle-MARK, timer2_held()
     * held timer 2 for ever and it never underflowed at all: the probe shows
     * only T1 and T4 events across the whole section. */
    if (p->skctl & 0x80) return 0;             /* force break: space */
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
    /* Before the reload, which computes the period about to run.  A linked
     * pair's event arrives as the HIGH channel, but the counter it reloads is
     * the LOW one -- so that is the first-period flag to clear. */
    p->ch_first[ch] = 0;
    if (ch == 1 && (p->audctl & 0x10)) p->ch_first[0] = 0;
    /* Timer 2 underflowing in two-tone resyncs timer 1, after a delay. */
    if (ch == 1 && (p->skctl & 0x08)) p->tt_resync = TWOTONE_RESYNC;
    if (ch == 3 && (p->audctl & 0x08)) p->ch_first[2] = 0;

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
    if (PAIR_FIRST_IRQ && linked && p->hi_skip[pair]) {
        p->hi_skip[pair] = 0;      /* the one-shot already raised this one */
        return;
    }
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
    if (pokey_timer_probe)
        fprintf(stderr, "  SKCTL <- $%02X at tick %llu (init %d -> %d)\n",
                val, (unsigned long long)p->ticks, p->init, now);
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
        p->chain = CHAIN_RELEASE;
    }
    p->init = now;
}

void pokey_timer_tick(pokey_timer *p)
{
    p->ticks++;
    for (int i = 0; i < 8; i++)
        if (p->st_lag[i] && --p->st_lag[i] == 0) {
            /* The mask is read HERE under MASK_AT_SURFACE: the underflow enters
             * the delay chain regardless and IRQEN gates the latch at the point
             * the bit is presented. */
            if (MASK_AT_SURFACE && !(p->irqen & (1u << i))) continue;
            if (IRQEN_ARMS_INFLIGHT && !p->st_armed[i]) continue;
            p->irqst = (uint8_t)(p->irqst & ~(1u << i));
            /* The cycle the BIT BECOMES READABLE, which is what every IRQST
             * bracket in pokey_timertiming actually measures.  Deriving it by
             * adding a lag to the raise by hand is how the last premise went
             * wrong. */
            if (pokey_timer_probe)
                fprintf(stderr, "    -> IRQST bit %d readable at +%llu\n", i,
                        (unsigned long long)(p->ticks - p->stimer_at));
        }
    if (PAIR_FIRST_IRQ)
        for (int i = 0; i < 2; i++)
            if (p->hi_first_armed[i] && --p->hi_first[i] <= 0) {
                /* ...and it RE-ARMS: the interrupt edge runs its own divider
                 * for every period, not just the first.  Covering only the
                 * first period passes the 16-bit HI loop #1 and then fails
                 * loop #2 late, which is the same gap one period further on. */
                p->hi_first[i] = ((p->audf[2 * i + 1] << 8) | p->audf[2 * i])
                               + PAIR_REARM_ADD
                               + ((i == 0 && (p->skctl & 0x08)) ? TWOTONE_EXTRA : 0);
                p->hi_first_per[i] = p->hi_first[i];
                p->hi_skip[i] = 1;
                p->hi_lag[i] = PAIR_IRQ_LAG;
            }
    if (p->hi_age[0] < 255) p->hi_age[0]++;
    if (p->hi_age[1] < 255) p->hi_age[1]++;
    for (int i = 0; i < 4; i++) if (p->ch_age[i] < 255) p->ch_age[i]++;
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
    if (held34) {
        reload(p, 2); reload(p, 3);
        /* The pair's INTERRUPT divider is held in reset by async receive too.
         * It is a second divider on the same pair, not a bookkeeping variable:
         * pokey_asyncrecv's skiptest is a RESET test, not a period test -- it
         * turns the mode on at stimer+6 lines and off at +8, then requires the
         * next interrupt a full 4-line period later at +12 rather than at +8
         * where the uninterrupted count would have put it.  Holding cnt[] and
         * letting this one free-run fires at +8 and trips sub-case 3, which is
         * exactly how PAIR_FIRST_IRQ cost this test while passing both of
         * pokey_timertiming's 16-bit HI loops. */
        if (PAIR_FIRST_IRQ && p->hi_first_armed[1]) {
            p->hi_first[1] = ((p->audf[3] << 8) | p->audf[2]) + PAIR_REARM_ADD;
            p->hi_skip[1]  = 0;
            p->hi_lag[1]   = 0;
        }
    }

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
            /* Every reload here is past the first period by construction --
             * STIMER sets locnt directly -- so the two-tone extra is
             * unconditional.  Timers 1 and 2 are the pair two-tone keys
             * between, so pair 3+4 does not take it. */
            p->locnt[0] = af_lo(p, 0) + LINK_FAST
                        + ((p->skctl & 0x08) ? TWOTONE_EXTRA : 0);
            p->lo_age[0] = 0;               /* the latch is still open, just */
            raise(p, POKEY_IRQ_TIMER1);
        } else if (p->lo_age[0] < 255) {
            p->lo_age[0]++;
        }
    }
    /* BEFORE the decrement: a resync landing on the same tick as timer 1's
     * underflow must cancel it, which is the +2 sub-test. */
    if (p->tt_resync && --p->tt_resync == 0) reload(p, 0);
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
        /* A STIMER STROBE CANCELS AN INTERRUPT THAT HAS ONLY JUST UNDERFLOWED.
         * pokey_timertiming's preemption section tabulates the boundary for two
         * AUDF values and both STIMER strobes at once:
         *
         *     AUDF1=0    4c/ 5c     8c/ 9c
         *     AUDF1=8   12c/13c    24c/25c
         *
         * Period is AUDF + 4, so those underflows land at the end of cycles 3,
         * 7, 11 and 23 -- and every single "preempts" cycle is the one
         * IMMEDIATELY AFTER an underflow, every "does not" the one after that.
         * So the window is ONE cycle, not the four the status bit is in flight
         * for: STIMER reaches the counter and the first stage of the delay that
         * carries the underflow to IRQST, and nothing further along it.
         *
         * A bit raised on the last tick still has its full lag standing, and one
         * more tick would have decremented it -- so "st_lag still at its maximum"
         * IS the one-cycle window, with no separate timer needed.  IRQST is
         * active low and the bit has not been cleared yet, so dropping the
         * countdown is the whole cancellation. */
        if (STIMER_CANCELS_FRESH) {
            uint8_t fresh = POKEY_IRQ_TIMER1 | POKEY_IRQ_TIMER2 | POKEY_IRQ_TIMER4;
            for (int i = 0; i < 8; i++) {
                if (!(fresh & (1u << i)) || p->st_lag[i] != IRQST_LAG) continue;
                p->st_lag[i] = 0;
                if (p->irq_arm == IRQ_LINE_LAG + IRQST_LAG) p->irq_arm = 0;
                if (pokey_timer_probe)
                    fprintf(stderr, "    STIMER cancels in-flight IRQST bit %d\n", i);
            }
        }

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
        for (int i = 0; i < 4; i++) p->ch_first[i] = 1;
        for (int i = 0; i < 4; i++) reload(p, i);
        /* A LINKED PAIR'S FIRST PERIOD AFTER STIMER IS THE RAW 16-BIT VALUE,
         * with none of the propagation LINK_FAST adds to every period after it.
         * pokey_timertiming's 16-bit HI loop #1 pins it: with AUDF 16/0 it
         * wants IRQST bit 1 readable at +23, and 16 + PAIR_IRQ_LAG(3) +
         * IRQST_LAG(4) is 23 exactly, where 16 + LINK_FAST puts it at 30. */
        if (STIMER_PAIR_RAW) {
            if (p->audctl & 0x10)
                p->cnt[0] = ((p->audf[1] << 8) | p->audf[0]) + STIMER_PAIR_ADD;
            if (p->audctl & 0x08)
                p->cnt[2] = ((p->audf[3] << 8) | p->audf[2]) + STIMER_PAIR_ADD;
        }
        p->locnt[0] = p->audf[0] + ((p->audctl & 0x40) ? 4 : 1) + LO_EXTRA;
        p->lo_el[0] = p->lo_el[1] = 0;
        p->lo_first[0] = p->lo_first[1] = 1;
        p->locnt[1] = p->audf[2] + ((p->audctl & 0x20) ? 4 : 1) + LO_EXTRA;
        if (pokey_timer_probe)
            fprintf(stderr, "    STIMER loads cnt[0]=%d locnt[0]=%d\n",
                    p->cnt[0], p->locnt[0]);
        p->hi_lag[0] = p->hi_lag[1] = 0;
        /* THE PAIR'S FIRST INTERRUPT AFTER STIMER GETS ITS OWN COUNTDOWN.
         * Its counter is shared with the SERIAL clock, and the two edges are
         * not the same event: pokey_sertiming wants the serial tick at
         * AUDF + LINK_FAST, pokey_timertiming wants the interrupt at AUDF + 4
         * (measured — see emu/README.md; sweeping the shared value gives 4 for
         * one test and 7 for the other and nothing for both).  So the serial
         * edge keeps cnt[] and the interrupt runs a one-shot beside it. */
        if (PAIR_FIRST_IRQ) {
            for (int i = 0; i < 2; i++) {
                int linked = (i == 0) ? (p->audctl & 0x10) : (p->audctl & 0x08);
                /* The one-shot counts MACHINE cycles, so it models the 1.79 MHz
                 * tap and nothing else.  A pair clocked off the 64 kHz base
                 * divider still gets its interrupt from cnt[], which counts BASE
                 * ticks: arming this for it fires after AUDF machine cycles
                 * instead of AUDF*28, which is what the ptimer gate's
                 * "linked 1+2 counts 16 bits" caught (262 against 7168). */
                int fast   = (i == 0) ? (p->audctl & 0x40) : (p->audctl & 0x20);
                p->hi_first_armed[i] = 0; p->hi_skip[i] = 0;
                if (linked && fast) {
                    p->hi_first[i] = ((p->audf[2 * i + 1] << 8) | p->audf[2 * i])
                                   + PAIR_FIRST_ADD;
                    p->hi_first_per[i] = p->hi_first[i];
                    p->hi_first_armed[i] = 1;
                }
            }
        }
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
        /* ...and an enable takes up an underflow masked on the last tick.  After
         * the clear above, which would otherwise undo it. */
        if (IRQEN_ARMS_INFLIGHT)
            for (int i = 0; i < 8; i++)
                if ((val & (1u << i)) && p->st_lag[i] && !p->st_armed[i]) {
                    p->st_armed[i] = 1;
                    p->irq_arm = (uint8_t)(p->st_lag[i] + IRQ_LINE_LAG);
                }
        break;
    default: break;
    }
}

/* ACID_PTPROBE=1 also reports WHEN the guest READS IRQST, in the same frame the
 * underflow and "readable at" lines use -- ticks since the last STIMER.  Without
 * that the two cannot be compared, and ACID_PCWATCH is no substitute: it fires
 * when PC BECOMES the address, which for an instruction after `sta wsync` is
 * before the halt is felt, not when the read happens. */
uint8_t pokey_timer_irqst_probe(const pokey_timer *p)
{
    if (pokey_timer_probe)
        fprintf(stderr, "  IRQST read at +%llu -> $%02X\n",
                (unsigned long long)(p->ticks - p->stimer_at),
                (uint8_t)(p->irqst | 0xE0));
    return 0;
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
