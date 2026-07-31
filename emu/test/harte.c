/*
 * harte.c — run the Tom Harte single-step vectors against xt6502.
 *
 * Reads the .vec files already cached in sim/harte/vec/ for the fabric core's
 * harness (1000 cases per opcode), so the software and fabric cores are held to
 * literally the same vectors.
 *
 * This checks the EXACT CYCLE-BY-CYCLE BUS TRACE — address, data and direction
 * of every cycle — not just the final register/RAM state.  Final state alone
 * would pass a core that reaches the right answer with the wrong bus behaviour,
 * and the bus behaviour is the entire point: ANTIC's DMA and /RDY interact with
 * the dummy reads and the RMW double write, so a core that is merely
 * functionally right would drift the moment ANTIC is attached.
 *
 *   emu/test/harte [opcode-hex ...]      (default: all cached opcodes)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>
#include "../xt6502.h"

#define VECDIR "../sim/harte/vec"
#define MAXCYC 16

static uint8_t mem[65536];

typedef struct { uint16_t a; uint8_t v; uint8_t rd; } bcyc;
static bcyc trace[MAXCYC];
static int  ntrace;

static uint8_t bus_rd(void *ctx, uint16_t a)
{
    (void)ctx;
    if (ntrace < MAXCYC) { trace[ntrace].a = a; trace[ntrace].v = mem[a]; trace[ntrace].rd = 1; }
    ntrace++;
    return mem[a];
}

static void bus_wr(void *ctx, uint16_t a, uint8_t v)
{
    (void)ctx;
    if (ntrace < MAXCYC) { trace[ntrace].a = a; trace[ntrace].v = v; trace[ntrace].rd = 0; }
    ntrace++;
    mem[a] = v;
}

/* one opcode's vectors; returns cases failed, and reports the first failure */
static int run_opcode(const char *path, const char *name, int *ncases)
{
    FILE *f = fopen(path, "r");
    if (!f) { fprintf(stderr, "  %s: cannot open %s\n", name, path); return -1; }

    unsigned n = 0;
    if (fscanf(f, "%u", &n) != 1) { fclose(f); return -1; }
    *ncases = (int)n;

    int failed = 0;
    for (unsigned k = 0; k < n; k++) {
        unsigned pc, s, a, x, y, p, cnt, addr, val, rw;

        /* initial state */
        if (fscanf(f, "%x %x %x %x %x %x", &pc, &s, &a, &x, &y, &p) != 6) break;
        if (fscanf(f, "%u", &cnt) != 1) break;
        /* Harte only specifies the bytes it lists; the rest of RAM is
         * don't-care, so leave it as-is rather than pretending it is zero. */
        for (unsigned i = 0; i < cnt; i++) {
            if (fscanf(f, "%x %x", &addr, &val) != 2) break;
            mem[addr] = (uint8_t)val;
        }

        /* expected cycles */
        unsigned ncyc;
        if (fscanf(f, "%u", &ncyc) != 1) break;
        bcyc want[MAXCYC];
        for (unsigned i = 0; i < ncyc; i++) {
            if (fscanf(f, "%x %x %u", &addr, &val, &rw) != 3) break;
            if (i < MAXCYC) { want[i].a = (uint16_t)addr; want[i].v = (uint8_t)val;
                              want[i].rd = (uint8_t)rw; }
        }

        xt6502 c;
        xt6502_init(&c, bus_rd, bus_wr, NULL);
        c.pc = (uint16_t)pc; c.s = (uint8_t)s; c.a = (uint8_t)a;
        c.x  = (uint8_t)x;   c.y = (uint8_t)y; c.p = (uint8_t)p;
        ntrace = 0;
        xt6502_step(&c);
        /* A jammed CPU never retires, so the vector is cycle-bounded rather
         * than instruction-bounded: keep clocking the lock-up dance until the
         * trace is as long as the one Harte recorded. */
        while (c.jammed && ntrace < (int)ncyc && ntrace < MAXCYC)
            xt6502_step(&c);

        /* expected final state */
        unsigned fpc, fs, fa, fx, fy, fp, fcnt;
        if (fscanf(f, "%x %x %x %x %x %x", &fpc, &fs, &fa, &fx, &fy, &fp) != 6) break;
        if (fscanf(f, "%u", &fcnt) != 1) break;

        const char *why = NULL;
        char detail[256];
        detail[0] = 0;

        if (c.pc != fpc || c.s != fs || c.a != fa || c.x != fx || c.y != fy || c.p != fp) {
            why = "registers";
            snprintf(detail, sizeof detail,
                     "got pc=%04x s=%02x a=%02x x=%02x y=%02x p=%02x  "
                     "want pc=%04x s=%02x a=%02x x=%02x y=%02x p=%02x",
                     c.pc, c.s, c.a, c.x, c.y, c.p, fpc, fs, fa, fx, fy, fp);
        } else if (ntrace != (int)ncyc) {
            why = "cycle count";
            snprintf(detail, sizeof detail, "got %d cycles, want %u", ntrace, ncyc);
        } else {
            for (unsigned i = 0; i < ncyc && i < MAXCYC; i++)
                if (trace[i].a != want[i].a || trace[i].v != want[i].v
                    || trace[i].rd != want[i].rd) {
                    why = "bus trace";
                    snprintf(detail, sizeof detail,
                             "cycle %u: got %04x %02x %s, want %04x %02x %s",
                             i, trace[i].a, trace[i].v, trace[i].rd ? "r" : "w",
                             want[i].a, want[i].v, want[i].rd ? "r" : "w");
                    break;
                }
        }

        /* expected RAM */
        for (unsigned i = 0; i < fcnt; i++) {
            if (fscanf(f, "%x %x", &addr, &val) != 2) break;
            if (!why && mem[addr] != (uint8_t)val) {
                why = "memory";
                snprintf(detail, sizeof detail, "[%04x] got %02x want %02x",
                         addr, mem[addr], val);
            }
        }

        if (why) {
            if (!failed)
                printf("  FAIL %s case %u (%s): %s\n", name, k, why, detail);
            failed++;
        }
    }
    fclose(f);
    return failed;
}

int main(int argc, char **argv)
{
    char path[512], name[16];
    int opcodes = 0, bad = 0, total = 0;

    if (argc > 1) {
        for (int i = 1; i < argc; i++) {
            snprintf(path, sizeof path, "%s/%s.vec", VECDIR, argv[i]);
            int n = 0, f = run_opcode(path, argv[i], &n);
            if (f < 0) continue;
            opcodes++; total += n; if (f) bad++;
        }
    } else {
        DIR *d = opendir(VECDIR);
        if (!d) { fprintf(stderr, "cannot open %s (run from emu/)\n", VECDIR); return 2; }
        struct dirent *e;
        char names[512][16];
        int nn = 0;
        while ((e = readdir(d)) && nn < 512) {
            size_t l = strlen(e->d_name);
            if (l > 4 && !strcmp(e->d_name + l - 4, ".vec")) {
                snprintf(names[nn], sizeof names[nn], "%.*s", (int)(l - 4), e->d_name);
                nn++;
            }
        }
        closedir(d);
        /* stable order so a regression report is diffable */
        for (int i = 0; i < nn; i++)
            for (int j = i + 1; j < nn; j++)
                if (strcmp(names[j], names[i]) < 0) {
                    char t[16]; strcpy(t, names[i]); strcpy(names[i], names[j]); strcpy(names[j], t);
                }
        for (int i = 0; i < nn; i++) {
            snprintf(path, sizeof path, "%s/%s.vec", VECDIR, names[i]);
            snprintf(name, sizeof name, "%s", names[i]);
            int n = 0, f = run_opcode(path, name, &n);
            if (f < 0) continue;
            opcodes++; total += n; if (f) bad++;
        }
    }

    printf("harte: %d/%d opcodes pass (%d cases)\n", opcodes - bad, opcodes, total);
    return bad ? 1 : 0;
}
