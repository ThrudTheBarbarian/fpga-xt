/*
 * sd.c — bring up the SD card via FatFs (ff.c) + xsdps, and prove the read path.
 * Runs pre-scheduler (xsdps card-init busy-waits via usleep/global timer).
 * The harvested diskio.c glues FatFs -> xsdps; f_mount triggers disk_initialize.
 */
#include "ff.h"

extern void puts0(const char *);
extern void putu(unsigned);

#ifdef XT_HW

static FATFS   g_fs;
static DIR     g_dir;
static FILINFO g_fno;

void sd_init(void)
{
    puts0("[sd] mounting...\r\n");
    FRESULT r = f_mount(&g_fs, "0:", 1);          /* opt=1: mount now (forces card init) */
    if (r != FR_OK) {
        puts0("[sd] f_mount FAILED rc="); putu((unsigned)r); puts0("\r\n");
        return;
    }
    puts0("[sd] SD mounted (FatFs)\r\n");

    /* list the root directory: proves directory traversal + shows the card contents */
    r = f_opendir(&g_dir, "0:/");
    if (r != FR_OK) { puts0("[sd] opendir / rc="); putu((unsigned)r); puts0("\r\n"); return; }
    puts0("[sd] 0:/ contents:\r\n");
    for (;;) {
        r = f_readdir(&g_dir, &g_fno);
        if (r != FR_OK || g_fno.fname[0] == 0) break;
        puts0("  "); puts0(g_fno.fname);
        puts0((g_fno.fattrib & AM_DIR) ? "/\r\n" : "\r\n");
    }
    f_closedir(&g_dir);
    puts0("[sd] read path OK\r\n");
}

#else  /* qemu: no SD card */
void sd_init(void) { }
#endif
