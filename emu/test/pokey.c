/*
 * pokey.c — directed tests for the POKEY RANDOM LFSR.
 *
 * The acceptance criteria are the four values ACID800 itself depends on, which
 * is what makes this worth having as a standalone gate: if these drift, every
 * ANTIC timing test built on RANDOM-as-a-clock silently measures the wrong
 * thing rather than failing usefully.
 */
#include <stdio.h>
#include "../pokey_rand.h"

static int fails;

/* Value read `n` machine cycles after the SKCTL release. */
static uint8_t at(uint8_t audctl, int n)
{
    pokey_rand p;
    pokey_rand_reset(&p);
    pokey_rand_audctl(&p, audctl);
    pokey_rand_skctl(&p, 0x03);           /* leave init: seed is all-ones */
    for (int i = 0; i < n; i++) pokey_rand_tick(&p);
    return pokey_rand_read(&p);
}

static void expect(const char *what, unsigned got, unsigned want)
{
    if (got == want) return;
    printf("  FAIL %s: got $%02X want $%02X\n", what, got, want);
    fails++;
}

int main(void)
{
    /* 9-bit poly (AUDCTL[7] set) — the three simultaneous constraints that
     * pinned this model, straight out of ACID800 antic_wsync. */
    expect("9-bit @113",  at(0x80, 113), 0x95);
    expect("9-bit @227",  at(0x80, 227), 0x4B);
    expect("9-bit @342",  at(0x80, 342), 0x0D);

    /* 17-bit poly (AUDCTL[7] clear) — pokey_noise's single constraint. */
    expect("17-bit @113", at(0x00, 113), 0x08);

    /* Init FILLS PROGRESSIVELY rather than snapping to $FF.  RANDOM is bits
     * [8:1] of the 9-bit register, so exactly 8 init shifts fill it — the
     * property to check is that it is not $FF BEFORE then, and is $FF after. */
    {
        pokey_rand p;
        pokey_rand_reset(&p);
        pokey_rand_audctl(&p, 0x80);
        pokey_rand_skctl(&p, 0x03);
        for (int i = 0; i < 113; i++) pokey_rand_tick(&p);
        expect("pre-init", pokey_rand_read(&p), 0x95);   /* $95 = 10010101 */

        pokey_rand_skctl(&p, 0x00);                      /* enter init "hot" */
        pokey_rand_tick(&p);
        /* one shift: a one enters at the top, the rest is the surviving state */
        expect("init +1 (partial fill)", pokey_rand_read(&p), 0xCA);
        for (int i = 1; i < 8; i++) pokey_rand_tick(&p);
        expect("init +8 (now full)", pokey_rand_read(&p), 0xFF);
    }

    /* AUDCTL[7] switches which REGISTER is read, not just its width. */
    {
        pokey_rand p;
        pokey_rand_reset(&p);
        pokey_rand_skctl(&p, 0x03);
        for (int i = 0; i < 113; i++) pokey_rand_tick(&p);
        pokey_rand_audctl(&p, 0x00);
        uint8_t v17 = pokey_rand_read(&p);
        pokey_rand_audctl(&p, 0x80);
        uint8_t v9 = pokey_rand_read(&p);
        expect("same tick, 17-bit view", v17, 0x08);
        expect("same tick, 9-bit view",  v9,  0x95);
    }

    printf("pokey: %s\n", fails ? "FAIL" : "all RANDOM LFSR tests pass");
    return fails ? 1 : 0;
}
