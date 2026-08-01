/*
 * acid.c — run the real ACID800 .xex tests against the software machine.
 *
 * No Atari OS ROM is involved (we have none, and could not vendor one).  The
 * suite's own symbol table — the .lab file beside each .xex — gives the three
 * addresses that make scoring possible without one:
 *
 *   _testInit    patched to RTS.  It opens IOCB0 through the OS, which we do
 *                not have; the MEASUREMENT does not need it.
 *   _testPassed  reaching it is a pass.
 *   _testFailed  reaching it is a fail.
 *
 * That scores the part of each test that actually measures hardware, which is
 * the part being built.  A test whose measurement never terminates shows as
 * "hung" rather than silently as either result.
 *
 * One more thing the OS normally supplies and the tests genuinely need: the NMI
 * DISPATCHER.  Without it the NMI vector at $FFFA is zero, so the first VBI
 * sends the CPU to address 0 and every test that enables interrupts derails —
 * which is exactly what the PC histogram showed, 28 million hits at $0000.  So
 * install the smallest stub that does what the OS does: read NMIST, and jump
 * through VDSLST for a DLI or VVBLKI for a VBI.  The default VBI handler ticks
 * RTCLOK, because _waitVBL polls it.
 *
 *   emu/build/acid <dir>          run every .xex in <dir>
 *   emu/build/acid <dir> <name>   run one
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>
#include "../system.h"

#define MAX_CYCLES 200000000ULL

static int lab_lookup(const char *path, const char *sym, uint16_t *out)
{
    FILE *f = fopen(path, "r");
    if (!f) return 0;
    char line[256];
    int found = 0;
    while (fgets(line, sizeof line, f)) {
        unsigned bank, addr; char name[128];
        if (sscanf(line, "%x %x %127s", &bank, &addr, name) == 3
            && !strcmp(name, sym)) { *out = (uint16_t)addr; found = 1; break; }
    }
    fclose(f);
    return found;
}

/* Load an Atari XEX: $FFFF header (optional per segment), then start/end/data.
 * Returns the RUN address from $02E0, or 0. */
static int load_xex(atari *s, const char *path, uint16_t *runaddr)
{
    FILE *f = fopen(path, "rb");
    if (!f) return 0;
    int first = 1;
    *runaddr = 0;
    for (;;) {
        unsigned char h[4];
        if (fread(h, 1, 2, f) != 2) break;
        if (h[0] == 0xFF && h[1] == 0xFF) {          /* segment marker */
            if (fread(h, 1, 2, f) != 2) break;
        }
        unsigned start = (unsigned)h[0] | ((unsigned)h[1] << 8);
        if (fread(h, 1, 2, f) != 2) break;
        unsigned end = (unsigned)h[0] | ((unsigned)h[1] << 8);
        if (end < start) break;
        unsigned n = end - start + 1;
        for (unsigned i = 0; i < n; i++) {
            int c = fgetc(f);
            if (c < 0) { fclose(f); return first ? 0 : 1; }
            s->ram[(start + i) & 0xFFFF] = (uint8_t)c;
        }
        if (start <= 0x02E1 && end >= 0x02E0)
            *runaddr = (uint16_t)(s->ram[0x02E0] | (s->ram[0x02E1] << 8));
        first = 0;
    }
    fclose(f);
    return 1;
}

/* Where a hung test is spinning.  A histogram rather than a trace: a test that
 * never terminates is in a loop, and the loop's addresses are what identify it
 * in the .lst. */
static unsigned long pc_hits[65536];
static int trace_on;

/* Outcomes.  JAM and TIMEOUT were both reported as "hung", which hid the
 * difference between a test that DERAILED into an illegal opcode and one that
 * is genuinely looping — very different faults needing very different work. */
#define R_PASS     0
#define R_FAIL     1
#define R_JAM     -1
#define R_TIMEOUT -3
#define R_SKIP    -2

static int run_one(const char *dir, const char *name, unsigned long long *cyc)
{
    char xex[512], lab[512];
    snprintf(xex, sizeof xex, "%s/%s.xex", dir, name);
    snprintf(lab, sizeof lab, "%s/%s.lab", dir, name);

    uint16_t t_init = 0, t_pass = 0, t_fail = 0, t_skip = 0, run = 0;
    if (!lab_lookup(lab, "_testPassed", &t_pass)) return R_SKIP;
    if (!lab_lookup(lab, "_testFailed", &t_fail)) return R_SKIP;
    lab_lookup(lab, "_testInit", &t_init);
    /* The suite has its own SKIP path — _SKIP jumps here when a test decides it
     * cannot run (a 65C816 probe on a 6502, <64K of memory, a POKEY IRQ source
     * that is not responding).  Reaching it is a legitimate outcome, not a
     * failure of ours, and treating it as one was reporting these as JAMs. */
    lab_lookup(lab, "_testSkipped", &t_skip);

    static atari s;
    atari_init(&s);
    { const char *p = getenv("ACID_PFPROBE"); if (p) s.pf_probe = atoi(p); }
    if (getenv("ACID_GLYPHPROBE")) antic_glyph_probe = atoi(getenv("ACID_GLYPHPROBE"));
    if (getenv("ACID_COLPROBE")) s.col_probe = 1;
    if (!load_xex(&s, xex, &run) || !run) return R_SKIP;

    if (t_init) s.ram[t_init] = 0x60;            /* RTS — see the header */

    /* ---- the OS's NMI dispatcher, in fourteen bytes ---------------------- */
    static const uint8_t nmi_stub[] = {
        0x48,                    /* $FF00  PHA                              */
        0xAD, 0x0F, 0xD4,        /* $FF01  LDA NMIST                        */
        0x10, 0x04,              /* $FF04  BPL vbi                          */
        0x68,                    /* $FF06  PLA                              */
        0x6C, 0x00, 0x02,        /* $FF07  JMP (VDSLST)                     */
        /* The two NMI paths push DIFFERENT amounts, and the handlers read their
         * own return address off the stack, so this is load-bearing:
         *   DLI  pushes NOTHING  (antic_dlitiming reads PCL at $0104,X after
         *                         two pushes of its own)
         *   VBI  pushes A, X, Y  (cpu_bugs reads PCL at $0105,X and PCH at
         *                         $0106,X with no pushes of its own, and its
         *                         bail-out path pulls exactly three registers)
         * A is already on the stack from the PHA above — the original value,
         * since LDA NMIST clobbered the register but not the copy. */
        0x8A,                    /* $FF0A  TXA            vbi:              */
        0x48,                    /* $FF0B  PHA                              */
        0x98,                    /* $FF0C  TYA                              */
        0x48,                    /* $FF0D  PHA                              */
        0x6C, 0x22, 0x02,        /* $FF0E  JMP (VVBLKI)                     */
    };
    /* The OS also dispatches IRQ/BRK through VIMIRQ.  Without it a BRK returns
     * immediately from a bare RTI, the test's handler never runs, and the
     * return address it was relying on is wrong — which showed up as the CPU
     * executing the STACK PAGE ($01FE, $01F9) and jamming there. */
    static const uint8_t irq_stub[] = {
        0x6C, 0x16, 0x02,        /* $FF20  JMP (VIMIRQ) */
    };
    /* default handlers: tick RTCLOK (what _waitVBL polls), then RTI */
    static const uint8_t dflt[] = {
        0xE6, 0x14,              /* $FF30  INC RTCLOK+2                     */
        0xD0, 0x06,              /* $FF32  BNE done                         */
        0xE6, 0x13,              /* $FF34  INC RTCLOK+1                     */
        0xD0, 0x02,              /* $FF36  BNE done                         */
        0xE6, 0x12,              /* $FF38  INC RTCLOK                       */
        /* the VBI dispatch pushed A,X,Y — unwind them, or the RTI returns to
         * whatever the registers happened to hold */
        0x68,                    /* $FF3A  PLA            done:             */
        0xA8,                    /* $FF3B  TAY                              */
        0x68,                    /* $FF3C  PLA                              */
        0xAA,                    /* $FF3D  TAX                              */
        0x68,                    /* $FF3E  PLA                              */
        0x40,                    /* $FF3F  RTI                              */
        0x40,                    /* $FF40  RTI    — bare, for DLI and IRQ   */
    };
    memcpy(&s.ram[0xFF00], nmi_stub, sizeof nmi_stub);
    memcpy(&s.ram[0xFF20], irq_stub, sizeof irq_stub);
    memcpy(&s.ram[0xFF30], dflt,     sizeof dflt);
    s.ram[0xFFFA] = 0x00; s.ram[0xFFFB] = 0xFF;      /* NMI -> dispatcher */
    s.ram[0xFFFE] = 0x20; s.ram[0xFFFF] = 0xFF;      /* IRQ/BRK -> dispatcher */
    if (!s.ram[0x0217]) { s.ram[0x0216] = 0x40; s.ram[0x0217] = 0xFF; }  /* VIMIRQ */
    if (!s.ram[0x0201]) { s.ram[0x0200] = 0x40; s.ram[0x0201] = 0xFF; }  /* VDSLST */
    if (!s.ram[0x0223]) { s.ram[0x0222] = 0x30; s.ram[0x0223] = 0xFF; }  /* VVBLKI */

    s.cpu.pc = run;
    s.cpu.s  = 0xFD;
    s.cpu.p  = XTF_I | XTF_U;

    if (trace_on) memset(pc_hits, 0, sizeof pc_hits);
    int armed = 0;
    while (s.cycles < MAX_CYCLES) {
        /* Trace the bus around the SKCTL release, which is where the ANTIC
         * timing tests start counting.  Their own comments state the scanline
         * cycles each instruction should occupy, so the trace is directly
         * comparable against the source. */
        if (trace_on && !armed && s.dbg_skctl_at && !s.dbg_rand_seen) {
            armed = 1;
            s.dbg_trace = 20;
        }
        if (getenv("ACID_NMIPROBE") && s.cpu.pc == 0xFF00) {
            static int n; if (++n <= 6 || getenv("ACID_NMICOUNT"))
                fprintf(stderr, "  [nmi #%d] cycle %llu nmist $%02X nmien $%02X dl_addr $%04X\n",
                        n, (unsigned long long)s.cycles, s.an.nmist, s.an.nmien, s.an.dl_addr);
        }
        if (s.cpu.pc == t_pass) { *cyc = s.cycles; return 0; }
        if (t_skip && s.cpu.pc == t_skip) { *cyc = s.cycles; return R_SKIP; }
        if (s.cpu.pc == t_fail) {
            *cyc = s.cycles;
            /* _testFailed is reached by JSR with its message inline immediately
             * after the call, so the return address on the stack points one byte
             * short of the text.  That names the exact assertion that broke,
             * which d0..d5 alone never do. */
            {
                uint16_t sp = (uint16_t)(0x0100 + s.cpu.s);
                uint16_t ra = (uint16_t)(s.ram[sp + 1] | (s.ram[sp + 2] << 8));
                printf("      \"");
                for (int i = 1; i <= 72 && s.ram[ra + i]; i++) {
                    uint8_t ch = s.ram[ra + i];
                    putchar(ch >= 0x20 && ch < 0x7F ? ch : '.');
                }
                printf("\"\n");
            }
            /* d0..d7 are the suite's scratch at $C8..$CF, and they are what the
             * _ASSERT macros compare — so on a failure they say WHICH value was
             * wrong, not merely that one was. */
            if (trace_on && s.dbg_rand_seen)
                printf("      LFSR advances from SKCTL release to first RANDOM read:"
                       " %llu (hardware: 113)\n",
                       (unsigned long long)(s.dbg_rand_at - s.dbg_skctl_at - 1));
            if (trace_on)
                printf("      d0..d7 = %02X %02X %02X %02X %02X %02X %02X %02X\n",
                       s.ram[0xC8], s.ram[0xC9], s.ram[0xCA], s.ram[0xCB],
                       s.ram[0xCC], s.ram[0xCD], s.ram[0xCE], s.ram[0xCF]);
            return 1;
        }
        if (s.cpu.jammed) {
            *cyc = s.cycles;
            /* where it died, and the opcode that killed it — a JAM is always a
             * derail, so the address is the first question. */
            if (trace_on)
                printf("      jammed at $%04X on opcode $%02X\n",
                       s.cpu.jam_pc, s.cpu.jam_op);
            return R_JAM;
        }
        if (trace_on) pc_hits[s.cpu.pc]++;
        atari_step(&s);
    }
    *cyc = s.cycles;
    return R_TIMEOUT;
}

int main(int argc, char **argv)
{
    const char *dir = (argc > 1) ? argv[1] : "../rsrc/acid800/Acid800/standalone";
    char names[128][64];
    int n = 0;

    if (argc > 2 && !strcmp(argv[2], "-t")) {
        trace_on = 1;
        if (argc > 3) snprintf(names[n++], 64, "%s", argv[3]);
    } else if (argc > 2) {
        snprintf(names[n++], 64, "%s", argv[2]);
    } else {
        DIR *d = opendir(dir);
        if (!d) { fprintf(stderr, "acid: cannot open %s\n", dir); return 2; }
        struct dirent *e;
        while ((e = readdir(d)) && n < 128) {
            size_t l = strlen(e->d_name);
            if (l > 4 && !strcmp(e->d_name + l - 4, ".xex"))
                snprintf(names[n++], 64, "%.*s", (int)(l - 4), e->d_name);
        }
        closedir(d);
        for (int i = 0; i < n; i++)
            for (int j = i + 1; j < n; j++)
                if (strcmp(names[j], names[i]) < 0) {
                    char t[64]; strcpy(t, names[i]);
                    strcpy(names[i], names[j]); strcpy(names[j], t);
                }
    }

    int pass = 0, fail = 0, jam = 0, loop = 0, skip = 0;
    for (int i = 0; i < n; i++) {
        unsigned long long cyc = 0;
        int r = run_one(dir, names[i], &cyc);
        const char *tag = r == R_PASS ? "PASS" : r == R_FAIL ? "fail"
                        : r == R_JAM  ? "JAM " : r == R_TIMEOUT ? "LOOP" : "skip";
        if (r == R_PASS) pass++; else if (r == R_FAIL) fail++;
        else if (r == R_JAM) jam++; else if (r == R_TIMEOUT) loop++; else skip++;
        printf("  %-24s %s  %llu cycles\n", names[i], tag, cyc);
        if (trace_on && (r == R_JAM || r == R_TIMEOUT)) {
            /* top spinning addresses — look these up in <name>.lst */
            for (int k = 0; k < 8; k++) {
                unsigned long best = 0; int at = -1;
                for (int q = 0; q < 65536; q++)
                    if (pc_hits[q] > best) { best = pc_hits[q]; at = q; }
                if (at < 0 || !best) break;
                printf("      spin $%04X  %lu hits\n", at, best);
                pc_hits[at] = 0;
            }
        }
    }
    printf("acid800: %d pass, %d fail, %d jammed, %d looping, %d skipped (of %d)\n",
           pass, fail, jam, loop, skip, n);
    return 0;
}
