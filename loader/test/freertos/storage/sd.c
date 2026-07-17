/*
 * sd.c — bring up the SD card via FatFs (ff.c) + xsdps, and prove the read path.
 * Runs pre-scheduler (xsdps card-init busy-waits via usleep/global timer).
 * The harvested diskio.c glues FatFs -> xsdps; f_mount triggers disk_initialize.
 */
#include "ff.h"
#include "diskio.h"
#include "blkdev.h"
#include "vfs.h"
#include <stdint.h>
#include "xtsys.h"      /* XT_XTOS_MEDIA_CHANGE (the OS->app message ABI) */

extern void klog(const char *);      /* -> /OS/var/log/system.log (not console) */
extern void klog_u(unsigned);

#ifdef XT_HW

static FATFS   g_fs;
static DIR     g_dir;
static FILINFO g_fno;

/* block device sd0: raw LBA r/w via the validated diskio->xsdps path.
 * minixfs + swap ride this directly; FatFs uses diskio natively. */
static int sd0_read(blkdev_t *d, uint32_t lba, uint32_t cnt, void *buf)
{ (void)d; return disk_read(0, (BYTE *)buf, lba, cnt) == RES_OK ? 0 : -1; }
static int sd0_write(blkdev_t *d, uint32_t lba, uint32_t cnt, const void *buf)
{ (void)d; return disk_write(0, (const BYTE *)buf, lba, cnt) == RES_OK ? 0 : -1; }
static blkdev_t sd0 = { "sd0", 512, 0, sd0_read, sd0_write, 0 };

/* filesystem capacity for statfs/df: f_getfree scans the FAT for free clusters, and the
 * mounted volume geometry (data clusters * sectors-per-cluster) gives the total. out =
 * { total_sectors, free_sectors, sector_bytes }. SD sectors are 512 bytes. */
int sd_statfs_raw(uint32_t out[3])
{
    FATFS *fs = 0;
    DWORD  nclst = 0;
    if (f_getfree("0:", &nclst, &fs) != FR_OK || !fs) return -1;
    out[0] = (uint32_t)(fs->n_fatent - 2) * fs->csize;   /* total data sectors */
    out[1] = (uint32_t)nclst * fs->csize;                /* free sectors */
    out[2] = 512;
    return 0;
}

void sd_init(void)
{
    klog("[sd] mounting...\r\n");
    FRESULT r = f_mount(&g_fs, "0:", 1);          /* opt=1: mount now (forces card init) */
    if (r != FR_OK) {
        klog("[sd] f_mount FAILED rc="); klog_u((unsigned)r); klog("\r\n");
        return;
    }
    klog("[sd] SD mounted (FatFs)\r\n");

    /* expose the card: block device sd0 + FatFs mounted at /sd in the VFS */
    { DWORD sc = 0; if (disk_ioctl(0, GET_SECTOR_COUNT, &sc) == RES_OK) sd0.block_count = (uint32_t)sc; }
    blkdev_register(&sd0);
    { extern void vfs_fatfs_init(void); extern int vfs_add_mount(const char *, const char *, void *);
      vfs_fatfs_init(); vfs_add_mount("/", "fatfs", 0); }   /* SD = the root filesystem */
    klog("[sd] blkdev sd0 + / (fatfs root) registered\r\n");

    /* prove blkdev sd0: raw LBA 0 (MBR/boot sector) ends in the 0x55AA signature */
    {
        static uint8_t sec[512];
        if (blkdev_read(&sd0, 0, 1, sec) == 0)
            klog((sec[510] == 0x55 && sec[511] == 0xAA)
                  ? "[sd] blkdev sd0 LBA0 = 0x55AA OK\r\n"
                  : "[sd] blkdev sd0 LBA0 read (no 55AA sig)\r\n");
        else
            klog("[sd] blkdev sd0 read FAILED\r\n");
    }

    /* prove the VFS dispatch: open /README.txt (SD root) via vfs_open */
    {
        vfs_file vf;
        if (vfs_open("/README.txt", 0, &vf) == 0) {
            char b[80]; long n = vf.read ? vf.read(&vf, b, sizeof b - 1) : -1;
            if (n > 0) {
                b[n] = 0;
                for (long i = 0; i < n; i++) if (b[i] == '\n') { b[i] = 0; break; }
                klog("[sd] vfs /sd/README.txt: "); klog(b); klog("\r\n");
            }
            if (vf.close) vf.close(&vf);
        } else {
            klog("[sd] vfs open /sd/README.txt failed\r\n");
        }
    }

    klog("[sd] read path OK\r\n");
}

/* enumerate files in an SD directory into out[] (NUL-terminated names, <=31 chars,
 * subdirectories skipped). Returns the count, or -1 if the dir can't be opened.
 * Used by the /OS/boot auto-runner. Single-threaded (reuses the static DIR/FILINFO). */
int sd_listdir_raw(const char *dir, char out[][32], int max)
{
    if (f_opendir(&g_dir, dir) != FR_OK) return -1;
    int n = 0;
    while (n < max && f_readdir(&g_dir, &g_fno) == FR_OK && g_fno.fname[0]) {
        if (g_fno.fattrib & AM_DIR) continue;
        int i = 0; while (g_fno.fname[i] && i < 31) { out[n][i] = g_fno.fname[i]; i++; }
        out[n][i] = 0; n++;
    }
    f_closedir(&g_dir);
    return n;
}

/* ---- SD hot-plug watcher --------------------------------------------------
 * The fs task calls this ~every 500 ms while idle (it is the SOLE FatFs owner,
 * so f_mount here is serialized + safe). Detects card removal/insertion via the
 * FAST present-state probe (sd_card_present has none of disk_status's up-to-5s
 * absent-card debounce spin) and remounts on reinsert. Either transition drops
 * every cached dir listing so a swapped card never shows the old one's files. */
extern int  sd_card_present(void);       /* diskio.c: one register read, no wait */
extern void dcache_flush_all(void);      /* frtos_os.c */
extern void xtos_broadcast(const int16_t *m8);   /* frtos_os.c: OS -> GUI apps */
static int  g_sd_present = 1;            /* mounted at boot */

/* tell GUI apps the SD went away / came back (they may grey out or close windows
 * rooted on it). Delivered as a normal AES message via SYS_xtos_recv / evnt_multi. */
static void media_change_msg(int present)
{
    int16_t m[8] = { (int16_t)XT_XTOS_MEDIA_CHANGE, 0, 0,
                     (int16_t)present, 0 /*volume 0 = SD*/, 0, 0, 0 };
    xtos_broadcast(m);
}

void sd_hotplug_poll(void)
{
    int present = sd_card_present();
    if (present == g_sd_present) return;            /* no transition */
    if (!present) {
        g_sd_present = 0;
        dcache_flush_all();                         /* stale listings must not survive a swap */
        klog("[sd] card REMOVED\r\n");
        media_change_msg(0);
    } else {
        FRESULT r = f_mount(&g_fs, "0:", 1);        /* opt=1: re-init now (a different card is fine) */
        dcache_flush_all();
        if (r == FR_OK) { g_sd_present = 1; klog("[sd] card inserted (remounted)\r\n"); media_change_msg(1); }
        else            { klog("[sd] card inserted, remount FAILED rc="); klog_u((unsigned)r); klog("\r\n"); }
    }
}

#else  /* qemu: no SD card */
void sd_init(void) { }
int  sd_listdir_raw(const char *dir, char out[][32], int max) { (void)dir; (void)out; (void)max; return -1; }
void sd_hotplug_poll(void) { }
#endif
