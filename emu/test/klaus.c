/*
 * klaus.c — Klaus Dormann's 6502 functional test against xt6502.
 *
 * Uses the binary already vendored at sim/test_data/ for the fabric core, so
 * both cores answer to the same test.  Success is the PC settling on the
 * documented success trap; any OTHER stuck PC is a failure trap, and the
 * address identifies the failing subtest via the .lst.
 *
 * Note this is a FLAT 64 KB memory with no hidden stack: unlike the fabric
 * core's tb_klaus, there is no separate stack RAM to model here, because the
 * software core has no banked-stack embellishment.
 */
#include <stdio.h>
#include <string.h>
#include "../xt6502.h"

#define BIN      "../sim/test_data/6502_functional_test.bin"
#define START    0x0400
#define SUCCESS  0x3469

static uint8_t mem[65536];

static uint8_t bus_rd(void *ctx, uint16_t a) { (void)ctx; return mem[a]; }
static void    bus_wr(void *ctx, uint16_t a, uint8_t v) { (void)ctx; mem[a] = v; }

int main(void)
{
    FILE *f = fopen(BIN, "rb");
    if (!f) { fprintf(stderr, "klaus: cannot open %s (run from emu/)\n", BIN); return 2; }
    size_t n = fread(mem, 1, sizeof mem, f);
    fclose(f);
    printf("klaus: loaded %zu bytes\n", n);

    xt6502 c;
    xt6502_init(&c, bus_rd, bus_wr, NULL);
    c.pc = START;

    uint16_t last = 0xFFFF;
    int      stuck = 0;
    /* The test is ~96 million cycles; the cap is a long way above that so a
     * genuine hang is reported as a hang rather than as a pass. */
    for (uint64_t i = 0; i < 500000000ULL; i++) {
        uint16_t before = c.pc;
        xt6502_step(&c);
        if (c.jammed) {
            printf("klaus: JAM at $%04X after %llu cycles\n",
                   c.pc, (unsigned long long)c.cycles);
            return 1;
        }
        if (c.pc == before) {                    /* a `JMP *` trap */
            if (++stuck > 2) {
                if (c.pc == SUCCESS) {
                    printf("klaus: PASS (success trap $%04X, %llu cycles)\n",
                           c.pc, (unsigned long long)c.cycles);
                    return 0;
                }
                printf("klaus: FAIL — trap at $%04X (%llu cycles); "
                       "cross-reference 6502_functional_test.lst\n",
                       c.pc, (unsigned long long)c.cycles);
                return 1;
            }
        } else {
            stuck = 0;
        }
        last = before;
    }
    (void)last;
    printf("klaus: did not terminate\n");
    return 1;
}
