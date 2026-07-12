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

static inline void w8(unsigned off, uint8_t v)
{ *(volatile uint8_t *)(BLT_BASE + off) = v; }
static inline void w16(unsigned off, uint16_t v)
{ w8(off, (uint8_t)v); w8(off + 1, (uint8_t)(v >> 8)); }
static inline void w32(unsigned off, uint32_t v)
{ w8(off, (uint8_t)v); w8(off+1, (uint8_t)(v>>8)); w8(off+2, (uint8_t)(v>>16)); w8(off+3, (uint8_t)(v>>24)); }
static inline uint32_t r32(unsigned off)
{ return *(volatile uint32_t *)(BLT_BASE + off); }

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
        flags |= BL_F_SRC_DDR;
        w32(BL_SRC_BASE, row0(sphys, c->sx, c->sy, sstr));
        w16(BL_SRC_STR,  (uint16_t)sstr);
        w16(BL_SRC_X_LO, 0); w16(BL_SRC_Y_LO, 0);
        w16(BL_SRC_W_LO, (uint16_t)dw); w16(BL_SRC_H_LO, (uint16_t)dh);
    } else if (c->op != XT_BLIT_FILL) {
        return -1;                                        /* unknown op: reject, never guess */
    }

    w32(BL_DST_BASE, row0(dphys, c->dx, c->dy, dstr));
    w16(BL_DST_STR,  (uint16_t)dstr);
    w16(BL_DST_X_LO, 0); w16(BL_DST_Y_LO, 0);
    w16(BL_DST_W_LO, (uint16_t)dw); w16(BL_DST_H_LO, (uint16_t)dh);
    w8 (BL_FLAGS,    (uint8_t)flags);
    w8 (BL_RASTER,   0x3);                                /* S (source copy) */
    if (c->op == XT_BLIT_FILL) w32(BL_SRC_BASE, c->color); /* fill colour rides the src reg */
    __asm__ volatile("dsb");
    w8 (BL_CMD, c->op == XT_BLIT_FILL ? BL_CMD_RECT_FILL : BL_CMD_BLOCK_BLIT);
    __asm__ volatile("dsb");
    return (long)blit_seq();
}
