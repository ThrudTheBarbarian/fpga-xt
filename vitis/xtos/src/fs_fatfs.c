// fs_fatfs.c — retarget newlib's file syscalls onto FatFs (the SD card).
//
// With these, standard C file I/O (fopen/fread/fseek/...), and therefore
// FreeType, Lua's io, and any C program, read/write the SD card using Unix
// paths (single volume -> a leading '/' is the default drive's root).
//
// fd 0/1/2 are the UART console; fd>=3 are open FatFs files.  The BSP's own
// syscalls are __attribute__((weak)), so these strong definitions override them.
//
// SD DMA cache rule: f_read/f_write must use a 32-byte-aligned buffer (the xsdps
// ADMA2 driver flushes/invalidates the caller's cache lines).  newlib's stdio
// buffers aren't aligned, so _read/_write bounce through an aligned static
// buffer.  That static bounce is NOT reentrant — fine while file I/O is confined
// to one task (the console/boot task); add per-fd buffers if that changes.

#include <errno.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <stdint.h>
#include <string.h>
#include "ff.h"

/* Defined locally to avoid pulling <stdio.h>/<unistd.h> prototypes that would
 * clash with the bare _read/_write/_lseek syscall signatures below. */
#ifndef SEEK_SET
#define SEEK_SET 0
#define SEEK_CUR 1
#define SEEK_END 2
#endif

/* newlib calls the _-prefixed syscalls (the reentrant layer -> _open/_read/...);
 * the BSP provides these as __attribute__((weak)), so the strong definitions
 * here override them.  The non-underscore POSIX names (open/read/...) are NOT
 * redefined — their libc prototypes differ and we don't need them. */

#define FS_MAXF 8
static FIL  fs_fil[FS_MAXF];
static char fs_used[FS_MAXF];

/* UART1 TX (console), standalone of main.c's helpers. */
static void cons_putc(char c)
{
    volatile uint32_t *u = (volatile uint32_t *)0xE0001000u;
    while (u[0x2C / 4] & 0x10u) { }
    u[0x30 / 4] = (uint32_t)(unsigned char)c;
}

int _open(const char *path, int flags, int mode)
{
    (void)mode;
    BYTE m;
    int acc = flags & O_ACCMODE;
    if      (acc == O_WRONLY) m = FA_WRITE;
    else if (acc == O_RDWR)   m = FA_READ | FA_WRITE;
    else                      m = FA_READ;
    if (flags & O_CREAT) m |= (flags & O_TRUNC) ? FA_CREATE_ALWAYS
                            : (flags & O_EXCL)  ? FA_CREATE_NEW
                                                : FA_OPEN_ALWAYS;
    else if (flags & O_TRUNC) m |= FA_CREATE_ALWAYS;
    if (flags & O_APPEND) m |= FA_OPEN_APPEND;

    int i;
    for (i = 0; i < FS_MAXF; i++) if (!fs_used[i]) break;
    if (i == FS_MAXF) { errno = EMFILE; return -1; }
    if (f_open(&fs_fil[i], path, m) != FR_OK) { errno = ENOENT; return -1; }
    fs_used[i] = 1;
    return i + 3;
}

int _read(int fd, char *buf, int n)
{
    if (fd <= 2) return 0;            /* console read goes via the REPL, not here */
    int i = fd - 3;
    if (i < 0 || i >= FS_MAXF || !fs_used[i]) { errno = EBADF; return -1; }
    static char bb[512] __attribute__((aligned(32)));
    int total = 0;
    while (n > 0) {
        UINT want = (n > 512) ? 512u : (UINT)n, got = 0;
        if (f_read(&fs_fil[i], bb, want, &got) != FR_OK) { errno = EIO; return -1; }
        if (got == 0) break;
        memcpy(buf + total, bb, got);
        total += (int)got; n -= (int)got;
        if (got < want) break;       /* short read = EOF */
    }
    return total;
}

int _write(int fd, char *buf, int n)
{
    if (fd == 1 || fd == 2) { for (int k = 0; k < n; k++) cons_putc(buf[k]); return n; }
    if (fd <= 2) return n;            /* stdin write: discard */
    int i = fd - 3;
    if (i < 0 || i >= FS_MAXF || !fs_used[i]) { errno = EBADF; return -1; }
    static char wb[512] __attribute__((aligned(32)));
    int total = 0;
    while (n > 0) {
        UINT want = (n > 512) ? 512u : (UINT)n, put = 0;
        memcpy(wb, buf + total, want);
        if (f_write(&fs_fil[i], wb, want, &put) != FR_OK) { errno = EIO; return -1; }
        total += (int)put; n -= (int)put;
        if (put < want) break;
    }
    return total;
}

int _close(int fd)
{
    if (fd <= 2) return 0;
    int i = fd - 3;
    if (i < 0 || i >= FS_MAXF || !fs_used[i]) { errno = EBADF; return -1; }
    f_close(&fs_fil[i]); fs_used[i] = 0; return 0;
}

off_t _lseek(int fd, off_t off, int whence)
{
    if (fd <= 2) return 0;
    int i = fd - 3;
    if (i < 0 || i >= FS_MAXF || !fs_used[i]) { errno = EBADF; return -1; }
    FSIZE_t base = (whence == SEEK_CUR) ? f_tell(&fs_fil[i])
                 : (whence == SEEK_END) ? f_size(&fs_fil[i]) : 0;
    FSIZE_t pos = base + (FSIZE_t)off;
    if (f_lseek(&fs_fil[i], pos) != FR_OK) { errno = EIO; return -1; }
    return (off_t)pos;
}

int _fstat(int fd, struct stat *st)
{
    memset(st, 0, sizeof *st);
    if (fd <= 2) { st->st_mode = S_IFCHR; return 0; }   /* console = char device */
    int i = fd - 3;
    if (i < 0 || i >= FS_MAXF || !fs_used[i]) { errno = EBADF; return -1; }
    st->st_mode = S_IFREG;
    st->st_size = (off_t)f_size(&fs_fil[i]);
    return 0;
}

int _isatty(int fd) { return (fd <= 2) ? 1 : 0; }

/* os.remove() via Lua / remove() via libc -> FatFs unlink.  _link (hardlink)
 * has no FAT equivalent. */
int _unlink(const char *path) { return (f_unlink(path) == FR_OK) ? 0 : (errno = EIO, -1); }
int _link(const char *o, const char *n) { (void)o; (void)n; errno = ENOSYS; return -1; }
