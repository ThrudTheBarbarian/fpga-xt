/*
 * usys.h — user-side syscall stubs (the support/arm9/lib harness, in miniature).
 * Reaches the kernel via `svc #1`: number in r7, args r0-r5, return r0.
 */
#ifndef USYS_H
#define USYS_H

#define SYS_exit    0x101
#define SYS_getpid  0x103
#define SYS_write   0x303

static inline long __syscall(long n, long a0, long a1, long a2)
{
    register long r7 __asm__("r7") = n;
    register long r0 __asm__("r0") = a0;
    register long r1 __asm__("r1") = a1;
    register long r2 __asm__("r2") = a2;
    __asm__ volatile("svc #1" : "+r"(r0) : "r"(r7), "r"(r1), "r"(r2) : "memory");
    return r0;
}

static inline long sys_write(int fd, const void *buf, unsigned len)
{ return __syscall(SYS_write, fd, (long)buf, (long)len); }
static inline long sys_getpid(void) { return __syscall(SYS_getpid, 0, 0, 0); }
static inline void sys_exit(int code) { __syscall(SYS_exit, code, 0, 0); for (;;) {} }

#endif
