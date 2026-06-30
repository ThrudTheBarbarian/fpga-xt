/*
 * sd.c — bring up the SD card via FatFs (ff.c) + xsdps, and prove the read path.
 * Runs pre-scheduler (xsdps card-init busy-waits via usleep/global timer).
 * The harvested diskio.c glues FatFs -> xsdps; f_mount triggers disk_initialize.
 */
#include "ff.h"

extern void puts0(const char *);
extern void putu(unsigned);

#ifdef XT_HW

static FATFS g_fs;
static FIL   g_fil;

void sd_init(void)
{
    FRESULT r = f_mount(&g_fs, "0:", 1);          /* opt=1: mount now (forces card init) */
    if (r != FR_OK) {
        puts0("[sd] f_mount FAILED rc="); putu((unsigned)r); puts0("\r\n");
        return;
    }
    puts0("[sd] SD mounted (FatFs)\r\n");

    /* read a known file to prove the read path end-to-end */
    r = f_open(&g_fil, "0:/OS/etc/motd", FA_READ);
    if (r != FR_OK) { puts0("[sd] open /OS/etc/motd rc="); putu((unsigned)r); puts0("\r\n"); return; }
    char buf[96]; UINT n = 0;
    f_read(&g_fil, buf, sizeof buf - 1, &n);
    buf[n] = 0;
    for (UINT i = 0; i < n; i++) if (buf[i] == '\n') { buf[i] = 0; break; }
    puts0("[sd] /OS/etc/motd ("); putu((unsigned)n); puts0(" B): "); puts0(buf); puts0("\r\n");
    f_close(&g_fil);
}

#else  /* qemu: no SD card */
void sd_init(void) { }
#endif
