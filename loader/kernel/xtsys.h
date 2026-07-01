/*
 * xtsys.h — XTOS syscall ABI (the FROZEN contract). Shared by the kernel
 * dispatch and the user-side libc stubs, and the spec the xtc compiler targets.
 *
 * Gateway: `svc #1` — number in r7, args r0-r5, return in r0 (r1:r0 for 64-bit).
 * A return in [-4095, -1] is -errno.
 *
 * Class blocks of 0x100 (docs/OS/dynamic-loading.md §8). EXISTING NUMBERS ARE
 * FROZEN — never renumber; a new call takes the next free slot in its block.
 * Reserved blocks: 0x500 registry/service, 0x700 input/events, 0x800 networking,
 * 0x900 debug, 0xA00-0xF00 spare.
 */
#ifndef XTSYS_H
#define XTSYS_H

#define XTOS_ABI_VERSION 1

/* meta — block 0x000 */
#define SYS_abi_version  0x000   /* () -> ABI version (currently 1) */

/* process / task — block 0x100 */
#define SYS_spawn    0x100   /* (path, argc, argv) -> pid */
#define SYS_exit     0x101   /* (code) -> no return */
#define SYS_waitpid  0x102   /* (pid) -> exit_code */
#define SYS_getpid   0x103   /* () -> pid */

/* memory — block 0x200 */
#define SYS_mmap     0x200   /* (fd, len, off) -> VA: map a file RO + shared, demand-paged */
#define SYS_munmap   0x201   /* (addr, len) -> 0 */
#define SYS_sbrk     0x202   /* (incr) -> old break: grow the per-process heap (libc malloc) */
#define SYS_shm_create 0x203 /* (size) -> id: allocate a shared-memory object */
#define SYS_shm_map    0x204 /* (id) -> VA: map an shm object PL0-RW into this process */

/* filesystem / VFS — block 0x300 */
#define SYS_open     0x300   /* (path, flags) -> fd */
#define SYS_close    0x301   /* (fd) -> 0 */
#define SYS_read     0x302   /* (fd, buf, len) -> n */
#define SYS_write    0x303   /* (fd, buf, len) -> n */
#define SYS_lseek    0x304   /* (fd, off, whence) -> pos */

/* time / timers — block 0x400. Peripherals are PL1-only, so libc's _gettimeofday
 * traps here; the kernel reads the A9 global timer (wall clock since boot — no RTC). */
#define SYS_gettimeofday 0x400 /* (struct timeval *tv) -> 0: fills {tv_sec, tv_usec} */

/* graphics / compositor — block 0x600. The OS owns the display plane; apps query
 * its descriptor and draw into it, then present (compositor on HW, ASCII on qemu). */
#define SYS_fb_info    0x600   /* (struct os_fbinfo *) -> 0 */
#define SYS_fb_present 0x601   /* () -> 0  (present the plane) */

#endif
