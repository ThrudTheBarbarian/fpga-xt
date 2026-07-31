/*
 * pokey_rand.c — POKEY's polynomial counters. See pokey_rand.h for provenance.
 */
#include "pokey_rand.h"

#define M9   0x000001FFu
#define M17  0x0001FFFFu

void pokey_rand_reset(pokey_rand *p)
{
    p->lfsr9  = M9;      /* all-ones: leaving init always starts from here */
    p->lfsr17 = M17;
    p->audctl = 0;
    p->skctl  = 0;
    p->init   = 1;       /* SKCTL[1:0] == 0 out of reset */
}

void pokey_rand_tick(pokey_rand *p)
{
    if (p->init) {
        /* Init keeps SHIFTING and feeds in ones — it does not snap to $FF, so
         * RANDOM reads a partially-filled value on the way there. */
        p->lfsr9  = ((p->lfsr9  >> 1) | (1u <<  8)) & M9;
        p->lfsr17 = ((p->lfsr17 >> 1) | (1u << 16)) & M17;
        return;
    }
    uint32_t fb9  = (p->lfsr9  ^ (p->lfsr9  >> 5)) & 1u;
    uint32_t fb17 = (p->lfsr17 ^ (p->lfsr17 >> 5)) & 1u;
    p->lfsr9  = ((p->lfsr9  >> 1) | (fb9  <<  8)) & M9;
    p->lfsr17 = ((p->lfsr17 >> 1) | (fb17 << 16)) & M17;
}

uint8_t pokey_rand_read(const pokey_rand *p)
{
    /* AUDCTL[7] makes the 9-bit poly REPLACE the 17-bit one for RANDOM, so the
     * byte comes from a different register entirely — not just a shorter one. */
    return (uint8_t)((p->audctl & 0x80u) ? ((p->lfsr9  >> 1) & 0xFFu)
                                         : ((p->lfsr17 >> 9) & 0xFFu));
}

void pokey_rand_audctl(pokey_rand *p, uint8_t v) { p->audctl = v; }

void pokey_rand_skctl(pokey_rand *p, uint8_t v)
{
    p->skctl = v;
    p->init  = (uint8_t)((v & 0x03u) == 0);
}
