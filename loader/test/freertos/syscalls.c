/*
 * syscalls.c — newlib retarget for the FreeRTOS-on-qemu build, so malloc/
 * realloc/free (and thus FreeType) link. _sbrk hands out the OS heap
 * (0x0200_0000 region per docs/Zynq/memory-map.md); console I/O goes to
 * semihosting. (malloc is non-reentrant here — one task allocates at a time;
 * configUSE_NEWLIB_REENTRANT is a later concern.)
 */
#include <errno.h>
#include <sys/stat.h>
#include "bare_rt.h"

extern char _heap_start[], _heap_end[];

void *_sbrk(int incr)
{
    static char *brk;
    if (!brk) brk = _heap_start;
    if (brk + incr > _heap_end) { errno = ENOMEM; return (void *)-1; }
    char *p = brk; brk += incr; return p;
}

int _write(int fd, char *buf, int len)
{
    if (fd == 1 || fd == 2) {
        int rem = len; const char *p = buf;
        while (rem > 0) { int c = rem > 200 ? 200 : rem; rt_write(p, c); p += c; rem -= c; }
        return len;
    }
    errno = EBADF; return -1;
}

int _read(int fd, char *buf, int len)
{
    if (fd != 0) { errno = EBADF; return -1; }
    int n = 0;
    while (n < len) { int c = sh_readc(); if (c < 0) break; buf[n++] = (char)c; if (c == '\n') break; }
    return n;
}

void _exit(int code) { sh_exit(code); for (;;) {} }
int  _close(int fd) { (void)fd; return -1; }
int  _lseek(int fd, int off, int whence) { (void)fd; (void)off; (void)whence; return 0; }
int  _fstat(int fd, struct stat *st) { (void)fd; st->st_mode = S_IFCHR; return 0; }
int  _isatty(int fd) { (void)fd; return 1; }
int  _kill(int pid, int sig) { (void)pid; (void)sig; errno = EINVAL; return -1; }
int  _getpid(void) { return 1; }
