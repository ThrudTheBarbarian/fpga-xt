/*
 * usys.h — user-side syscall stubs (the support/arm9/lib harness, in miniature).
 * Reaches the kernel via `svc #1`: number in r7, args r0-r5, return r0.
 */
#ifndef USYS_H
#define USYS_H

#define SYS_exit    0x101
#define SYS_getpid  0x103
#define SYS_open    0x300
#define SYS_close   0x301
#define SYS_read    0x302
#define SYS_write   0x303
#define SYS_lseek   0x304
#define SYS_fb_info    0x400
#define SYS_fb_present 0x401

/* the OS display-plane descriptor (filled by SYS_fb_info) */
struct os_fbinfo { int w, h, stride; unsigned long addr; };

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
static inline long sys_open(const char *path, int flags)
{ return __syscall(SYS_open, (long)path, flags, 0); }
static inline long sys_read(int fd, void *buf, unsigned len)
{ return __syscall(SYS_read, fd, (long)buf, (long)len); }
static inline long sys_close(int fd) { return __syscall(SYS_close, fd, 0, 0); }
static inline long sys_lseek(int fd, long off, int whence)
{ return __syscall(SYS_lseek, fd, off, whence); }
static inline long sys_fb_info(struct os_fbinfo *fi) { return __syscall(SYS_fb_info, (long)fi, 0, 0); }
static inline long sys_fb_present(void) { return __syscall(SYS_fb_present, 0, 0, 0); }

#endif
