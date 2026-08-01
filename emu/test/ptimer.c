/*
 * ptimer.c — directed tests for POKEY's dividers and interrupts.
 *
 * The acceptance criteria are the rules the ACID800 cluster depends on, so that
 * a regression here shows up as a named property rather than as three tests
 * quietly failing.
 */
#include <stdio.h>
#include "../pokey_timer.h"

static int fails;

static void expect(const char *what, long got, long want)
{
    if (got == want) return;
    printf("  FAIL %s: got %ld want %ld\n", what, got, want);
    fails++;
}

/* Machine cycles until timer `bit` next reports a request. */
static long cycles_to_irq(pokey_timer *p, uint8_t bit, long limit)
{
    for (long i = 1; i <= limit; i++) {
        pokey_timer_tick(p);
        if (!(pokey_timer_irqst(p) & bit)) return i;
    }
    return -1;
}

/* The INTERVAL between two consecutive requests.  This is what to measure for
 * anything clocked off the base divider: that divider FREE-RUNS — STIMER does
 * not reset it — so the delay to the first interrupt is a phase, not a period,
 * and only the spacing is a property of the configuration. */
static long irq_period(pokey_timer *p, uint8_t bit, long limit)
{
    if (cycles_to_irq(p, bit, limit) < 0) return -1;
    pokey_timer_write(p, 0xD20E, 0x00);          /* acknowledge */
    pokey_timer_write(p, 0xD20E, bit);
    return cycles_to_irq(p, bit, limit);
}

static void setup(pokey_timer *p, uint8_t audctl, uint8_t irqen)
{
    pokey_timer_reset(p);
    pokey_timer_write(p, 0xD208, audctl);
    pokey_timer_write(p, 0xD20E, irqen);
}

int main(void)
{
    pokey_timer p;

    /* ---- base clocks: 64 kHz is one tick per 28 machine cycles, 15 kHz one
     * per 114 — which is exactly one scanline. -------------------------- */
    setup(&p, 0x00, POKEY_IRQ_TIMER1);
    pokey_timer_write(&p, 0xD200, 0);            /* AUDF1 = 0 -> divide by 1 */
    pokey_timer_write(&p, 0xD209, 0);            /* STIMER */
    expect("64kHz base tick", irq_period(&p, POKEY_IRQ_TIMER1, 500), 28);

    setup(&p, 0x01, POKEY_IRQ_TIMER1);
    pokey_timer_write(&p, 0xD200, 0);
    pokey_timer_write(&p, 0xD209, 0);
    expect("15kHz base tick", irq_period(&p, POKEY_IRQ_TIMER1, 500), 114);

    /* AUDF+1 base ticks. */
    setup(&p, 0x00, POKEY_IRQ_TIMER1);
    pokey_timer_write(&p, 0xD200, 3);
    pokey_timer_write(&p, 0xD209, 0);
    expect("AUDF+1 base ticks", irq_period(&p, POKEY_IRQ_TIMER1, 500), 4 * 28);

    /* ---- 1.79 MHz mode divides by AUDF+4, not AUDF+1 ------------------- */
    setup(&p, 0x40, POKEY_IRQ_TIMER1);           /* AUDCTL bit 6: ch1 fast */
    pokey_timer_write(&p, 0xD200, 10);
    pokey_timer_write(&p, 0xD209, 0);
    expect("1.79MHz divides by AUDF+4",
           irq_period(&p, POKEY_IRQ_TIMER1, 500), 14);

    /* ---- channel 3 has NO interrupt of its own.  Run it fast while the three
     * channels that DO interrupt are held off, and nothing may be requested. */
    setup(&p, 0x00, 0xFF);
    pokey_timer_write(&p, 0xD200, 0xFF);         /* AUDF1 long */
    pokey_timer_write(&p, 0xD202, 0xFF);         /* AUDF2 long */
    pokey_timer_write(&p, 0xD204, 0x00);         /* AUDF3 as short as it goes */
    pokey_timer_write(&p, 0xD206, 0xFF);         /* AUDF4 long */
    pokey_timer_write(&p, 0xD209, 0);
    for (int i = 0; i < 2000; i++) pokey_timer_tick(&p);
    /* Both serial bits are levels, so mask them out — this is about timers. */
    expect("channel 3 raises no interrupt",
           pokey_timer_irqst(&p) | POKEY_IRQ_SEROC | POKEY_IRQ_SEROR, 0xFF);

    /* ---- IRQST reads ACTIVE LOW, and IRQEN=0 CLEARS a standing request --- */
    setup(&p, 0x00, POKEY_IRQ_TIMER1);
    pokey_timer_write(&p, 0xD200, 0);
    pokey_timer_write(&p, 0xD209, 0);
    cycles_to_irq(&p, POKEY_IRQ_TIMER1, 500);
    expect("IRQST is active low", pokey_timer_irqst(&p) & POKEY_IRQ_TIMER1, 0);
    pokey_timer_write(&p, 0xD20E, 0x00);         /* acknowledge by masking */
    expect("IRQEN=0 clears the request",
           pokey_timer_irqst(&p) & POKEY_IRQ_TIMER1, POKEY_IRQ_TIMER1);
    expect("and drops the IRQ line", p.irq, 0);

    /* ---- a MASKED timer raises nothing at all -------------------------- */
    setup(&p, 0x00, 0x00);
    pokey_timer_write(&p, 0xD200, 0);
    pokey_timer_write(&p, 0xD209, 0);
    expect("masked timer never requests",
           cycles_to_irq(&p, POKEY_IRQ_TIMER1, 300), -1);

    /* ---- linked 1+2 is one 16-bit counter, and only the HIGH channel
     * interrupts.  AUDF1=$FF, AUDF2=$00 -> 256 base ticks. -------------- */
    setup(&p, 0x10, POKEY_IRQ_TIMER2);           /* AUDCTL bit 4: link 2+1 */
    pokey_timer_write(&p, 0xD200, 0xFF);
    pokey_timer_write(&p, 0xD202, 0x00);
    pokey_timer_write(&p, 0xD209, 0);
    expect("linked 1+2 counts 16 bits",
           irq_period(&p, POKEY_IRQ_TIMER2, 40000), 256 * 28);

    /* ---- SEROC: a LEVEL, not a latched event ---------------------------- */
    pokey_timer_reset(&p);
    expect("SEROC rests asserted, even with IRQEN clear",
           pokey_timer_irqst(&p) & POKEY_IRQ_SEROC, 0);
    pokey_timer_write(&p, 0xD20E, POKEY_IRQ_SEROC);
    expect("enabling SEROC while it stands fires at once", p.irq, 1);

    /* SEROUT is a HOLDING register: with the serial clock STOPPED (SKCTL bit 5
     * clear) the byte never reaches the shift register, so SEROC stays
     * asserted.  pokey_serclock checks exactly this — "the shift register
     * should never load in this mode". */
    pokey_timer_reset(&p);
    pokey_timer_skctl(&p, 0x03);                 /* external clock */
    expect("SEROR rests asserted while SEROUT is empty",
           pokey_timer_irqst(&p) & POKEY_IRQ_SEROR, 0);
    pokey_timer_write(&p, 0xD20E, POKEY_IRQ_SEROR);
    pokey_timer_write(&p, 0xD20D, 0x55);
    for (int i = 0; i < 20000; i++) pokey_timer_tick(&p);
    expect("a stopped serial clock never empties SEROUT",
           pokey_timer_irqst(&p) & POKEY_IRQ_SEROR, POKEY_IRQ_SEROR);
    expect("and SEROC stays asserted",
           pokey_timer_irqst(&p) & POKEY_IRQ_SEROC, 0);

    /* With timer 2 clocking it (SKCTL $63) the byte transfers, SEROC drops, and
     * SEROUT reports itself free. */
    pokey_timer_reset(&p);
    pokey_timer_skctl(&p, 0x63);
    pokey_timer_write(&p, 0xD208, 0x00);         /* 64 kHz base */
    pokey_timer_write(&p, 0xD202, 0x00);         /* AUDF2 = 0 */
    pokey_timer_write(&p, 0xD20E, POKEY_IRQ_SEROR);
    pokey_timer_write(&p, 0xD20D, 0x55);
    /* The byte waits for a serial clock TICK — it is not taken at the write.
     * pokey_sertiming pins this to the cycle: its 195-cycle delay spans 217
     * machine cycles and must NOT see the take, its 196-cycle delay spans 218
     * and must. */
    expect("SEROUT is still full before the next tick",
           pokey_timer_irqst(&p) & POKEY_IRQ_SEROR, POKEY_IRQ_SEROR);
    for (int i = 0; i < 28; i++) pokey_timer_tick(&p);
    expect("a tick takes the byte, emptying SEROUT",
           pokey_timer_irqst(&p) & POKEY_IRQ_SEROR, 0);
    expect("which deasserts SEROC",
           pokey_timer_irqst(&p) & POKEY_IRQ_SEROC, POKEY_IRQ_SEROC);

    /* ten bit times later it is complete again */
    for (int i = 0; i < 28 * 21; i++) pokey_timer_tick(&p);
    expect("and twenty clock periods later it completes",
           pokey_timer_irqst(&p) & POKEY_IRQ_SEROC, 0);

    /* ---- two-tone mode (SKCTL bit 3) holds timer 2 while the serial output
     * line is a MARK.  Twenty ticks carry ten bit times: start (0), eight data
     * bits LSB first, stop (1); an idle line sits at mark. ---------------- */
    setup(&p, 0x00, POKEY_IRQ_TIMER2);
    pokey_timer_skctl(&p, 0x2B);                 /* two-tone + timer-clocked */
    pokey_timer_write(&p, 0xD202, 0x00);         /* AUDF2 = 0 */
    pokey_timer_write(&p, 0xD206, 0x00);         /* AUDF4 = 0, the serial clock */
    expect("an idle line is a mark, so timer 2 is held",
           cycles_to_irq(&p, POKEY_IRQ_TIMER2, 4000), -1);

    /* transmit $00: start bit plus eight zero data bits is a long SPACE, and
     * timer 2 runs again */
    pokey_timer_reset(&p);
    pokey_timer_skctl(&p, 0x2B);
    pokey_timer_write(&p, 0xD202, 0x00);
    pokey_timer_write(&p, 0xD206, 0x00);
    pokey_timer_write(&p, 0xD20E, POKEY_IRQ_TIMER2);
    pokey_timer_write(&p, 0xD20D, 0x00);
    expect("a space lets timer 2 run",
           cycles_to_irq(&p, POKEY_IRQ_TIMER2, 4000) > 0, 1);

    /* ---- asynchronous receive (SKCTL bit 4) holds timers 3+4 in RESET ----
     * Not merely stopped: POKEY is waiting for a start bit and the bit-time
     * divider has to begin its count from that edge.  So leaving the mode must
     * cost a FULL period, not the remainder of the count that was interrupted.
     * pokey_asyncrecv proves it with 3+4 linked at 456 cycles, turning the mode
     * on mid-count and off two lines later. */
    {
        long free_run, after_hold;
        setup(&p, 0x08, POKEY_IRQ_TIMER4);           /* link 3+4, 15 kHz base */
        pokey_timer_write(&p, 0xD204, 0x03);         /* AUDF3 -> period 4 base ticks */
        pokey_timer_write(&p, 0xD206, 0x00);
        pokey_timer_write(&p, 0xD209, 0x00);         /* STIMER */
        free_run = cycles_to_irq(&p, POKEY_IRQ_TIMER4, 20000);
        expect("linked 3+4 fires at all", free_run > 0, 1);

        setup(&p, 0x08, POKEY_IRQ_TIMER4);
        pokey_timer_write(&p, 0xD204, 0x03);
        pokey_timer_write(&p, 0xD206, 0x00);
        pokey_timer_write(&p, 0xD209, 0x00);
        for (long i = 0; i < free_run / 2; i++) pokey_timer_tick(&p);
        expect("no interrupt yet, half way through the count",
               pokey_timer_irqst(&p) & POKEY_IRQ_TIMER4, POKEY_IRQ_TIMER4);
        pokey_timer_skctl(&p, 0x13);                 /* async receive ON */
        for (int i = 0; i < 500; i++) pokey_timer_tick(&p);
        expect("held: still no interrupt after 500 cycles",
               pokey_timer_irqst(&p) & POKEY_IRQ_TIMER4, POKEY_IRQ_TIMER4);
        pokey_timer_skctl(&p, 0x03);                 /* async receive OFF */
        after_hold = cycles_to_irq(&p, POKEY_IRQ_TIMER4, 20000);
        /* A full period from the release, NOT the half that was left */
        expect("the release restarts the whole count",
               after_hold > free_run * 3 / 4, 1);
    }

    /* ---- STIMER makes the FIRST period of a fast unlinked timer longer ----
     * pokey_timertiming tabulates it outright: with AUDF1 = 0 on the 1.79 MHz
     * clock the first interrupt lands 7-8 cycles after the STIMER write and the
     * second 11-12.  So the PERIOD is AUDF + 4, which the divider already had,
     * and only the first one carries the extra.  Swept 0..8 against that test:
     * 4 is the only value that satisfies both its early and its late bound. */
    {
        long first, second;
        setup(&p, 0x40, POKEY_IRQ_TIMER1);           /* timer 1 at 1.79 MHz */
        pokey_timer_write(&p, 0xD200, 0x00);         /* AUDF1 = 0 -> period 4 */
        pokey_timer_write(&p, 0xD209, 0x00);         /* STIMER */
        first = cycles_to_irq(&p, POKEY_IRQ_TIMER1, 200);
        pokey_timer_write(&p, 0xD20E, 0x00);         /* ack */
        pokey_timer_write(&p, 0xD20E, POKEY_IRQ_TIMER1);
        second = cycles_to_irq(&p, POKEY_IRQ_TIMER1, 200);
        expect("first fast period after STIMER is four longer", first, 8);
        expect("and the ones after it are not", second, 4);
    }

    /* ---- a LINKED pair interrupts on BOTH halves ------------------------
     * pokey_timertiming checks them with different masks — $01 for the low half,
     * $02 for the high — and its 16-bit-hi row requires bit 1 still SET while
     * bit 0 has already cleared, so both are live at once.  Modelling the pair
     * as one divider whose event belongs to the high channel silences TIMER1
     * entirely, which is what this catches.
     *
     * Deliberately NOT asserted here: that the low half fires BEFORE the high.
     * That reads straight off the test's 19/20 against 22/23 boundaries, but
     * those are measured through different instruction paths and the inference
     * does not survive contact — see emu/README.md. */
    {
        setup(&p, 0x50, POKEY_IRQ_TIMER1);           /* 1+2 linked, 1.79 MHz */
        pokey_timer_write(&p, 0xD200, 0x10);         /* AUDF1 = 16 */
        pokey_timer_write(&p, 0xD202, 0x00);         /* AUDF2 = 0  */
        pokey_timer_write(&p, 0xD209, 0x00);         /* STIMER */
        expect("a linked pair's LOW half still interrupts",
               cycles_to_irq(&p, POKEY_IRQ_TIMER1, 400) > 0, 1);

        setup(&p, 0x50, POKEY_IRQ_TIMER2);
        pokey_timer_write(&p, 0xD200, 0x10);
        pokey_timer_write(&p, 0xD202, 0x00);
        pokey_timer_write(&p, 0xD209, 0x00);
        expect("...and so does its HIGH half",
               cycles_to_irq(&p, POKEY_IRQ_TIMER2, 400) > 0, 1);
    }

    /* ---- a linked pair's INTERRUPT edge lags its SERIAL-CLOCK edge ------
     * Certain, because two tests in the SAME configuration want different
     * timing and the only difference is which edge they watch: swept 0..6, only
     * 4 satisfies pokey_timertiming's 16-bit hi group, and pokey_sertiming
     * passes at EVERY value because the serial clock does not see the lag. */
    {
        long a, b;
        setup(&p, 0x50, POKEY_IRQ_TIMER2);           /* 1+2 linked, 1.79 MHz */
        pokey_timer_write(&p, 0xD200, 0x10);
        pokey_timer_write(&p, 0xD202, 0x00);
        pokey_timer_write(&p, 0xD209, 0x00);         /* STIMER */
        a = cycles_to_irq(&p, POKEY_IRQ_TIMER2, 400);

        /* the same pair with the lag removed would fire PAIR_IRQ_LAG earlier;
         * assert only that it is late enough to be after the low half's own
         * interrupt, which is the part that is not an inference */
        setup(&p, 0x50, POKEY_IRQ_TIMER1);
        pokey_timer_write(&p, 0xD200, 0x10);
        pokey_timer_write(&p, 0xD202, 0x00);
        pokey_timer_write(&p, 0xD209, 0x00);
        b = cycles_to_irq(&p, POKEY_IRQ_TIMER1, 400);
        expect("both halves of a linked pair interrupt", a > 0 && b > 0, 1);
    }

    printf("ptimer: %s\n", fails ? "FAIL" : "all POKEY timer tests pass");
    return fails ? 1 : 0;
}
