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
#include "../system.h"
#include "../prof.h"

/* Emulation-only clock.
 *
 * Dividing total emulated cycles by total WALL time does not measure the
 * emulator: it measures FatFs. Each test loads a .xex and a .lab off the card
 * before a single 6502 cycle is executed, and antic_default is 37 cycles of
 * emulation behind a full file-load round trip -- so the end-to-end figure is
 * mostly SDIO, and the short tests dominate it. Time the run loop alone.
 *
 * On xtos this reads the kernel's three words directly rather than going
 * through libc's struct timeval: time_t is 64-bit there, so seconds occupy
 * words [0..1] and microseconds word [2] (the same reason progs/wsweep.c
 * bypasses libc).
 *
 * INTEGER ONLY: the xtos build links against libc.so with an undefined-symbol
 * guard, and double arithmetic here drags in __aeabi_dadd/ddiv/... which are not
 * resolvable at load. Microseconds in a uint64 are exact and cost nothing. */
#ifdef __XTOS__
#include "usys.h"
static unsigned long long now_us(void)
{
    unsigned tv[3] = {0, 0, 0};
    __syscall(SYS_gettimeofday, (long)tv, 0, 0);
    return (unsigned long long)tv[0] * 1000000ull + tv[2];
}
#else
#include <sys/time.h>
static unsigned long long now_us(void)
{
    struct timeval tv;
    gettimeofday(&tv, 0);
    return (unsigned long long)tv.tv_sec * 1000000ull + (unsigned)tv.tv_usec;
}
#endif

static unsigned long long g_emu_t0;   /* set when a test's run loop starts */
static unsigned long long g_emu_us;   /* emulation-only time of the last run_one */

/* A9 PMU, read straight from PL0 (the kernel sets PMUSERENR — see zynq.c).
 *
 * Cycles vs instructions-retired is the whole point: it says whether the A9 is
 * STALLED or is simply executing far more instructions than the same C does on
 * the host, and those two want completely different fixes. L1D access/refill
 * come along because if it IS stalls, the next question is immediately "how many
 * touches, and how many of them miss".
 *
 * The counters are 32-bit and PMCCNTR wraps in ~6.4 s at 667 MHz, so sample and
 * RESET periodically into 64-bit accumulators rather than reading once across a
 * 53-second run — a single reading would silently alias. */
#ifdef __XTOS__
static unsigned long long pmu_cyc, pmu_ins, pmu_ref, pmu_acc, pmu_iref, pmu_bmiss, pmu_bexec;

static unsigned pmu_rd_ctr(unsigned i)
{
    unsigned v;
    __asm__ volatile("mcr p15,0,%0,c9,c12,5" :: "r"(i));    /* PMSELR */
    __asm__ volatile("isb");
    __asm__ volatile("mrc p15,0,%0,c9,c13,2" : "=r"(v));    /* PMXEVCNTR */
    return v;
}

static void pmu_sample(void)          /* accumulate, then zero the counters */
{
    unsigned c;
    __asm__ volatile("mrc p15,0,%0,c9,c13,0" : "=r"(c));    /* PMCCNTR */
    pmu_cyc += c;
    pmu_ins   += pmu_rd_ctr(0);
    pmu_ref   += pmu_rd_ctr(1);
    pmu_acc   += pmu_rd_ctr(2);
    pmu_iref  += pmu_rd_ctr(3);
    pmu_bmiss += pmu_rd_ctr(4);
    pmu_bexec += pmu_rd_ctr(5);
    unsigned v;                                              /* PMCR: reset both */
    __asm__ volatile("mrc p15,0,%0,c9,c12,0" : "=r"(v));
    __asm__ volatile("mcr p15,0,%0,c9,c12,0" :: "r"(v | (1u << 1) | (1u << 2)));
    __asm__ volatile("isb");
}
static void pmu_reset(void)           /* zero WITHOUT accumulating: drops the load phase */
{
    unsigned v;
    __asm__ volatile("mrc p15,0,%0,c9,c12,0" : "=r"(v));
    __asm__ volatile("mcr p15,0,%0,c9,c12,0" :: "r"(v | (1u << 1) | (1u << 2)));
    __asm__ volatile("isb");
}
/* PMCCNTR wraps every ~6.4 s at 667 MHz. The board runs ~50 K emulated cycles/s,
 * so 1e6 emulated cycles is ~19 s -- THREE wraps, and the first reading aliased
 * to an impossible 178 MHz. 25 K emulated cycles is ~0.5 s: comfortably inside. */
#define PMU_SAMPLE_EVERY 25000ull
#else
#define pmu_sample() ((void)0)
#define pmu_reset()  ((void)0)
#define PMU_SAMPLE_EVERY 25000ull
#endif

/* Whether a disk drive answers on the serial line -- see the DSKINV stub and
 * sio.c.  ON, because there IS one: sio.c decodes the command frame and shifts
 * its reply back a bit at a time.  Build -DSIO_DEVICE=0 to unplug it. */
#ifndef SIO_DEVICE
#define SIO_DEVICE 1
#endif


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

/* Which bytes the XEX actually put down.  ACID_TRAPOUT uses this to recognise
 * the moment execution leaves real code, on any test. */
static uint8_t loaded[65536];

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
            loaded[(start + i) & 0xFFFF] = 1;
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
/* the last few PCs before a derail — see the JAM report below */
#define PC_RING 64
static uint16_t pc_ring[PC_RING];
static unsigned pc_ring_n;
static int      derail_shown;
static int      key_inject;   /* ACID_KEY: CH code to hand a waiting module */

/* Outcomes.  JAM and TIMEOUT were both reported as "hung", which hid the
 * difference between a test that DERAILED into an illegal opcode and one that
 * is genuinely looping — very different faults needing very different work. */
#define R_PASS     0
#define R_FAIL     1
#define R_JAM     -1
#define R_TIMEOUT -3
#define R_SKIP    -2
/* the module did its work and RTSd back to the loader, as under DOS */
#define R_RET     -4

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
    { const char *p = getenv("ACID_BUSTRACE"); if (p) s.bus_probe = atoi(p); }
    if (getenv("ACID_IRQPROBE")) { s.irq_probe = 1; s.irq_shadow = 0xFF; }
    if (getenv("ACID_GLYPHPROBE")) antic_glyph_probe = atoi(getenv("ACID_GLYPHPROBE"));
    if (getenv("ACID_PTPROBE")) pokey_timer_probe = atoi(getenv("ACID_PTPROBE"));
    if (getenv("ACID_COLPROBE")) s.col_probe = 1;
    if (!load_xex(&s, xex, &run) || !run) return R_SKIP;

    if (t_init) s.ram[t_init] = 0x60;            /* RTS — see the header */

    /* The suite's character output goes through `jmp (_vputchar)`, a vector the
     * OS fills in when _testInit opens IOCB0 — which is exactly the call we
     * stub out above, so the vector stays zero and the first _print sends the
     * CPU to $0000.  Point it at an RTS: printing becomes a no-op and the
     * module runs on.  This is the same accommodation as the _testInit stub,
     * for the same reason: we have no OS, and the MEASUREMENT does not need
     * one.  The four mod_* modules do nothing BUT print and draw, so without it
     * they cannot get past their first line of output. */
    { uint16_t vput = 0;
      if (lab_lookup(lab, "_vputchar", &vput)) {
          s.ram[0xFF50] = 0x60;                  /* RTS */
          s.ram[vput]     = 0x50;
          s.ram[vput + 1] = 0xFF;
      } }

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

    /* Those stubs and vectors live at $FF00-$FFFF, which XL banking overlays
     * with the OS ROM whenever PORTB bit 0 is set -- and it is set out of
     * reset, because an undriven PIA line floats high.  Mirror them into the
     * ROM image so the dispatcher answers under either mapping; a real machine
     * has the equivalent code in its kernel. */
    memcpy(&s.rom_os[0xFF00 - 0xC000], &s.ram[0xFF00], 0x100);

    /* RAMTOP.  mmu_xlbanking's FIRST action is `lda ramtop / cmp #$41` and it
     * skips below that, so a bare XEX run with the OS variables at zero can
     * never reach the banking checks.  $C0 is what an XL kernel leaves. */
    sio_probe = getenv("ACID_SIOPROBE") != NULL;
    gtia_probe = getenv("ACID_PMPROBE") != NULL;
    { const char *k = getenv("ACID_KEY"); if (k) key_inject = (int)strtol(k, 0, 16); }
    s.ram[0x006A] = 0xC0;
    if (!s.ram[0x0217]) { s.ram[0x0216] = 0x40; s.ram[0x0217] = 0xFF; }  /* VIMIRQ */

    /* OS SHADOW REGISTERS.  The library sets SKCTL = 3 at init but later
     * restores it from SSKCTL ($0232), which a booted OS holds at 3 and a bare
     * XEX run leaves at zero — putting POKEY's poly counters back into init, so
     * RANDOM reads $ff forever.  antic_dmapattern never writes SKCTL itself and
     * cannot decode its random pair without this. */
    s.ram[0x0232] = 0x03;                            /* SSKCTL */

    /* OS ENTRY VECTORS.  pokey_skstat opens with "jsr dskinv" to ask D1: for a
     * status, and SKIPS itself if that fails — but with no OS ROM the call lands
     * in unloaded RAM and the CPU BRK-walks the whole address space instead.
     * Answering "no device" turns a derail into the skip the test intends.
     * Returning with N set is what its "bpl disk_ok" tests. */
    static const uint8_t nodev[] = {
        0xA9, 0x80,              /* LDA #$80   — N set: operation failed */
        0x8D, 0x03, 0x03,        /* STA DSTATS                          */
        0xA0, 0x8A,              /* LDY #$8A   — device does not respond */
        0x60,                    /* RTS                                  */
    };
    /* The vectors are three bytes apart because in ROM each is a JMP, so the
     * handler goes elsewhere and each vector jumps to it — writing the handler
     * at all three addresses would have them overlap and corrupt each other. */
    memcpy(&s.ram[0xE480], nodev, sizeof nodev);
    for (unsigned v = 0xE453; v <= 0xE459; v += 3) {
        s.ram[v] = 0x4C; s.ram[v + 1] = 0x80; s.ram[v + 2] = 0xE4;   /* JMP $E480 */
    }
    /* ...except DSKINV ($E453), which now answers SUCCESS because there IS a
     * drive on the serial line.  pokey_skstat and pokey_serdirect open with
     * `jsr dskinv` purely as a "is a drive present" gate and SKIP if it fails;
     * everything they actually test comes after, driving PBCTL/SKCTL/SEROUT
     * directly and watching SKSTAT.  So this opens the gate and nothing more --
     * it is NOT a paravirtual SIO standing in for the line, and it would be a
     * lie if no device answered.  CIOV ($E456) and SIOV ($E459) keep the
     * no-device answer.
     *
     * This was OFF while the drive did not exist, because "no device -> skip" is
     * then the CORRECT answer and opening the gate would have had the emulator
     * claim hardware it did not have.  sio.c is that hardware. */
    /* And it answers as the DRIVE would, not as an unconditional success: a
     * STATUS ($53) completes, and anything else comes back $8B -- DEVICE NAK.
     * pokey_serdirect needs BOTH.  It has two gates, not one: the first wants
     * the status command to succeed, and the second issues a deliberately
     * invalid read of sector 0 and requires Y = $8B, skipping if no command it
     * tries is refused.  A stub that always succeeds passes the first and
     * skips at the second. */
    static const uint8_t dskok[] = {
        0xAD, 0x02, 0x03,        /* LDA DCOMND                                */
        0xC9, 0x53,              /* CMP #$53                                  */
        0xF0, 0x07,              /* BEQ ok                                    */
        0xA9, 0x8B,              /* LDA #$8B                                  */
        0x8D, 0x03, 0x03,        /* STA DSTATS                                */
        0xA0, 0x8B,              /* LDY #$8B   -- device NAK                  */
        0x60,                    /* RTS                                       */
        0xA9, 0x01,              /* LDA #$01               ok:                */
        0x8D, 0x03, 0x03,        /* STA DSTATS                                */
        0xA0, 0x01,              /* LDY #$01   -- N clear: it succeeded       */
        0x60,                    /* RTS                                       */
    };
    if (SIO_DEVICE) {
        memcpy(&s.ram[0xE4A0], dskok, sizeof dskok);
        s.ram[0xE453] = 0x4C; s.ram[0xE454] = 0xA0; s.ram[0xE455] = 0xE4;
    }

    /* IOCB 0's PUT-CHARACTER vector.  The library prints through it —
     * _vputchar is loaded from ICPTL ($0346) and then INCREMENTED, because the
     * OS stores these vectors as address-1 for its RTS despatch.  On a real
     * machine it points into the E: screen handler; here it is zero, so
     * "jmp (_vputchar)" lands on $0001 and every module that prints derails.
     * Discarding the character lets them run. */
    s.ram[0xE490] = 0xA0; s.ram[0xE491] = 0x01;      /* LDY #1  (success)      */
    s.ram[0xE492] = 0x60;                            /* RTS                    */
    s.ram[0x0346] = 0x8F; s.ram[0x0347] = 0xE4;      /* ICPTL/H = $E490 - 1    */
    /* The OS ENTRY POINTS have to reach ROM too, and only once they EXIST —
     * the $FF00 mirror above runs before these are written, so copying there
     * would copy zeros.  Without this they are invisible the moment a test
     * leaves the OS ROM enabled: `jsr dskinv` reads $E453 from rom_os, finds a
     * zero, and BRK-walks through the vector table until it falls out the far
     * end.  That is exactly how pokey_skstat and pokey_serdirect died — not a
     * POKEY bug, and not the interrupt storm the $FF20/$FF40 spins suggested. */
    memcpy(&s.rom_os[0xE400 - 0xC000], &s.ram[0xE400], 0x100);
    /* and POKEY itself: a booted OS has already taken the poly counters OUT of
     * init.  antic_dmapattern never writes SKCTL at all — the library call that
     * would is on a path it does not take — so left at the hardware reset value
     * the counters stay held and RANDOM reads $ff forever. */
    pokey_rand_skctl(&s.pk, 0x03);
    if (!s.ram[0x0201]) { s.ram[0x0200] = 0x40; s.ram[0x0201] = 0xFF; }  /* VDSLST */
    if (!s.ram[0x0223]) { s.ram[0x0222] = 0x30; s.ram[0x0223] = 0xFF; }  /* VVBLKI */

    /* DOS CALLS RUNAD WITH JSR, so a module that finishes its work and does a
     * plain `rts` returns to the loader.  Jumping to it with an empty stack
     * instead makes that `rts` pop zeros, and the CPU lands in zero page and
     * BRK-walks upward -- every $00 byte is a BRK, vectoring to the stub and
     * RTIing two bytes on -- until it hits a $02 and jams.  That is exactly what
     * all three mod_* JAMs were: mod_dispmin's trail ends `2835 2837 283A 283C
     * 283F`, and $283F is main's own `rts`.  Nothing was wrong with the module.
     *
     * So push a return address the way DOS would.  $FF70 is an infinite branch
     * to itself, so a module that returns parks there instead of derailing, and
     * the harness sees the ordinary timeout rather than a spurious JAM. */
    s.ram[0xFF70] = 0x4C; s.ram[0xFF71] = 0x70; s.ram[0xFF72] = 0xFF;  /* JMP $FF70 */
    memcpy(&s.rom_os[0xFF70 - 0xC000], &s.ram[0xFF70], 3);
    s.cpu.pc = run;
    s.cpu.s  = 0xFD;
    s.ram[0x01FD] = 0xFF;            /* RTS pops PC+1, so push $FF6F */
    s.ram[0x01FC] = 0x6F;
    s.cpu.s  = 0xFB;
    s.cpu.p  = XTF_I | XTF_U;

    if (trace_on) { memset(pc_hits, 0, sizeof pc_hits);
                    pc_ring_n = 0; derail_shown = 0; }
    /* ACID_TRAP=<hex addr>: remember the last PCs and dump them the first time
     * execution reaches that address.  Several tests DERAIL rather than fail —
     * pokey_skstat spins on uninitialised RAM at $3720, and the five mod_* jam
     * in the stack or zero page — and for those the useful question is not what
     * they assert but how they got there. */
    unsigned trap = 0;
    int trapout = getenv("ACID_TRAPOUT") != NULL;
    { const char *t = getenv("ACID_TRAP"); if (t) trap = (unsigned)strtoul(t, NULL, 16); }
    uint16_t hist[8192] = {0}; int hn = 0, hcount = 0, trapped = 0;

    int armed = 0;
    g_emu_t0 = now_us();     /* everything above is load + setup, not emulation */
    pmu_reset();             /* ...and so the counters must start here too */
    unsigned long long pmu_next = PMU_SAMPLE_EVERY;
    while (s.cycles < MAX_CYCLES) {
        if (s.cycles >= pmu_next) { pmu_sample(); pmu_next = s.cycles + PMU_SAMPLE_EVERY; }
        if (trapout && !trapped) {
            /* The first PC outside the loaded code — the moment of the derail
             * itself, rather than anywhere along the BRK-walk through zeroed
             * RAM that follows it. */
            uint16_t pc = s.cpu.pc;
            /* "Inside" means a byte the XEX actually loaded, or one of the
             * runner's own stubs.  Deriving it from the load map rather than
             * hardcoding a range is what makes this usable on any test. */
            int inside = loaded[pc] || (pc >= 0xFF00 && pc <= 0xFF4F)
                                    /* only the OS entry points the runner
                                     * actually FILLS: $E453/$E456/$E459 are
                                     * JMP $E480 and $E480+ is the nodev stub.
                                     * Everything between is zeroed, so calling
                                     * it BRK-walks; counting that as "inside"
                                     * hid the entry and reported the exit. */
                                    || (pc >= 0xE453 && pc <= 0xE45B)
                                    || (pc >= 0xE480 && pc <= 0xE493)
                                    || (pc >= 0xE4A0 && pc <= 0xE4B7);
            if (!inside) {
                trapped = 1;
                int n = hcount < 40 ? hcount : 40;
                fprintf(stderr, "  DERAIL to $%04X after %d instructions; last %d PCs:\n",
                        pc, hcount, n);
                fprintf(stderr, "    VIMIRQ $%02X%02X  VDSLST $%02X%02X  VVBLKI $%02X%02X"
                        "  irqen $%02X irqst $%02X pia.irq %d P $%02X\n",
                        s.ram[0x0217], s.ram[0x0216], s.ram[0x0201], s.ram[0x0200],
                        s.ram[0x0223], s.ram[0x0222], s.pt.irqen,
                        pokey_timer_irqst(&s.pt), s.pia.irq, s.cpu.p);
                for (int i = n; i > 0; i--)
                    fprintf(stderr, "    $%04X\n", hist[(hn - i + 8192) % 8192]);
            }
            hist[hn] = pc; hn = (hn + 1) % 8192; hcount++;
        }
        if (trap) {
            if (!trapped && s.cpu.pc == trap) {
                trapped = 1;
                fprintf(stderr, "  TRAP $%04X reached; previous PCs (oldest first):\n", trap);
                for (int i = 0; i < 40; i++) {
                    uint16_t pc = hist[(hn + i) % 8192];
                    if (pc) fprintf(stderr, "    $%04X\n", pc);
                }
            }
            hist[hn] = s.cpu.pc; hn = (hn + 1) % 8192;
        }
        /* Trace the bus around the SKCTL release, which is where the ANTIC
         * timing tests start counting.  Their own comments state the scanline
         * cycles each instruction should occupy, so the trace is directly
         * comparable against the source. */
        if (trace_on && !armed && s.dbg_skctl_at && !s.dbg_rand_seen) {
            armed = 1;
            s.dbg_trace = 20;
        }
        { const char *pw = getenv("ACID_PCWATCH");
          if (pw && s.cpu.pc == (uint16_t)strtoul(pw, NULL, 16))
              fprintf(stderr, "  [pc %04X] line %d cycle %d\n",
                      s.cpu.pc, s.an.scanline, s.an.cycle); }
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
        if (s.cpu.pc == 0xFF70) { *cyc = s.cycles; return R_RET; }
        /* ACID_KEY=<hex>: hand the module a keypress.  mod_options and
         * mod_vbxe80 do not hang -- they spin on `lda:req ch` ($02FC), the OS
         * keyboard register, waiting to be told what to do (mod_options'
         * `waitkey:` then compares for 'C' and 'F').  With no keyboard they wait
         * for ever, which is the honest answer, so the key is INJECTED ONLY when
         * asked for rather than defaulted -- the choice changes what the module
         * does, so it belongs to whoever is running it. */
        if (key_inject && s.cycles > 2000000 && s.ram[0x02FC] == 0)
            s.ram[0x02FC] = (uint8_t)key_inject;
        if (s.cpu.jammed) {
            *cyc = s.cycles;
            /* where it died, and the opcode that killed it — a JAM is always a
             * derail, so the address is the first question. */
            if (trace_on) {
                printf("      jammed at $%04X on opcode $%02X\n",
                       s.cpu.jam_pc, s.cpu.jam_op);
                /* HOW IT GOT THERE.  A JAM is always a derail, and the address
                 * alone never says why -- the instruction that jumped is the
                 * question.  The spin list is a HOT-ADDRESS report and answers a
                 * different one entirely (mod_dispmin's top entries are just its
                 * 256-iteration screen-clear loop, which is perfectly healthy). */
                printf("      last %d PCs:", PC_RING);
                for (unsigned k = pc_ring_n > PC_RING ? pc_ring_n - PC_RING : 0;
                     k < pc_ring_n; k++)
                    printf(" %04X", pc_ring[k & (PC_RING - 1)]);
                printf("\n");
                /* ...and WHICH interrupt line is standing.  A derail that walks
                 * through zero page two bytes at a time between IRQ entries is a
                 * source nobody acknowledged, and the only useful question is
                 * which one -- naming it beats inferring it from IRQST, whose
                 * probe only fires on CHANGES and so says nothing about a line
                 * that is simply stuck high. */
                printf("      irq: pokey=%d pia=%d  irqen $%02X irqst $%02X"
                       "  pactl $%02X pbctl $%02X\n",
                       s.pt.irq, s.pia.irq, s.pt.irqen,
                       pokey_timer_irqst(&s.pt), s.pia.ctl[0], s.pia.ctl[1]);
            }
            return R_JAM;
        }
        if (trace_on) {
            pc_hits[s.cpu.pc]++;
            /* Skip the $FF00 stub page.  Once a derail reaches zero page every
             * $00 byte is a BRK, which vectors to the stub and RTIs back two
             * bytes on -- so the ring fills with FF20/FF40 pairs that are the
             * SYMPTOM and crowd out the instructions that actually did the
             * derailing.  (Mistaking those pairs for a stuck interrupt is how
             * the previous diagnosis went wrong; both IRQ lines read 0.) */
            if ((s.cpu.pc & 0xFF00u) != 0xFF00u)
                pc_ring[pc_ring_n++ & (PC_RING - 1)] = s.cpu.pc;
            /* THE MOMENT OF THE DERAIL.  Once the CPU is loose in zero page it
             * BRK-walks upward two bytes at a time, so by the time it jams the
             * ring holds nothing but symptom -- even 64 deep.  Trip on the
             * FIRST entry below $0200 instead and dump the ring there: that is
             * the instruction that jumped, which is the only useful question. */
            if (!derail_shown && s.cpu.pc < 0x0200) {
                derail_shown = 1;
                printf("      DERAILED into $%04X; last %d PCs before it:",
                       s.cpu.pc, PC_RING);
                for (unsigned k = pc_ring_n > PC_RING ? pc_ring_n - PC_RING : 0;
                     k + 1 < pc_ring_n; k++)
                    printf(" %04X", pc_ring[k & (PC_RING - 1)]);
                printf("\n");
            }
        }
        atari_step(&s);
    }
    *cyc = s.cycles;
    return R_TIMEOUT;
}

/* Collect the base name of every .xex in `dir`.  THE ONE PLATFORM SPLIT IN THIS
 * HARNESS, and it is not cosmetic: xtos's libc.so exports no opendir/readdir at
 * all, and because a program links `-shared -nostdlib` those come out as
 * UNDEFINED symbols that link cleanly and then kill the process at load.  The
 * symptom is the whole suite exiting instantly with no output while a single
 * named test runs fine, which is exactly what happened the first time this ran
 * on the board.  Check with `arm-none-eabi-nm -u <prog>.so`.
 *
 * xtos has a better primitive anyway: SYS_getdents fills a buffer with packed
 * {mode, size, mtime, reclen, namelen, name} records, so a whole directory
 * arrives in one syscall rather than a readdir plus a stat per entry. */
#ifdef __XTOS__
#include "usys.h"

static int list_xex(const char *dir, char names[][64], int *n)
{
    char buf[4096];
    for (int index = 0; *n < 128; ) {
        long got = sys_getdents(dir, index, buf);
        if (got < 0) return -1;
        if (got == 0) break;
        const char *p = buf;
        for (long i = 0; i < got && *n < 128; i++) {
            unsigned short reclen  = *(const unsigned short *)(p + 12);
            unsigned short namelen = *(const unsigned short *)(p + 14);
            const char *nm = p + 16;
            if (namelen > 4 && !strcmp(nm + namelen - 4, ".xex"))
                snprintf(names[(*n)++], 64, "%.*s", namelen - 4, nm);
            p += reclen;
        }
        index += (int)got;
    }
    return 0;
}
#else
#include <dirent.h>

static int list_xex(const char *dir, char names[][64], int *n)
{
    DIR *d = opendir(dir);
    if (!d) return -1;
    struct dirent *e;
    while ((e = readdir(d)) && *n < 128) {
        size_t l = strlen(e->d_name);
        if (l > 4 && !strcmp(e->d_name + l - 4, ".xex"))
            snprintf(names[(*n)++], 64, "%.*s", (int)(l - 4), e->d_name);
    }
    closedir(d);
    return 0;
}
#endif

int main(int argc, char **argv)
{
    /* LINE-BUFFER the results.  Piped (over ssh, or into a file) stdout is
     * block-buffered, so a run that dies part-way loses every line still sitting
     * in the 4 KB buffer and looks like it produced nothing at all -- which is
     * exactly how the first on-board run presented, and it hid where it died. */
    setvbuf(stdout, 0, _IOLBF, 0);
    const char *dir = (argc > 1) ? argv[1] : "../rsrc/acid800/Acid800/standalone";
    char names[128][64];
    int n = 0;

    if (argc > 2 && !strcmp(argv[2], "-t")) {
        trace_on = 1;
        if (argc > 3) snprintf(names[n++], 64, "%s", argv[3]);
    } else if (argc > 2) {
        snprintf(names[n++], 64, "%s", argv[2]);
    } else {
        if (list_xex(dir, names, &n) < 0) {
            fprintf(stderr, "acid: cannot open %s\n", dir); return 2;
        }
        for (int i = 0; i < n; i++)
            for (int j = i + 1; j < n; j++)
                if (strcmp(names[j], names[i]) < 0) {
                    char t[64]; strcpy(t, names[i]);
                    strcpy(names[i], names[j]); strcpy(names[j], t);
                }
    }

    int pass = 0, fail = 0, jam = 0, loop = 0, skip = 0; int ret = 0;
    unsigned long long emu_us_total = 0, emu_cyc_total = 0;
    for (int i = 0; i < n; i++) {
        unsigned long long cyc = 0;
        int r = run_one(dir, names[i], &cyc);
        g_emu_us = now_us() - g_emu_t0;    /* run loop only; excludes the .xex/.lab load */
        pmu_sample();                      /* catch the tail since the last periodic sample */
        emu_us_total += g_emu_us; emu_cyc_total += cyc;
        const char *tag = r == R_PASS ? "PASS" : r == R_FAIL ? "fail"
                        : r == R_JAM  ? "JAM " : r == R_TIMEOUT ? "LOOP"
                        : r == R_RET  ? "ran " : "skip";
        if (r == R_PASS) pass++; else if (r == R_FAIL) fail++;
        else if (r == R_JAM) jam++; else if (r == R_TIMEOUT) loop++;
        else if (r == R_RET) ret++; else skip++;
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
    printf("acid800: %d pass, %d fail, %d jammed, %d looping, %d ran, %d skipped"
           " (of %d)\n", pass, fail, jam, loop, ret, skip, n);
    /* Emulation only. Compare this with wall-clock to see how much of a run is
     * actually the file loads -- on the board they are the larger half. */
    if (emu_us_total > 0) {
        unsigned long long cps = emu_cyc_total * 1000000ull / emu_us_total;
        unsigned long long permille = cps * 1000ull / 1789773ull;   /* vs realtime */
        printf("acid800: %llu emulated cycles in %llu.%03llu s of emulation"
               " = %llu cycles/s (%llu.%llu%% of realtime 1.79 MHz)\n",
               emu_cyc_total, emu_us_total / 1000000ull,
               (emu_us_total % 1000000ull) / 1000ull,
               cps, permille / 10ull, permille % 10ull);
    }
#ifdef __XTOS__
    /* IPC is the discriminator. ~0.1 => the core is STALLED, so the per-cycle
     * design's memory traffic is the problem and the event-scheduled rewrite is
     * the right fix. ~1.0 => it is retiring far more instructions than the same C
     * does on the host, which is a codegen problem and a completely different
     * job. Everything else here is only useful once that is settled. */
    if (pmu_cyc && emu_cyc_total) {
        printf("acid800: PMU  cycles=%llu insns=%llu  L1D acc=%llu refill=%llu\n",
               pmu_cyc, pmu_ins, pmu_acc, pmu_ref);
        printf("acid800: PMU  L1I refill=%llu  branches=%llu mispred=%llu\n",
               pmu_iref, pmu_bexec, pmu_bmiss);
        printf("acid800: PMU  IPC=%llu.%02llu  host-cyc/emu-cyc=%llu"
               "  L1D-acc/emu-cyc=%llu  L1D-miss=%llu.%llu%%\n",
               pmu_ins / pmu_cyc, (pmu_ins * 100ull / pmu_cyc) % 100ull,
               pmu_cyc / emu_cyc_total,
               pmu_acc / emu_cyc_total,
               pmu_acc ? (pmu_ref * 1000ull / pmu_acc) / 10ull : 0ull,
               pmu_acc ? (pmu_ref * 1000ull / pmu_acc) % 10ull : 0ull);
        /* stall budget: how many host cycles each miss class could account for.
         * A9 L1I refill ~ tens of cycles; a mispredict ~8. If neither times its
         * count comes near host-cyc/emu-cyc, the stall is somewhere else again. */
        printf("acid800: PMU  L1I-refill/emu-cyc=%llu  mispred/emu-cyc=%llu"
               "  mispred-rate=%llu%%\n",
               pmu_iref / emu_cyc_total, pmu_bmiss / emu_cyc_total,
               pmu_bexec ? pmu_bmiss * 100ull / pmu_bexec : 0ull);
#if defined(EMU_PROF) && defined(__XTOS__)
        /* Per-subsystem share. The CPU core is DERIVED (total - parts) because
         * sys_cycle is re-entered from the CPU's own bus access, so wrapping it
         * would double-count. */
        {
            unsigned long long parts = 0;
            for (int k = 0; k < PROF_N; k++) parts += prof_acc[k];
            printf("acid800: PROF  (host cycles, %% of emulation, per emu-cycle)\n");
            for (int k = 0; k < PROF_N; k++)
                printf("acid800: PROF  %-14s %12llu  %3llu%%  %6llu/emu-cyc  calls=%llu\n",
                       prof_name[k], prof_acc[k],
                       pmu_cyc ? prof_acc[k] * 100ull / pmu_cyc : 0ull,
                       prof_acc[k] / emu_cyc_total, prof_cnt[k]);
            for (int k = 0; k < PROFC_N; k++)
                printf("acid800: PROF  count %-18s %12llu\n", prof_cname[k], prof_c[k]);
            unsigned long long cpu = pmu_cyc > parts ? pmu_cyc - parts : 0;
            printf("acid800: PROF  %-14s %12llu  %3llu%%  %6llu/emu-cyc  (derived)\n",
                   "6502+bus", cpu, pmu_cyc ? cpu * 100ull / pmu_cyc : 0ull,
                   cpu / emu_cyc_total);
        }
#endif
    }
#endif
    return 0;
}
