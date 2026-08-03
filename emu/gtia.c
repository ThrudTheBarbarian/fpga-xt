/*
 * gtia.c — GTIA collisions and object rendering.  See gtia.h.
 */
#include "gtia.h"
#include "prof.h"
#include <stdio.h>
#include <string.h>

void gtia_init(gtia *g)
{
    memset(g, 0, sizeof *g);
    g->consol = 0;
}

/* How long a SIZEP write takes to reach the object, in colour clocks.  Measured
 * against gtia_pmresize through tools/pmresize-check.py, which pins the effect
 * at colour clock $62 and scores 112/112 there against 35/56/54/28 on the clocks
 * either side. */
/* ONE, now that the WSYNC release is right: the store lands on colour clock $62
 * and the effect belongs on the next clock rendered after it.  3 overshot while
 * the release was a cycle late; 0 is not the low end of a sweep at all, it takes
 * the direct-write branch below and never runs the resize rule. */
#ifndef SIZEP_DELAY
#define SIZEP_DELAY 1
#endif

/* SIZEP/SIZEM: 0 and 2 are 1x, 1 is 2x, 3 is 4x. */
static int size_scale(uint8_t s)
{
    switch (s & 3) {
    case 1:  return 2;
    case 3:  return 4;
    default: return 1;
    }
}

int gtia_probe;

/* Internal forms used by the hot path; the extern symbols forward here for
 * system.c's P/M probe.
 *
 * NEGATIVE RESULT, recorded so it is not retried: making these `static inline`
 * changed NOTHING on the board (99,993 vs 100,010 cycles/s). They are extern but
 * live in the SAME translation unit as gtia_clock, so -O2 already inlined them
 * and still emitted the symbols. Call overhead was never the cost.
 *
 * What IS measured: in antic_dmapattern nothing is ever lit -- gtia_clock takes
 * its early return on all 5,009,672 non-vblank calls and the "something lit"
 * path runs ZERO times -- and obj_step takes its idle path 96.1% of the time
 * (21,008,448 of 21,871,800). So the emulator spends most of its life proving
 * there is nothing to draw. */
static inline int player_lit(const gtia *g, int i)
{
    for (int r = 0; r < g->p_n[i]; r++)
        if ((g->grafp[i] >> (7 - g->p_bit[i][r])) & 1) return 1;
    return 0;
}

static inline int missile_lit(const gtia *g, int i)
{
    return g->m_active[i] && ((g->grafm >> (2 * i + (1 - g->m_bit[i]))) & 1);
}

int gtia_player_lit(const gtia *g, int i)  { return player_lit(g, i); }
int gtia_missile_lit(const gtia *g, int i) { return missile_lit(g, i); }

/* Advance every object by one colour clock.
 *
 * HPOS is compared against the LIVE position with no once-a-line "already
 * emitted" interlock, so a match (re)starts the object — which is why moving
 * HPOS mid-line redraws the player (gtia_pmretrigger).
 *
 * The divider then runs at the CURRENT width.  Changing SIZEP mid-object
 * changes the divide ratio with the phase counter part-way through, and the
 * phase is NOT reset — that is what makes two routes to the same size differ
 * (gtia_pmresize's "alt" cases). */
static void obj_step(gtia *g, int hpos)
{
    /* A NEW SCANLINE RETIRES EVERY RUN.  The shift register reloads from GRAFP
     * each line and re-triggers on the HPOS match, so nothing carries across
     * the boundary.  It only shows up through the 1xalt LOCKUP: an ordinary run
     * retires by reaching bit 8, but a LOCKED one never advances its bit and so
     * never retires -- it survived into every later scanline, emitting for ever,
     * which is the $FE ("player lit at every probe") gtia_pmresize saw at
     * 2x-to-1xalt where $40 was wanted.  The run being measured was fine; the
     * one left over from the previous iteration was not. */
    if (hpos == 0)
        for (int i = 0; i < 4; i++) g->p_n[i] = 0;

    for (int i = 0; i < 4; i++) {
        /* A SIZEP write reaching the object THIS clock replaces the ordinary
         * advance, and what it does is not "roll if the phase has reached the
         * new width".  Both rules below were SEARCHED against every cell of
         * gtia_pmresize rather than assumed -- see tools/pmresize-check.py.
         *
         *  - the run rolls iff the phase's low bits are ALL ONES for the new
         *    width, (ph & (w-1)) == (w-1), which is the counter about to carry.
         *    "Roll iff ph + 1 >= w" agrees except at phase 2 of width 2.
         *  - and SIZEP 2 -- the "1xalt" that divides by one exactly as SIZEP 0
         *    does -- STOPS THE RUN DEAD when the counter's two bits disagree.
         *    A locked run emits its current bit for the rest of the line, which
         *    is the $FE the test's alt tables carry at four of sixteen
         *    positions, and is what its runtest comment calls a lockup. */
        int resize = g->sizep_cnt[i] && --g->sizep_cnt[i] == 0;
        if (resize) g->sizep[i] = g->sizep_pend[i];

        /* IDLE FAST PATH. A player with no live runs that is not triggering on
         * this clock has nothing to advance and nothing to start, and that is
         * the common case: the objects occupy a small part of a 228-clock line,
         * so for most of it this loop was computing a width and a phase rule for
         * runs that do not exist. The state it would touch is untouched here, so
         * skipping is exact rather than approximate.
         *
         * p_active is still assigned below, unconditionally, so an object that
         * retired on an earlier clock cannot be left marked live. */
        if (!g->p_n[i] && hpos != g->hposp[i]) {
            PROF_COUNT(PROFC_OBJ_IDLE);
            g->p_active[i] = 0;
            goto missile;
        }
        PROF_COUNT(PROFC_OBJ_FULL);

        int w = size_scale(g->sizep[i]);
        int alt = (g->sizep[i] & 3) == 2;

        /* Advance every live run, retiring the ones that have shifted out. */
        int keep = 0;
        for (int r = 0; r < g->p_n[i]; r++) {
            int bit = g->p_bit[i][r], ph = g->p_phase[i][r];
            int lk = g->p_locked[i][r];
            if (lk) {
                /* frozen: neither phase nor bit moves again */
            } else if (resize) {
                if (alt && ((ph >> 1) & 1) != (ph & 1)) lk = 1;
                else if ((ph & (w - 1)) == (w - 1))     { ph = 0; bit++; }
                else                                    ph++;
            } else {
                if (++ph >= w) { ph = 0; bit++; }
            }
            if (bit >= 8) continue;                  /* run finished */
            g->p_bit[i][keep] = bit; g->p_phase[i][keep] = ph;
            g->p_locked[i][keep] = (uint8_t)lk; keep++;
        }
        g->p_n[i] = keep;

        if (gtia_probe && i == 0 && (g->p_n[0] || resize))
            fprintf(stderr, "    EMU cc $%02X n %d bit %d ph %d locked %d"
                            " sizep %d cnt %d%s\n",
                    hpos, g->p_n[0], g->p_n[0] ? g->p_bit[0][0] : -1,
                    g->p_n[0] ? g->p_phase[0][0] : -1,
                    g->p_n[0] ? g->p_locked[0][0] : -1,
                    g->sizep[0], g->sizep_cnt[0], resize ? "  <-- RESIZE" : "");

        if (hpos == g->hposp[i]) {
            /* The match RE-ANCHORS every run still emitting: its divider phase
             * restarts here and its bit counter advances with it, because the
             * boundary it was heading for is superseded by this one.  A run that
             * ALREADY rolled on this very clock is left alone -- its boundary is
             * this boundary, and rolling again would count one twice.  That last
             * clause is worth 19 cells on its own (653 -> 672). */
            for (int r = 0; r < g->p_n[i]; r++)
                if (g->p_phase[i][r] != 0) {
                    g->p_phase[i][r] = 0;
                    g->p_bit[i][r]++;
                }
            /* ...and the new run joins the ones already running rather than
             * replacing them. */
            keep = 0;
            for (int r = 0; r < g->p_n[i]; r++)
                if (g->p_bit[i][r] < 8) {
                    g->p_bit[i][keep] = g->p_bit[i][r];
                    g->p_phase[i][keep] = g->p_phase[i][r];
                    g->p_locked[i][keep] = g->p_locked[i][r];
                    keep++;
                }
            g->p_n[i] = keep;
            if (g->p_n[i] < GTIA_RUNS) {
                g->p_bit[i][g->p_n[i]] = 0;
                g->p_phase[i][g->p_n[i]] = 0;
                g->p_locked[i][g->p_n[i]] = 0;
                g->p_n[i]++;
            }
        }
        g->p_active[i] = g->p_n[i] > 0;
missile:
        if (hpos == g->hposm[i]) {
            g->m_active[i] = 1; g->m_bit[i] = 0; g->m_phase[i] = 0;
        } else if (g->m_active[i]) {
            if (++g->m_phase[i] >= size_scale((uint8_t)(g->sizem >> (2 * i)))) {
                g->m_phase[i] = 0;
                if (++g->m_bit[i] >= 2) g->m_active[i] = 0;
            }
        }
    }
}

void gtia_clock(gtia *g, int hpos, int pf, int hires_lit)
{
    /* ABLATION HOOK, for measurement only -- never shipped enabled. The PROF
     * timers wrap this call with two PMCCNTR reads, and a coprocessor read is
     * not cheap, so the attributed share is an upper bound rather than a
     * measurement. Building -DABLATE_GTIA removes the whole function's work and
     * the throughput delta gives its TRUE cost, and therefore the ceiling on
     * what optimising it can ever be worth. Results are wrong with this on. */
#ifdef ABLATE_GTIA
    (void)hpos; (void)pf; (void)hires_lit; (void)g;
    return;
#endif
    obj_step(g, hpos);

    /* No collisions of ANY kind during vertical blank — four separate
     * assertions in gtia_collision cover this.  The objects still SHIFT, they
     * simply do not register. */
    if (g->vblank) return;

    int visible = hpos >= GTIA_VISIBLE_L && hpos <= GTIA_VISIBLE_R;

    /* Lit-ness as BITMASKS, and nothing beyond this point matters when nothing
     * is lit -- which is most colour clocks, since the objects occupy a small
     * part of the line. The pairwise loops below were 32 iterations of trivial
     * work executed unconditionally, every colour clock of every emulated cycle;
     * as masks they are 4 iterations and are skipped outright when idle.
     * gtia_clock is 70% of the emulator's entire runtime, so this is the hot
     * path, not a micro-optimisation. */
    unsigned pm = 0, mm = 0;
    for (int i = 0; i < 4; i++) {
        if (player_lit(g, i))  pm |= 1u << i;
        if (missile_lit(g, i)) mm |= 1u << i;
    }
    if (!pm && !mm) { PROF_COUNT(PROFC_CLK_EARLY); return; }   /* no object here */
    PROF_COUNT(PROFC_CLK_FULL);

    /* HBLANK is NOT a uniform "collisions off": missile/player still registers
     * there while player/player does not (gtia_collision). */
    if (mm && pm)
        for (int i = 0; i < 4; i++)
            if (mm & (1u << i)) g->mpl[i] |= (uint8_t)pm;

    if (visible && pm)
        for (int i = 0; i < 4; i++)
            if (pm & (1u << i)) g->ppl[i] |= (uint8_t)(pm & ~(1u << i));

    if (!visible) return;

    /* Playfield collisions.
     *
     * In a HI-RES mode GTIA is not shown the two half-clock pixels
     * individually — it is shown "something is lit here", and that collides as
     * PF2 whichever half it was (gtia_collision2).  That single rule is the
     * mechanism behind antic_hiresbug.
     *
     * Mode 9 produces NO playfield collisions at all: its playfield byte is a
     * luminance rather than a colour index, so there is no colour to collide
     * with. */
    int mode = (g->prior >> 6) & 3;
    if (mode == GTIA_MODE_9) return;

    int cls = g->hires ? (hires_lit ? 2 : -1) : pf;
    if (cls < 0) return;

    for (int i = 0; i < 4; i++) {
        if (pm & (1u << i)) g->ppf[i] |= (uint8_t)(1 << cls);
        if (mm & (1u << i)) g->mpf[i] |= (uint8_t)(1 << cls);
    }
}

uint8_t gtia_read(gtia *g, uint16_t addr)
{
    switch (addr & 0x1F) {
    case 0x00: case 0x01: case 0x02: case 0x03:
        return (uint8_t)(g->mpf[addr & 3] & 0x0F);
    case 0x04: case 0x05: case 0x06: case 0x07:
        return (uint8_t)(g->ppf[addr & 3] & 0x0F);
    case 0x08: case 0x09: case 0x0A: case 0x0B:
        return (uint8_t)(g->mpl[addr & 3] & 0x0F);
    case 0x0C: case 0x0D: case 0x0E: case 0x0F:
        return (uint8_t)(g->ppl[addr & 3] & 0x0F);
    case 0x1F:
        /* CONSOL drives the switch lines LOW; the read returns the resulting
         * line state, so it is the complement of what was written
         * (gtia_consol). */
        return (uint8_t)(~g->consol & 0x07);
    default:
        /* GTIA only drives the low nibble, so an unused read is $0F — NOT
         * ANTIC's $FF (gtia_default).  One shared open-bus value gets one of
         * the two chips wrong. */
        return 0x0F;
    }
}

void gtia_write(gtia *g, uint16_t addr, uint8_t val)
{
    switch (addr & 0x1F) {
    case 0x00: case 0x01: case 0x02: case 0x03: g->hposp[addr & 3] = val; break;
    case 0x04: case 0x05: case 0x06: case 0x07: g->hposm[addr & 3] = val; break;
    case 0x08: case 0x09: case 0x0A: case 0x0B:
        if (SIZEP_DELAY) {
            g->sizep_pend[addr & 3] = val;
            g->sizep_cnt[addr & 3]  = SIZEP_DELAY;
        } else {
            g->sizep[addr & 3] = val;
        }
        break;
    case 0x0C: g->sizem = val; break;
    case 0x0D: case 0x0E: case 0x0F: case 0x10: g->grafp[(addr - 0x0D) & 3] = val; break;
    case 0x11: g->grafm  = val; break;
    case 0x12: case 0x13: case 0x14: case 0x15: g->colpm[(addr - 0x12) & 3] = val; break;
    case 0x16: case 0x17: case 0x18: case 0x19: g->colpf[(addr - 0x16) & 3] = val; break;
    case 0x1A: g->colbk  = val; break;
    case 0x1B: g->prior  = val; break;
    case 0x1C: g->vdelay = val; break;
    case 0x1D: g->gractl = val; break;
    case 0x1E:                                  /* HITCLR */
        memset(g->mpf, 0, sizeof g->mpf); memset(g->ppf, 0, sizeof g->ppf);
        memset(g->mpl, 0, sizeof g->mpl); memset(g->ppl, 0, sizeof g->ppl);
        break;
    case 0x1F: g->consol = val; break;
    default: break;
    }
}
