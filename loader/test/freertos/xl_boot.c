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

    if (!path) {                        /* eject everything, back to BASIC */
        GP0_SALLYRST = 1; __asm__ volatile("dsb");
        xl_unmount_all();
        if (build_patched_os(img) != 0) { GP0_SALLYRST = 0; return -5; }
        upload_image(img);
        GP0_CONSOL = CONSOL_NONE; __asm__ volatile("dsb");   /* OPTION released -> BASIC on -> READY */
        GP0_SALLYRST = 0; __asm__ volatile("dsb");
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

    GP0_SALLYRST = 1; __asm__ volatile("dsb");      /* the realm sleeps */
    xl_unmount_all();                               /* v1: one medium per session */
    if (build_patched_os(img) != 0) {
        frtos_free(buf, NULL);
        GP0_SALLYRST = 0;
        return -5;
    }
    upload_image(img);
    g_drv[drive - 1].img   = buf;
    g_drv[drive - 1].len   = sz;
    g_drv[drive - 1].secsz = secsz;
    GP0_CONSOL = CONSOL_OPTION_HELD; __asm__ volatile("dsb"); /* hold OPTION -> XL OS leaves BASIC OFF ($A000-$BFFF = RAM) */
    GP0_SALLYRST = 0; __asm__ volatile("dsb");      /* coldstart; the OS boots Dn: */

    klog("[xl] booted "); klog(path);
    klog(" as D"); klog_u((unsigned)drive);
    klog(secsz == 256 ? ": (DD)\r\n" : ": (SD)\r\n");
    return 0;
}

#else  /* qemu: no fabric 6502 */

void xl_sio_service(volatile uint8_t *page) { (void)page; }
int  xl_boot(const char *path, int drive) { (void)path; (void)drive; return -19; }

#endif /* XT_HW */
