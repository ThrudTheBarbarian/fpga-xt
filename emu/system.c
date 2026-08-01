/*
 * system.c — the machine.  See system.h.
 */
#include "system.h"
#include <stdio.h>
#include <stdio.h>

/* ANTIC's own fetches go straight to memory: they are already accounted for as
 * DMA cycles, so they must not recurse into the CPU's cycle path. */
static uint8_t antic_fetch(void *ctx, uint16_t addr)
{
    return ((atari *)ctx)->ram[addr];
}

/* Advance the world by machine cycles until ANTIC yields one to the CPU.  This
 * is the whole architecture in five lines: ANTIC decides, the CPU waits. */
/* ANTIC fetched P/M data; GRACTL decides whether GTIA latches it — players and
 * missiles separately, and independently of whether ANTIC fetched at all. */
static void pm_latch(atari *s)
{
    if (!s->an.pm_fetched) return;
    s->an.pm_fetched = 0;

    /* VDELAY shifts an object DOWN one scanline, preserving its two-line
     * extent: gtia_vdelay wants on,on,off,off without it and off,on,on,off with
     * it.  In two-line resolution the same byte is fetched for both scanlines
     * of a pair, so delaying the LATCH by one fetch is exactly that shift —
     * whereas "skip the first line" gives on,off,on,off and fails half the
     * assertions.  VDELAY has a bit per object: 0..3 missiles, 4..7 players. */
    if (s->gt.gractl & 0x02)
        for (int i = 0; i < 4; i++)
            s->gt.grafp[i] = (s->gt.vdelay & (0x10 << i)) ? s->pm_prev_p[i]
                                                          : s->an.pm_p[i];
    if (s->gt.gractl & 0x01) {
        /* the four missiles share GRAFM two bits each, and are delayed
         * independently */
        uint8_t g = 0;
        for (int i = 0; i < 4; i++) {
            uint8_t src = (s->gt.vdelay & (1 << i)) ? s->pm_prev_m : s->an.pm_m;
            g |= (uint8_t)(src & (0x03 << (2 * i)));
        }
        s->gt.grafm = g;
    }
    for (int i = 0; i < 4; i++) s->pm_prev_p[i] = s->an.pm_p[i];
    s->pm_prev_m = s->an.pm_m;
}

/* One machine cycle is TWO colour clocks, and GTIA is clocked on every one of
 * them — collisions come off the emitted pixel stream, so a renderer that
 * decides object positions once per scanline cannot express gtia_collision
 * (a sprite straddling the blanking edge collides on its visible clocks only)
 * or gtia_pmretrigger (a mid-line HPOS write redraws the player on that line). */
static void render_cycle(atari *s, int cyc)
{
    /* GTIA blanks on what ANTIC is EMITTING, not on the scanline number.  Past
     * the bottom of the display the list is stalled on whatever instruction it
     * last latched: a blank-line instruction really does blank, but a DISPLAY
     * mode keeps feeding GTIA and collisions keep registering.  That is
     * antic_hiresbug — the same handler, the same players, the same DMACTL, and
     * the only difference is whether the DLI's own instruction is $80 (blank)
     * or $CF (mode F). */
    int an_mode = s->an.dl_insn & 0x0F;
    int emitting = an_mode >= 2 && (s->an.dmactl & 0x20);
    s->gt.vblank = (s->an.scanline < ANTIC_DISPLAY_TOP ||
                    s->an.scanline >= ANTIC_DISPLAY_BOTTOM) && !emitting;
    for (int h = 0; h < 2; h++) {
        /* ANTIC's cycle 0 is NOT colour clock 0 — GTIA's counter leads it by six
         * clocks.  gtia_pmretrigger pins this: its second case commits an HPOS
         * write on scanline cycle 29 and requires the player to have ALREADY
         * been drawn at $40, so cc(29) must be just past $40 = 64, i.e.
         * 2*29 + 6.  With no offset the write lands at 58 and the first draw
         * never happens.
         *
         * Playfield alignment is untouched: antic_pf_at's window already starts
         * at 2*(pf_nominal + 3) = 2*pf_nominal + 6, an absolute colour clock. */
        int cc = (cyc * 2 + h + GTIA_CC_ORIGIN) % GTIA_CLOCKS;
        int hires = 0, pf;
        /* PRIOR bits 7-6 select the GTIA modes, which reinterpret ANTIC mode F's
         * hi-res bits as nibbles picking a colour register:
         *   mode  9 ($40) — 16 lumas of COLBK, and NO playfield collisions
         *   mode 10 ($80) — nibbles 4..7 are COLPF0..3, and the playfield is
         *                   shifted one colour clock; 0..3 are the player
         *                   colours, which are not playfield for collisions
         *   mode 11 ($C0) — 16 hues, likewise no playfield collisions */
        int gmode = (s->gt.prior >> 6) & 3;
        if (gmode && (s->an.dl_insn & 0x0F) == 0x0F) {
            int nib = antic_pf_nibble(&s->an, cc, gmode == GTIA_MODE_10 ? 1 : 0);
            /* In mode 10 the nibble's BIT 2 selects playfield, and bits 1:0 the
             * class — so $4..$7 and $C..$F all collide as PF0..PF3 while
             * $0..$3 and $8..$B collide as nothing.  gtia_collision2 asserts all
             * sixteen; a "4..7" range check gets the low half right and reports
             * background for the whole top half. */
            pf = (gmode == GTIA_MODE_10 && (nib & 4)) ? (nib & 3) : -1;
        } else {
            pf = antic_pf_at(&s->an, cc, &hires);
        }
        /* A GTIA mode re-reads mode F's bits as NIBBLES, so the playfield is no
         * longer hi-res: leaving this set makes GTIA apply the "lit collides as
         * PF2" rule and throw the nibble's colour class away. */
        s->gt.hires = (s->an.dl_insn & 0x0F) == 0x0F && !gmode;
        uint8_t before = (uint8_t)(s->gt.ppf[0] | s->gt.ppf[1] | s->gt.ppf[2] |
                                   s->gt.ppf[3] | s->gt.ppl[0] | s->gt.ppl[1]);
        gtia_clock(&s->gt, cc, pf, hires);
        if (s->col_probe) {
            uint8_t after = (uint8_t)(s->gt.ppf[0] | s->gt.ppf[1] | s->gt.ppf[2] |
                                      s->gt.ppf[3] | s->gt.ppl[0] | s->gt.ppl[1]);
            if (after != before)
                fprintf(stderr, "  COLLIDE sl %3d cc $%02X mode %2d ppf %x%x%x%x ppl %x%x vbl %d\n",
                        s->an.scanline, cc, s->an.dl_insn & 0x0F,
                        s->gt.ppf[0], s->gt.ppf[1], s->gt.ppf[2], s->gt.ppf[3],
                        s->gt.ppl[0], s->gt.ppl[1], s->gt.vblank);
        }
        if (s->pf_probe && s->an.scanline == s->pf_probe) {
            int lit = 0;
            for (int i = 0; i < 4; i++) {
                if (gtia_player_lit(&s->gt, i))  lit |= 0x80 >> i;
                if (gtia_missile_lit(&s->gt, i)) lit |= 0x08 >> i;
            }
            if (lit || pf >= 0)
                fprintf(stderr, "  f%-3llu mode %2d chactl $%02X cc $%02X pf %2d objs $%02X hp0 $%02X act%d bit%d\n",
                        (unsigned long long)(s->cycles / (114ULL * 262ULL)),
                        s->an.dl_insn & 0x0F, s->an.chactl, cc, pf, lit, s->gt.hposp[0], s->gt.p_active[0], s->gt.p_bit[0]);
        }
    }
}

static void sys_cycle(atari *s)
{
    int was_halted = s->an.wsync_halt;
    for (;;) {
        /* Catch a pulse raised since the last tick — a NMIEN write landing in
         * the same cycle as the status set raises /NMI from antic_write, and
         * the next tick would clear it again before it was ever sampled. */
        if (s->an.nmi) s->nmi_hold = 1;
        int cyc  = s->an.cycle;
        int took = antic_tick(&s->an);
        render_cycle(s, cyc);
        pm_latch(s);
        s->cycles++;
        /* Hold ANTIC's one-cycle /NMI pulse until the CPU latches the edge, then
         * drop it so the NEXT event raises a fresh one.  The real 6502 clocks
         * its NMI edge detector every cycle, including cycles it is halted for
         * DMA, so the pulse must not be lost just because the CPU is not being
         * serviced on that cycle. */
        if (s->an.nmi) s->nmi_hold = 1;
        s->cpu.nmi = s->nmi_hold;
        if (s->cpu.nmi_pend) s->nmi_hold = 0;
        if (!took) {                /* the CPU gets this one */
            if (was_halted && s->col_probe)
                fprintf(stderr, "  WSYNC release: CPU resumes sl %3d cyc %3d\n",
                        s->an.scanline, cyc);
            return;
        }
        pokey_rand_tick(&s->pk); s->pk_ticks++;   /* ANTIC's cycles advance it here */
    }
}

/* The CPU's own cycle advances the LFSR only AFTER its access is serviced.
 * Reading $D20A must see the state as of the START of the cycle: ticking first
 * put every RANDOM read exactly one machine cycle late, which
 * tools/pokey-random-decode.py named precisely from antic_wsync's d0 ($4A where
 * $95 was wanted, step 114 against step 113). */
static void cpu_cycle_done(atari *s) { pokey_rand_tick(&s->pk); s->pk_ticks++; }

static uint8_t io_read(atari *s, uint16_t a)
{
    switch (a & 0xFF00) {
    case 0xD000:
        if (s->col_probe && ((a & 0x1F) == 0x04 || (a & 0x1F) == 0x0C))
            fprintf(stderr, "  SAMPLE sl %3d cyc %3d ppf %x%x%x%x mpf %x%x%x%x\n",
                    s->an.scanline, s->an.cycle,
                    s->gt.ppf[0], s->gt.ppf[1], s->gt.ppf[2], s->gt.ppf[3],
                    s->gt.mpf[0], s->gt.mpf[1], s->gt.mpf[2], s->gt.mpf[3]);
        return gtia_read(&s->gt, a);
    case 0xD200:
        if ((a & 0x0F) == 0x0A) {
            if (!s->dbg_rand_seen) { s->dbg_rand_at = s->pk_ticks; s->dbg_rand_seen = 1; }
            return pokey_rand_read(&s->pk);
        }
        return 0xFF;
    case 0xD400:
        if (s->col_probe && (a & 0x0F) == 0x0F)
            fprintf(stderr, "  NMIST read sl %3d cyc %3d -> $%02X\n",
                    s->an.scanline, s->an.cycle - 1, s->an.nmist);
        return antic_read(&s->an, a);
    default:     return s->ram[a];
    }
}

static void io_write(atari *s, uint16_t a, uint8_t v)
{
    switch (a & 0xFF00) {
    case 0xD000:
        if (s->col_probe && (a & 0x1F) == 0x1E)
            fprintf(stderr, "  HITCLR  sl %3d cyc %3d\n", s->an.scanline, s->an.cycle);
        if (s->col_probe && (a & 0x1F) < 0x08)
            fprintf(stderr, "  HPOS%d <- $%02X sl %3d cyc %3d\n",
                    a & 0x07, v, s->an.scanline, s->an.cycle);
        gtia_write(&s->gt, a, v);
        break;
    case 0xD200:
        if ((a & 0x0F) == 0x08) pokey_rand_audctl(&s->pk, v);
        if ((a & 0x0F) == 0x0F) {
            if ((v & 3) && s->pk.init) { s->dbg_skctl_at = s->pk_ticks; s->dbg_rand_seen = 0; }
            if (s->col_probe)
                fprintf(stderr, "  SKCTL <- $%02X sl %3d cyc %3d\n",
                        v, s->an.scanline, s->an.cycle);
            pokey_rand_skctl(&s->pk, v);
        }
        break;
    case 0xD400:
        if (s->col_probe && (a & 0x0F) == 0x0E)
            fprintf(stderr, "  NMIEN  write $%02X sl %3d cyc %3d (set_now %d nmist $%02X)\n",
                    v, s->an.scanline, s->an.cycle - 1, s->an.nmist_set_now, s->an.nmist);
        if (s->col_probe && (a & 0x0F) == 0x0F)
            fprintf(stderr, "  NMIRES write sl %3d cyc %3d (set_now %d nmist $%02X)\n",
                    s->an.scanline, s->an.cycle - 1, s->an.nmist_set_now, s->an.nmist);
        antic_write(&s->an, a, v);
        break;
    default:     s->ram[a] = v; break;
    }
}

static void dbg(atari *s, uint16_t a, int wr)
{
    if (s->dbg_trace <= 0) return;
    s->dbg_trace--;
    printf("    line %3d cyc %3d  %s $%04X   pk=%llu\n",
           s->an.scanline, s->an.cycle, wr ? "W" : "R", a,
           (unsigned long long)(s->pk_ticks - s->dbg_skctl_at));
}

static uint8_t bus_rd(void *ctx, uint16_t a)
{
    atari *s = ctx;
    sys_cycle(s);
    dbg(s, a, 0);
    uint8_t v = (a >= 0xD000 && a < 0xD800) ? io_read(s, a) : s->ram[a];
    cpu_cycle_done(s);
    return v;
}

static void bus_wr(void *ctx, uint16_t a, uint8_t v)
{
    atari *s = ctx;
    s->an.cpu_writing = 1;
    sys_cycle(s);
    s->an.cpu_writing = 0;
    dbg(s, a, 1);
    if (a >= 0xD000 && a < 0xD800) io_write(s, a, v);
    else                           s->ram[a] = v;
    cpu_cycle_done(s);
}

void atari_init(atari *s)
{
    for (unsigned i = 0; i < sizeof s->ram; i++) s->ram[i] = 0;
    xt6502_init(&s->cpu, bus_rd, bus_wr, s);
    antic_init(&s->an, antic_fetch, s, ANTIC_LINES_NTSC);
    gtia_init(&s->gt);
    pokey_rand_reset(&s->pk);
    s->cycles = 0;
}

void atari_step(atari *s) { xt6502_step(&s->cpu); }
