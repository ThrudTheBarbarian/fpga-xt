/* Representative inner-loop shape for a cycle-stepped 6502+ANTIC: per Atari
 * machine cycle, decide whether ANTIC steals the cycle, and if not advance one
 * CPU micro-cycle through a switch-dispatched state machine, writing a palette
 * index into an 8-bit surface during the display window.  Not an emulator --
 * it models the DISPATCH COST, which is what determines whether 1.79 MHz
 * cycle-exact is affordable on one A9. */
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include "usys.h"

static long long now_us(void)
{
    unsigned tv[3];
    __syscall(SYS_gettimeofday, (long)tv, 0, 0);
    return (long long)tv[0] * 1000000ll + tv[2];
}

static uint8_t  fb[262*228];
static uint8_t  mem64k[65536];
static uint8_t  steal_tbl[114];
static void run(void);

typedef struct { uint16_t pc, addr; uint8_t a,x,y,s,p,op,ucyc; } cpu_t;

void _app_entry(int argc, char **argv)
{ (void)argc; (void)argv; run(); sys_exit(0); }

static void run(void)
{
    cpu_t c; memset(&c,0,sizeof c); c.pc=0x2000;
    for (int i=0;i<114;i++) steal_tbl[i] = (i>=18 && i<98 && !(i&1)) || (i<6);
    for (int i=0;i<65536;i++) mem64k[i] = (uint8_t)(i*7u+3u);

    const long FRAMES = 600;               /* 10 seconds of Atari time at 60Hz */
    long cycles = 0; uint32_t sink = 0;
    long long t0 = now_us();

    for (long f=0; f<FRAMES; f++)
      for (int line=0; line<262; line++) {
        uint8_t *row = &fb[line*228];
        for (int hc=0; hc<114; hc++) {
            cycles++;
            if (steal_tbl[hc]) {                    /* ANTIC owns the cycle */
                uint16_t a = (uint16_t)(line*40 + hc);
                uint8_t  d = mem64k[a & 0xFFFF];
                row[(hc*2)&255]   = d & 0x0F;       /* palette index out */
                row[(hc*2+1)&255] = (d>>4) & 0x0F;
                continue;                           /* CPU loses this cycle */
            }
            switch (c.ucyc) {                       /* one CPU micro-cycle */
                case 0: c.op = mem64k[c.pc++]; c.ucyc = 1; break;
                case 1: c.addr = mem64k[c.pc++]; c.ucyc = 2; break;
                case 2: c.addr |= (uint16_t)mem64k[c.pc++]<<8; c.ucyc = 3; break;
                case 3: c.a = mem64k[c.addr]; c.p = (c.a?0:2)|(c.a&0x80);
                        c.ucyc = 0; break;
                default: c.ucyc = 0; break;
            }
            sink += c.a;
        }
      }
    double el = (double)(now_us() - t0) / 1e6;
    double atari_s = cycles / 1789790.0;
    printf("cycles=%ld  elapsed=%.3fs  atari-time=%.3fs  REALTIME FACTOR=%.2fx  sink=%u\n",
           cycles, el, atari_s, atari_s/el, sink);
    printf("%.1f ns per Atari machine cycle (budget at 1.79MHz = 558.7 ns)\n", el*1e9/cycles);
}
