/*
 * irq.c — directed interrupt-timing tests for xt6502.
 *
 * Tom Harte ties the interrupt lines inactive, so 256/256 there says nothing
 * about WHEN an interrupt is taken.  ACID800's cpu_clisei does, and it is
 * merciless: three scenarios that between them pin down the NMOS one-instruction
 * delay, the I flag's value in the PUSHED status, and the fact that an interrupt
 * can be taken with I already set.
 *
 * These are those three scenarios rewritten as a host test, so the property is
 * checked on every build instead of only when the full suite is run on a
 * machine.  See docs/Acid800/cpu_clisei.md.
 */
#include <stdio.h>
#include <string.h>
#include "../xt6502.h"

#define IRQ_HANDLER 0x9000
#define NMI_HANDLER 0x9100

static uint8_t mem[65536];

/* Cycle-precise /NMI injection.  Scenario 5 needs the line to rise DURING a
 * chosen cycle of a BRK, which no amount of stepping between instructions can
 * arrange — so raise it from the bus callback, which is the one hook that runs
 * once per machine cycle.  The callback runs BEFORE the cycle is counted, hence
 * the -1: `nmi_at` is 1-based over the instruction's own cycles. */
static xt6502 *dut;
static long nmi_at = -1;

static void inject(void)
{
    if (dut && nmi_at >= 0 && (long)dut->cycles == nmi_at - 1) dut->nmi = 1;
}

static uint8_t bus_rd(void *ctx, uint16_t a) { (void)ctx; inject(); return mem[a]; }
static void    bus_wr(void *ctx, uint16_t a, uint8_t v) { (void)ctx; inject(); mem[a] = v; }

static int fails;

/* Run until the CPU vectors to the IRQ handler; report X at that moment and the
 * status byte the interrupt sequence pushed. */
static int run_to_irq(xt6502 *c, uint8_t *x_at_irq, uint8_t *pushed_p)
{
    for (int i = 0; i < 100; i++) {
        xt6502_step(c);
        if (c->pc == IRQ_HANDLER) {
            *x_at_irq = c->x;
            /* the sequence pushed PCH, PCL, P — so P is at S+1 */
            *pushed_p = mem[0x0100 | (uint8_t)(c->s + 1)];
            return 1;
        }
        if (c->jammed) return 0;
    }
    return 0;
}

static void setup(xt6502 *c, const uint8_t *prog, size_t n, uint16_t org)
{
    memset(mem, 0, sizeof mem);
    memcpy(mem + org, prog, n);
    mem[0xFFFE] = IRQ_HANDLER & 0xff;
    mem[0xFFFF] = IRQ_HANDLER >> 8;
    mem[IRQ_HANDLER] = 0x02;              /* JAM, so an overrun is obvious */

    dut = NULL; nmi_at = -1;
    xt6502_init(c, bus_rd, bus_wr, NULL);
    c->pc = org;
    c->s  = 0xFD;
    c->p  = XTF_I | XTF_U;                /* interrupts masked to start */
    c->irq = 1;                           /* ...but the line is asserted */
}

static void check(const char *name, int ok, const char *what,
                  unsigned got, unsigned want)
{
    if (ok) return;
    printf("  FAIL %s: %s got $%02x, want $%02x\n", name, what, got, want);
    fails++;
}

int main(void)
{
    xt6502 c;
    uint8_t x, p;

    /* ---- 1: exactly ONE instruction executes after CLI -------------------
     * The NMOS part samples the interrupt lines during the PENULTIMATE cycle,
     * so CLI's own poll still sees I set and the following instruction runs
     * to completion before the IRQ is taken. */
    {
        static const uint8_t prog[] = {
            0xA2, 0xFF,   /* LDX #$FF */
            0xE8,         /* INX      -> X = $00 */
            0x58,         /* CLI      */
            0xE8,         /* INX      -> X = $01  <- interrupt expected AFTER this */
            0xE8, 0xE8, 0x78
        };
        setup(&c, prog, sizeof prog, 0x2000);
        if (!run_to_irq(&c, &x, &p)) { printf("  FAIL cli: no interrupt\n"); fails++; }
        else check("cli", x == 0x01, "X at IRQ", x, 0x01);
    }

    /* ---- 2: a CLI/SEI pair still interrupts — with I SET in the push -----
     * The poll at SEI's penultimate cycle sees the I that CLI cleared, so the
     * interrupt is taken; but SEI has completed by the time the status is
     * pushed, so the pushed byte has I set.  Both halves matter. */
    {
        static const uint8_t prog[] = {
            0xA2, 0xFF,   /* LDX #$FF */
            0xE8,         /* INX -> X = $00 */
            0x58,         /* CLI */
            0x78,         /* SEI  <- interrupt expected after this, X still $00 */
            0xE8, 0xE8, 0xE8
        };
        setup(&c, prog, sizeof prog, 0x2000);
        if (!run_to_irq(&c, &x, &p)) { printf("  FAIL clisei: no interrupt\n"); fails++; }
        else {
            check("clisei", x == 0x00, "X at IRQ", x, 0x00);
            check("clisei", (p & XTF_I) != 0, "pushed I flag", p & XTF_I, XTF_I);
        }
    }

    /* ---- 3: RTI/SEI — the interrupt lands BETWEEN them, I CLEAR ----------
     * RTI pulls the status at its 4th of 6 cycles, so the penultimate-cycle
     * poll already sees the pulled I.  RTI's I is therefore NOT delayed the
     * way CLI's is, and the pushed status has I clear. */
    {
        static const uint8_t prog[] = {
            0xA2, 0xFF,         /* $2000 LDX #$FF */
            0xE8,               /* $2002 INX -> X = $00 */
            0xA9, 0x20, 0x48,   /* $2003 LDA #>next / PHA */
            0xA9, 0x10, 0x48,   /* $2006 LDA #<next / PHA */
            0xA9, 0x20, 0x48,   /* $2009 LDA #$20 (I clear) / PHA */
            0x40,               /* $200C RTI  <- interrupt expected right after */
            0xEA, 0xEA, 0xEA,   /* $200D pad */
            0x78,               /* $2010 next: SEI */
            0xE8                /* $2011 INX */
        };
        setup(&c, prog, sizeof prog, 0x2000);
        if (!run_to_irq(&c, &x, &p)) { printf("  FAIL rtisei: no interrupt\n"); fails++; }
        else {
            check("rtisei", x == 0x00, "X at IRQ", x, 0x00);
            check("rtisei", (p & XTF_I) == 0, "pushed I flag", p & XTF_I, 0);
        }
    }

    /* ---- 4: NMI is edge-triggered and one-shot --------------------------- */
    {
        static const uint8_t prog[] = { 0xEA, 0xEA, 0xEA, 0xEA, 0xEA, 0xEA };
        setup(&c, prog, sizeof prog, 0x2000);
        c.irq = 0;
        mem[0xFFFA] = IRQ_HANDLER & 0xff;
        mem[0xFFFB] = IRQ_HANDLER >> 8;
        xt6502_step(&c);                  /* NOP, line low */
        c.nmi = 1;                        /* rising edge latches */
        xt6502_step(&c);                  /* NOP; poll sees it */
        xt6502_step(&c);                  /* the NMI sequence */
        check("nmi", c.pc == IRQ_HANDLER, "PC after NMI", c.pc, IRQ_HANDLER);
        /* held high must NOT retrigger: return and check we run on */
        c.pc = 0x2000;
        c.p &= (uint8_t)~XTF_I;
        xt6502_step(&c);
        check("nmi", c.pc != IRQ_HANDLER, "level-held NMI retriggered", c.pc, 0x2001);
    }

    /* ---- 5: the NMI/BRK hijack boundary ---------------------------------
     * The vector is committed after the PCH push — the sequence's THIRD cycle.
     * An NMI latched at or before it diverts the vector to $FFFA with the BRK's
     * own pushes intact; one latched after it is not deferred, it is SWALLOWED
     * for good.  ACID800 antic_blockednmi turns on exactly this boundary: the
     * VBI request lands on BRK cycle 4 in its first half (BRK must complete
     * through $FFFE and the NMI must never happen) and on cycle 3 in its
     * second (the NMI must take over). */
    for (int k = 1; k <= 7; k++) {
        static const uint8_t prog[] = { 0x00, 0xEA, 0xEA, 0xEA, 0xEA, 0xEA };
        int hijack = (k <= 3);
        setup(&c, prog, sizeof prog, 0x2000);
        c.irq = 0;
        mem[0xFFFA] = NMI_HANDLER & 0xff;
        mem[0xFFFB] = NMI_HANDLER >> 8;
        mem[IRQ_HANDLER] = mem[NMI_HANDLER] = 0xEA;      /* NOP, so we can run on */
        dut = &c; nmi_at = k;

        xt6502_step(&c);                                 /* the BRK */
        check("brknmi", c.pc == (hijack ? NMI_HANDLER : IRQ_HANDLER),
              "vector taken", c.pc, hijack ? NMI_HANDLER : IRQ_HANDLER);
        if (!hijack) {
            /* and it must be GONE, not merely late */
            xt6502_step(&c);
            check("brknmi", c.pc == IRQ_HANDLER + 1,
                  "swallowed NMI came back", c.pc, IRQ_HANDLER + 1);
        }
    }

    printf("irq: %s\n", fails ? "FAIL" : "all interrupt-timing tests pass");
    return fails ? 1 : 0;
}
