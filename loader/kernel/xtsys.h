/*
 * xtsys.h — XTOS syscall numbers (the frozen ABI), shared by the kernel
 * dispatch and the user-side stubs. Numbers follow docs/OS/dynamic-loading.md
 * §8: class blocks of 0x100; reach the gateway via `svc #1` with the number in
 * r7, args in r0-r5, return in r0.
 */
#ifndef XTSYS_H
#define XTSYS_H

/* process / task — block 0x100 */
#define SYS_spawn    0x100
#define SYS_exit     0x101
#define SYS_waitpid  0x102
#define SYS_getpid   0x103

/* filesystem / VFS — block 0x300 */
#define SYS_open     0x300
#define SYS_close    0x301
#define SYS_read     0x302
#define SYS_write    0x303
#define SYS_lseek    0x304
#define SYS_mmap     0x305   /* (fd, len, off) -> VA: map a file RO + shared, demand-paged */
#define SYS_munmap   0x306   /* (addr, len) -> 0 */
#define SYS_sbrk     0x307   /* (incr) -> old break: grow the per-process heap (libc malloc) */

/* graphics / display — block 0x400. The OS owns the display plane; apps query
 * its descriptor and draw into it, then present (compositor on HW, ASCII on qemu) */
#define SYS_fb_info    0x400   /* (struct os_fbinfo *) -> 0 */
#define SYS_fb_present  0x401  /* () -> 0  (flush the plane to the display) */

/* time / clock — block 0x500. Peripherals are PL1-only, so libc's _gettimeofday
 * traps here; the kernel reads the A9 global timer (wall clock since boot — no RTC). */
#define SYS_gettimeofday 0x500 /* (struct timeval *tv) -> 0: fills {tv_sec, tv_usec} */

#endif
