/*
 * cpu1.h — the second Cortex-A9 (the AMP core) and the mailbox we talk to it
 * through.
 *
 * Stage 1 of the software-6502/ANTIC investigation (docs/Design/software-
 * emulation-investigation.md) is "prove an app can be launched on the OTHER A9
 * core so it can be given over to the emulator".  This is that mechanism.
 *
 * ---- how CPU1 is released ------------------------------------------------
 * The Zynq BootROM parks CPU1 in a WFE loop polling one word at 0xFFFF_FFF0
 * (OCM) and jumps to whatever non-zero address turns up there (UG585 §6.3,
 * XAPP1078).  Nothing in our boot path has ever touched CPU1 — the FSBL runs on
 * CPU0 and `rst -system` in the JTAG flow resets both cores back through the
 * BootROM — so CPU1 is still sitting in that pen.  Waking it is therefore just:
 * write cpu1_entry to the pen word, DSB, SEV.  No SLCR reset dance, and no
 * trampoline at address 0 (which the kernel could not write anyway: mmu.c maps
 * section 0 as a NULL trap).
 *
 * ---- where CPU1's code lives ---------------------------------------------
 * Nowhere special: CPU1 runs IN PLACE out of the kernel image.  The kernel is
 * loaded at its link address and CPU0's map is identity, so kernel VA == PA,
 * and CPU1 — which arrives with its MMU off, addressing physically — fetches
 * exactly the same instructions.  Nothing is copied, and none of it has to be
 * position-independent.
 *
 * ---- the one rule --------------------------------------------------------
 * CPU1 code may touch ONLY uncached memory.  CPU0 runs with a write-back
 * D-cache and the SCU is not coherent with an MMU-off core, so any kernel
 * global CPU1 read could be stale by a cache line.  Everything CPU1 writes or
 * reads therefore lives in the AMP reservation below, which mmu.c already maps
 * Normal NON-cacheable (SEC_PLANE_K) on CPU0's side, and which CPU1 sees as
 * Strongly-ordered (MMU off) — uncached on both sides, coherent by
 * construction, with no cache maintenance anywhere.  The PL310 L2 is not
 * enabled in this port, so there is nothing behind that either.
 */
#ifndef XT_CPU1_H
#define XT_CPU1_H

/* ---- the AMP reservation (docs/Zynq/memory-map.md) ------------------------
 * Carved out of the 0x2100_0000 spare block.  16 MB, of which the mailbox and
 * CPU1's stack use the first 64 KB; the rest is scratch for whatever CPU1 is
 * given to run (the software 6502/ANTIC, when it exists). */
#define CPU1_BASE        0x21000000
#define CPU1_MBOX_ADDR   (CPU1_BASE + 0x00000000)   /* the mailbox */
#define CPU1_STACK_TOP   (CPU1_BASE + 0x00010000)   /* 64 KB SVC stack, grows down */
#define CPU1_SCRATCH     (CPU1_BASE + 0x00010000)   /* free to CPU1_BASE + 16 MB */

/* ---- the BootROM's CPU1 pen ----------------------------------------------
 * Disassembled from the live board's OCM rather than taken on faith:
 *
 *   FFFFFF2C  dsb sy
 *   FFFFFF30  wfe
 *   FFFFFF34  mvn r0, #15          ; r0 = 0xFFFFFFF0
 *   FFFFFF38  ldr lr, [r0]
 *   FFFFFF3C  cmn lr, #0xD4        ; lr == 0xFFFFFF2C ?
 *   FFFFFF40  beq 0xFFFFFF2C       ; yes -> keep waiting
 *   FFFFFF44  ICIALLU / BPIALL / TLBIALL
 *   FFFFFF54  mcr SCTLR, #0        ; MMU + caches OFF
 *   FFFFFF58  bx  lr               ; -> the address we published
 *
 * Two consequences that are easy to get wrong, and did cost a debugging round:
 *
 *  1. The "nothing to do" sentinel is 0xFFFFFF2C — the address of the loop
 *     itself — NOT zero.  Writing 0 to the pen does not disarm it, it tells
 *     CPU1 to jump to address 0.
 *  2. The pen word lives in OCM and SURVIVES `rst -system`, and the BootROM
 *     does NOT re-initialise it on a warm reset.  A start address left there by
 *     the previous boot is therefore still live when CPU1 comes out of reset:
 *     CPU1 leaves the pen instantly and starts executing the kernel image WHILE
 *     JTAG IS STILL DOWNLOADING THE NEW ELF OVER IT.  So the pen must be
 *     re-parked (set back to the sentinel) once it has done its job. */
#define CPU1_PEN_ADDR    0xFFFFFFF0
#define CPU1_PEN_PARKED  0xFFFFFF2C   /* sentinel = the pen loop's own address */

#define CPU1_MAGIC       0x43505531   /* 'CPU1' — written BY CPU1 on arrival */

/* ---- mailbox field offsets ------------------------------------------------
 * cpu1_boot.S needs these as literals; _Static_assert in cpu1.c keeps them
 * honest against the struct. */
#define CPU1_MB_MAGIC      0x00
#define CPU1_MB_HEARTBEAT  0x04
#define CPU1_MB_MPIDR      0x08
#define CPU1_MB_CMD        0x0c
#define CPU1_MB_SEQ        0x10
#define CPU1_MB_ACK        0x14
#define CPU1_MB_ARG        0x18       /* [4] */
#define CPU1_MB_RES        0x28       /* [4] */
#define CPU1_MB_FAULT_PC   0x38
#define CPU1_MB_FAULT_KIND 0x3c
#define CPU1_MB_FAULT_SPSR 0x40
#define CPU1_MB_FAULT_DFSR 0x44       /* CP15 c5,c0,0 — why the data abort */
#define CPU1_MB_FAULT_DFAR 0x48       /* CP15 c6,c0,0 — the address it faulted on */
#define CPU1_MB_TTBR       0x4c       /* CPU0 -> CPU1: the table to run on */
#define CPU1_MB_MIDR       0x50       /* CPU1 -> CPU0: its own identity + state */
#define CPU1_MB_SCTLR      0x54
#define CPU1_MB_ACTLR      0x58

/* fault_kind values stored by CPU1's own vector table */
#define CPU1_FAULT_NONE  0
#define CPU1_FAULT_RST   1
#define CPU1_FAULT_UND   2
#define CPU1_FAULT_SVC   3
#define CPU1_FAULT_PABT  4
#define CPU1_FAULT_DABT  5
#define CPU1_FAULT_RSVD  6
#define CPU1_FAULT_IRQ   7
#define CPU1_FAULT_FIQ   8

/* ---- commands ------------------------------------------------------------
 * CPU0 fills arg[], sets cmd, then bumps seq; CPU1 runs it and echoes seq into
 * ack.  One outstanding request at a time — this is a doorbell, not a queue. */
#define CPU1_CMD_NOP    0
#define CPU1_CMD_PING   1   /* res[0] = arg[0] ^ 0xA5A5A5A5, res[1] = MPIDR */
#define CPU1_CMD_BENCH  2   /* arg[0] iterations; res[0] = PERIPHCLK ticks, res[1] = checksum */
#define CPU1_CMD_STOP   3   /* ack, then WFI for ever */

#ifndef __ASSEMBLER__
#include <stdint.h>

typedef struct {
    volatile uint32_t magic;       /* CPU1_MAGIC once CPU1 reached cpu1_main */
    volatile uint32_t heartbeat;   /* free-running; CPU1 is alive iff this moves */
    volatile uint32_t mpidr;       /* CPU1's own MPIDR — proof of WHICH core ran */
    volatile uint32_t cmd;
    volatile uint32_t seq;         /* CPU0 -> CPU1 doorbell */
    volatile uint32_t ack;         /* CPU1 -> CPU0 completion (echoes seq) */
    volatile uint32_t arg[4];
    volatile uint32_t res[4];
    /* The FIRST fault only — the handlers refuse to overwrite a recorded one, so
     * an exception loop cannot erase the interesting one underneath it. */
    volatile uint32_t fault_pc;    /* CPU1 took an exception: the offending PC.
                                    * Meaningless for an ASYNCHRONOUS external
                                    * abort — check DFSR before believing it. */
    volatile uint32_t fault_kind;  /* which vector (CPU1_FAULT_*) */
    volatile uint32_t fault_spsr;  /* mode/state CPU1 faulted from */
    volatile uint32_t fault_dfsr;  /* data-fault status */
    volatile uint32_t fault_dfar;  /* data-fault address */

    volatile uint32_t ttbr;        /* CPU0 -> CPU1: TTBR0 value (table | attrs).
                                    * CPU1 shares CPU0's MASTER table rather than
                                    * building its own: it is a flat identity map
                                    * with the AMP region already non-cacheable
                                    * and peripherals already Device, which is
                                    * exactly what CPU1 wants.  CPU1 never
                                    * switches it (per-process tables are CPU0's
                                    * business), so vm_switch cannot pull the
                                    * ground out from under it. */
    volatile uint32_t midr;        /* CPU1 -> CPU0: identity + post-enable state, */
    volatile uint32_t sctlr;       /* so /OS/proc/cpuinfo can report the real */
    volatile uint32_t actlr;       /* thing rather than what we hoped we set. */
} cpu1_mbox;

/* ---- CPU0 side (cpu1.c) --------------------------------------------------- */
void cpu1_init(void);        /* release CPU1, wait (bounded) for its magic */
int  cpu1_alive(void);       /* 1 once CPU1 has announced itself */
cpu1_mbox *cpu1_box(void);   /* the mailbox, for read-only inspection */
uint32_t cpu1_heartbeat_delta(uint32_t us);  /* idle-counter movement over `us` */
int  cpu1_retry(void);       /* re-arm the pen + wake, for a core that missed boot */
uint32_t cpu1_scu_ctrl(void);/* SCU control (bit 0 = enabled) */
uint32_t cpu1_actlr(void);   /* CPU0's ACTLR (bit 6 = SMP) */
void cpu1_debug(uint32_t v[5]); /* pen_armed, pen_final, rst_before, rst_held, rst_after */
/* Submit one command and wait for the ack.  0 = done, -1 = not up / timed out /
 * already busy.  Busy-waits, so keep timeout_us small. */
int  cpu1_call(uint32_t cmd, const uint32_t arg[4], uint32_t res[4], uint32_t timeout_us);

/* ---- CPU1 side (cpu1_core.c / cpu1_boot.S) -------------------------------- */
void cpu1_entry(void);       /* asm: CPU1's entry point, published to the pen */
void cpu1_main(void);        /* C: CPU1's command loop */
#endif /* !__ASSEMBLER__ */

#endif /* XT_CPU1_H */
