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
    0xad,0xc6,0xd5,0x48,0xad,0xc8,0xd5,0x48,0xa9,0xff,0x8d,0xc8,0xd5,0xa9,0x01,0x8d,
    0xc6,0xd5,0xa2,0x0b,0xbd,0x00,0x03,0x9d,0x40,0x40,0xca,0x10,0xf7,0xa9,0x5a,0x8d,
    0x05,0x40,0x8d,0xc7,0xd5,0xad,0xc7,0xd5,0x29,0x01,0xf0,0xf9,0xad,0x04,0x40,0x30,
    0x34,0x29,0x01,0xd0,0x1e,0xad,0x03,0x03,0x29,0x40,0xf0,0x17,0xad,0x04,0x03,0x85,
    0x32,0xad,0x05,0x03,0x85,0x33,0xa0,0x00,0xb9,0xc0,0x40,0x91,0x32,0xc8,0xcc,0x08,
    0x03,0xd0,0xf5,0xad,0x03,0x40,0x8d,0x03,0x03,0xaa,0x68,0x8d,0xc8,0xd5,0x68,0x8d,
    0xc6,0xd5,0x8a,0xa8,0x60,0x68,0x8d,0xc8,0xd5,0x68,0x8d,0xc6,0xd5,0x4c,0xff,0xff
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

extern void vTaskDelay(uint32_t);  /* FreeRTOS: let the coldstart run before we poll */

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
typedef struct {
    uint8_t  *img;          /* whole ATR file, kernel memory (NULL = empty) */
    uint32_t  len;
    uint16_t  secsz;        /* 128 / 256 from the ATR header */
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

static void xl_unmount_all(void)
{
    for (int i = 0; i < 8; i++) {
        if (g_drv[i].img) frtos_free(g_drv[i].img, NULL);
        g_drv[i].img = NULL; g_drv[i].len = 0; g_drv[i].secsz = 0;
    }
}

/* ---- SIO service (runs in the mathcop worker task) ------------------------ */
void xl_sio_service(volatile uint8_t *page)
{
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

    switch (cmd) {
    case 0x53: {                                    /* STATUS: 4 bytes */
        out[0] = (uint8_t)(d->secsz == 256 ? 0x20 : 0x00);   /* bit5 = DD */
        out[1] = 0xFF; out[2] = 0xE0; out[3] = 0x00;
        outlen = 4;
        break;
    }
    case 0x52: {                                    /* READ sector DAUX */
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

    if (outlen) {
        uint32_t l = (dbyt && dbyt < outlen) ? dbyt : outlen;
        if (dbuf >= 0x1000) {                       /* straight into BRAM; also the
                                                     * only safe route when DBUF is
                                                     * under the mapped overlay */
            romwin_write(dbuf, out, l);
            flags |= MC_SIO_DELIVERED;
        } else {
            memcpy((uint8_t *)data, out, l);        /* stub copies (boot sectors) */
        }
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

/* ---- the syscall ----------------------------------------------------------- */
int xl_boot(const char *path, int drive)
{
    static uint8_t img[0x10000];        /* kernel BSS; single caller (task ctx) */

    /* Preserve ALL control bits across the cold-boot except the reset-hold
     * itself (bit0): bit1 = core select (`6502 core turbo` clears it), bit2 =
     * ANTIC timing-machine authority (sallyrst[2]) — masking with CPUSEL_FID
     * alone silently stripped bit2 on every xexload, turning the timing
     * machine off mid-sweep. */
    uint32_t sel = GP0_SALLYRST & ~1u;

    if (!path) {                        /* eject everything, back to BASIC */
        GP0_SALLYRST = sel | 1u; __asm__ volatile("dsb");
        xl_unmount_all();
        if (build_patched_os(img) != 0) { GP0_SALLYRST = sel; return -5; }
        upload_image(img);
        GP0_CONSOL = CONSOL_NONE; __asm__ volatile("dsb");   /* OPTION released -> BASIC on -> READY */
        GP0_SALLYRST = sel; __asm__ volatile("dsb");
        klog("[xl] cold boot, no media\r\n");
        return 0;
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
    if (got != sz || !(buf[0] == 0x96 && buf[1] == 0x02)) {   /* ATR magic $0296 */
        frtos_free(buf, NULL);
        klog("[xl] not an ATR (v1 boots ATRs only)\r\n");
        return -22;
    }
    uint16_t secsz = (uint16_t)(buf[4] | (buf[5] << 8));
    if (secsz != 128 && secsz != 256) { frtos_free(buf, NULL); return -22; }

    GP0_SALLYRST = sel | 1u; __asm__ volatile("dsb");   /* the realm sleeps (core preserved) */
    xl_unmount_all();                               /* v1: one medium per session */
    if (build_patched_os(img) != 0) {
        frtos_free(buf, NULL);
        GP0_SALLYRST = sel;
        return -5;
    }
    upload_image(img);
    g_drv[drive - 1].img   = buf;
    g_drv[drive - 1].len   = sz;
    g_drv[drive - 1].secsz = secsz;
    GP0_CONSOL = CONSOL_OPTION_HELD; __asm__ volatile("dsb"); /* hold OPTION -> XL OS leaves BASIC OFF ($A000-$BFFF = RAM) */
    GP0_SALLYRST = sel; __asm__ volatile("dsb");    /* coldstart; the OS boots Dn: on the selected core */

    klog("[xl] booted "); klog(path);
    klog(" as D"); klog_u((unsigned)drive);
    klog(secsz == 256 ? ": (DD)\r\n" : ": (SD)\r\n");
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
    if (dbg_run_from(&s) != 0) return -1;           /* INIT runs, RTS -> POKE_TRAP breakpoint */
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
    static uint8_t img[0x10000];        /* kernel BSS; single caller (task ctx) */
    uint32_t sel = turbo ? 0u : CPUSEL_FID;  /* default = fidelity core (cycle-exact ref) */

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
    if (build_patched_os(img) != 0) {
        frtos_free(atr, NULL); frtos_free(xex, NULL);
        GP0_SALLYRST = 0; __asm__ volatile("dsb");
        return -5;
    }
    upload_image(img);
    g_drv[0].img = atr; g_drv[0].len = atrsz; g_drv[0].secsz = 128;   /* D1: = boot disk */

    DBG_BKPT = 0x0706; __asm__ volatile("dsb");     /* trap the boot continuation */
    DBG_CFG  = 1u;      __asm__ volatile("dsb");     /* bkpt_en=1, halt_at_reset=0 */
    GP0_CONSOL   = CONSOL_OPTION_HELD; __asm__ volatile("dsb");   /* BASIC OFF across coldstart */
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
    GP0_CONSOL = CONSOL_NONE; __asm__ volatile("dsb");   /* past coldstart -> release OPTION */

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
            if (xex_run_init(&reg, initad) != 0) {
                frtos_free(xex, NULL);
                klog("[xl] xex: INIT run failed\r\n");
                return -5;
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
int  xl_boot(const char *path, int drive) { (void)path; (void)drive; return -19; }
int  xex_boot(const char *path, int turbo, int hold) { (void)path; (void)turbo; (void)hold; return -19; }

#endif /* XT_HW */
