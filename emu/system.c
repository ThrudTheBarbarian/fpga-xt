/*
 * system.c — the machine.  See system.h.
 */
#include "system.h"
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
    if (s->gt.gractl & 0x02)
        for (int i = 0; i < 4; i++) s->gt.grafp[i] = s->an.pm_p[i];
    if (s->gt.gractl & 0x01)
        s->gt.grafm = s->an.pm_m;
}

/* One machine cycle is TWO colour clocks, and GTIA is clocked on every one of
 * them — collisions come off the emitted pixel stream, so a renderer that
 * decides object positions once per scanline cannot express gtia_collision
 * (a sprite straddling the blanking edge collides on its visible clocks only)
 * or gtia_pmretrigger (a mid-line HPOS write redraws the player on that line). */
static void render_cycle(atari *s, int cyc)
{
    s->gt.vblank = (s->an.scanline < ANTIC_DISPLAY_TOP ||
                    s->an.scanline >= ANTIC_DISPLAY_BOTTOM);
    for (int h = 0; h < 2; h++) {
        int cc = cyc * 2 + h;
        if (cc >= GTIA_CLOCKS) break;
        int hires = 0;
        int pf = antic_pf_at(&s->an, cc, &hires);
        s->gt.hires = (s->an.dl_insn & 0x0F) == 0x0F;
        gtia_clock(&s->gt, cc, pf, hires);
    }
}

static void sys_cycle(atari *s)
{
    for (;;) {
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
        if (!took) return;          /* the CPU gets this one */
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
    case 0xD000: return gtia_read(&s->gt, a);
    case 0xD200:
        if ((a & 0x0F) == 0x0A) {
            if (!s->dbg_rand_seen) { s->dbg_rand_at = s->pk_ticks; s->dbg_rand_seen = 1; }
            return pokey_rand_read(&s->pk);
        }
        return 0xFF;
    case 0xD400: return antic_read(&s->an, a);
    default:     return s->ram[a];
    }
}

static void io_write(atari *s, uint16_t a, uint8_t v)
{
    switch (a & 0xFF00) {
    case 0xD000: gtia_write(&s->gt, a, v); break;
    case 0xD200:
        if ((a & 0x0F) == 0x08) pokey_rand_audctl(&s->pk, v);
        if ((a & 0x0F) == 0x0F) {
            if ((v & 3) && s->pk.init) { s->dbg_skctl_at = s->pk_ticks; s->dbg_rand_seen = 0; }
            pokey_rand_skctl(&s->pk, v);
        }
        break;
    case 0xD400: antic_write(&s->an, a, v); break;
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
    sys_cycle(s);
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
