/*
 * system.c — the machine.  See system.h.
 */
#include "system.h"
#ifndef PHANTOM_PM
#define PHANTOM_PM 1
#endif
/* Player 0's slot, MEASURED: gtia_phantomdma wants $AD in GRAFP0, and cycle 3
 * of its scanline is the only cycle carrying a byte whose low nibble is $D —
 * the opcode fetch of the test's own `lda $0100`.  Players 1..3 follow it. */
#ifndef PM_SLOT_P
#define PM_SLOT_P 3
#endif
/* The missile latch works the same way, but NO test in the suite pins its slot:
 * gtia_phantomdma leaves GRACTL bit 0 clear and writes GRAFM directly.  So the
 * mechanism is written down and left OFF rather than run on a guessed cycle. */
#ifndef PHANTOM_PM_M
#define PHANTOM_PM_M 0
#endif
#ifndef PM_SLOT_M
#define PM_SLOT_M 2
#endif

/* ---- pseudo mode E -------------------------------------------------------
 * gtia_psuedomodee switches PRIOR into GTIA mode 10 near the end of one
 * scanline and back out early in the next, and its two cases differ ONLY in
 * whether the restoring write lands on cycle 14 or cycle 15.  Cycle 14 gives an
 * ordinary hi-res line, whose $E4 pattern collides as PF2 alone ($04).  Cycle
 * 15 gives $0F — all four playfield classes — from the same data, which the
 * hi-res decode cannot produce however it is phased.
 *
 * $E4 is `11 10 01 00`, so four classes from four colour clocks means the
 * two-bit pairs are being read as a playfield INDEX.  Not mode E's mapping,
 * where `00` is background: a direct index, `00` -> PF0.  That is what the test
 * is named for — it looks like mode E and its colours are not mode E's.
 *
 * So GTIA decides ONCE PER SCANLINE whether mode F is hi-res, and a GTIA mode
 * still selected at that instant disables hi-res for the whole line.  Leave the
 * GTIA mode afterwards and the playfield keeps arriving with hi-res off, which
 * is the pair-as-index decode.
 *
 * Cycle 15 is MEASURED, and the two cases bracket it from both sides: at 14 and
 * below the "cycle 14" case also goes pseudo, at 16 and above the "cycle 15"
 * case does not go pseudo at all.  Exactly one value separates them. */
#ifndef PSEUDO_MODE_E
#define PSEUDO_MODE_E 1
#endif
#ifndef GTIA_MODE_LATCH
#define GTIA_MODE_LATCH 15
#endif
#include <stdio.h>

/* ANTIC's own fetches go straight to memory: they are already accounted for as
 * DMA cycles, so they must not recurse into the CPU's cycle path. */
static void bus_note(atari *s, int cyc, const char *who, uint16_t addr, uint8_t v)
{
    s->last_bus = v;
    s->an.bus_byte = v;              /* ANTIC's virtual slot latches this */
    antic_virt_latch(&s->an, cyc, v);
    if (s->bus_probe && s->an.scanline == s->bus_probe)
        fprintf(stderr, "  BUS sl %3d cyc %3d %-5s $%04X -> $%02X\n",
                s->an.scanline, cyc, who, addr, v);
}

static uint8_t antic_fetch(void *ctx, uint16_t addr)
{
    atari *s = (atari *)ctx;
    /* Remember what ANTIC drove onto the bus.  GTIA latches its P/M graphics on
     * fixed slots whether or not ANTIC actually fetched P/M data there, so with
     * GRACTL enabling the latch and DMACTL's P/M DMA OFF it captures whatever
     * went past — gtia_phantomdma's whole subject. */
    bus_note(s, s->an.cycle, "ANTIC", addr, s->ram[addr]);
    return s->last_bus;
}

/* Advance the world by machine cycles until ANTIC yields one to the CPU.  This
 * is the whole architecture in five lines: ANTIC decides, the CPU waits. */
/* The PHANTOM latch: GRACTL opens the P/M latches on fixed scanline slots
 * whether or not DMACTL asked ANTIC to fetch anything there, so each object
 * captures whatever was ON THE BUS at its own slot.
 *
 * The source is the BUS, not ANTIC.  gtia_phantomdma is built on precisely
 * that: DMACTL is $21, so ANTIC does no P/M DMA at all and the CPU is the one
 * driving those cycles — it arranges an `lda $0100` to straddle them, and the
 * byte it wants latched into GRAFP0 is $AD, which is that instruction's own
 * OPCODE fetch.  Nothing ANTIC touches on that line ends in $D.
 *
 * It therefore has to run AFTER the cycle's access, which is why it is not part
 * of pm_latch(): on a cycle the CPU gets, sys_cycle() has returned long before
 * the read happens. */
static void phantom_latch(atari *s, int c)
{
    /* Only where DMACTL is NOT driving that object.  Where it is, ANTIC really
     * does put the P/M byte on the bus at the slot and the ordinary path in
     * pm_latch() below has already taken it — with VDELAY applied, which the
     * phantom has no business overriding.  Gating this on "ANTIC fetched
     * nothing THIS cycle" instead cost antic_pmdma, antic_charcontrol and
     * gtia_vdelay: pm_dma() does its fetches at line_start, so by the slot
     * cycles the flag is long since consumed and the phantom clobbered a
     * perfectly good latch.  Player DMA drags missile DMA along with it, so the
     * missile gate has to test both bits — as pm_dma() itself does. */
    if (!PHANTOM_PM) return;
    int player  = (s->an.dmactl & 0x08) != 0;
    int missile = (s->an.dmactl & 0x04) != 0 || player;
    if (PHANTOM_PM_M && !missile && (s->gt.gractl & 0x01) && c == PM_SLOT_M)
        s->gt.grafm = s->last_bus;
    if (!player && (s->gt.gractl & 0x02) && c >= PM_SLOT_P && c < PM_SLOT_P + 4)
        s->gt.grafp[c - PM_SLOT_P] = s->last_bus;
}

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

/* One machine cycle of the serial bus.  The command line is PIA port B's CB2,
 * which PBCTL bit 3 drives LOW to assert, and the drive's reply reaches POKEY as
 * a line LEVEL -- POKEY's receiver assembles it, and pokey_serdirect reads the
 * very same level out of SKSTAT bit 4 and assembles it in software instead. */
static void sio_tx(void *ctx, uint8_t b) { sio_recv((sio *)ctx, b); }

static void sio_cycle(atari *s)
{
    sio_cmd(&s->sio, !s->pia.c2[1]);
    sio_tick(&s->sio);
    pokey_timer_serin_line(&s->pt, sio_line(&s->sio));
}

/* ACID_IRQPROBE=1: every IRQST transition with the cycle it happened on.  The
 * POKEY timing tests bracket an interrupt between two reads one machine cycle
 * apart, so "which cycle did it fire on" is the whole question and instruction
 * granularity cannot answer it. */
static void irq_note(atari *s)
{
    if (!s->irq_probe || s->pt.irqst == s->irq_shadow) return;
    fprintf(stderr, "  IRQST $%02X -> $%02X  sl %3d cyc %3d  (machine cycle %llu)"
                    "  chain %lu cnt0 %d audctl $%02X irqen $%02X\n",
            s->irq_shadow, s->pt.irqst, s->an.scanline, s->an.cycle,
            (unsigned long long)s->cycles, (unsigned long)s->pt.chain,
            s->pt.cnt[0], s->pt.audctl, s->pt.irqen);
    s->irq_shadow = s->pt.irqst;
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
    if (cyc == 0) s->hires_ok = 1;
    if (cyc == GTIA_MODE_LATCH) s->hires_ok = (uint8_t)!((s->gt.prior >> 6) & 3);
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
        } else if (PSEUDO_MODE_E && !s->hires_ok && (s->an.dl_insn & 0x0F) == 0x0F) {
            pf = antic_pf_pair(&s->an, cc);      /* the pair IS the index */
        } else {
            pf = antic_pf_at(&s->an, cc, &hires);
        }
        /* A GTIA mode re-reads mode F's bits as NIBBLES, so the playfield is no
         * longer hi-res: leaving this set makes GTIA apply the "lit collides as
         * PF2" rule and throw the nibble's colour class away. */
        s->gt.hires = (s->an.dl_insn & 0x0F) == 0x0F && !gmode &&
                      !(PSEUDO_MODE_E && !s->hires_ok);
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
                        s->an.dl_insn & 0x0F, s->an.chactl, cc, pf, lit, s->gt.hposp[0], s->gt.p_active[0], s->gt.p_n[0] ? s->gt.p_bit[0][0] : 0);
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
        /* A cycle ANTIC takes is rendered here; a cycle the CPU gets is rendered
         * AFTER its bus access, so a GTIA register write lands before the two
         * colour clocks that same cycle emits.  gtia_pmretrigger is what pins
         * this: it writes HPOSP0 mid-line and times the redraw against the
         * beam, and it only passes with the write applied first.
         *
         * The stored value is cycle + 1 so that zero means "nothing deferred"
         * — cycle 0 is a real cycle. */
        if (took) { phantom_latch(s, cyc); render_cycle(s, cyc); }
        else      s->pending_render = cyc + 1;
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
        sio_cycle(s);
        pokey_timer_tick(&s->pt);
        s->cpu.irq = (uint8_t)(s->pt.irq | s->pia.irq);
        irq_note(s);
    }
}

/* The CPU's own cycle advances the LFSR only AFTER its access is serviced.
 * Reading $D20A must see the state as of the START of the cycle: ticking first
 * put every RANDOM read exactly one machine cycle late, which
 * tools/pokey-random-decode.py named precisely from antic_wsync's d0 ($4A where
 * $95 was wanted, step 114 against step 113). */
static void cpu_cycle_done(atari *s)
{
    if (s->pending_render) {
        phantom_latch(s, s->pending_render - 1);
        render_cycle(s, s->pending_render - 1);
        s->pending_render = 0;
    }
    pokey_rand_tick(&s->pk); s->pk_ticks++;
    sio_cycle(s);
    pokey_timer_tick(&s->pt);
    s->cpu.irq = (uint8_t)(s->pt.irq | s->pia.irq);
    irq_note(s);
}

static uint8_t io_read(atari *s, uint16_t a)
{
    switch (a & 0xFF00) {
    case 0xD000:
        if (s->col_probe && (a & 0x1F) >= 0x08 && (a & 0x1F) <= 0x0F)
            fprintf(stderr, "  PLREAD $%04X sl %3d cyc %3d -> $%02X\n",
                    a, s->an.scanline, s->an.cycle, gtia_read(&s->gt, a));
        if (s->col_probe && ((a & 0x1F) == 0x04 || (a & 0x1F) == 0x0C))
            fprintf(stderr, "  SAMPLE sl %3d cyc %3d ppf %x%x%x%x mpf %x%x%x%x\n",
                    s->an.scanline, s->an.cycle,
                    s->gt.ppf[0], s->gt.ppf[1], s->gt.ppf[2], s->gt.ppf[3],
                    s->gt.mpf[0], s->gt.mpf[1], s->gt.mpf[2], s->gt.mpf[3]);
        return gtia_read(&s->gt, a);
    case 0xD200:
        /* $D20E reads back IRQST, ACTIVE LOW — it is IRQEN only on write. */
        if ((a & 0x0F) == 0x0E) {
            if (s->col_probe && s->ser_mark)
                fprintf(stderr, "  IRQST read %llu machine cycles after SEROUT\n",
                        (unsigned long long)(s->cycles - s->ser_mark));
            (void)pokey_timer_irqst_probe(&s->pt);
            return pokey_timer_irqst(&s->pt);
        }
        if ((a & 0x0F) == 0x0A) {
            if (!s->dbg_rand_seen) { s->dbg_rand_at = s->pk_ticks; s->dbg_rand_seen = 1; }
            return pokey_rand_read(&s->pk);
        }
        if ((a & 0x0F) == 0x0D) return pokey_timer_serin(&s->pt);
        if ((a & 0x0F) == 0x0F) return pokey_timer_skstat(&s->pt);
        return 0xFF;
    case 0xD300: return pia_read(&s->pia, a);
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
        if (s->col_probe && (a & 0x1F) >= 0x08 && (a & 0x1F) <= 0x0B)
            fprintf(stderr, "  SIZEP%d <- $%02X at cyc %3d -> cc $%02X (sl %d)\n",
                    a & 3, v, s->an.cycle,
                    (s->an.cycle * 2 + GTIA_CC_ORIGIN) % GTIA_CLOCKS, s->an.scanline);
        gtia_write(&s->gt, a, v);
        break;
    case 0xD200:
        if (s->col_probe && (a & 0x0F) == 0x0D)
            fprintf(stderr, "  SEROUT <- $%02X sl %3d cyc %3d skctl $%02X "
                    "cnt0 %5d cnt2 %5d bits %d full %d\n",
                    v, s->an.scanline, s->an.cycle, s->pt.skctl,
                    s->pt.cnt[0], s->pt.cnt[2], s->pt.ser_bits, s->pt.serout_full),
            s->ser_mark = s->cycles;
        pokey_timer_write(&s->pt, a, v);
        if ((a & 0x0F) == 0x08) pokey_rand_audctl(&s->pk, v);
        if ((a & 0x0F) == 0x0F) {
            if ((v & 3) && s->pk.init) { s->dbg_skctl_at = s->pk_ticks; s->dbg_rand_seen = 0; }
            if (s->col_probe)
                fprintf(stderr, "  SKCTL <- $%02X sl %3d cyc %3d\n",
                        v, s->an.scanline, s->an.cycle);
            pokey_rand_skctl(&s->pk, v);
            pokey_timer_skctl(&s->pt, v);
        }
        break;
    case 0xD300: pia_write(&s->pia, a, v); break;
    case 0xD400:
        if (s->col_probe && (a & 0x0F) == 0x0E)
            fprintf(stderr, "  NMIEN  write $%02X sl %3d cyc %3d (set_now %d nmist $%02X)\n",
                    v, s->an.scanline, s->an.cycle - 1, s->an.nmist_set_now, s->an.nmist);
        if (s->col_probe && ((a & 0x0F) == 0x04 || (a & 0x0F) == 0x00))
            fprintf(stderr, "  %s <- $%02X sl %3d cyc %3d  insn $%02X line $%02X\n",
                    (a & 0x0F) == 0x04 ? "HSCROL" : "DMACTL", v,
                    s->an.scanline, s->an.cycle - 1, s->an.dl_insn,
                    s->an.hscrol_line);
        if (s->col_probe && (a & 0x0F) == 0x0A)
            fprintf(stderr, "  WSYNC  write sl %3d cyc %3d (halt %d extra %d)\n",
                    s->an.scanline, s->an.cycle - 1, s->an.wsync_halt,
                    s->an.wsync_extra);
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

/* Whether XL banking is modelled at all.  A plain 800 has none, and every
 * other test in the suite ran against flat RAM before this existed. */
#ifndef XL_BANKING
#define XL_BANKING 1
#endif

/* PORTB as the MMU sees it: an output bit reads its latch, an input bit floats
 * high on the pull-ups, and after reset every bit is an input — so the machine
 * powers up with the OS ROM in and BASIC and self-test out, which is right. */
static uint8_t portb_of(const atari *s)
{
    return (uint8_t)((s->pia.out[1] & s->pia.ddr[1]) | (uint8_t)~s->pia.ddr[1]);
}

/* The ROM byte overlaying `a`, or NULL when RAM shows through. */
static const uint8_t *rom_at(const atari *s, uint16_t a)
{
    if (!XL_BANKING) return NULL;
    uint8_t pb = portb_of(s);

    if (pb & 0x01) {                       /* OS ROM enabled */
        if (a >= 0xC000 && a < 0xD000) return &s->rom_os[a - 0xC000];
        if (a >= 0xD800)               return &s->rom_os[a - 0xC000];
        /* the self-test window is a view of the OS ROM at $1000, and only
         * appears when the OS ROM itself is in */
        if (!(pb & 0x80) && a >= 0x5000 && a < 0x5800)
            return &s->rom_os[0x1000 + (a - 0x5000)];
    }
    if (!(pb & 0x02) && a >= 0xA000 && a < 0xC000)
        return &s->rom_basic[a - 0xA000];
    return NULL;
}

static uint8_t bus_rd(void *ctx, uint16_t a)
{
    atari *s = ctx;
    s->an.cpu_acc++;
    sys_cycle(s);
    dbg(s, a, 0);
    const uint8_t *rp;
    uint8_t v = (a >= 0xD000 && a < 0xD800) ? io_read(s, a)
              : (rp = rom_at(s, a)) != NULL ? *rp
              : s->ram[a];
    bus_note(s, s->pending_render - 1, "CPU-R", a, v);
    cpu_cycle_done(s);
    return v;
}

static void bus_wr(void *ctx, uint16_t a, uint8_t v)
{
    atari *s = ctx;
    s->an.cpu_acc++;
    s->an.cpu_writing = 1;
    sys_cycle(s);
    s->an.cpu_writing = 0;
    dbg(s, a, 1);
    if (a >= 0xD000 && a < 0xD800) io_write(s, a, v);
    else if (!rom_at(s, a))        s->ram[a] = v;   /* a write through ROM is
                                                     * dropped, RAM untouched */
    bus_note(s, s->pending_render - 1, "CPU-W", a, v);
    cpu_cycle_done(s);
}

void atari_init(atari *s)
{
    for (unsigned i = 0; i < sizeof s->ram; i++) s->ram[i] = 0;
    xt6502_init(&s->cpu, bus_rd, bus_wr, s);
    antic_init(&s->an, antic_fetch, s, ANTIC_LINES_NTSC);
    gtia_init(&s->gt);
    pokey_rand_reset(&s->pk);
    pokey_timer_reset(&s->pt);
    sio_reset(&s->sio);
    /* AFTER the timer reset, which clears the hook field by field. */
    s->pt.ser_tx  = sio_tx;
    s->pt.ser_ctx = &s->sio;
    pia_reset(&s->pia);
    s->cycles = 0;
}

void atari_step(atari *s) { xt6502_step(&s->cpu); }
