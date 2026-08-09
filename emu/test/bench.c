/*
 * bench.c — what does a frame of the REAL emulator cost?
 *
 * The investigation's actual question is whether a cycle-stepped 6502+ANTIC
 * fits on one A9 (docs/Design/software-emulation-investigation.md).  That was
 * answered once, before any of this existed, by loader/test/freertos/progs/
 * cycbench.c — which models the DISPATCH SHAPE rather than an emulator, so it
 * is a lower bound and nothing more.  This measures the thing itself.
 *
 * The workload is deliberately the expensive case rather than a friendly one:
 * a character-mode display list with playfield DMA, player/missile DMA and all
 * four missiles enabled, so every scanline pays for the DMA schedule, the line
 * buffer, the P/M latch and 228 colour clocks of GTIA.  A blank screen would
 * flatter it by skipping most of that.
 */
#include <stdio.h>
#include <string.h>
#include <time.h>
#include "../system.h"

#define FRAMES 300
#define CYCLES_PER_FRAME (ANTIC_LINE_CYCLES * ANTIC_LINES_NTSC)

static double now(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (double)t.tv_sec + (double)t.tv_nsec * 1e-9;
}

int main(void)
{
    static atari s;
    atari_init(&s);

    /* a 24-row mode 2 screen, LMS at $4000, then JVB */
    uint16_t dl = 0x2C00;
    s.ram[dl++] = 0x70; s.ram[dl++] = 0x70; s.ram[dl++] = 0x70;
    s.ram[dl++] = 0x42; s.ram[dl++] = 0x00; s.ram[dl++] = 0x40;
    for (int i = 0; i < 23; i++) s.ram[dl++] = 0x02;
    s.ram[dl++] = 0x41; s.ram[dl++] = 0x00; s.ram[dl++] = 0x2C;
    for (int i = 0; i < 960; i++) s.ram[0x4000 + i] = (uint8_t)(i & 0x7F);
    for (int i = 0; i < 1024; i++) s.ram[0xE000 + i] = (uint8_t)(0x5A + i);

    s.ram[0x02E0] = 0x00; s.ram[0x02E1] = 0x20;

    /* the CPU spins; what is being timed is the machine, not the program */
    uint16_t pc = 0x2000;
    s.ram[pc++] = 0xEA; s.ram[pc++] = 0xEA;
    s.ram[pc++] = 0x4C; s.ram[pc++] = 0x00; s.ram[pc++] = 0x20;
    s.cpu.pc = 0x2000;
    s.cpu.s  = 0xFD;

    antic_write(&s.an, 0xD402, 0x00);
    antic_write(&s.an, 0xD403, 0x2C);
    antic_write(&s.an, 0xD409, 0xE0);      /* CHBASE */
    antic_write(&s.an, 0xD400, 0x3E);      /* normal width, DL + P/M DMA */
    antic_write(&s.an, 0xD407, 0x30);      /* PMBASE */
    gtia_write(&s.gt, 0xD01D, 0x03);       /* GRACTL: latch players+missiles */
    for (int i = 0; i < 4; i++) {
        gtia_write(&s.gt, (uint16_t)(0xD000 + i), (uint8_t)(0x40 + i * 0x20));
        gtia_write(&s.gt, (uint16_t)(0xD004 + i), (uint8_t)(0x50 + i * 0x20));
    }
    gtia_write(&s.gt, 0xD011, 0xFF);

    uint64_t target = (uint64_t)FRAMES * CYCLES_PER_FRAME;
    double t0 = now();
    while (s.cycles < target) atari_step(&s);
    double dt = now() - t0;

    double fps  = FRAMES / dt;
    double ns   = dt * 1e9 / (double)s.cycles;
    /* the A9 measurement in the notes: 6 to 7.5x slower than this host */
    printf("bench: %d frames in %.3f s\n", FRAMES, dt);
    printf("  %.1f frames/s   %.2f ns per machine cycle   %.1fx realtime\n",
           fps, ns, fps / 59.92);
    printf("  projected on one A9 at 6.0x slower: %5.1f fps  (%.1fx realtime)\n",
           fps / 6.0, fps / 6.0 / 59.92);
    printf("  projected on one A9 at 7.5x slower: %5.1f fps  (%.1fx realtime)\n",
           fps / 7.5, fps / 7.5 / 59.92);
    return 0;
}
