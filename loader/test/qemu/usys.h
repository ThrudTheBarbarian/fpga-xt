/*
 * usys.h — user-side syscall stubs (the support/arm9/lib harness, in miniature).
 * Reaches the kernel via `svc #1`: number in r7, args r0-r5, return r0.
 */
#ifndef USYS_H
#define USYS_H

#include "xtsys.h"   /* syscall numbers — one source of truth (frozen ABI) */

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
static inline long sys_spawn(const char *path, int argc, char **argv)
{ return __syscall(SYS_spawn, (long)path, argc, (long)argv); }
static inline long sys_waitpid(int pid) { return __syscall(SYS_waitpid, pid, 0, 0); }
static inline void sys_exit(int code) { __syscall(SYS_exit, code, 0, 0); for (;;) {} }
static inline long sys_open(const char *path, int flags)
{ return __syscall(SYS_open, (long)path, flags, 0); }
static inline long sys_read(int fd, void *buf, unsigned len)
{ return __syscall(SYS_read, fd, (long)buf, (long)len); }
static inline long sys_close(int fd) { return __syscall(SYS_close, fd, 0, 0); }
static inline long sys_lseek(int fd, long off, int whence)
{ return __syscall(SYS_lseek, fd, off, whence); }
/* mmap a romfs file read-only + shared (len=0 -> whole file from off). Returns a
 * pointer to the file's bytes (no copy), or NULL. */
static inline void *sys_mmap(int fd, unsigned len, unsigned off)
{ long r = __syscall(SYS_mmap, fd, (long)len, (long)off); return r > 0 ? (void *)r : (void *)0; }
static inline long sys_munmap(void *addr, unsigned len)
{ return __syscall(SYS_munmap, (long)addr, (long)len, 0); }
/* shared memory: create an object (-> id), map it PL0-RW into this process (-> ptr).
 * Same VA in every mapper, so the id is enough to share; freed when the last mapper exits. */
static inline int   sys_shm_create(unsigned size) { return (int)__syscall(SYS_shm_create, (long)size, 0, 0); }
static inline void *sys_shm_map(int id) { long r = __syscall(SYS_shm_map, id, 0, 0); return r ? (void *)r : (void *)0; }
static inline long sys_fb_info(struct os_fbinfo *fi) { return __syscall(SYS_fb_info, (long)fi, 0, 0); }
static inline long sys_fb_present(void) { return __syscall(SYS_fb_present, 0, 0, 0); }
/* OS-owned desk-sized WM backdrop buffer (WALLPAPER_BASE region — no process-heap
 * cost); wrap fi->addr as a gfx_surface and decode the wallpaper into it. */
static inline long sys_fb_wallpaper(struct os_fbinfo *fi) { return __syscall(SYS_fb_wallpaper, (long)fi, 0, 0); }

#endif
