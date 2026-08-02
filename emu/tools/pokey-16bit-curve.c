/* When does the 16-bit lo timer fire, as a function of AUDF1?
 *
 * pokey_timertiming states the answer in its own comments (its source lines
 * 628-629): the IRQST bit-0 boundary sits at AUDF1 + 9 / AUDF1 + 10 cycles
 * past the STIMER write --
 *
 *     AUDF1=0    9c/10c   *extrapolated
 *     AUDF1=13  22c/23c
 *
 * so this prints our own boundary for a range of AUDF1 and compares. */
#include <stdio.h>
#include <string.h>
#include "pokey_timer.h"

static int fire_cycle(int audf1)
{
    pokey_timer p;
    pokey_timer_reset(&p);
    pokey_timer_skctl(&p, 0x03);                 /* out of init */
    pokey_timer_write(&p, 0xD208, 0x50);         /* AUDCTL: 16-bit, 1.79MHz */
    pokey_timer_write(&p, 0xD200, (uint8_t)audf1);
    pokey_timer_write(&p, 0xD202, 0x00);         /* AUDF2 */
    pokey_timer_write(&p, 0xD209, 0x00);         /* STIMER at cycle 0 */
    /* the test clears and re-arms IRQEN AFTER stimer, at +6c and +12c */
    for (int c = 1; c <= 400; c++) {
        pokey_timer_tick(&p);
        if (c == 6)  pokey_timer_write(&p, 0xD20E, 0x00);
        if (c == 12) pokey_timer_write(&p, 0xD20E, 0x01);
        if (c > 12 && !(pokey_timer_irqst(&p) & 0x01)) return c;
    }
    return -1;
}

int main(void)
{
    printf("AUDF1  ours   test says (AUDF1+10)\n");
    for (int n = 0; n <= 16; n++) {
        int c = fire_cycle(n);
        printf("  %2d   %4d   %4d   %s\n", n, c, n + 10,
               c == n + 10 ? "" : "  <-- differs");
    }
    return 0;
}
