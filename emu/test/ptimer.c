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
    expect("64kHz base tick", cycles_to_irq(&p, POKEY_IRQ_TIMER1, 500), 28);

    setup(&p, 0x01, POKEY_IRQ_TIMER1);
    pokey_timer_write(&p, 0xD200, 0);
    pokey_timer_write(&p, 0xD209, 0);
    expect("15kHz base tick", cycles_to_irq(&p, POKEY_IRQ_TIMER1, 500), 114);

    /* AUDF+1 base ticks. */
    setup(&p, 0x00, POKEY_IRQ_TIMER1);
    pokey_timer_write(&p, 0xD200, 3);
    pokey_timer_write(&p, 0xD209, 0);
    expect("AUDF+1 base ticks", cycles_to_irq(&p, POKEY_IRQ_TIMER1, 500), 4 * 28);

    /* ---- 1.79 MHz mode divides by AUDF+4, not AUDF+1 ------------------- */
    setup(&p, 0x40, POKEY_IRQ_TIMER1);           /* AUDCTL bit 6: ch1 fast */
    pokey_timer_write(&p, 0xD200, 10);
    pokey_timer_write(&p, 0xD209, 0);
    expect("1.79MHz divides by AUDF+4",
           cycles_to_irq(&p, POKEY_IRQ_TIMER1, 500), 14);

    /* ---- channel 3 has NO interrupt of its own.  Run it fast while the three
     * channels that DO interrupt are held off, and nothing may be requested. */
    setup(&p, 0x00, 0xFF);
    pokey_timer_write(&p, 0xD200, 0xFF);         /* AUDF1 long */
    pokey_timer_write(&p, 0xD202, 0xFF);         /* AUDF2 long */
    pokey_timer_write(&p, 0xD204, 0x00);         /* AUDF3 as short as it goes */
    pokey_timer_write(&p, 0xD206, 0xFF);         /* AUDF4 long */
    pokey_timer_write(&p, 0xD209, 0);
    for (int i = 0; i < 2000; i++) pokey_timer_tick(&p);
    expect("channel 3 raises no interrupt", pokey_timer_irqst(&p), 0xFF);

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
           cycles_to_irq(&p, POKEY_IRQ_TIMER2, 40000), 256 * 28);

    printf("ptimer: %s\n", fails ? "FAIL" : "all POKEY timer tests pass");
    return fails ? 1 : 0;
}
