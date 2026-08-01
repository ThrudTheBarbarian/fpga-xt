/*
 * system.c — the machine.  See system.h.
 */
#include "system.h"

/* ANTIC's own fetches go straight to memory: they are already accounted for as
 * DMA cycles, so they must not recurse into the CPU's cycle path. */
static uint8_t antic_fetch(void *ctx, uint16_t addr)
{
    return ((atari *)ctx)->ram[addr];
}

/* Advance the world by machine cycles until ANTIC yields one to the CPU.  This
 * is the whole architecture in five lines: ANTIC decides, the CPU waits. */
static void sys_cycle(atari *s)
{
    for (;;) {
        int took = antic_tick(&s->an);
        s->cycles++;
        s->cpu.nmi = (uint8_t)s->an.nmi;
        if (!took) return;          /* the CPU gets this one */
        pokey_rand_tick(&s->pk);    /* ANTIC's cycles advance the LFSR here */
    }
}

/* The CPU's own cycle advances the LFSR only AFTER its access is serviced.
 * Reading $D20A must see the state as of the START of the cycle: ticking first
 * put every RANDOM read exactly one machine cycle late, which
 * tools/pokey-random-decode.py named precisely from antic_wsync's d0 ($4A where
 * $95 was wanted, step 114 against step 113). */
static void cpu_cycle_done(atari *s) { pokey_rand_tick(&s->pk); }

static uint8_t io_read(atari *s, uint16_t a)
{
    switch (a & 0xFF00) {
    case 0xD000: return gtia_read(&s->gt, a);
    case 0xD200:
        if ((a & 0x0F) == 0x0A) return pokey_rand_read(&s->pk);
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
        if ((a & 0x0F) == 0x0F) pokey_rand_skctl(&s->pk, v);
        break;
    case 0xD400: antic_write(&s->an, a, v); break;
    default:     s->ram[a] = v; break;
    }
}

static uint8_t bus_rd(void *ctx, uint16_t a)
{
    atari *s = ctx;
    sys_cycle(s);
    uint8_t v = (a >= 0xD000 && a < 0xD800) ? io_read(s, a) : s->ram[a];
    cpu_cycle_done(s);
    return v;
}

static void bus_wr(void *ctx, uint16_t a, uint8_t v)
{
    atari *s = ctx;
    sys_cycle(s);
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
