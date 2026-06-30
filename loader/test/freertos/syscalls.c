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

/* libc.so's syscall primitives. libc runs in the calling program's context — now
 * USER mode (PL0) — so any call that touches kernel state (console, the fd table,
 * the heap break) must TRAP to PL1 via svc #1, where do_syscall runs it privileged.
 * (Once AP enforcement lands in 3c, a direct call into the kernel from PL0 would
 * fault; these stubs are the user/kernel gateway.) Pure stubs that touch no kernel
 * state stay plain functions. */
static inline long sc(long n, long a0, long a1, long a2)
{
    register long r7 __asm__("r7") = n;
    register long r0 __asm__("r0") = a0;
    register long r1 __asm__("r1") = a1;
    register long r2 __asm__("r2") = a2;
    __asm__ volatile("svc #1" : "+r"(r0) : "r"(r7), "r"(r1), "r"(r2) : "memory");
    return r0;
}

int   _write(int fd, char *buf, int len)         { return (int)sc(SYS_write, fd, (long)buf, len); }
int   _read(int fd, char *buf, int len)          { return (int)sc(SYS_read, fd, (long)buf, len); }
int   _open(const char *path, int flags, int m)  { (void)m; return (int)sc(SYS_open, (long)path, flags, 0); }
int   _close(int fd)                             { return (int)sc(SYS_close, fd, 0, 0); }
int   _lseek(int fd, int off, int whence)        { return (int)sc(SYS_lseek, fd, off, whence); }
int   _getpid(void)                              { return (int)sc(SYS_getpid, 0, 0, 0); }

/* _sbrk is called by libc malloc from BOTH programs (PL0) and the kernel/boot
 * (PL1 — main() runs in SVC mode, where a nested svc would clobber lr_svc). So
 * trap to PL1 only when actually unprivileged; otherwise call the impl directly. */
extern void *sys_sbrk(int incr);
void *_sbrk(int incr)
{
    unsigned m; __asm__ volatile("mrs %0, cpsr" : "=r"(m));
    if ((m & 0x1fu) == 0x10u) return (void *)sc(SYS_sbrk, incr, 0, 0);  /* User mode -> trap */
    return sys_sbrk(incr);                                              /* privileged -> direct */
}

void _exit(int code) { sc(SYS_exit, code, 0, 0); for (;;) {} }
void abort(void) { _exit(99); }   /* referenced by libgcc unwind */

/* stubs that touch NO kernel state — safe to run at PL0 directly (they sit in
 * kernel text, which stays PL0-executable; they never read kernel data). */
int _fstat(int fd, void *st) { (void)fd; (void)st; return -1; }   /* newlib falls back to a default buffer */
int _isatty(int fd) { return fd < 3; }                            /* 0/1/2 are the console */
int _stat(const char *p, void *st) { (void)p; (void)st; return -1; }
int _kill(int pid, int sig) { (void)pid; (void)sig; return -1; }
int _gettimeofday(void *tv, void *tz) { (void)tz; return tv ? (int)sc(SYS_gettimeofday, (long)tv, 0, 0) : -1; }
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
