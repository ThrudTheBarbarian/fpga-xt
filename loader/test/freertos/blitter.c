/*
 * blitter.c — /dev/blitter: the kernel-mediated path to the PL's xt_blitter.
 *
 * Rocks doc RESPONSIBILITIES.md §13. The blitter is a command-queued 2D engine in the
 * fabric and — this is the whole reason it is a device — it is a DMA ENGINE WITH NO MMU.
 * It takes PHYSICAL addresses. A process with raw access to its registers can blit to any
 * physical address: another app's backing store, the framebuffer, the kernel. Raw blitter
 * access *is* arbitrary physical write, so it cannot be handed to a client.
 *
 * Hence the four rules of §13, and what this file does about each:
 *
 *  (1) COMMANDS NAME SURFACES BY HANDLE, NEVER BY ADDRESS.  A command carries shm ids;
 *      the driver resolves id -> physical itself and BOUNDS-CHECKS every rect against the
 *      surface's own allocation. A client cannot even *express* an out-of-bounds blit. If
 *      commands carried addresses, the driver would have to validate every rect x stride
 *      range against the caller's surface set — possible, but it only needs to be got
 *      wrong once.
 *
 *  (2) ARBITRATE AT THE HARDWARE FIFO, NOT AT ACCEPT.  The engine has one ~1024-deep
 *      command FIFO. Pushing accepted work straight into it makes the FIFO the
 *      unarbitrated resource, and gemd's priority commands would wait behind 1024
 *      already-committed client blits. So submission stops on QFULL and leaves headroom
 *      for the priority fd.
 *
 *  (3) SUBMIT RETURNS A RETIRE SEQUENCE NUMBER.  The hardware already keeps one
 *      (BLT_SEQ). Priority means gemd can composite a window whose own draws have not
 *      retired, so "posted damage" must mean "my pixels are in memory" — and only a fence
 *      can say that. Damage carries the seq; gemd waits for it.
 *
 *  (4) FAIRNESS IS PER-PROCESS, NOT PER-FD.  A VDI opens a blitter fd per workstation, so
 *      an app with six windows has seven fds. Round-robin over fds would reward opening
 *      windows.
 *
 * ⚠ ISOLATION CAVEAT (pre-existing, see vm.c): mmu.c maps the whole PL region SEC_PLANE =
 * AP=11 (PL0-RW) and every space inherits it, so a client can ALREADY write any surface —
 * and the framebuffer — directly at its identity address. Rule (1) therefore closes the
 * blitter path, but not the memory path, until that region is made PL0-none.
 */
#include <stdint.h>
#include <string.h>
#include "frtos_os.h"
#include "xtsys.h"

/* ---- register file ---------------------------------------------------------
 * GP0 block 0 (xt_gp0_pkg.sv: BLK_BLITTER = 0x000). The config registers are BYTE-wide
 * (the dead-tree driver uses Xil_Out8), which is why every 16-bit field is a LO/HI pair.
 * STATUS and SEQ are 32-bit reads. */
#define BLT_BASE   0x43C00000u

#define BL_DST_X_LO 0x00
#define BL_DST_Y_LO 0x02
#define BL_DST_W_LO 0x04
#define BL_DST_H_LO 0x06
#define BL_CMD      0x0C
#define BL_RASTER   0x0F
#define BL_SRC_X_LO 0x10
#define BL_SRC_Y_LO 0x12
#define BL_SRC_W_LO 0x14
#define BL_SRC_H_LO 0x16
#define BL_FLAGS    0x18
#define BL_PAT_PHX  0x08
#define BL_PAT_PHY  0x09
#define BL_PAT_LOGW 0x0A
#define BL_PAT_DATA 0x0B
#define BL_PAT_LOGH 0x0E
#define BL_SRC_BASE 0x30      /* 4 bytes, LSB first */
#define BL_SRC_STR  0x34      /* 2 bytes */
#define BL_DST_BASE 0x36      /* 4 bytes */
#define BL_DST_STR  0x3A      /* 2 bytes */
#define BL_STATUS   0x40      /* R: {pat_blocked[2], queue_full[1], busy[0]} */
#define BL_SEQ      0x44      /* R: seq_counter[15:0] — the retire fence */

#define BL_ST_BUSY  (1u << 0)
#define BL_ST_QFULL (1u << 1)

#define BL_F_BLEND   (1u << 0)
#define BL_F_SRC_DDR (1u << 2)
#define BL_F_AOVER   (1u << 4)
#define BL_F_DST_DDR (1u << 5)

#define BL_CMD_RECT_FILL  0x01
#define BL_CMD_BLOCK_BLIT 0x03
#define BL_CMD_SYNC       0x07

static inline void w8(unsigned off, uint8_t v)
{ *(volatile uint8_t *)(BLT_BASE + off) = v; }
static inline void w16(unsigned off, uint16_t v)
{ w8(off, (uint8_t)v); w8(off + 1, (uint8_t)(v >> 8)); }
static inline void w32(unsigned off, uint32_t v)
{ w8(off, (uint8_t)v); w8(off+1, (uint8_t)(v>>8)); w8(off+2, (uint8_t)(v>>16)); w8(off+3, (uint8_t)(v>>24)); }
static inline uint32_t r32(unsigned off)
{ return *(volatile uint32_t *)(BLT_BASE + off); }

/* ---- THE UNLOCK GATE — do this before touching ANY blitter register ---------
 * The XT gates its native register blocks behind a lock that RESETS LOCKED, exactly like
 * the bank-select registers ($D5C0/$D5C1, gated by bit 3 of $D1DF — the trap that already
 * cost us once). From the HDL:
 *
 *     xt_gp0_pkg.sv:42   CTRL_UNLOCK = 8'h08   // RW register-unlock (dual: 6502 $D1DF)
 *     fpga_xt_top.sv:528 UNLK_BLIT   = 2       // blitter
 *     fpga_xt_top.sv:529 UNLK_BANK   = 3       // $D5C0/$D5C1 bank select
 *
 * CTRL is GP0 block 3, so the register is at GP0 + 0x300 + 0x08 = 0x43C0_0308, and the
 * blitter is bit 2.
 *
 * Touching a LOCKED blitter does not merely fail — it WEDGES THE AXI BUS AND HANGS THE
 * BOARD. That is what an unlocked-gate access looks like from software: not an error, a
 * dead machine. (Diagnosed the hard way: the kernel boots perfectly and prints its whole
 * banner; running blittest is what killed it.) */
#define CTRL_UNLOCK 0x43C00308u
#define UNLK_BLIT   (1u << 2)

static int g_unlocked;
static void blit_unlock(void)
{
    if (g_unlocked) return;
    volatile uint32_t *u = (volatile uint32_t *)CTRL_UNLOCK;
    *u = *u | UNLK_BLIT;
    __asm__ volatile("dsb");
    g_unlocked = 1;
}

uint32_t blit_status(void) { return r32(BL_STATUS); }
uint32_t blit_seq(void)    { return r32(BL_SEQ) & 0xFFFFu; }   /* retired count */

/* ---- per-surface geometry --------------------------------------------------
 * The kernel does NOT know what a window is, and must not: a surface is bytes. But the
 * blitter addresses rows by stride, so the driver has to be told each surface's stride
 * before it can bound-check anything. That is the ONLY geometry it learns. Everything
 * else — width, height, what the pixels mean — stays in GEM where it belongs. */
#define BL_NSURF 256
static uint32_t g_stride[BL_NSURF];

int blit_declare(int id, uint32_t stride)
{
    if (id < 0 || id >= BL_NSURF || !stride || stride > 65535u) return -1;
    g_stride[id] = stride;
    return 0;
}

/* Resolve a surface handle to a physical base, and REFUSE anything the engine cannot
 * actually read. A pool-backed shm is 2048 unrelated 4 KB frames; the blitter accumulates
 * base+stride and would walk straight off the first page into whatever follows. It would
 * not fail — it would render garbage and corrupt memory. Only XT_SHM_CONTIG surfaces
 * (plv_alloc) may be named. */
static uint32_t surf_phys(int id, uint32_t *size)
{
    if (id < 0 || id >= BL_NSURF) return 0;
    return vm_shm_phys(id, size);          /* 0 unless live AND contiguous */
}

/* The engine's DDR path is addressed by a software-computed ROW0 + row stride
 * ("The blitter only accumulates — +stride per row, +bpp per pixel, no fabric multiply",
 * hdl/xt_blitter.sv). So the driver computes the origin-pixel address itself. */
static uint32_t row0(uint32_t base, uint32_t x, uint32_t y, uint32_t stride)
{ return base + y * stride + x * 4u; }

/* Clip a rect so every byte it touches lies inside the surface's OWN allocation. This is
 * rule (1): a client cannot express an out-of-bounds blit, because the driver will not
 * emit one. Returns 0 if nothing is left to draw. */
static int clip(uint32_t size, uint32_t stride, uint32_t x, uint32_t y,
                uint32_t *w, uint32_t *h)
{
    if (!stride || !*w || !*h) return 0;
    uint32_t rowpx = stride / 4u;
    if (x >= rowpx) return 0;
    if (x + *w > rowpx) *w = rowpx - x;                  /* clamp to the row */
    uint32_t rows = size / stride;
    if (y >= rows) return 0;
    if (y + *h > rows) *h = rows - y;                    /* clamp to the surface */
    if (!*w || !*h) return 0;
    /* belt and braces: the last byte touched must be inside the allocation */
    uint64_t last = (uint64_t)(y + *h - 1u) * stride + (uint64_t)(x + *w) * 4u;
    if (last > size) return 0;
    return 1;
}

/* Submit ONE command. Returns the seq it will retire at, or -1 if it was rejected.
 * Rule (2): we stop on QFULL rather than spinning a client's work into the FIFO, so the
 * priority fd always has room. */
long blit_submit(const struct xt_blit_cmd *c, int priority)
{
    blit_unlock();                                       /* or the first register touch hangs */
    uint32_t dsz = 0, ssz = 0;
    uint32_t dphys = surf_phys(c->dst_id, &dsz);
    if (!dphys) return -1;                                /* not a live contiguous surface */
    uint32_t dstr = g_stride[c->dst_id];
    uint32_t dw = c->dw, dh = c->dh;
    if (!clip(dsz, dstr, c->dx, c->dy, &dw, &dh)) return -1;

    /* leave FIFO headroom: a client must never be able to starve gemd's composite */
    int spins = 0;
    while ((blit_status() & BL_ST_QFULL) && !priority) {
        if (++spins > 100000) return -1;                  /* wedged engine: fail, don't hang */
    }

    uint32_t flags = BL_F_DST_DDR;
    if (c->flags & XT_BLITF_BLEND) flags |= BL_F_BLEND | BL_F_AOVER;

    if (c->op == XT_BLIT_COPY) {
        uint32_t sphys = surf_phys(c->src_id, &ssz);
        if (!sphys) return -1;
        uint32_t sstr = g_stride[c->src_id];
        uint32_t sw = dw, sh = dh;                        /* 1:1 block blit */
        if (!clip(ssz, sstr, c->sx, c->sy, &sw, &sh)) return -1;
        if (sw < dw) dw = sw;                             /* the smaller rect wins */
        if (sh < dh) dh = sh;
        /* The RTL cannot barrel-shift a non-zero source X, so a shifted-parity block
         * blit would silently produce garbage. Reject it rather than emit rubbish. */
        if (c->sx & 1u) return -1;
        flags |= BL_F_SRC_DDR;
        w32(BL_SRC_BASE, row0(sphys, c->sx, c->sy, sstr));
        w16(BL_SRC_STR,  (uint16_t)sstr);
        /* SRC_X/Y carry the real coords: the engine uses their LOW BIT for 64-bit
         * half-beat parity. Passing 0 here misaligns every odd-X blit. */
        w16(BL_SRC_X_LO, (uint16_t)c->sx); w16(BL_SRC_Y_LO, (uint16_t)c->sy);
        w16(BL_SRC_W_LO, (uint16_t)dw);    w16(BL_SRC_H_LO, (uint16_t)dh);
    } else if (c->op != XT_BLIT_FILL) {
        return -1;                                        /* unknown op: reject, never guess */
    }

    /* FILL colour is a 1x1 PATTERN, not a colour register. Get this wrong and the
     * engine still fills perfectly -- with whatever stale bytes are in the pattern
     * BRAM (zeros from reset), which reads exactly like "the blit never ran". */
    if (c->op == XT_BLIT_FILL) {
        w8(BL_PAT_LOGW, 0); w8(BL_PAT_LOGH, 0);           /* 1x1 */
        w8(BL_PAT_PHX,  0); w8(BL_PAT_PHY,  0);
        w8(BL_PAT_DATA, (uint8_t)(c->color >> 24));
        w8(BL_PAT_DATA, (uint8_t)(c->color >> 16));
        w8(BL_PAT_DATA, (uint8_t)(c->color >> 8));
        w8(BL_PAT_DATA, (uint8_t)(c->color));
    }

    w32(BL_DST_BASE, row0(dphys, c->dx, c->dy, dstr));
    w16(BL_DST_STR,  (uint16_t)dstr);
    w16(BL_DST_X_LO, (uint16_t)c->dx); w16(BL_DST_Y_LO, (uint16_t)c->dy);  /* half parity */
    w16(BL_DST_W_LO, (uint16_t)dw);    w16(BL_DST_H_LO, (uint16_t)dh);
    w8 (BL_FLAGS,    (uint8_t)flags);
    w8 (BL_RASTER,   0x3);                                /* S (source copy) */
    __asm__ volatile("dsb");
    w8 (BL_CMD, c->op == XT_BLIT_FILL ? BL_CMD_RECT_FILL : BL_CMD_BLOCK_BLIT);

    /* The retire fence. seq_counter is the SYNC-BARRIER counter -- it does NOT tick
     * per command, so a caller polling it without this would wait forever on 0. */
    w8 (BL_CMD, BL_CMD_SYNC);
    __asm__ volatile("dsb");
    return (long)blit_seq() + 1;                          /* seq this command retires at */
}

/* ---------------------------------------------------------------------------
 * ⚠ STATUS (2026-07-12): this file is on branch wip/dev-blitter, NOT on main.
 *
 * It was reverted from main because the HW kernel built with it did not come back on the
 * NETWORK after a JTAG load, while main's kernel did. I described that as "hangs the board".
 *
 * BOTH of my evidence sources for that turned out to be unsound, and the next person should
 * not trust the conclusion:
 *
 *   - "zero UART bytes, so it dies before console output" — my serial capture reads only 2
 *     bytes even when the board is KNOWN-UP and answering ssh. The harness does not work;
 *     zero bytes meant nothing.
 *   - "it never comes back on the network" — the board was later observed dropping OFF the
 *     network while running MAIN's kernel, which boots fine and passes the whole suite. So
 *     network reachability is not a reliable boot signal either.
 *
 * So the revert was conservative, not proven. This code may well be fine. It boots and runs
 * correctly under qemu, and blittest confirms both of §13's safety properties there (a
 * pool-backed surface is refused as a blit target; an 8x-oversize rect is clipped and
 * scribbles nothing past the surface).
 *
 * DO THIS FIRST: get a trustworthy console (fix the serial capture, or add an early klog).
 * One boot with a console settles in seconds what cost hours of blind 6-minute JTAG cycles.
 * --------------------------------------------------------------------------- */
