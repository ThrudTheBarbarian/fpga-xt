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
/* poll (WNOHANG): -11 = still running, else reaps + returns the exit code */
static inline long sys_waitpid_nb(int pid) { return __syscall(SYS_waitpid, pid, XT_WAIT_NB, 0); }
static inline void sys_exit(int code) { __syscall(SYS_exit, code, 0, 0); for (;;) {} }
static inline long sys_open(const char *path, int flags)
{ return __syscall(SYS_open, (long)path, flags, 0); }
static inline long sys_read(int fd, void *buf, unsigned len)
{ return __syscall(SYS_read, fd, (long)buf, (long)len); }
static inline long sys_close(int fd) { return __syscall(SYS_close, fd, 0, 0); }
static inline long sys_lseek(int fd, long off, int whence)
{ return __syscall(SYS_lseek, fd, off, whence); }
/* metadata + symlinks (block 0x300). stat follows symlinks, lstat does not. */
static inline long sys_stat(const char *path, struct xt_stat *st)
{ return __syscall(SYS_stat, (long)path, (long)st, 0); }
static inline long sys_lstat(const char *path, struct xt_stat *st)
{ return __syscall(SYS_lstat, (long)path, (long)st, 0); }
static inline long sys_readlink(const char *path, char *buf, unsigned size)
{ return __syscall(SYS_readlink, (long)path, (long)buf, (long)size); }
static inline long sys_symlink(const char *target, const char *linkpath)
{ return __syscall(SYS_symlink, (long)target, (long)linkpath, 0); }
static inline long sys_unlink(const char *path)
{ return __syscall(SYS_unlink, (long)path, 0, 0); }
/* enumerate a directory: index 0,1,2,... -> 1 (filled), 0 (end), -1 (err) */
static inline long sys_readdir(const char *path, int index, struct xt_dirent *ent)
{ return __syscall(SYS_readdir, (long)path, index, (long)ent); }
static inline long sys_mkdir(const char *path, int mode)
{ return __syscall(SYS_mkdir, (long)path, mode, 0); }
static inline long sys_chdir(const char *path) { return __syscall(SYS_chdir, (long)path, 0, 0); }
static inline long sys_getcwd(char *buf, unsigned size)
{ return __syscall(SYS_getcwd, (long)buf, (long)size, 0); }
static inline long sys_rename(const char *oldp, const char *newp)
{ return __syscall(SYS_rename, (long)oldp, (long)newp, 0); }
/* kernel pipe: fd[0]=read end, fd[1]=write end (see xtsys.h for semantics) */
static inline long sys_pipe(int fd[2]) { return __syscall(SYS_pipe, (long)fd, 0, 0); }
/* spawn with the child's stdio wired to parent fds (argv NULL-terminated; -1 = console).
 * fds[3] = do-NOT-inherit bitmask for the parent's other pipe fds (cloexec analogue);
 * pipe fds not masked out are inherited by the child at the SAME slot. */
static inline long sys_spawn_fd(const char *path, char **argv, const int fds[4])
{ return __syscall(SYS_spawn_fd, (long)path, (long)argv, (long)fds); }
/* duplicate a pipe end onto a chosen fd slot (refcounted) */
static inline long sys_dup2(int oldfd, int newfd)
{ return __syscall(SYS_dup2, oldfd, newfd, 0); }
/* sig 0 probes existence; anything else kills at the next syscall boundary */
static inline long sys_kill(int pid, int sig) { return __syscall(SYS_kill, pid, sig, 0); }
static inline long sys_reboot(int cmd) { return __syscall(SYS_reboot, cmd, 0, 0); }
static inline long sys_fstat(int fd, struct xt_stat *st)
{ return __syscall(SYS_fstat, fd, (long)st, 0); }
/* char-device controls (Linux request codes; see xtsys.h) */
static inline long sys_ioctl(int fd, unsigned req, void *argp)
{ return __syscall(SYS_ioctl, fd, (long)req, (long)argp); }
/* sockets (IPv4; ip = be32, port = host order; see xtsys.h block 0x320) */
static inline long sys_socket(int type) { return __syscall(SYS_socket, type, 0, 0); }
static inline long sys_connect(int fd, unsigned ip_be, unsigned port)
{ return __syscall(SYS_connect, fd, (long)ip_be, (long)port); }
static inline long sys_bind(int fd, unsigned ip_be, unsigned port)
{ return __syscall(SYS_bind, fd, (long)ip_be, (long)port); }
static inline long sys_listen(int fd, int backlog) { return __syscall(SYS_listen, fd, backlog, 0); }
static inline long sys_accept(int fd, unsigned peer[2])
{ return __syscall(SYS_accept, fd, (long)peer, 0); }
/* non-blocking accept (the select primitive): -2 = none pending right now */
static inline long sys_accept_nb(int fd, unsigned peer[2])
{ return __syscall(SYS_accept, fd, (long)peer, 1); }
static inline long sys_resolve(const char *name, unsigned *ip_be)
{ return __syscall(SYS_resolve, (long)name, (long)ip_be, 0); }
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
static inline long sys_settime(unsigned unix_sec) { return __syscall(SYS_settime, (long)unix_sec, 0, 0); }
static inline long sys_fb_info(struct os_fbinfo *fi) { return __syscall(SYS_fb_info, (long)fi, 0, 0); }
static inline long sys_fb_present(void) { return __syscall(SYS_fb_present, 0, 0, 0); }
/* OS-owned desk-sized WM backdrop buffer (WALLPAPER_BASE region — no process-heap
 * cost); wrap fi->addr as a gfx_surface and decode the wallpaper into it. */
static inline long sys_fb_wallpaper(struct os_fbinfo *fi) { return __syscall(SYS_fb_wallpaper, (long)fi, 0, 0); }
/* Block for the next input event (mouse/keyboard); timeout_ms < 0 = forever.  The
 * cursor sprite is moved kernel-side; `ev` is filled with the event. */
static inline long sys_input(struct os_event *ev, int timeout_ms) { return __syscall(SYS_input, (long)ev, timeout_ms, 0); }

#endif
