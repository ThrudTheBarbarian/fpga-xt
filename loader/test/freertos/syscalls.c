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
#include "frtos_os.h"
#include "xtsys.h"

/* _sbrk hands out the OS heap; its base is set just above libc.so's pinned image
 * once libc.so is loaded (sbrk_set_base), its end is the top of the heap. */
static char *g_brk, *g_brk_end;
void sbrk_set_base(void *base, void *end) { g_brk = base; g_brk_end = end; }

/* the kernel/boot heap. Grows UP from libc.so's image; its ceiling is the page
 * pool's frontier (vm_page_floor), which grows DOWN from the top of DDR — the two
 * meet in the middle, sharing one ~480 MB arena (docs/Zynq/memory-map.md). The
 * check+update runs under a short IRQ-masked critical section so it can't race the
 * page allocator running in a data-abort handler on the same core. libc.so's
 * exported _sbrk (frtos_os.c) delegates here for the kernel; processes get a
 * private heap. */
uint32_t kern_heap_top(void) { return (uint32_t)g_brk; }

void *kern_sbrk(int incr)
{
    if (!g_brk) return (void *)-1;
    uint32_t ceil = vm_page_floor();
    if (g_brk_end && (uint32_t)g_brk_end < ceil) ceil = (uint32_t)g_brk_end;  /* absolute cap */
    unsigned f = xt_irq_save();
    char *p = g_brk;
    if ((uint32_t)(p + incr) > ceil) { xt_irq_restore(f); return (void *)-1; }
    g_brk = p + incr;
    xt_irq_restore(f);
    return p;
}

/* _write is libc.so's console output. It runs in the calling program's context —
 * which is now USER mode (PL0) — so it must NOT do the semihosting/console write
 * directly (that has to happen privileged): trap to PL1 via svc #1, where
 * do_syscall(SYS_write) drives g_console. (The romfs file ops below don't touch
 * privileged state, so they stay direct calls.) */
int _write(int fd, char *buf, int len)
{
    register long r7 __asm__("r7") = SYS_write;
    register long r0 __asm__("r0") = fd;
    register long r1 __asm__("r1") = (long)buf;
    register long r2 __asm__("r2") = len;
    __asm__ volatile("svc #1" : "+r"(r0) : "r"(r7), "r"(r1), "r"(r2) : "memory");
    return (int)r0;
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

/* libc.so's exit path runs at PL0 — trap to PL1 (svc #1 SYS_exit), which deletes
 * the task. (sh_exit's semihosting would be a no-op from User mode.) */
void _exit(int code)
{
    register long r7 __asm__("r7") = SYS_exit;
    register long r0 __asm__("r0") = code;
    __asm__ volatile("svc #1" : "+r"(r0) : "r"(r7) : "memory");
    for (;;) {}
}
void abort(void) { _exit(99); }   /* referenced by libgcc unwind */

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
