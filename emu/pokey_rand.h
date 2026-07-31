/*
 * pokey_rand.h — POKEY's polynomial counters and the RANDOM register.
 *
 * POKEY stays in HARDWARE in the shipping design; this is here because the
 * ACID800 timing tests cannot run without it. They use `RANDOM` ($D20A) as a
 * ONE-CYCLE-RESOLUTION CLOCK: release the poly counters from SKCTL init at a
 * known scanline cycle, then read $D20A and the value *is* the cycle count,
 * encoded. See docs/Acid800/README.md.
 *
 * So this is not a sound model and has no audio path — it is the LFSR only,
 * and it is a prerequisite for antic_wsync, antic_vcount, antic_dlitiming,
 * antic_dmapattern (which needs the 9-bit mode) and cpu_timing.
 *
 * ---- provenance -----------------------------------------------------------
 * The parameters are NOT guessed. They are the HW-pinned model from this
 * repo's own `hdl/pokey_audio.sv`, whose comments record how each was fixed:
 *
 *  9-bit  x^9 + x^5 + 1, right-shifting, feedback q[0]^q[5] into bit 8,
 *         seeded all-ones, RANDOM = bits [8:1].
 *         Pinned by fitting THREE independent ACID800 antic_wsync reads
 *         simultaneously: $95 at 113 cycles after the SKCTL release, $4B at
 *         227, $0D at 342. Of every width/tap/seed/shift/direction combination
 *         searched, only this one satisfies all three.
 *
 *  17-bit same realisation — right-shifting, feedback q[0]^q[5] into bit 16,
 *         seeded all-ones, RANDOM = bits [16:9]. For a right-shifting LFSR,
 *         x^17+x^12+1 and x^17+x^5+1 are reciprocal realisations of the same
 *         polynomial, so this is POKEY's documented poly read the other way
 *         round. Fit to ONE constraint (pokey_noise reads $08 at 113 cycles
 *         with AUDCTL=0), chosen because it is the only exact fit that is also
 *         structurally identical to the verified 9-bit form. Treat it as less
 *         firmly established than the 9-bit.
 *
 * ---- SKCTL init does NOT snap to $FF --------------------------------------
 * While SKCTL[1:0] == 0 the counters are held in "init", but they keep
 * SHIFTING and feed in ones, so the register fills progressively and RANDOM
 * only reaches $FF after enough shifts. Pinned by two ACID800 pokey_noise
 * assertions that are consistent with nothing else: ~228 cycles after entering
 * init reads $FF, but ~4 cycles after ("hot-stop") reads $E9 — the top bits
 * already ones, the rest the surviving pre-stop state. This is also why an
 * all-ones seed fits the release data: leaving init ALWAYS starts from
 * all-ones.
 */
#ifndef POKEY_RAND_H
#define POKEY_RAND_H

#include <stdint.h>

typedef struct {
    uint32_t lfsr9;    /*  9 bits */
    uint32_t lfsr17;   /* 17 bits */
    uint8_t  audctl;   /* bit 7 selects the 9-bit poly for RANDOM */
    uint8_t  skctl;
    uint8_t  init;     /* SKCTL[1:0] == 0: counters held in init */
} pokey_rand;

void    pokey_rand_reset(pokey_rand *p);
void    pokey_rand_tick(pokey_rand *p);              /* exactly one machine cycle */
uint8_t pokey_rand_read(const pokey_rand *p);        /* $D20A */
void    pokey_rand_audctl(pokey_rand *p, uint8_t v); /* $D208 */
void    pokey_rand_skctl(pokey_rand *p, uint8_t v);  /* $D20F */

#endif /* POKEY_RAND_H */
