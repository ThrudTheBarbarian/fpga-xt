/* xl_boot.c — launching 8-bit software on the fabric 6502 (docs/OS/app-launch.md).
 *
 * The whole trick is that the A9 never drives the 6502's PC.  SYS_xl_boot:
 *   1. HOLDS the SALLY realm in reset (CTRL SALLYRST, the M-launch register);
 *   2. builds the 64 KB address-space image from the SD ROMs (mkromhex layout:
 *      BASIC at $A000, OS low $C000-$CFFF, OS high $D800-$FFFF) and PATCHES it:
 *        - SIOV's JMP target -> the paravirtual SIO stub (tools/xl_sio_stub.s),
 *        - the RESET vector  -> the coldstart-forcing stub (xl_reset_stub.s),
 *      both placed in a free run of OS ROM padding found by scanning;
 *   3. uploads $1000-$FFFF through the sally_rom_loader GP0 window — which both
 *      installs the patched OS and SCRUBS RAM $1000-$9FFF to zero (the window
 *      cannot reach $0000-$0FFF; the OS coldstart owns that RAM anyway);
 *   4. mounts the ATR (whole file preloaded into kernel memory — sector serving
 *      must never touch the filesystem from the mailbox worker) and RELEASES
 *      reset.  The XL OS coldstarts and boots D1: through the stub.
 *
 * Sector service (xl_sio_service) runs in the MATHCOP WORKER task on the
 * MC_OP_SIO doorbell: decode the DCB from the chunk, serve from the mount
 * table.  Reads with DBUF >= $1000 are written STRAIGHT INTO BRAM through the
 * ROM window (and flagged DELIVERED so the stub skips its copy) — which is also
 * what makes a load INTO $4000-$5FFF safe while the math page overlays it.
 * Reads with DBUF < $1000 (boot sectors) go through the mailbox page and the
 * stub's copy loop.  Writes land in the RAM-resident image only (v1: media
 * changes are NOT persisted back to the SD, and a write FROM a $4000-$5FFF
 * buffer is refused — the stub would stage it through the overlay it maps).
 *
 * Mount-table concurrency: mounts change ONLY while the 6502 is held in reset,
 * so the worker can never be mid-request across a change.  No locks.
 */

#include <stdint.h>
#include <string.h>
#include "FreeRTOS.h"
#include "task.h"
#include "xtsys.h"
#include "mathcop.h"
#include "vfs.h"

extern void  klog(const char *);
extern void  klog_u(unsigned);
extern void *frtos_alloc(uint32_t size, uint32_t align, void *host);
extern void  frtos_free(void *p, void *host);

#ifdef XT_HW

/* ---- hardware handles ---------------------------------------------------- */
#define GP0_SALLYRST   (*(volatile uint32_t *)0x43C0031Cu)   /* XT_CTRL_SALLYRST */
#define GP0_CONSOL     (*(volatile uint32_t *)0x43C00324u)   /* XT_CTRL_CONSOL: CONSOL keys the 6502 reads */
/* Virtual SIO drive, GP0 block 0xA (hdl/regmap/xt_gp0_map.h; sio-bridge.md §13) */
#define SIO_OWN_REG    (*(volatile uint32_t *)0x43C00A08u)   /* XT_SIO_OWN   ownership table */
#define SIO_REQ_REG    (*(volatile uint32_t *)0x43C00A0Cu)   /* XT_SIO_REQ   {aux2,aux1,cmd,dev} */
#define SIO_DSTAT_REG  (*(volatile uint32_t *)0x43C00A10u)   /* XT_SIO_DSTAT {..,busy,req_pending} */
#define SIO_RSP_REG    (*(volatile uint32_t *)0x43C00A14u)   /* XT_SIO_RSP   {len[24:16], ok[0]} */
/* Console-keys values (active-low: bit0=START bit1=SELECT bit2=OPTION, 0=pressed).
 * Games must boot with BASIC OFF; the XL OS leaves BASIC off only when OPTION is
 * held at coldstart. Hold OPTION ($03) across a game coldstart so $A000-$BFFF stays
 * RAM (BASIC ROM shadowing that RAM derails games). Release ($07) for boot-to-BASIC. */
#define CONSOL_OPTION_HELD  0x03u
#define CONSOL_NONE         0x07u
#define ROMWIN_BASE    ((volatile uint8_t *)0x43C00000u)     /* + sally addr, >= $1000 */

static void romwin_write(uint16_t a, const uint8_t *p, uint32_t n)
{
    /* PACE every byte.  The sally_rom_loader does NOT actually back-pressure on
     * a full FIFO — a tight A9 store loop outruns its clk_sys->clk_sally CDC
     * drain (depth 4) and SILENTLY DROPS all but the last ~4 bytes of the burst.
     * That was invisible for a ~128 B sector delivery (fits the residual) but
     * corrupted the 49 KB OS upload: only the tail ($FFFC-$FFFF, the vectors)
     * survived, so the reset vector got patched to a $CBD5 stub that itself was
     * dropped -> reset fetched $00=BRK -> immediate derail (HW-proven).  Until
     * the loader asserts real WREADY back-pressure (RTL follow-up), fence each
     * byte so the FIFO empties between writes: dsb (one write in flight) + a
     * short spin comfortably slower than the ~10 ns/entry clk_sally drain.
     * ~60 KB * a few hundred ns = a few ms per launch — invisible. */
    for (uint32_t i = 0; i < n; i++) {
        ROMWIN_BASE[(uint32_t)a + i] = p[i];     /* byte lane via WSTRB */
        __asm__ volatile("dsb");                 /* B-response before the next */
        for (volatile int k = 0; k < 16; k++) { } /* let the depth-4 FIFO drain */
    }
    __asm__ volatile("dsb");
}

/* ---- the 6502 stubs (assembled from tools/xl_*_stub.s with xa; regenerate
 * with `xa -o out.bin tools/xl_sio_stub.s` and re-dump if the .s changes).
 * Position-independent; each ends in JMP $FFFF whose operand [len-2] is fixed
 * up to the ORIGINAL vector target at patch time. ------------------------- */
static const uint8_t sio_stub[] = {
    0xa9,0x40,0x8d,0xcd,0xd5,0xa2,0x00,0xbd,0x00,0x03,0x8d,0xce,0xd5,0xe8,0xe0,0x0c,
    0xd0,0xf5,0xa9,0x05,0x8d,0xcd,0xd5,0xa9,0x5a,0x8d,0xce,0xd5,0x8d,0xc7,0xd5,0xad,
    0xc7,0xd5,0x29,0x01,0xf0,0xf9,0xa9,0x04,0x8d,0xcd,0xd5,0xad,0xce,0xd5,0x30,0x34,
    0x29,0x01,0xd0,0x23,0xad,0x03,0x03,0x29,0x40,0xf0,0x1c,0xad,0x04,0x03,0x85,0x32,
    0xad,0x05,0x03,0x85,0x33,0xa9,0xc0,0x8d,0xcd,0xd5,0xa0,0x00,0xad,0xce,0xd5,0x91,
    0x32,0xc8,0xcc,0x08,0x03,0xd0,0xf5,0xa9,0x03,0x8d,0xcd,0xd5,0xad,0xce,0xd5,0x8d,
    0x03,0x03,0xa8,0x60,0x4c,0xff,0xff
};
/* Reset stub (tools/xl_reset_stub.s): disable NMI+DMA, wipe RAM $0000-$BFFF on
 * the 6502 itself (the A9 ROM window can't reach $0000-$0FFF), then JMP the
 * original RESET target.  The RAM sweep also zeroes PUPBT ($033D-F) → the OS
 * takes the coldstart path.  Makes every reset a repeatable clean power-on. */
static const uint8_t rst_stub[] = {
    0xa9,0x00,0x8d,0x0e,0xd4,0x8d,0x00,0xd4,0x85,0xf0,0xa9,0x01,0x85,0xf1,0xa0,0x00,
    0xa9,0x00,0x91,0xf0,0xc8,0xd0,0xfb,0xe6,0xf1,0xa5,0xf1,0xc9,0xc0,0xd0,0xf3,0xa2,
    0x00,0xa9,0x00,0x95,0x00,0xe8,0xd0,0xfb,0x4c,0xff,0xff
};

/* ---- GP0 6502 DEBUG facility (block base 0x43C00800; see progs/dbg6502.c) --
 * The A9 host drives the 6502 during an XEX load exactly as atari800's binload
 * does in software: it halts the core at a breakpoint, writes program bytes,
 * and injects PC/regs to run the INIT/RUN entry points.  This runs almost no
 * 6502 code during load (just the OS coldstart + the boot sector + one A9-
 * commanded STA per sub-$1000 byte), so it is immune to the fragile streaming
 * loader that derailed on HW. */
#define DBG_BASE       0x43C00800u
#define DBG_HALT       (*(volatile uint32_t *)(DBG_BASE + 0x00u))
#define DBG_GO         (*(volatile uint32_t *)(DBG_BASE + 0x04u))
#define DBG_CFG        (*(volatile uint32_t *)(DBG_BASE + 0x0Cu))   /* [0]bkpt_en [1]halt_at_reset */
#define DBG_BKPT       (*(volatile uint32_t *)(DBG_BASE + 0x10u))
#define DBG_COMMIT     (*(volatile uint32_t *)(DBG_BASE + 0x14u))
#define DBG_WPC        (*(volatile uint32_t *)(DBG_BASE + 0x18u))
#define DBG_WAXYS      (*(volatile uint32_t *)(DBG_BASE + 0x1Cu))   /* A|X<<8|Y<<16|SP<<24 */
#define DBG_WPSH       (*(volatile uint32_t *)(DBG_BASE + 0x20u))   /* P|SPhi<<8 */
#define DBG_STAT       (*(volatile uint32_t *)(DBG_BASE + 0x24u))   /* [0]halted [1]bkpt [2]step [3]run */
#define DBG_PC         (*(volatile uint32_t *)(DBG_BASE + 0x28u))
#define DBG_AXYS       (*(volatile uint32_t *)(DBG_BASE + 0x2Cu))
#define DBG_PSH        (*(volatile uint32_t *)(DBG_BASE + 0x30u))

#define CPUSEL_FID     2u          /* CTRL_SALLYRST bit1 = cpu_sel (0=turbo, 2=fidelity) */

/* The 1-byte STA scratch the A9 rewrites to place a sub-$1000 byte, plus the
 * INIT return-trap — both in high RAM that no acid800 segment ever touches
 * ($6000-$8FFF is free in all 63 tests). */
#define POKE_STA       0x6000u     /* "8D ll hh" (STA abs); operand rewritten per byte */
#define POKE_TRAP      0x6003u     /* PC after the STA (and INIT's RTS) = our halt point */

/* Release OPTION once the XL OS coldstart has sampled CONSOL.  The PRIMARY
 * release is EVENT-based: the OS decides the BASIC mapping during init, BEFORE
 * it attempts the D1: boot, so the FIRST paravirtual SIO request after a hold
 * proves the decision is made — xl_sio_service releases there (works with no
 * media too: the boot attempt still calls the SIOV stub).  A TIMED release
 * (generous 15 s) is only the backstop for a realm that never issues SIO.  A
 * fixed short timer alone was a RACE: the fidelity core's coldstart can run
 * past 5 s, and a release landing before the OPTION sample booted the game
 * WITH BASIC mapped — the blue/green derail (HW, 2026-08-08).  The generation
 * counter guards back-to-back boots: only the NEWEST hold's release fires.
 * (The old ATR path held OPTION FOREVER — games polling OPTION at their menus
 * saw it stuck.) */
#define CONSOL_HOLD_MS  15000u
static volatile uint32_t g_consol_gen;
static volatile uint8_t  g_consol_held;      /* a hold is live; first SIO releases it */

static void consol_release_now(void)
{
    ++g_consol_gen;                          /* cancel any pending timed release */
    g_consol_held = 0;
    GP0_CONSOL = CONSOL_NONE; __asm__ volatile("dsb");
}

static void consol_release_task(void *arg)
{
    uint32_t gen = (uint32_t)arg;
    vTaskDelay(CONSOL_HOLD_MS);
    if (gen == g_consol_gen) {
        g_consol_held = 0;
        GP0_CONSOL = CONSOL_NONE; __asm__ volatile("dsb");
    }
    vTaskDelete(NULL);
}

static void consol_hold_option(void)
{
    GP0_CONSOL = CONSOL_OPTION_HELD; __asm__ volatile("dsb");
    g_consol_held = 1;
    uint32_t gen = ++g_consol_gen;
    if (xTaskCreate(consol_release_task, "consol", 256, (void *)gen,
                    tskIDLE_PRIORITY + 1, NULL) != pdPASS) {
        /* no task memory: OPTION stays held until the SIO event (old behaviour) */
    }
}

/* Poll DBG_STAT.halted, bounded so a wrong core / no-halt never wedges the task.
 * Returns 1 = halted, 0 = timed out. */
static int dbg_wait_halt(void)
{
    for (uint32_t i = 0; i < 8000000u; i++)
        if (DBG_STAT & 1u) return 1;
    return 0;
}

/* 6502 register shadow (valid while halted): A9 keeps X/Y/SP/P stable across the
 * STA pokes (STA touches neither), refreshing after any injected routine runs. */
typedef struct { uint16_t pc; uint8_t a, x, y, sp, p; } cpu6502;

static void dbg_read_regs(cpu6502 *r)
{
    uint32_t axys = DBG_AXYS, psh = DBG_PSH;
    r->pc = (uint16_t)(DBG_PC & 0xFFFF);
    r->a  = (uint8_t)(axys & 0xFF);
    r->x  = (uint8_t)((axys >> 8) & 0xFF);
    r->y  = (uint8_t)((axys >> 16) & 0xFF);
    r->sp = (uint8_t)((axys >> 24) & 0xFF);
    r->p  = (uint8_t)(psh & 0xFF);
}

/* Inject PC + regs and run from there until the next halt (breakpoint). r->a is
 * updated to reflect the run's end where relevant; caller refreshes if needed. */
static int dbg_run_from(const cpu6502 *r)
{
    DBG_WPC   = r->pc;
    DBG_WAXYS = (uint32_t)r->a | ((uint32_t)r->x << 8) |
                ((uint32_t)r->y << 16) | ((uint32_t)r->sp << 24);
    DBG_WPSH  = (uint32_t)r->p;              /* SP is 8-bit here; hi-nibble stays 0 */
    __asm__ volatile("dsb");
    DBG_COMMIT = 1; __asm__ volatile("dsb");
    if (!dbg_wait_halt()) return -1;         /* commit fetch+decode halts */
    DBG_GO = 1; __asm__ volatile("dsb");
    return dbg_wait_halt() ? 0 : -1;         /* run to the trap breakpoint */
}

/* Store one byte at a 6502 address the A9 cannot reach directly (< $1000): point
 * the scratch STA at `addr`, load A=val, run the single instruction. Keeps X/Y/
 * SP/P from the shadow (STA disturbs none). */
static int dbg_poke(cpu6502 *r, uint16_t addr, uint8_t val)
{
    uint8_t lo = (uint8_t)addr, hi = (uint8_t)(addr >> 8);
    romwin_write((uint16_t)(POKE_STA + 1), &lo, 1);
    romwin_write((uint16_t)(POKE_STA + 2), &hi, 1);
    cpu6502 s = *r; s.pc = POKE_STA; s.a = val;
    int rc = dbg_run_from(&s);               /* executes STA, halts at POKE_TRAP */
    r->a = val;                              /* only A changed */
    return rc;
}

/* ---- mount table ---------------------------------------------------------- */
/* One ATX sector RECORD.  A logical sector can have SEVERAL of these -- that is
 * the whole point of the format (see the atx_* block below). */
typedef struct {
    uint32_t off;           /* file offset of the payload (0 = no data field) */
    uint16_t pos;           /* angular position, ATX units (26042 per revolution) */
    uint16_t wkoff;         /* first weak byte within the sector, 0xFFFF = none */
    uint8_t  trk, num;      /* track 0.., sector id 1..18 */
    uint8_t  status;        /* raw ATX status byte */
    uint8_t  pad;
} atx_sec;

typedef enum { IMG_ATR = 0, IMG_ATX } xl_imgkind;

typedef struct {
    uint8_t  *img;          /* whole image file, kernel memory (NULL = empty) */
    uint32_t  len;
    uint16_t  secsz;        /* 128 / 256 */
    xl_imgkind kind;
    atx_sec  *atx;          /* ATX: sector map (NULL for ATR) */
    uint32_t  natx;
    uint8_t   fdc;          /* last FDC status byte, $FF = clean (STATUS cmd) */
    uint32_t  rot_us;       /* ATX: wait until the last sector read came round */
} xl_drive;
static xl_drive g_drv[8];

/* ATR sector geometry: 16-byte header, then sectors 1..3 are ALWAYS 128 bytes
 * (the classic quirk), the rest secsz.  Returns payload length, 0 = bad. */
static uint32_t atr_sector(const xl_drive *d, uint32_t sec, uint32_t *off)
{
    if (sec < 1) return 0;
    uint32_t o, l;
    if (d->secsz <= 128 || sec <= 3) { o = 16 + (sec - 1) * 128; l = 128; }
    else { o = 16 + 3 * 128 + (sec - 4) * 256; l = 256; }
    if (o + l > d->len) return 0;
    *off = o;
    return l;
}

/* ============================ ATX (AT8X) ==================================
 * An ATR is a flat bag of sectors; an ATX is a description of a DISC.  It
 * records, per track, which sectors are actually THERE, where each one sits
 * ANGULARLY, whether its data field is intact, and whether some of its bytes
 * read back differently every time.  All four of those are copy protection,
 * and a loader that only understands "sector N -> 128 bytes" defeats none of
 * them -- it returns success where the real disc returns failure, and the
 * game's protection check concludes it has been copied.
 *
 * WHAT WE CAN AND CANNOT HONOUR.  The paravirtual SIO hands the 6502 a status
 * byte and a payload per request, which is exactly the channel the FDC-level
 * protections use, so:
 *   - a MISSING sector (no record on the track)      -> SIO timeout
 *   - a bad/missing data field                       -> device error + CRC in FDC status
 *   - a DELETED-data address mark                    -> data, flagged in FDC status
 *   - WEAK BITS (extended record)                    -> those bytes randomised per read
 *   - DUPLICATE sectors at different angular positions -> whichever one the head
 *     reaches next, from a real rotation model (below)
 * What we cannot reproduce is a protection that TIMES the transfer itself: our
 * reply completes when the A9 gets to it, not after a rotational latency.  Any
 * check that measures how long a read took will still be fooled.  Fixing that
 * means delaying the doorbell, which is a follow-up.
 *
 * ROTATION.  A 1050 spins at 288 RPM = 208333 us/rev, and ATX positions are in
 * units of 8 us, so a revolution is 26042 units.  We take the head's angular
 * position from the A9 global timer (free-running at PERIPHCLK = 333 MHz) and,
 * where a logical sector has several copies, return the one the head would
 * reach FIRST.  Two reads a few milliseconds apart therefore land on different
 * copies -- which is what the protection is looking for.
 * ==========================================================================*/
#define ATX_UNITS_PER_REV  26042u        /* 208333 us / 8 us */
#define ATX_US_PER_REV     208333u
#define ATX_SPT            18u           /* logical sectors per track, SD */

/* A real drive does NOT fail fast on a bad sector: its firmware re-reads it
 * before giving up, and each attempt costs a whole revolution.  We were
 * reporting the error after the rotational latency alone -- about 10x too
 * early.  That lands on exactly the reads a protection cares about, because a
 * deliberately-bad sector is the one thing it asks for. */
#define ATX_ERR_RETRIES    4u            /* re-reads before the drive reports it */

/* ATX sector-status bits.  These are ACTIVE HIGH, and the FDC status byte the
 * guest reads back is simply their INVERSE -- the reference implementation does
 * exactly `mFDCStatus = ~atxStatus | 0xC0` (Altirra, ATDiskImage::LoadATX), and
 * the bit positions below are its, not a guess:
 *
 *     0x04 long   0x08 CRC error   0x10 record-not-found   0x20 deleted
 *
 * An earlier reading of this had 0x04 as "deleted" and 0x08 as "missing", which
 * is two bits wrong in each case.  It survived because BallBlazer.atx's only
 * flagged sectors carry 0x08, and inverting 0x08 lands on the CRC bit whichever
 * name you give it -- the right FDC status reached the guest for the wrong
 * reason.  A disc using 0x04, 0x10 or 0x20 would have been served nonsense. */
#define ATXS_LONG      0x04u             /* sector longer than the default size */
#define ATXS_CRC       0x08u             /* data field present but CRC is bad */
#define ATXS_MISSING   0x10u             /* record not found: NO data field */
#define ATXS_DELETED   0x20u             /* deleted-data address mark */
#define ATXS_EXTENDED  0x40u             /* extended record follows (weak bits) */
#define ATXS_KNOWN     (ATXS_LONG | ATXS_CRC | ATXS_MISSING | ATXS_DELETED | \
                        ATXS_EXTENDED)

static uint32_t a9_us(void)
{
    return (*(volatile uint32_t *)0xF8F00200u) / 333u;   /* PERIPHCLK = 333 MHz */
}

static uint32_t rd32(const uint8_t *p) { return (uint32_t)p[0]|((uint32_t)p[1]<<8)|((uint32_t)p[2]<<16)|((uint32_t)p[3]<<24); }
static uint16_t rd16(const uint8_t *p) { return (uint16_t)(p[0]|(p[1]<<8)); }

/* Walk the track records and build the sector map.  Returns 0 on success. */
static int atx_parse(xl_drive *d)
{
    const uint8_t *b = d->img;
    if (d->len < 48 || b[0]!='A'||b[1]!='T'||b[2]!='8'||b[3]!='X') return -1;
    uint32_t off = rd32(b + 0x1C);                 /* first track record */
    if (!off || off >= d->len) return -1;

    /* Pass 1: count records so the map is one allocation. */
    uint32_t n = 0, p = off;
    while (p + 32 <= d->len) {
        uint32_t tsize = rd32(b + p);
        uint16_t ttype = rd16(b + p + 4);
        if (tsize < 32 || p + tsize > d->len || ttype != 0) break;
        n += rd16(b + p + 10);
        p += tsize;
    }
    if (!n) return -1;
    d->atx = frtos_alloc(n * sizeof(atx_sec), 8, NULL);
    if (!d->atx) return -12;

    /* Pass 2: fill it. */
    uint32_t k = 0; p = off;
    while (p + 32 <= d->len && k < n) {
        uint32_t tsize   = rd32(b + p);
        uint16_t ttype   = rd16(b + p + 4);
        if (tsize < 32 || p + tsize > d->len || ttype != 0) break;
        uint8_t  trk     = b[p + 8];
        uint16_t scount  = rd16(b + p + 10);
        uint32_t hdrsize = rd32(b + p + 20);
        uint32_t slist   = p + (hdrsize ? hdrsize : 32);
        uint32_t rec     = slist + 8;              /* 8-byte sector-list header */
        for (uint16_t i = 0; i < scount && k < n; i++, rec += 8) {
            if (rec + 8 > d->len) break;
            atx_sec *e = &d->atx[k++];
            e->trk    = trk;
            e->num    = b[rec];
            e->status = b[rec + 1];
            e->pos    = rd16(b + rec + 2);
            /* startData is relative to the TRACK RECORD, not the file.  Read it
             * as file-relative and sector 1 lands inside the sector list itself
             * and decodes as an all-zero boot sector (verified against
             * BallBlazer.atx: track-relative gives flags=00 nsec=2 load=$3C00
             * init=$E477, whose first instruction is LDA $D301 / ORA #$02 —
             * a protected loader turning BASIC off). */
            uint32_t sd = rd32(b + rec + 4);
            e->off    = sd ? p + sd : 0;
            e->wkoff  = 0xFFFF;
            e->pad    = 0;
            if (e->off >= d->len) e->off = 0;      /* defensive: no data field */
        }
        /* What follows the sector list is a CHUNK CHAIN, and a chunk header is
         * { u32 size, u8 type, u8 num, u16 data } -- so the type is at +4, not
         * at +1.  Reading it at +1 (an earlier guess at the layout) picked up
         * the top byte of the size field, so a weak-bit chunk was never
         * recognised and wkoff stayed unset: every weak sector read back as
         * ordinary stable data, which is a silent failure of exactly the
         * protection the format exists to carry.  Types: 0x00 sector data,
         * 0x01 sector list, 0x10 weak bits, 0x11 extended sector header. */
        uint32_t ext = rec;
        while (ext + 8 <= p + tsize && ext + 8 <= d->len) {
            uint32_t csize = rd32(b + ext);
            uint8_t  etype = b[ext + 4];
            uint8_t  esec  = b[ext + 5];
            uint16_t edata = rd16(b + ext + 6);
            if (csize == 0) break;                 /* zero size terminates */
            if (etype == 0x10)
                for (uint32_t j = 0; j < k; j++)
                    if (d->atx[j].trk == trk && d->atx[j].num == esec)
                        d->atx[j].wkoff = edata;
            ext += (csize >= 8) ? csize : 8;
        }
        p += tsize;
    }
    d->natx = k;
    return 0;
}

/* Read logical sector `sec` (1-based).  Fills out/olen and the FDC status byte.
 * Returns the SIO status to hand back. */
static uint8_t atx_read(xl_drive *d, uint32_t sec, uint8_t *out, uint32_t *olen)
{
    *olen = 0; d->fdc = 0xFF;
    if (sec < 1) return 0x90;
    uint32_t trk = (sec - 1) / ATX_SPT, num = (sec - 1) % ATX_SPT + 1;

    /* Collect the copies of this logical sector. */
    const atx_sec *cand[8]; uint32_t nc = 0;
    for (uint32_t i = 0; i < d->natx && nc < 8; i++)
        if (d->atx[i].trk == trk && d->atx[i].num == num) cand[nc++] = &d->atx[i];

    if (!nc) {                                     /* the sector is NOT on the disc */
        d->fdc &= (uint8_t)~0x10u;                 /* record not found */
        return 0x8A;                               /* SIO timeout, like a real drive */
    }

    /* Where the head is NOW, in ATX units.  This does two jobs: it picks between
     * duplicate copies of a sector, and it gives the ROTATIONAL LATENCY -- how
     * long until the chosen sector actually comes round under the head.  A real
     * drive pays that on EVERY read, not just where there is a choice, so it is
     * computed unconditionally rather than only when nc > 1. */
    uint32_t head = (a9_us() % ATX_US_PER_REV) / 8u;
    const atx_sec *e = cand[0];
    uint32_t best = (cand[0]->pos + ATX_UNITS_PER_REV - head) % ATX_UNITS_PER_REV;
    for (uint32_t i = 1; i < nc; i++) {
        uint32_t d2 = (cand[i]->pos + ATX_UNITS_PER_REV - head) % ATX_UNITS_PER_REV;
        if (d2 < best) { best = d2; e = cand[i]; }
    }
    d->rot_us = best * 8u;                         /* ATX positions are 8 us apart */

    /* The FDC status the guest reads IS the inverse of the ATX status byte, so
     * derive it rather than clearing bits one at a time and hoping the set is
     * complete.  Bits 6/7 are forced high: the reference does the same and notes
     * bit 7's purpose is unknown. */
    d->fdc = (uint8_t)(~e->status | 0xC0u);

    uint32_t len = d->secsz ? d->secsz : 128;
    if (sec <= 3) len = 128;                       /* the classic boot-sector quirk */

    /* Record-not-found: the header is on the track but there is no data field,
     * so there is nothing to hand back.  Distinct from "no record at all"
     * above, which is a bus timeout because the drive never answers. */
    if (e->status & ATXS_MISSING) {
        d->rot_us += ATX_ERR_RETRIES * ATX_US_PER_REV;
        return 0x90;
    }

    if (!e->off || e->off + len > d->len) {        /* truncated/absent data field */
        d->fdc &= (uint8_t)~0x08u;                 /* CRC error */
        return 0x90;
    }
    memcpy(out, d->img + e->off, len);
    *olen = len;

    /* Weak bits are located by the weak-bits CHUNK, so the chunk is what gates
     * them -- not the 0x40 status bit, which an image need not also set. */
    {                                              /* weak bits: fresh garbage per read */
        uint32_t w = e->wkoff;
        if (w != 0xFFFFu && w < len) {
            uint32_t r = a9_us() * 1103515245u + 12345u;
            for (uint32_t i = w; i < len; i++) { r = r * 1103515245u + 12345u; out[i] = (uint8_t)(r >> 16); }
        }
    }
    /* A deleted-data mark still returns the data; only the FDC status says so,
     * and that is already carried by the inversion above. */
    if (e->status & ATXS_CRC) {                    /* data returned, but bad */
        d->rot_us += ATX_ERR_RETRIES * ATX_US_PER_REV;
        return 0x90;
    }
    if (e->status & ~ATXS_KNOWN) {                 /* unknown flag -> fail safe */
        d->fdc &= (uint8_t)~0x08u;
        return 0x90;
    }
    return 0x01;
}

static void xl_unmount_all(void)
{
    /* Release the WHOLE ownership table, not one drive: a session must not be
     * able to leave an ID claimed, and the next one should re-decide from clean
     * (docs/OS/sio-bridge.md §13.8). */
    SIO_OWN_REG = 0; __asm__ volatile("dsb");
    for (int i = 0; i < 8; i++) {
        if (g_drv[i].img) frtos_free(g_drv[i].img, NULL);
        if (g_drv[i].atx) frtos_free(g_drv[i].atx, NULL);
        g_drv[i].img = NULL; g_drv[i].len = 0; g_drv[i].secsz = 0;
        g_drv[i].atx = NULL; g_drv[i].natx = 0;
        g_drv[i].kind = IMG_ATR; g_drv[i].fdc = 0xFF;
    }
}

/* ---- SIO service (runs in the mathcop worker task) ------------------------ */
/* The disk operation itself, shared by BOTH front ends: the SIOV mailbox
 * (xl_sio_service) and the virtual drive on the serial bus (xl_sio_bus_poll).
 * ONE implementation of "be a disk" -- which is the whole argument for serving
 * the bus at all rather than keeping two code paths that can disagree
 * (docs/OS/sio-bridge.md 13.7).  Returns the SIO status byte and fills
 * out/outlen with any payload.  `data` is only used by the write NAK path. */
static uint8_t xl_disk_op(xl_drive *d, uint8_t cmd, uint16_t daux,
                          uint8_t *out, uint32_t *outlenp)
{
    uint8_t  st = 0x01;
    uint32_t outlen = 0;
    volatile uint8_t *data = 0;              /* writes are NAKed; nothing staged */
        switch (cmd) {
    case 0x53: {                                    /* STATUS: 4 bytes */
        out[0] = (uint8_t)(d->secsz == 256 ? 0x20 : 0x00);   /* bit5 = DD */
        /* byte 1 is the FDC status, active-LOW ($FF = clean).  For an ATX the
         * last read leaves its verdict here, which is where a protection check
         * looks to confirm the sector really was bad. */
        out[1] = (d->kind == IMG_ATX) ? d->fdc : 0xFF;
        out[2] = 0xE0; out[3] = 0x00;
        outlen = 4;
        break;
    }
    case 0x52: {                                    /* READ sector DAUX */
        if (d->kind == IMG_ATX) {
            st = atx_read(d, daux, out, &outlen);
            break;
        }
        uint32_t off, l = atr_sector(d, daux, &off);
        if (!l) { st = 0x90; break; }               /* off the medium */
        memcpy(out, d->img + off, l);
        outlen = l;
        break;
    }
    case 0x50: case 0x57:                           /* PUT / WRITE sector */
        /* v1 is READ-ONLY-boot: the compact stub no longer stages write data
         * (it dropped the write loop to fit the ROM padding run), so a write
         * would land garbage. NAK it cleanly; media write-back is a follow-up. */
        (void)data;
        st = 0x8B;
        break;
    default:
        st = 0x8B;                                  /* device NAK */
        break;
    }
    *outlenp = outlen;
    return st;
}

/* ---- the virtual drive on the SERIAL BUS (docs/OS/sio-bridge.md §13) ------
 * The other front end.  xl_sio_service above is reached by patching SIOV, so it
 * only ever sees titles that load through the OS; a FAST LOADER programs POKEY
 * and drives the bus itself and never calls SIOV at all.  This is what answers
 * those: the fabric (hdl/xt_sio_drive.sv) decodes and CHECKSUMS the command
 * frame, we do the disk work, and it paces the reply back at whatever rate the
 * guest programmed.
 *
 * Polling, not an interrupt, and that is fine on purpose: the drive holds the
 * guest waiting until we answer, so OUR service latency simply BECOMES the
 * rotational latency -- which the guest should be seeing anyway (§13.5). */
static void sio_mbox_write(uint32_t off, const uint8_t *src, uint32_t n);  /* fwd */

/* Extra service latency in microseconds before the drive is released to reply.
 * Tunable at runtime through the mailbox debug path; 0 restores the old
 * answer-immediately behaviour. */
uint32_t g_sio_delay_us = 0;

/* ROTATIONAL PACING on the serial bus.  Non-zero = hold the reply until the
 * sector would actually have reached the head.
 *
 * This is the path BallBlazer uses and the SIOV model never touched: a fast
 * loader drives the bus itself, so g_siov_baud/g_siov_latency_us -- calibrated
 * against the reference and confirmed accurate -- were calibrating a code path
 * this title never enters.  The fabric already paces the BYTES at the rate the
 * guest programmed; what was still missing is the wait BEFORE the first byte,
 * which on a 1050 averages half a revolution (~104 ms) and here comes from the
 * sector's own recorded angular position.
 *
 * ON by default, unlike the SIOV model, because it is scoped by FORMAT rather
 * than by title: it applies only to ATX, and only ATX records the angular
 * position it needs.  An ATX exists because the disc was protected -- that is
 * what the format is for -- so those are exactly the titles whose loaders time
 * the drive.  Everything shipped as an ATR (ElektraGlide, Despatch Rider) is
 * untouched and stays as fast as it is today, so this costs nothing where
 * authentic load times were the wrong trade.  `xlboot -a` still forces it on
 * alongside the SIOV model; this default is what makes it reach titles launched
 * from the desktop, which never run xlboot at all. */
uint32_t g_sio_rot = 1;

/* Paravirtual SIOV service model (see the note in xl_sio_service).
 *
 * DEFAULT IS FAST (baud 0 = model off), because authentic timing means
 * AUTHENTIC LOAD TIMES: a real 1050 at 19200 takes ~130 ms per sector, which is
 * ~110 s for ElektraGlide and ~60 s for Despatch Rider where an instant answer
 * took seconds.  That is the correct emulation and the wrong default for daily
 * use, so it is opt-in PER TITLE -- the handful of titles whose intros are
 * timed against the drive (BallBlazer) switch it on and pay for it, and
 * everything else stays snappy.
 *
 * Set g_siov_baud to the link rate (19200 standard, higher for a US-Doubler,
 * docs/OS/sio-bridge.md §13.6) to enable it. */
uint32_t g_siov_baud       = 0u;
/* 27 ms, not the ~60 ms a bare rotational average suggests: the delay itself
 * costs scheduling time, so the figure is CALIBRATED against the reference
 * rather than derived in isolation.  At 19200 with a 128-byte sector this puts
 * a SIOV call at 62,087 6502 instructions against Altirra's ~62,000 -- 100% of
 * reference.  Re-measure with tools/trace_diff.py if the tick rate or the
 * service path changes. */
uint32_t g_siov_latency_us = 27000u;

static void xl_sio_bus_poll(void)
{
    if (!(SIO_DSTAT_REG & 1u)) return;              /* nothing waiting */

    uint32_t rq   = SIO_REQ_REG;
    uint8_t  dev  = (uint8_t)(rq & 0xFFu);
    uint8_t  cmd  = (uint8_t)((rq >> 8) & 0xFFu);
    uint16_t daux = (uint16_t)((rq >> 16) & 0xFFFFu);   /* aux1 | aux2<<8 */

    uint8_t  out[256];
    uint32_t outlen = 0;
    /* An ABSENT device times out (0x8A); it does not NAK.  The difference is the
     * whole behaviour of a machine with no disk attached: 0x8B says "a drive is
     * there and refused", so the OS retries — which is the buzz you hear — and
     * its D1: boot never concludes, leaving a green screen with no READY.  0x8A
     * says "nobody answered", which is what a real SIO bus does with nothing on
     * it, and the OS gives up on disk boot and goes to BASIC.  (Write NAKs below
     * are a different thing: those are a MOUNTED drive refusing one command.) */
    uint8_t  st = 0x8A;                             /* device does not respond */

    int drive = (dev >= 0x31 && dev <= 0x38) ? (int)(dev - 0x31) : -1;
    if (drive >= 0 && g_drv[drive].img)
        st = xl_disk_op(&g_drv[drive], cmd, daux, out, &outlen);

    /* SERVICE LATENCY (experiment, 2026-08-14).  A real drive does not answer the
     * instant the command frame lands: it waits for the sector to come under the
     * head.  We answer as fast as the A9 can, and BallBlazer's INTRO ANIMATES
     * WHILE ITS SECTORS STREAM -- so if we deliver in too tight a burst the
     * guest's SIO ISR starves the VBI animation and objects stop, jump, or vanish
     * (docs/OS/sio-bridge.md 13.5: the rotation model currently decides only
     * WHICH duplicate sector, never WHEN the frame starts).  g_sio_delay_us is a
     * knob so the hypothesis can be MEASURED rather than argued: 0 = today's
     * behaviour. */
    uint32_t wait_us = g_sio_delay_us;
    if (g_sio_rot && drive >= 0 && g_drv[drive].kind == IMG_ATX)
        wait_us += g_drv[drive].rot_us;
    if (wait_us) {
        /* Up to a full revolution (208 ms), so sleep the whole milliseconds
         * rather than burning them: this task holds the guest either way, and
         * spinning that long would starve everything at or below its priority.
         * The sub-millisecond remainder is finer than a tick, so it spins. */
        uint32_t ms = wait_us / 1000u;
        if (ms) vTaskDelay(pdMS_TO_TICKS(ms));
        uint32_t t0 = a9_us(), rem = wait_us % 1000u;
        while ((uint32_t)(a9_us() - t0) < rem) { /* spin: shorter than a tick */ }
    }

    if (outlen) sio_mbox_write(MC_OFF_SIO_DATA, out, outlen);

    /* TRANSACTION LOG (first 64).  The one instrument that ends the guessing:
     * what the guest ASKED for and what we ANSWERED, in order.  Everything about
     * this bug lives in that pairing -- a wrong sector number, a status a real
     * drive would not give, a length the loader did not expect. */
    /* 512, not 64: the intro runs well past the first 64 requests, and the two
     * other flagged sectors (431, 602) are never reached inside that window --
     * the log ran out before the interesting part rather than after it. */
    { static int nlog;
      if (nlog < 512) { nlog++;
        char lb[96];
        /* Built by hand: the kernel's printf has no %X, and the first cut of this
         * log came back as "cmd=02X" -- a broken instrument reads exactly like a
         * broken system, which is the one thing an instrument must never do. */
        /* A macro that expands to "a, b" and is USED as `lb[n++] = HX2(v)` loses
         * the second nibble: assignment binds tighter than the comma operator, so
         * it reads (lb[n++] = high), low -- and the low nibble is evaluated and
         * thrown away.  Every field printed at half width and still looked like a
         * plausible number.  A function, not a macro. */
        static const char hx[] = "0123456789ABCDEF";
        int n = 0;
        #define PUT2(v) do { lb[n++] = hx[((v)>>4)&15]; lb[n++] = hx[(v)&15]; } while (0)
        const char *t = "[sio] dev=";
        while (*t) lb[n++] = *t++;
        PUT2(dev);
        t = " cmd="; while (*t) lb[n++] = *t++;
        PUT2(cmd);
        t = " aux="; while (*t) lb[n++] = *t++;
        PUT2(daux >> 8); PUT2(daux & 0xFF);
        t = " st="; while (*t) lb[n++] = *t++;
        PUT2(st);
        t = " len="; while (*t) lb[n++] = *t++;
        PUT2(outlen >> 8); PUT2(outlen & 0xFF);
        t = " fdc="; while (*t) lb[n++] = *t++;
        { uint8_t f = drive >= 0 ? g_drv[drive].fdc : 0xFF; PUT2(f); }
        /* First two payload bytes.  A bad-CRC sector is bad because its data is
         * UNSTABLE, so a protection can read it twice and require a DIFFERENCE;
         * we hand back the same stored bytes every time.  Logging them is what
         * makes that visible instead of assumed. */
        if (outlen) { t = " d="; while (*t) lb[n++] = *t++;
                      PUT2(out[0]); PUT2(out[1]); }
        lb[n++] = '\r'; lb[n++] = '\n'; lb[n] = 0;
        #undef PUT2
        klog(lb); } }

    /* Writing SIO_RSP releases the drive to pace the reply and clears
     * req_pending.  ok=1 -> COMPLETE, ok=0 -> ERROR; a NAKed or absent device
     * answers with ERROR and no payload, which is what a real drive does. */
    SIO_RSP_REG = ((outlen & 0x1FFu) << 16) | ((st == 0x01u) ? 1u : 0u);
    __asm__ volatile("dsb");
}

static void xl_sio_bus_task(void *arg)
{
    (void)arg;
    for (;;) { xl_sio_bus_poll(); vTaskDelay(1); }
}

/* Claim device IDs for the virtual drive.  Bit i = $31+i.  Called at mount;
 * cleared on eject so a session cannot leave an ID claimed (§13.8), and so a
 * real peripheral that appeared meanwhile is seen on the next probe. */
static void xl_sio_bus_claim(uint8_t mask)
{
    SIO_OWN_REG = mask; __asm__ volatile("dsb");
}

void xl_sio_service(volatile uint8_t *page)
{
    /* First SIO request after a hold = the XL OS is past its coldstart OPTION
     * sample (the BASIC decision precedes the D1: boot attempt) — release it.
     * Runs in the mathcop worker task; the flag/gen writes are benign races. */
    if (g_consol_held) consol_release_now();

    volatile uint8_t *dcb  = page + MC_OFF_SIO_DCB;
    volatile uint8_t *data = page + MC_OFF_SIO_DATA;
    uint8_t  ddevic = dcb[0], dunit = dcb[1], cmd = dcb[2], dstats = dcb[3];
    uint16_t dbuf = (uint16_t)(dcb[4] | (dcb[5] << 8));
    uint16_t dbyt = (uint16_t)(dcb[8] | (dcb[9] << 8));
    uint16_t daux = (uint16_t)(dcb[10] | (dcb[11] << 8));
    uint8_t  st = 0x01, flags = 0;

    /* SIO bus id = DDEVIC + DUNIT-1: disks are DDEVIC $31 with DUNIT the drive
     * number (D1: = $31/unit1, D2: = $31/unit2 ...). Some callers instead bump
     * DDEVIC; handle both by summing the offsets. */
    int drive = -1;
    if (ddevic >= 0x31 && ddevic <= 0x38)
        drive = (int)(ddevic - 0x31) + (dunit ? (int)dunit - 1 : 0);
    if (drive < 0 || drive > 7 || !g_drv[drive].img) {
        page[MC_OFF_SIO_FLAGS] = MC_SIO_NOTMINE;    /* the real bus's business */
        page[MC_OFF_STATUS]    = 0x01;
        return;
    }
    xl_drive *d = &g_drv[drive];

    uint8_t  out[256];
    uint32_t outlen = 0;

    st = xl_disk_op(d, cmd, daux, out, &outlen);

    if (outlen) {
        uint32_t l = (dbyt && dbyt < outlen) ? dbyt : outlen;
        /* ALWAYS hand the payload back through the mailbox — never romwin_write()
         * here.  The ROM window is only safe while the 6502 is HELD IN RESET.
         * sally_mem shares one BRAM port between the CPU read and the ROM-load
         * write, addressed by `mem_addr_w = rom_we ? rom_addr : addr`, and the
         * CPU's read latch is `bram_dout_q <= mem[mem_addr_w]`.  So a rom_we
         * landing in the same clk as a CPU read hands the CPU the byte at the
         * ROM-WINDOW address instead of its own — a corrupted opcode fetch.
         *
         * This used to fire for every sector with DBUF >= $1000, i.e. while the
         * game was running and spinning in the stub's wait loop.  Despatch Rider
         * delivers 3 such sectors and survives; ElektraGlide streams $1000-$B9FF
         * (~340 sectors, ~43k paced byte-writes) and a collision is near-certain
         * — it derailed ~985k instructions in, landing on a KIL somewhere
         * different every run.  That is the whole DR-works/EG-dies split.
         *
         * The old comment claimed the window was "the only safe route when DBUF
         * is under the mapped overlay".  There is no overlay any more (the
         * mailbox is a register port, hdl/xt_sio_mbox.sv), so the copy path is
         * uniformly correct: <=256 B at MC_OFF_SIO_DATA, and the mailbox index
         * is 9 bits so the stub walks it across $FF->$100 unaided. */
        memcpy((uint8_t *)data, out, l);
    }
    /* SERVICE TIME.  A real drive does not answer instantly, and this is not a
     * cosmetic detail: BallBlazer's intro ANIMATES FROM THE VBI WHILE ITS
     * SECTORS STREAM, so the duration of a SIOV call is how much animation the
     * game gets per load step.  Measured against Altirra (tools/trace_diff.py,
     * anchored at $3C06): a real OS SIO call is ~62,000 6502 instructions
     * (~130 ms) per 128-byte sector, ours was 775 (~1.6 ms) -- about 80x too
     * fast.  On hardware one sector then spans a tenth of a VBI tick instead of
     * ~8, so objects barely move between reads: the vehicle never sweeps across,
     * the ball stops, the man never gets out.  Gameplay streams nothing, which
     * is exactly why gameplay was unaffected.
     *
     * The delay is DERIVED, not a magic number: the SIO frames at the link rate,
     * plus the rotational latency the head genuinely costs.  Both are runtime
     * knobs so the model can be swept and so a faster link (US-Doubler,
     * docs/OS/sio-bridge.md 13.6) shortens the transfer term by itself.
     * vTaskDelay, not a spin: the guest is blocked on the mailbox either way and
     * other kernel tasks should keep running. */
    if (g_siov_baud) {
        uint32_t frame_bytes = 5u          /* command frame */
                             + 2u          /* ACK + COMPLETE */
                             + outlen      /* payload */
                             + (outlen ? 1u : 0u);   /* data checksum */
        uint32_t us = (frame_bytes * 10u * 1000000u) / g_siov_baud
                    + g_siov_latency_us;
        uint32_t ms = us / 1000u;
        if (ms) vTaskDelay(pdMS_TO_TICKS(ms));
    }

    page[MC_OFF_SIO_FLAGS] = flags;
    page[MC_OFF_STATUS]    = st;

#ifdef XL_SIO_TRACE
    /* TEMP: trace the first requests of a boot to diagnose the data path. */
    { static int n; if (n < 40) { n++;
        char b[96]; int k = 0;
        const char *hx = "0123456789ABCDEF";
        #define P(s) do{ for(const char*_p=(s);*_p&&k<90;_p++) b[k++]=*_p; }while(0)
        #define PH(v,d) do{ for(int _i=(d)-1;_i>=0;_i--) if(k<90) b[k++]=hx[((v)>>(_i*4))&0xF]; }while(0)
        P("[xl] sio cmd="); PH(cmd,2);
        P(" d"); PH((unsigned)drive+1,1);
        P(" sec="); PH(daux,4);
        P(" buf="); PH(dbuf,4);
        P(" n="); PH((unsigned)outlen,4);
        P(" st="); PH(st,2);
        P(flags & MC_SIO_DELIVERED ? " DLV\r\n" : "\r\n");
        b[k] = 0; klog(b);
        #undef P
        #undef PH
    } }
#endif
}

/* ---- the mailbox window (xt_sio_mbox, GP0 0xAxx) --------------------------
 * math_cop used to hold this page in DDR, so the worker could hand
 * xl_sio_service() a plain pointer.  With the maths engine dropped the page is
 * fabric BRAM reached through a seek/auto-increment window, so the service runs
 * against a BOUNCE BUFFER instead: pull in the bytes it reads, run it
 * UNCHANGED, push back the bytes it writes.  That keeps the disk semantics in
 * one place and the transport in another.
 *
 * ~70 word accesses per sector.  The 6502 is spinning on $D5C7 throughout, but
 * that is a poll loop, not a bus timeout — the stub waits as long as we take.
 *
 * ALWAYS signal completion, even on a request we do not understand: the one
 * unrecoverable outcome is leaving $D5C7.0 low, which is a 6502 wedged for ever
 * (it is exactly how the maths-drop regression presented). */
#define SIO_PTR        (*(volatile uint32_t *)0x43C00A00u)   /* XT_SIO_PTR */
#define SIO_DAT        (*(volatile uint32_t *)0x43C00A04u)   /* XT_SIO_DAT */
#define SIO_DONE_REG   (*(volatile uint32_t *)0x43C00604u)   /* XT_MATH_DONE: raises $D5C7.0 */
#define SIO_STAT_REG   (*(volatile uint32_t *)0x43C00608u)   /* XT_MATH_STAT: {..,ack_tgl,req_s2,pending} */
#define SIO_MBOX_BYTES 512u

/* off and n are word-aligned by construction (the mathcop.h offsets are). */
static void sio_mbox_read(uint32_t off, uint8_t *dst, uint32_t n)
{
    SIO_PTR = off & ~3u; __asm__ volatile("dsb");
    for (uint32_t i = 0; i < n; i += 4) {
        uint32_t w = SIO_DAT;                     /* pointer auto-increments */
        dst[i] = (uint8_t)w;         dst[i + 1] = (uint8_t)(w >> 8);
        dst[i + 2] = (uint8_t)(w >> 16); dst[i + 3] = (uint8_t)(w >> 24);
    }
}

static void sio_mbox_write(uint32_t off, const uint8_t *src, uint32_t n)
{
    SIO_PTR = off & ~3u; __asm__ volatile("dsb");
    for (uint32_t i = 0; i < n; i += 4) {
        SIO_DAT = (uint32_t)src[i]            | ((uint32_t)src[i + 1] << 8) |
                  ((uint32_t)src[i + 2] << 16) | ((uint32_t)src[i + 3] << 24);
        __asm__ volatile("dsb");
    }
}

/* Called from the mathcop worker task on a MC_SIO_CHUNK doorbell. */
void xl_sio_mbox_service(void)
{
    static uint8_t page[SIO_MBOX_BYTES];          /* kernel BSS; single caller */

    /* Words $000 and $004 carry STATUS/FLAGS/MAGIC; $040 the DCB. Nothing else
     * is read by the service. */
    sio_mbox_read(0, page, 8);
    sio_mbox_read(MC_OFF_SIO_DCB, page + MC_OFF_SIO_DCB, 12);

    /* Invalid magic on a doorbell: either a spurious level-IRQ re-wake (the
     * previous request's magic already consumed — benign, drop it silently
     * after the retry) or the 6502's magic write is IN FLIGHT (HW 2026-08-08:
     * a game-loader SIO request stalled with a fully-valid DCB in the page and
     * magic=0 — the write raced the doorbell's arrival at the worker).  Retry
     * briefly before deciding; log either way so the ring shows the truth. */
    if (page[MC_OFF_SIO_MAGIC] != MC_SIO_MAGIC) {
        for (int tries = 0; tries < 5 && page[MC_OFF_SIO_MAGIC] != MC_SIO_MAGIC; tries++) {
            vTaskDelay(1);
            sio_mbox_read(0, page, 8);
        }
        if (page[MC_OFF_SIO_MAGIC] == MC_SIO_MAGIC) {
            sio_mbox_read(MC_OFF_SIO_DCB, page + MC_OFF_SIO_DCB, 12);
            klog("[xl] sio late magic (served on retry)\r\n");
        } else {
            /* A bare $D5C7 write from RUNNING 6502 code — games sweep/probe
             * the CCTL page — is a doorbell with no request behind it.  Each
             * one flips the req toggle; when two coalesce into ONE pending
             * event the two-toggle handshake phase-slips and the NEXT real
             * request polls $D5C7.0 forever ($CB8A stall, HW 2026-08-08).
             * Re-align: if the toggles disagree (done reads 0) with nothing
             * pending and no request in the page, ring DONE to restore
             * parity.  The stub can't see the blip — it only polls AFTER its
             * own doorbell, which flips req and drops done again. */
            uint32_t stat = SIO_STAT_REG;
            if (!(stat & 1u) && (((stat >> 2) & 1u) != ((stat >> 1) & 1u))) {
                SIO_DONE_REG = MC_SIO_CHUNK; __asm__ volatile("dsb");
                klog("[xl] sio spurious doorbell -> parity realigned\r\n");
            } else {
                klog("[xl] sio doorbell with no magic (dropped)\r\n");
            }
        }
    }

    if (page[MC_OFF_SIO_MAGIC] == MC_SIO_MAGIC) {
        xl_sio_service(page);
        page[MC_OFF_SIO_MAGIC] = 0;               /* consume it */
        sio_mbox_write(0, page, 8);               /* status + flags back */
        sio_mbox_write(MC_OFF_SIO_DATA, page + MC_OFF_SIO_DATA, 256);
        /* Ring DONE ONLY for a request actually served.  The doorbell IRQ is
         * LEVEL-triggered, so a spurious second wake (IRQ re-fire before the
         * event pop lands) re-enters here with the magic already consumed —
         * ringing DONE for that flips the mbox ack toggle with no matching
         * request and the two-toggle handshake goes PHASE-SLIPPED: $D5C7.0
         * reads 0 forever and the stub spins at $CB8A mid-load (HW 2026-08-08,
         * stat_word ack=1/req=0/pending=0; a manual MATH_DONE poke resumed the
         * boot — the parity proof). */
        SIO_DONE_REG = MC_SIO_CHUNK;              /* -> $D5C7.0: the stub may proceed */
        __asm__ volatile("dsb");
    }
}

/* ---- OS image build + patch ----------------------------------------------- */
static int read_whole(const char *path, uint8_t *dst, uint32_t cap, uint32_t *out_len)
{
    vfs_file f;
    if (vfs_open(path, 0, &f) != 0) return -1;
    uint32_t got = 0;
    for (;;) {
        long r = f.read ? f.read(&f, dst + got, cap - got) : -1;
        if (r < 0) { if (f.close) f.close(&f); return -1; }
        if (r == 0) break;
        got += (uint32_t)r;
        if (got == cap) break;
    }
    if (f.close) f.close(&f);
    if (out_len) *out_len = got;
    return 0;
}

/* find a run of >= need identical padding bytes ($00 or $FF) inside the OS ROM
 * regions — where a stub lives — starting the scan at `from` (so the two stubs
 * take DIFFERENT runs; one 214-byte run is far rarer than two of 196+14).
 * Returns 0 on failure; *end receives the byte after the placed stub. */
static uint16_t find_padding(const uint8_t *img, uint32_t need, uint16_t from,
                             uint16_t *end)
{
    static const struct { uint16_t lo, hi; } zone[2] =
        { { 0xC000, 0xCFF0 }, { 0xD800, 0xFFF0 } };
    for (int z = 0; z < 2; z++) {
        uint16_t lo = zone[z].lo < from ? from : zone[z].lo;
        if (lo > zone[z].hi) continue;
        uint32_t run = 0;
        for (uint32_t a = lo; a <= zone[z].hi; a++) {
            uint8_t pad = (img[a] == 0x00 || img[a] == 0xFF);
            run = (pad && (run == 0 || img[a] == img[a - 1])) ? run + 1 : (pad ? 1 : 0);
            if (run >= need) {
                uint16_t base = (uint16_t)(a - need + 1);
                if (end) *end = (uint16_t)(base + need);
                return base;
            }
        }
    }
    return 0;
}

/* The XL OS coldstart self-checks its own ROM before booting: $FF73 16-bit-sums
 * $C002-$CFFF + $5000-$57FF + $D800-$DFFF and compares to the value at $C000/$C001;
 * $FF92 sums $E000-$FFF7 + $FFFA-$FFFF vs $FFF8/$FFF9.  A mismatch clears bit0 of the
 * "$01" flag (LSR $01), and the coldstart then JMP $5003 into the built-in SELF-TEST
 * instead of booting the disk.  Our patches (SIO stub + reset stub in $CBxx, the SIOV
 * redirect at $E45A, the reset vector at $FFFC) all land inside those summed ranges, so
 * both checksums break.  Re-point the two stored checksums by the exact delta our edits
 * introduce.  $5000-$57FF is a separate self-test ROM we never touch, so it cancels out
 * of the delta; `xl` is the pristine 16 KB image where orig[a] == xl[a-0xC000] for both
 * the $C000-$CFFF and $D800-$FFFF windows.  (HW-proven: the /bin/6502 watchpoint on $01
 * caught the LSR that this defeats.) */
static void fix_os_checksums(uint8_t *img, const uint8_t *xl)
{
    static const struct { uint16_t lo, hi; } ra[2] = { {0xC002,0xD000}, {0xD800,0xE000} };
    static const struct { uint16_t lo, hi; } rb[2] = { {0xE000,0xFFF8}, {0xFFFA,0x0000} };
    uint16_t dA = 0, dB = 0;
    for (int i = 0; i < 2; i++)
        for (uint32_t a = ra[i].lo; a != ra[i].hi; a = (a + 1) & 0xFFFF)
            dA = (uint16_t)(dA + img[a] - xl[a - 0xC000]);
    for (int i = 0; i < 2; i++)
        for (uint32_t a = rb[i].lo; a != rb[i].hi; a = (a + 1) & 0xFFFF)
            dB = (uint16_t)(dB + img[a] - xl[a - 0xC000]);
    uint16_t newA = (uint16_t)((xl[0x0000] | (xl[0x0001] << 8)) + dA);   /* stored @ $C000/1 */
    uint16_t newB = (uint16_t)((xl[0x3FF8] | (xl[0x3FF9] << 8)) + dB);   /* stored @ $FFF8/9 */
    img[0xC000] = (uint8_t)(newA & 0xFF); img[0xC001] = (uint8_t)(newA >> 8);
    img[0xFFF8] = (uint8_t)(newB & 0xFF); img[0xFFF9] = (uint8_t)(newB >> 8);
}

static int build_patched_os(uint8_t *img /* 64K */)
{
    static uint8_t xl[16384], ba[8192];
    uint32_t xln = 0, ban = 0;
    if (read_whole("/OS/roms/atari-xl.rom", xl, sizeof xl, &xln) != 0 || xln != sizeof xl) {
        klog("[xl] /OS/roms/atari-xl.rom missing/short\r\n"); return -1;
    }
    if (read_whole("/OS/roms/atari-basic.rom", ba, sizeof ba, &ban) != 0 || ban != sizeof ba) {
        klog("[xl] /OS/roms/atari-basic.rom missing/short\r\n"); return -1;
    }
    memset(img, 0, 0x10000);
    memcpy(img + 0xA000, ba, 0x2000);               /* BASIC */
    memcpy(img + 0xC000, xl, 0x1000);               /* OS low  = xl[0x0000..] */
    memcpy(img + 0xD800, xl + 0x1800, 0x2800);      /* OS high = xl[0x1800..] */

    /* SIOV: the OS vector table entry at $E459 is JMP <real SIO>. */
    if (img[0xE459] != 0x4C) { klog("[xl] SIOV is not a JMP?\r\n"); return -1; }
    uint16_t orig_sio = (uint16_t)(img[0xE45A] | (img[0xE45B] << 8));
    uint16_t orig_rst = (uint16_t)(img[0xFFFC] | (img[0xFFFD] << 8));

    uint16_t after = 0;
    uint16_t sio_at = find_padding(img, sizeof sio_stub, 0xC000, &after);
    if (!sio_at) { klog("[xl] no ROM padding run for the SIO stub\r\n"); return -1; }
    uint16_t rst_at = find_padding(img, sizeof rst_stub, after, 0);
    if (!rst_at) { klog("[xl] no ROM padding run for the reset stub\r\n"); return -1; }

    memcpy(img + sio_at, sio_stub, sizeof sio_stub);
    img[sio_at + sizeof sio_stub - 2] = (uint8_t)(orig_sio & 0xFF);
    img[sio_at + sizeof sio_stub - 1] = (uint8_t)(orig_sio >> 8);
    img[0xE45A] = (uint8_t)(sio_at & 0xFF);
    img[0xE45B] = (uint8_t)(sio_at >> 8);

    memcpy(img + rst_at, rst_stub, sizeof rst_stub);
    img[rst_at + sizeof rst_stub - 2] = (uint8_t)(orig_rst & 0xFF);
    img[rst_at + sizeof rst_stub - 1] = (uint8_t)(orig_rst >> 8);
    img[0xFFFC] = (uint8_t)(rst_at & 0xFF);
    img[0xFFFD] = (uint8_t)(rst_at >> 8);

    /* Re-point the OS ROM self-checksums so the coldstart boots instead of self-testing. */
    fix_os_checksums(img, xl);

    klog("[xl] OS patched: SIO stub @$"); klog_u(sio_at);
    klog(" reset stub @$"); klog_u(rst_at); klog("\r\n");
    return 0;
}

static void upload_image(const uint8_t *img)
{
    /* $1000-$CFFF then $D800-$FFFF: skip the $D000-$D7FF hardware page.  This
     * both installs the OS and scrubs RAM $1000-$9FFF (part of the coldstart
     * guarantee — a previous session's pixels/code must not survive). */
    romwin_write(0x1000, img + 0x1000, 0xD000 - 0x1000);
    romwin_write(0xD800, img + 0xD800, 0x10000 - 0xD800);
}

/* ---- the syscalls ---------------------------------------------------------- */

/* The 64 KB address-space image every cold path rebuilds.  ONE buffer, file
 * scope: xl_boot / xex_boot / xl_reset all run in the syscall task, never
 * concurrently (this used to be two separate 64 KB function-statics). */
static uint8_t g_osimg[0x10000];

/* Cold-reset the realm KEEPING mounted media — a real power-cycle (the `6502
 * basic` / `6502 nobasic` commands, SYS_xl_reset).  Rebuilds + re-uploads the
 * patched OS image, so it carries the same clean power-on guarantee as a
 * launch (RAM $1000-$9FFF scrubbed, stubs re-patched — and a realm whose BRAM
 * was never loaded still comes up), then drives CONSOL across the coldstart:
 * basic!=0 releases OPTION (BASIC on), basic=0 holds it (BASIC off, released
 * automatically once the OS has sampled it).  A mounted disk reboots — exactly
 * like pressing reset on a real XL with the drive still attached. */
int xl_reset(int basic)
{
    /* Preserve ALL control bits across the cold-boot except the reset-hold
     * itself (bit0): bit1 = core select, bit2 = ANTIC timing-machine authority. */
    uint32_t sel = GP0_SALLYRST & ~1u;
    GP0_SALLYRST = sel | 1u; __asm__ volatile("dsb");
    if (build_patched_os(g_osimg) != 0) { GP0_SALLYRST = sel; return -5; }
    upload_image(g_osimg);
    if (basic) {
        ++g_consol_gen;                 /* cancel any pending OPTION release */
        GP0_CONSOL = CONSOL_NONE; __asm__ volatile("dsb");
    } else {
        consol_hold_option();
    }
    GP0_SALLYRST = sel; __asm__ volatile("dsb");
    klog(basic ? "[xl] cold reset (BASIC)\r\n" : "[xl] cold reset (no BASIC)\r\n");
    return 0;
}

int xl_boot(const char *path, int drive)
{
    /* Preserve ALL control bits across the cold-boot except the reset-hold
     * itself (bit0): bit1 = core select (`6502 core turbo` clears it), bit2 =
     * ANTIC timing-machine authority (sallyrst[2]) — masking with CPUSEL_FID
     * alone silently stripped bit2 on every xexload, turning the timing
     * machine off mid-sweep. */
    uint32_t sel = GP0_SALLYRST & ~1u;

    if (!path) {                        /* eject everything, back to BASIC */
        GP0_SALLYRST = sel | 1u; __asm__ volatile("dsb");
        xl_unmount_all();
        int rc = xl_reset(1);           /* fresh image, OPTION released -> READY */
        if (rc == 0) klog("[xl] cold boot, no media\r\n");
        return rc;
    }

    if (drive < 1 || drive > 8) return -22;

    /* Load and validate the ATR before touching the running realm. */
    vfs_file f;
    if (vfs_open(path, 0, &f) != 0) return -2;
    uint32_t sz = f.size;
    if (sz < 16 + 128 || sz > 4u * 1024 * 1024) { if (f.close) f.close(&f); return -22; }
    uint8_t *buf = frtos_alloc(sz, 16, NULL);
    if (!buf) { if (f.close) f.close(&f); return -12; }
    uint32_t got = 0;
    for (;;) {
        long r = f.read ? f.read(&f, buf + got, sz - got) : -1;
        if (r <= 0) break;
        got += (uint32_t)r;
        if (got == sz) break;
    }
    if (f.close) f.close(&f);
    int is_atr = (got == sz) && buf[0] == 0x96 && buf[1] == 0x02;              /* $0296 */
    int is_atx = (got == sz) && buf[0]=='A'&&buf[1]=='T'&&buf[2]=='8'&&buf[3]=='X';
    if (!is_atr && !is_atx) {
        frtos_free(buf, NULL);
        klog("[xl] not an ATR or ATX image\r\n");
        return -22;
    }
    uint16_t secsz = is_atr ? (uint16_t)(buf[4] | (buf[5] << 8)) : 128;
    if (secsz != 128 && secsz != 256) { frtos_free(buf, NULL); return -22; }

    GP0_SALLYRST = sel | 1u; __asm__ volatile("dsb");   /* the realm sleeps (core preserved) */
    xl_unmount_all();                               /* v1: one medium per session */
    if (build_patched_os(g_osimg) != 0) {
        frtos_free(buf, NULL);
        GP0_SALLYRST = sel;
        return -5;
    }
    upload_image(g_osimg);
    g_drv[drive - 1].img   = buf;
    g_drv[drive - 1].len   = sz;
    g_drv[drive - 1].secsz = secsz;
    g_drv[drive - 1].kind  = is_atx ? IMG_ATX : IMG_ATR;
    /* Claim this ID on the serial bus too, so a fast loader that bypasses SIOV
     * finds a drive there.  Both front ends stay live: BallBlazer boots its
     * first 17 sectors THROUGH the OS (and so through the SIOV stub) and only
     * then switches to the bus, so disabling one would break it. */
    xl_sio_bus_claim((uint8_t)(1u << (drive - 1)));
    { static int bus_task_started;
      if (!bus_task_started) {
          bus_task_started = 1;
          xTaskCreate(xl_sio_bus_task, "siobus", 512, NULL,
                      configMAX_PRIORITIES - 2, NULL);
      } }
    g_drv[drive - 1].fdc   = 0xFF;
    if (is_atx && atx_parse(&g_drv[drive - 1]) != 0) {
        klog("[xl] ATX parse failed\r\n");
        xl_unmount_all();
        GP0_SALLYRST = sel;
        return -22;
    }
    consol_hold_option();                           /* OPTION across coldstart -> BASIC OFF; auto-released */
    GP0_SALLYRST = sel; __asm__ volatile("dsb");    /* coldstart; the OS boots Dn: on the selected core */

    klog("[xl] booted "); klog(path);
    klog(" as D"); klog_u((unsigned)drive);
    if (is_atx) { klog(": (ATX, "); klog_u((unsigned)g_drv[drive-1].natx); klog(" sectors)\r\n"); }
    else        klog(secsz == 256 ? ": (DD)\r\n" : ": (SD)\r\n");
    return 0;
}

/* ---- XEX launch (host-driven, mirrors atari800's binload.c) ---------------
 * A bare-6502 streaming loader is too fragile on HW (an intermittent low-memory
 * corruption + an SIO re-read derailed it).  So we do exactly what atari800's
 * emulator does: the A9 is the HOST.  It boots the OS with a 1-SECTOR fake disk
 * whose boot-continuation ($0706) is caught by a HW BREAKPOINT (the GP0 DEBUG
 * facility) instead of an ESC trap; while the core is frozen there the A9 loads
 * every segment and drives the PC through the INIT/RUN vectors.  Almost no 6502
 * code runs during load (the OS coldstart, the one boot sector, and one A9-
 * commanded STA per sub-$1000 byte), so the fragile-code failure can't happen.
 *
 * Bytes at >= $1000 are written straight to BRAM through the ROM window (fast,
 * byte-accurate, no 6502).  Bytes at < $1000 (page 0 + $02xx only, <=31 bytes
 * across all acid800) can't be reached by the A9 (page-0 window = the GP0 regs),
 * so the A9 drives a single STA per byte via the debugger.  INIT ($02E2) runs
 * after its segment (return trap on the 6502 stack), and control finally JMPs
 * through RUNAD ($02E0).  atari800 also clears COLDST ($0244) and sets $09 = 1
 * to mark a successful boot; we mirror that.
 *
 * .xex layout: optional $FFFF magic (may repeat), then segments of
 *   start[2 LE], end[2 LE], (end-start+1) data bytes -> loaded to `start`. */

/* Validate the .xex segment chain (reject non-binaries cleanly). Returns 0 ok. */
static int xex_validate(const uint8_t *x, uint32_t n)
{
    uint32_t i = 0, nseg = 0;
    while (i + 4 <= n) {
        while (i + 2 <= n && x[i] == 0xFF && x[i + 1] == 0xFF) i += 2;   /* $FFFF markers */
        if (i + 4 > n) break;
        uint32_t s = x[i] | (x[i + 1] << 8);
        uint32_t e = x[i + 2] | (x[i + 3] << 8);
        i += 4;
        if (e < s) return -1;                       /* end before start */
        uint32_t len = e - s + 1;
        if (i + len > n) return -1;                 /* segment runs past EOF */
        i += len;
        nseg++;
    }
    return (nseg && i == n) ? 0 : -1;               /* must consume the whole file */
}

/* Build the 1-sector fake boot disk (mirrors atari800 BINLOAD_LoaderStart):
 * load one sector to $0700, DOSINI=$E477 (OS coldstart, so a RESET reboots).
 * $0706 (the boot continuation the OS JSRs) is an RTS placeholder -- we never
 * run it; the A9 breakpoints there and takes over.  Served by the ordinary SIO
 * worker, so the OS boots it exactly like a game's first sector. */
static uint8_t *synth_boot_atr(uint32_t *out_sz)
{
    const uint32_t SEC = 128, total = 1, filelen = 16 + total * SEC;
    uint8_t *atr = frtos_alloc(filelen, 16, NULL);
    if (!atr) return NULL;
    memset(atr, 0, filelen);
    uint32_t para = (total * SEC) / 16;
    atr[0] = 0x96; atr[1] = 0x02;                   /* ATR magic $0296 */
    atr[2] = para & 0xFF; atr[3] = (para >> 8) & 0xFF;
    atr[4] = SEC & 0xFF;  atr[5] = SEC >> 8;
    uint8_t *b = atr + 16;                          /* sector 1 */
    b[0] = 0x00;                                    /* flag */
    b[1] = 0x01;                                    /* one boot sector */
    b[2] = 0x00; b[3] = 0x07;                       /* load address $0700 */
    b[4] = 0x77; b[5] = 0xE4;                       /* DOSINI = $E477 (coldstart) */
    b[6] = 0x60;                                    /* $0706: RTS (never executed) */
    if (out_sz) *out_sz = filelen;
    return atr;
}

/* Run the segment's INIT routine ($02E2 vector) once it has loaded: push a
 * return address of POKE_TRAP-1 onto the 6502 stack (so its RTS lands on our
 * breakpoint), set PC = INITAD, and run.  Refreshes the reg shadow afterwards
 * (INIT can change any register). */
static int xex_run_init(cpu6502 *r, uint16_t initad)
{
    uint16_t ret = (uint16_t)(POKE_TRAP - 1);       /* RTS adds 1 -> POKE_TRAP */
    if (dbg_poke(r, (uint16_t)(0x0100 + r->sp), (uint8_t)(ret >> 8)) != 0) return -1;
    r->sp--;
    if (dbg_poke(r, (uint16_t)(0x0100 + r->sp), (uint8_t)(ret & 0xFF)) != 0) return -1;
    r->sp--;
    cpu6502 s = *r; s.pc = initad; s.p |= 0x01;     /* carry set (atari800 CPU_SetC before INIT) */
    if (dbg_run_from(&s) != 0) {                    /* INIT runs, RTS -> POKE_TRAP breakpoint */
        /* Trap timeout: some tests run ENTIRELY inside INIT and never return
         * -- cpu_65c816 detects the CPU, prints its verdict and parks in the
         * acid framework's end loop just past _testEnd.  A timeout with the
         * PC in that region is a COMPLETED run, not a broken load: report
         * success so the sweep classifies it na (never halts) instead of a
         * red load error.  Halt for a coherent PC read, resume either way. */
        DBG_HALT = 1; __asm__ volatile("dsb");
        for (int i = 0; i < 100000 && !(DBG_STAT & 1u); i++) { }
        uint16_t pc = (uint16_t)(DBG_PC & 0xFFFFu);
        DBG_GO = 1; __asm__ volatile("dsb");
        if (pc >= 0x1D90 && pc <= 0x1DC0) {
            klog("[xl] xex: INIT ran to the acid framework end (no return)\r\n");
            dbg_read_regs(r);
            return 1;                       /* ran to completion: skip the RUN phase */
        }
        return -1;
    }
    dbg_read_regs(r);                               /* INIT clobbered regs/SP: refresh */
    return 0;
}

/* acid800 standalone framework: every test ends in the shared library proc
 * _testEnd at 6502 $1D93 (the library links at a fixed base, so this address is
 * identical across all 63 tests -- verified in the .lst dumps).  _testEnd runs
 * `sei; sta nmien; ...; jmp ($fffc)` (a soft reset).  By the time it is reached,
 * _testPassed ($1DF8) / _testFailed ($1E0D) have ALREADY printed "Pass"/"FAIL."
 * to the screen and set Y (00 = pass, 80 = fail).  So arming a HW breakpoint at
 * $1D93 freezes the core on its result screen -- ANTIC keeps DMA-refreshing it,
 * Y still holds the verdict -- instead of the jmp($fffc) clobbering both. */
#define ACID800_TESTEND 0x1D93u

int xex_boot(const char *path, int turbo, int hold)
{
    /* Core select per arg; every OTHER control bit (e.g. sallyrst[2] = ANTIC
     * timing-machine authority) is preserved — this path hardcoded sel and
     * stripped them on every xexload. */
    uint32_t sel = (GP0_SALLYRST & ~3u) | (turbo ? 0u : CPUSEL_FID);

    if (!path) return -22;

    vfs_file f;
    if (vfs_open(path, 0, &f) != 0) return -2;
    uint32_t sz = f.size;
    if (sz < 6 || sz > 0xFF00u) {
        if (f.close) f.close(&f);
        klog("[xl] .xex too big/short\r\n");
        return -22;
    }
    uint8_t *xex = frtos_alloc(sz, 16, NULL);
    if (!xex) { if (f.close) f.close(&f); return -12; }
    uint32_t got = 0;
    for (;;) {
        long r = f.read ? f.read(&f, xex + got, sz - got) : -1;
        if (r <= 0) break;
        got += (uint32_t)r;
        if (got == sz) break;
    }
    if (f.close) f.close(&f);
    if (got != sz || xex_validate(xex, sz) != 0) {
        frtos_free(xex, NULL);
        klog("[xl] not a valid .xex\r\n");
        return -22;
    }

    uint32_t atrsz = 0;
    uint8_t *atr = synth_boot_atr(&atrsz);
    if (!atr) { frtos_free(xex, NULL); return -12; }

    /* ---- cold-boot the OS on the selected core, halted at the boot trap ---- */
    GP0_SALLYRST = sel | 1u; __asm__ volatile("dsb");   /* hold reset + select core */
    xl_unmount_all();
    if (build_patched_os(g_osimg) != 0) {
        frtos_free(atr, NULL); frtos_free(xex, NULL);
        GP0_SALLYRST = sel; __asm__ volatile("dsb");
        return -5;
    }
    upload_image(g_osimg);
    g_drv[0].img = atr; g_drv[0].len = atrsz; g_drv[0].secsz = 128;   /* D1: = boot disk */

    DBG_BKPT = 0x0706; __asm__ volatile("dsb");     /* trap the boot continuation */
    DBG_CFG  = 1u;      __asm__ volatile("dsb");     /* bkpt_en=1, halt_at_reset=0 */
    consol_hold_option();                            /* BASIC OFF across coldstart */
    GP0_SALLYRST = sel; __asm__ volatile("dsb");                  /* release -> coldstart */

    int halted = 0;                                 /* yield while the OS coldstarts + boots */
    /* 3000ms was marginal: the coldstart-to-$0706 time varies enough that a
     * bulk sweep saw well over a third of loads bail with -5 ("never hit the
     * boot trap") while the machine was in fact booting fine — the CPU is found
     * running normally in OS ROM afterwards.  A generous ceiling costs nothing
     * on the success path (this polls DBG_STAT and breaks out as soon as the
     * trap hits) and makes back-to-back xexloads reliable enough to sweep. */
    for (int ms = 0; ms < 12000 && !halted; ms += 10) {
        if (DBG_STAT & 1u) { halted = 1; break; }
        vTaskDelay(10);
    }
    if (!halted) {                                  /* never reached $0706 */
        frtos_free(xex, NULL);
        klog("[xl] xex: core never hit the boot trap (wrong CPU core?)\r\n");
        return -5;
    }
    consol_release_now();                                /* past coldstart -> release OPTION */

    /* ---- the A9 is now the loader (atari800 loader_cont) ------------------- */
    cpu6502 reg; dbg_read_regs(&reg);
    { const uint8_t sta[3] = { 0x8D, 0x00, 0x00 };  /* STA $0000 scratch @ POKE_STA */
      romwin_write(POKE_STA, sta, sizeof sta); }
    DBG_BKPT = POKE_TRAP; __asm__ volatile("dsb");  /* pokes + INIT RTS halt here now */

    dbg_poke(&reg, 0x0244, 0x00);                   /* COLDST = 0  (booted) */
    dbg_poke(&reg, 0x0009, 0x01);                   /* $09    = 1  (booted) */

    uint16_t runad = 0; int have_run = 0;
    uint32_t i = 0;
    while (i + 4 <= sz) {
        while (i + 2 <= sz && xex[i] == 0xFF && xex[i + 1] == 0xFF) i += 2;  /* $FFFF */
        if (i + 4 > sz) break;
        uint16_t s = (uint16_t)(xex[i] | (xex[i + 1] << 8));
        uint16_t e = (uint16_t)(xex[i + 2] | (xex[i + 3] << 8));
        i += 4;
        uint32_t len = (uint32_t)e - s + 1;
        const uint8_t *data = xex + i;
        i += len;

        if (!have_run) { runad = s; have_run = 1; }   /* default RUNAD = 1st segment start */

        /* place the segment: >= $1000 straight to BRAM, < $1000 one STA/byte */
        uint32_t j = 0;
        while (j < len) {
            uint16_t a = (uint16_t)(s + j);
            if (a >= 0x1000) {
                uint32_t run = 0;                     /* longest >= $1000 run from here */
                while (j + run < len && (uint16_t)(s + j + run) >= 0x1000) run++;
                romwin_write(a, data + j, run);
                j += run;
            } else {
                dbg_poke(&reg, a, data[j]);
                j++;
            }
        }
        /* track RUNAD/INITAD the same bytes wrote (the A9 can't read 6502 RAM) */
        for (uint32_t k = 0; k < len; k++) {
            uint16_t a = (uint16_t)(s + k);
            if (a == 0x02E0) runad = (uint16_t)((runad & 0xFF00) | data[k]);
            if (a == 0x02E1) runad = (uint16_t)((runad & 0x00FF) | (data[k] << 8));
        }
        /* a segment that set INITAD ($02E2/$02E3): run INIT now */
        if (s <= 0x02E2 && e >= 0x02E3) {
            uint16_t initad = (uint16_t)(data[0x02E2 - s] | (data[0x02E3 - s] << 8));
            int irc = xex_run_init(&reg, initad);
            if (irc < 0) {
                frtos_free(xex, NULL);
                klog("[xl] xex: INIT run failed\r\n");
                return -5;
            }
            if (irc == 1) {                 /* the test ran ENTIRELY inside INIT
                                             * (cpu_65c816): nothing to RUN — the
                                             * realm keeps its parked end state
                                             * and the sweep reads never-halts. */
                frtos_free(xex, NULL);
                return 0;
            }
        }
    }
    frtos_free(xex, NULL);

    /* ---- hand off to the program: JMP (RUNAD) ------------------------------
     * All cold-boots/SALLYRSTs are behind us (the coldstart ran back at reset
     * release, and the load phase never resets), so a breakpoint armed here
     * survives until the test itself executes it.  Non-hold: disarm and run
     * free.  hold: re-point the breakpoint from the load-phase POKE_TRAP to the
     * acid800 _testEnd ($1D93) and leave bkpt_en set, so the test runs free but
     * HALTS on its result screen (see ACID800_TESTEND above). */
    if (hold) {
        DBG_BKPT = ACID800_TESTEND; __asm__ volatile("dsb");
        DBG_CFG  = (DBG_CFG & ~2u) | 1u; __asm__ volatile("dsb");  /* bkpt_en=1, keep halt_at_reset */
    } else {
        DBG_CFG = 0u; __asm__ volatile("dsb");      /* bkpt_en=0: let it run free */
    }
    reg.pc = runad;
    DBG_WPC   = reg.pc;
    DBG_WAXYS = (uint32_t)reg.a | ((uint32_t)reg.x << 8) |
                ((uint32_t)reg.y << 16) | ((uint32_t)reg.sp << 24);
    DBG_WPSH  = (uint32_t)reg.p;
    __asm__ volatile("dsb");
    DBG_COMMIT = 1; __asm__ volatile("dsb");
    dbg_wait_halt();                                 /* PC latched, core halted */
    DBG_GO = 1; __asm__ volatile("dsb");             /* run RUNAD (hold: until $1D93) */

    klog("[xl] xex-boot "); klog(path); klog(" run=$"); klog_u(runad);
    if (hold) klog(" (hold@$1D93)");
    klog("\r\n");
    return 0;
}

#else  /* qemu: no fabric 6502 */

void xl_sio_service(volatile uint8_t *page) { (void)page; }
void xl_sio_mbox_service(void) { }
int  xl_boot(const char *path, int drive) { (void)path; (void)drive; return -19; }
int  xl_reset(int basic) { (void)basic; return -19; }
int  xex_boot(const char *path, int turbo, int hold) { (void)path; (void)turbo; (void)hold; return -19; }

#endif /* XT_HW */
