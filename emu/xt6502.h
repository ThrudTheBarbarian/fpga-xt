/*
 * xt6502.h — a cycle-exact 6502 in software.
 *
 * Part of the software 6502/ANTIC investigation
 * (docs/Design/software-emulation-investigation.md).  Written fresh against the
 * Altirra Hardware Reference Manual and the MOS datasheet; atari800 and Altirra
 * are GPL and this repo is permissive-only, so neither is vendored — they are
 * oracles and nothing else.
 *
 * ---- the shape, and why it is this shape ---------------------------------
 * ONE BUS CALLBACK PER MACHINE CYCLE.  Every read and write below is exactly
 * one 6502 cycle, issued in the order the real part issues it — including the
 * dummy reads, the RMW double write, and the page-cross fixups.  There is no
 * cycle counter to keep in step with anything, because the bus calls ARE the
 * clock.
 *
 * That is the whole point of moving this into software.  ANTIC runs INSIDE the
 * read callback: when it wants the bus it simply advances the world before
 * handing the CPU its byte, and a halted CPU is a callback that takes longer to
 * return.  So there is no CDC, no two rasters with an arbitrary relative phase,
 * no level-vs-edge strobe hazard, and no /RDY sampled at a commit slot inside a
 * 56-slot subcycle window — none of the four defects the fabric path has.  They
 * are not fixed here; they cannot be expressed here.
 *
 * ---- interrupts ----------------------------------------------------------
 * The NMOS part samples the interrupt lines during the PENULTIMATE cycle of an
 * instruction, not the last.  That one detail is what makes CLI/SEI/PLP take
 * effect one instruction late, and ACID800 tests it.  So the poll is a
 * two-deep pipeline (`poll` / `poll_prev`) clocked by the bus helpers, and the
 * decision at instruction end reads `poll_prev`.
 */
#ifndef XT6502_H
#define XT6502_H

#include <stdint.h>

/* One call == one machine cycle.  The implementation may take as long as it
 * likes (that is how ANTIC steals cycles), but it must service exactly one. */
typedef uint8_t (*xt6502_rd_fn)(void *ctx, uint16_t addr);
typedef void    (*xt6502_wr_fn)(void *ctx, uint16_t addr, uint8_t val);

typedef struct {
    uint16_t pc;
    uint8_t  a, x, y, s, p;

    /* Interrupt inputs, active-high here (1 = the /line is asserted). */
    uint8_t  irq;          /* level-sensitive, gated by the I flag */
    uint8_t  nmi;          /* edge-sensitive: a 0->1 transition latches it */
    uint8_t  nmi_prev;
    uint8_t  nmi_pend;

    uint8_t  jammed;       /* a KIL/JAM opcode was executed */
    uint8_t  jam_cnt;      /* drives the lock-up address dance (saturates) */

    /* penultimate-cycle interrupt poll (see the header comment) */
    uint8_t  poll, poll_prev;

    xt6502_rd_fn rd;
    xt6502_wr_fn wr;
    void        *ctx;

    uint64_t cycles;       /* machine cycles since init */
} xt6502;

enum {
    XTF_C = 0x01, XTF_Z = 0x02, XTF_I = 0x04, XTF_D = 0x08,
    XTF_B = 0x10, XTF_U = 0x20, XTF_V = 0x40, XTF_N = 0x80
};

void xt6502_init(xt6502 *c, xt6502_rd_fn rd, xt6502_wr_fn wr, void *ctx);

/* The real 7-cycle reset sequence (three dummy stack reads, then the vector),
 * so a system that watches the bus sees what it would see on hardware. */
void xt6502_reset(xt6502 *c);

/* Execute one instruction, or one interrupt sequence if the penultimate-cycle
 * poll said so.  Performs every bus cycle of it. */
void xt6502_step(xt6502 *c);

#endif /* XT6502_H */
