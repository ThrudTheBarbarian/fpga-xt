/*
 * syscalls.c — the bounded syscall-primitive surface the kernel EXPORTS to
 * libc.so (which owns malloc/stdio/...). The kernel itself is -nostdlib (its own
 * bare_libc); these are the newlib-level `_foo` that the loaded libc.so imports
 * via the kernel export table. No errno here — libc.so has its own; failures
 * just return -1.
 */
#include <stdint.h>
#include "bare_rt.h"
#include "romfs.h"

/* _sbrk hands out the OS heap; its base is set just above libc.so's pinned image
 * once libc.so is loaded (sbrk_set_base), its end is the top of the heap. */
static char *g_brk, *g_brk_end;
void sbrk_set_base(void *base, void *end) { g_brk = base; g_brk_end = end; }

/* the kernel/boot heap (shared pool above libc.so's image). libc.so's exported
 * _sbrk (frtos_os.c) delegates here for the kernel; processes get a private heap. */
void *kern_sbrk(int incr)
{
    if (!g_brk || g_brk + incr > g_brk_end) return (void *)-1;
    char *p = g_brk; g_brk += incr; return p;
}

int _write(int fd, char *buf, int len)
{
    if (fd == 1 || fd == 2) {
        int r = len; const char *p = buf;
        while (r > 0) { int c = r > 200 ? 200 : r; rt_write(p, c); p += c; r -= c; }
        return len;
    }
    return -1;
}

/* romfs-backed file descriptors for libc.so's fopen/fread/fseek (e.g. FreeType
 * loading a font). fds 0/1/2 are the console; 3+ index this table. Read-only.
 * _fstat stays a stub — newlib falls back to a default-size buffer. */
#define SEEK_SET 0
#define SEEK_CUR 1
#define SEEK_END 2
#define NFILES 8
static struct { int used; const uint8_t *data; uint32_t size, pos; } g_fd[NFILES];
static int fdx(int fd) { return (fd >= 3 && fd < 3 + NFILES && g_fd[fd - 3].used) ? fd - 3 : -1; }

int _open(const char *path, int flags, int mode)
{
    (void)flags; (void)mode;
    const uint8_t *d; uint32_t sz;
    if (!romfs_lookup(path, &d, &sz)) return -1;
    for (int i = 0; i < NFILES; i++)
        if (!g_fd[i].used) { g_fd[i] = (typeof(g_fd[i])){1, d, sz, 0}; return 3 + i; }
    return -1;
}

int _read(int fd, char *buf, int len)
{
    if (fd == 0) {                              /* stdin (semihosting) */
        int n = 0;
        while (n < len) { int c = sh_readc(); if (c < 0) break; buf[n++] = (char)c; if (c == '\n') break; }
        return n;
    }
    int i = fdx(fd); if (i < 0) return -1;
    uint32_t rem = g_fd[i].size - g_fd[i].pos;
    uint32_t k = (uint32_t)len < rem ? (uint32_t)len : rem;
    for (uint32_t j = 0; j < k; j++) buf[j] = (char)g_fd[i].data[g_fd[i].pos + j];
    g_fd[i].pos += k;
    return (int)k;
}

int _lseek(int fd, int off, int whence)
{
    int i = fdx(fd); if (i < 0) return -1;
    long p = whence == SEEK_CUR ? (long)g_fd[i].pos + off
           : whence == SEEK_END ? (long)g_fd[i].size + off : off;
    if (p < 0) p = 0;
    if (p > (long)g_fd[i].size) p = (long)g_fd[i].size;
    g_fd[i].pos = (uint32_t)p;
    return (int)p;
}

int _close(int fd) { int i = fdx(fd); if (i < 0) return -1; g_fd[i].used = 0; return 0; }

void _exit(int code) { sh_exit(code); for (;;) {} }
void abort(void) { sh_exit(99); for (;;) {} }   /* referenced by libgcc unwind */

int _fstat(int fd, void *st) { (void)fd; (void)st; return -1; }
int _isatty(int fd) { (void)fd; return fdx(fd) < 0 && fd < 3; }   /* console fds only */
int _stat(const char *p, void *st) { (void)p; (void)st; return -1; }
int _kill(int pid, int sig) { (void)pid; (void)sig; return -1; }
int _getpid(void) { return 1; }
int _gettimeofday(void *tv, void *tz) { (void)tv; (void)tz; return -1; }
int _times(void *buf) { (void)buf; return -1; }
int _link(const char *a, const char *b) { (void)a; (void)b; return -1; }
int _unlink(const char *p) { (void)p; return -1; }
int _fork(void) { return -1; }
int _execve(const char *p, char *const a[], char *const e[]) { (void)p; (void)a; (void)e; return -1; }
int _fcntl(int fd, int cmd, int arg) { (void)fd; (void)cmd; (void)arg; return -1; }
int _getentropy(void *buf, unsigned n) { (void)buf; (void)n; return -1; }
int _mkdir(const char *p, int m) { (void)p; (void)m; return -1; }
void _init(void) {}
void _fini(void) {}
int _jp2uc_l(int c, void *l) { (void)l; return c; }   /* JIS<->Unicode: no-op */
int _uc2jp_l(int c, void *l) { (void)l; return c; }
int _wait(int *st) { (void)st; return -1; }
/* libc.so references these but this newlib multilib didn't define them; never
 * called in practice — stub so the dynamic load resolves. */
int  regcomp(void *a, const void *b, int c) { (void)a; (void)b; (void)c; return -1; }
int  regexec(const void *a, const void *b, unsigned n, void *m, int e) { (void)a; (void)b; (void)n; (void)m; (void)e; return -1; }
void regfree(void *a) { (void)a; }
int  sigprocmask(int h, const void *s, void *o) { (void)h; (void)s; (void)o; return -1; }
