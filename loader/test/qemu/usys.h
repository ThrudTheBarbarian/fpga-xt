/*
 * usys.h — user-side syscall stubs (the support/arm9/lib harness, in miniature).
 * Reaches the kernel via `svc #1`: number in r7, args r0-r5, return r0.
 */
#ifndef USYS_H
#define USYS_H

#include <stdint.h>  /* uint16_t etc. — some wrappers pack args; be self-contained */
#include "xtsys.h"   /* syscall numbers — one source of truth (frozen ABI) */

/* the OS display-plane descriptor (filled by SYS_fb_info) */
struct os_fbinfo { int w, h, stride; unsigned long addr; };

/* spawn_fd aux: the fds[4] the kernel already reads, plus the env array to hand
 * the child (SYS_spawn_fd's da2 points here — kernel reads envp at offset 16) and
 * an optional cwd for the child (offset 20 — set by a vfork-window chdir; NULL =
 * inherit the spawner's cwd). Keeps the child's cwd/env off the PARENT. */
struct xt_spawn_aux { int fds[4]; char **envp; const char *cwd; };

static inline long __syscall(long n, long a0, long a1, long a2)
{
    long ret;
    do {
        register long r7 __asm__("r7") = n;
        register long r0 __asm__("r0") = a0;
        register long r1 __asm__("r1") = a1;
        register long r2 __asm__("r2") = a2;
        __asm__ volatile("svc #1" : "+r"(r0) : "r"(r7), "r"(r1), "r"(r2) : "memory");
        ret = r0;
        /* SA_RESTART: the kernel ran the handler on this return and asks us to
         * re-issue the interrupted syscall. Only ever seen when the delivered
         * handler set SA_RESTART, so plain (non-restart) EINTR still falls
         * through as -4. */
    } while (ret == XT_ERESTARTSYS);
    return ret;
}

static inline long sys_write(int fd, const void *buf, unsigned len)
{ return __syscall(SYS_write, fd, (long)buf, (long)len); }
/* append to the kernel diagnostic log (dmesg / /proc/kmsg + system.log) — for
 * boot daemons that shouldn't clutter the console */
static inline long sys_klog(const void *buf, unsigned len)
{ return __syscall(SYS_klog, (long)buf, (long)len, 0); }
/* DEBUG peek/poke of a 32-bit physical word (kernel does the access) — /bin/mem */
static inline long sys_devmem(unsigned long addr, unsigned long val, int write)
{ return __syscall(SYS_devmem, (long)addr, (long)val, (long)write); }
static inline long sys_getpid(void) { return __syscall(SYS_getpid, 0, 0, 0); }
/* drain one pending XTOS system message into msg[8] (int16). 1 = filled, 0 = none.
 * GUI apps loop this each evnt_multi (see gem/aes) -> surfaced as AES MU_MESAG. */
static inline long sys_xtos_recv(void *msg8) { return __syscall(SYS_xtos_recv, (long)msg8, 0, 0); }
static inline long sys_spawn(const char *path, int argc, char **argv)
{ return __syscall(SYS_spawn, (long)path, argc, (long)argv); }
static inline long sys_waitpid(int pid) { return __syscall(SYS_waitpid, pid, 0, 0); }
/* poll (WNOHANG): -11 = still running, else reaps + returns the exit code */
static inline long sys_waitpid_nb(int pid) { return __syscall(SYS_waitpid, pid, XT_WAIT_NB, 0); }
/* non-reaping "did this child exit?" probe: 1 exited, 0 running, -1 gone */
static inline long sys_waitpid_peek(int pid) { return __syscall(SYS_waitpid, pid, XT_WAIT_PEEK, 0); }
/* set/clear this process's syscall-trace flag (children inherit) -> dmesg */
static inline long sys_strace(int on) { return __syscall(SYS_strace, on, 0, 0); }
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
static inline long sys_spawn_fd_cwd(const char *path, char **argv, const int fds[4],
                                    char **envp, const char *cwd)
{
    struct xt_spawn_aux aux = { { fds[0], fds[1], fds[2], fds[3] }, envp, cwd };
    return __syscall(SYS_spawn_fd, (long)path, (long)argv, (long)&aux);
}
/* cwd=NULL (inherit the spawner's) — the common case; the vfork/exec path uses
 * sys_spawn_fd_cwd to hand the child a recorded chdir target. */
static inline long sys_spawn_fd(const char *path, char **argv, const int fds[4], char **envp)
{ return sys_spawn_fd_cwd(path, argv, fds, envp, (const char *)0); }
/* duplicate a pipe end onto a chosen fd slot (refcounted) */
static inline long sys_dup2(int oldfd, int newfd)
{ return __syscall(SYS_dup2, oldfd, newfd, 0); }
/* sig 0 probes existence; anything else kills at the next syscall boundary */
static inline long sys_kill(int pid, int sig) { return __syscall(SYS_kill, pid, sig, 0); }
static inline char **sys_envp(void) { return (char **)__syscall(SYS_envp, 0, 0, 0); }
static inline long sys_reboot(int cmd) { return __syscall(SYS_reboot, cmd, 0, 0); }
static inline long sys_fstat(int fd, struct xt_stat *st)
{ return __syscall(SYS_fstat, fd, (long)st, 0); }
/* filesystem capacity: out[0]=total sectors, out[1]=free sectors, out[2]=sector bytes */
static inline long sys_statfs(const char *path, unsigned out[3])
{ return __syscall(SYS_statfs, (long)path, (long)out, 0); }
/* batch dir read: fill buf (>= 4096 bytes) with packed {mode,size,mtime,namelen,name}
 * records from entry `index` onward -> record count (0 = end, -1 = not batch-enumerable) */
static inline long sys_getdents(const char *path, int index, void *buf)
{ return __syscall(SYS_getdents, (long)path, index, (long)buf); }
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
/* datagram recv with source: a[0]=buflen in, a[1]=src ip_be out, a[2]=src port out */
static inline long sys_recvfrom(int fd, void *buf, unsigned a[3])
{ return __syscall(SYS_recvfrom, fd, (long)buf, (long)a); }
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
static inline long sys_nanosleep(unsigned usec) { return __syscall(SYS_nanosleep, (long)usec, 0, 0); }
static inline long sys_fb_info(struct os_fbinfo *fi) { return __syscall(SYS_fb_info, (long)fi, 0, 0); }
static inline long sys_fb_present(void) { return __syscall(SYS_fb_present, 0, 0, 0); }
/* OS-owned desk-sized WM backdrop buffer (WALLPAPER_BASE region — no process-heap
 * cost); wrap fi->addr as a gfx_surface and decode the wallpaper into it. */
static inline long sys_fb_wallpaper(struct os_fbinfo *fi) { return __syscall(SYS_fb_wallpaper, (long)fi, 0, 0); }
/* Place the XL emulation plane at an on-screen rect (the emulator window's work
 * area); scale = 1..5 integer zoom, 0 = hide the plane. */
static inline long sys_xl_window(int x, int y, int w, int h, int scale) {
    return __syscall(SYS_xl_window, ((long)x << 16) | (uint16_t)y,
                     ((long)w << 16) | (uint16_t)h, scale);
}
/* Place/hide the drag-overlay plane (pixels pre-copied into DRAG_BASE by the
 * client).  Move a lifted window by re-calling with new x/y — no redraw. en=0 hides. */
static inline long sys_overlay(int x, int y, int w, int h, int en) {
    return __syscall(SYS_overlay, ((long)x << 16) | (uint16_t)y,
                     ((long)w << 16) | (uint16_t)h, en);
}
/* Block for the next input event (mouse/keyboard); timeout_ms < 0 = forever.  The
 * cursor sprite is moved kernel-side; `ev` is filled with the event. */
/* raw = 1: Enter/Space stay KEY events (typing into an emulator window) instead
 * of synthesizing mouse clicks; terminal-mouse reports still decode either way. */
static inline long sys_input(struct os_event *ev, int timeout_ms, int raw) { return __syscall(SYS_input, (long)ev, timeout_ms, raw); }
/* Inject one ASCII keystroke into the 6502's POKEY (Ctrl-C = Atari BREAK). */
static inline long sys_kbd_6502(int c) { return __syscall(SYS_kbd_6502, c, 0, 0); }

#endif
