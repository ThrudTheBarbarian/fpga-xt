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
/* sized peek/poke: size = 1/2/4 bytes. The kernel does the access (PL1), so an
 * unaligned Device cell (the SALLY ROM window, sub-word GP0 regs) works. */
static inline long sys_devmem_sz(unsigned long addr, unsigned long val, int write, int size)
{ return __syscall(SYS_devmem, (long)addr, (long)val, (long)((write & 1) | ((size & 0xFF) << 8))); }
static inline long sys_getpid(void) { return __syscall(SYS_getpid, 0, 0, 0); }
/* grab the on-screen frame of HW compositor plane `plane` (XT_PLANE_*) into buf
 * (>= 320*192*4 for the XL/6502 plane); returns (w<<16)|h or -errno. See SYS_plane_grab. */
/* Arm/disarm the CONTINUOUS 6502 trace ring (SYS_trace_ring).  Pass an
 * XT_SHM_CONTIG shm id and ena=1; the kernel resolves the id to a physical base
 * itself -- userland never sees or needs the address.  Returns the usable ring
 * size in bytes (a power of two, rounded DOWN from the allocation), or -errno.
 * Unlike the older halting ring this never stops the core, so it can observe
 * things that are timing-coupled to the outside world. */
/* How long the paravirtual SIOV service pretends to take.  baud 0 = answer
 * immediately (default); 19200 = a real 1050.  Per title, because authentic
 * timing costs authentic load times -- see SYS_sio_timing in xtsys.h. */
static inline long sys_sio_timing(unsigned baud, unsigned latency_us)
{ return __syscall(SYS_sio_timing, (long)baud, (long)latency_us, 0); }

static inline long sys_trace_ring(int shm_id, int ena)
{ return __syscall(SYS_trace_ring, shm_id, ena, 0); }

static inline long sys_plane_grab(int plane, void *buf)
{ return __syscall(SYS_plane_grab, plane, (long)buf, 0); }
/* drain one pending XTOS system message into msg[8] (int16). 1 = filled, 0 = none.
 * GUI apps loop this each evnt_multi (see gem/aes) -> surfaced as AES MU_MESAG. */
static inline long sys_xtos_recv(void *msg8) { return __syscall(SYS_xtos_recv, (long)msg8, 0, 0); }
static inline long sys_spawn(const char *path, int argc, char **argv)
{ return __syscall(SYS_spawn, (long)path, argc, (long)argv); }

/* ---- threads (see xtsys.h's SYS_thread_* block) ---------------------------
 * `entry` runs at PL0 on its own stack and is handed `arg` in r0; returning from it
 * is SYS_thread_exit with that value. stack_bytes 0 = the default. */
static inline long sys_thread_create(void (*entry)(void *), void *arg, unsigned stack_bytes)
{ return __syscall(SYS_thread_create, (long)entry, (long)arg, (long)stack_bytes); }
static inline long sys_thread_exit(int retval)
{ return __syscall(SYS_thread_exit, retval, 0, 0); }
static inline long sys_thread_join(int tid, int *retval)
{ return __syscall(SYS_thread_join, tid, (long)retval, 0); }
static inline long sys_thread_detach(int tid)
{ return __syscall(SYS_thread_detach, tid, 0, 0); }
static inline long sys_thread_self(void) { return __syscall(SYS_thread_self, 0, 0, 0); }
/* set this thread's TLS block; the kernel keeps it in TPIDRURW across switches, so
 * reads need no syscall at all — see sys_tls_get. */
static inline long sys_thread_tls(void *p) { return __syscall(SYS_thread_tls, (long)p, 0, 0); }
static inline void *sys_tls_get(void)
{ void *v; __asm__ volatile("mrc p15,0,%0,c13,c0,2" : "=r"(v)); return v; }
/* block while *uaddr == val (the compare and the enqueue are atomic against wake,
 * so there is no lost-wakeup window). timeout_ms < 0 = forever. */
static inline long sys_futex_wait(volatile unsigned *uaddr, unsigned val, long timeout_ms)
{ return __syscall(SYS_futex_wait, (long)uaddr, (long)val, timeout_ms); }
static inline long sys_futex_wake(volatile unsigned *uaddr, int n)
{ return __syscall(SYS_futex_wake, (long)uaddr, n, 0); }
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
/* the kernel CSPRNG -> bytes written, or -errno (-EIO = the TRNG never went
 * fresh; the clock-seeded bytes you would otherwise get are offered only to a
 * caller who asks with GRND_NONBLOCK and so knows what they are taking) */
static inline long sys_getrandom(void *buf, unsigned len, unsigned flags)
{ return __syscall(SYS_getrandom, (long)buf, (long)len, (long)flags); }
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
 * Same VA in every mapper, so the id is enough to share; freed when the last mapper exits.
 * flags: XT_SHM_* (xtsys.h); 0 = the classic pool-backed object. Unknown bits are REJECTED
 * (-1), never ignored — a program built for a newer flag set fails loudly on an older
 * kernel rather than silently getting memory with different properties. */
/* ---- services + poll (block 0x500) -----------------------------------------
 * Deliberately BSD-shaped: register == bind+listen, then connect/accept, then plain
 * read()/write()/close()/poll() on the returned fd. A channel fd is bidirectional.
 * A dead peer shows up as EOF on read (and XT_POLLHUP), which works even when the peer
 * is nobody's child -- unlike SIGCHLD. */
static inline int sys_svc_register(const char *name)   /* -> listen fd */
{ return (int)__syscall(SYS_svc_register, (long)name, 0, 0); }
static inline int sys_svc_connect(const char *name)    /* -> channel fd */
{ return (int)__syscall(SYS_svc_connect, (long)name, 0, 0); }
static inline int sys_svc_accept(int lfd)              /* -> channel fd; blocks. accept(2) for
                                                       * services -- sys_accept() is already
                                                       * taken by the lwIP socket path. */
{ return (int)__syscall(SYS_svc_accept, lfd, 0, 0); }
static inline int sys_poll(struct xt_pollfd *fds, int nfds, int timeout_ms)
{ return (int)__syscall(SYS_poll, (long)fds, nfds, timeout_ms); }
/* the pid at the other end of a channel fd (-1 if it isn't one). The kernel knows who
 * connected, so a server can act on a peer identity the peer cannot forge — which is what
 * lets gemd grant a surface capability to exactly the client that asked for the window. */
static inline int sys_chan_peer(int fd) { return (int)__syscall(SYS_chan_peer, fd, 0, 0); }

static inline int   sys_shm_create(unsigned size, unsigned flags)
{ return (int)__syscall(SYS_shm_create, (long)size, (long)flags, 0); }
static inline void *sys_shm_map(int id) { long r = __syscall(SYS_shm_map, id, 0, 0); return r ? (void *)r : (void *)0; }
/* drop this process's mapping + ref; the object is freed when the last mapper drops it.
 * A stale pointer into an unmapped surface FAULTS — it does not silently read whatever is
 * mapped there next. 0 on success, -1 if this process had it not mapped. */
static inline long sys_shm_unmap(int id) { return __syscall(SYS_shm_unmap, id, 0, 0); }
/* Owner-only: let process `pid` map this XT_SHM_OWNED object. An id is otherwise just a
 * number — this is what makes it a capability (a gemd surface is created XT_SHM_OWNED and
 * granted to the one client that asked for the window; no other client can map it). */
static inline long sys_shm_grant(int id, int pid) { return __syscall(SYS_shm_grant, id, pid, 0); }
static inline long sys_settime(unsigned unix_sec) { return __syscall(SYS_settime, (long)unix_sec, 0, 0); }
static inline long sys_nanosleep(unsigned usec) { return __syscall(SYS_nanosleep, (long)usec, 0, 0); }
/* init(1) only: "every boot script has run" — releases the kernel's shell_task to start the
 * login shell. init then goes resident as the reaper, so it must SAY it is done; it can never
 * signal that by exiting. */
static inline long sys_boot_done(void) { return __syscall(SYS_boot_done, 0, 0, 0); }
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
/* M6: place HW compositor plane `plane` (XT_PLANE_*) at a screen rect, integer zoom
 * `scale` 1..5; en=0 parks it off-screen. x/y may be negative (a window dragged past
 * an edge) — the kernel clips. First active plane flips the compositor to the Route-A
 * arrangement (desktop on top with alpha: an alpha=0 area reveals the plane below). */
/* Cold-boot the fabric 6502 with an ATR mounted as D<drive>: (the XL OS boots it
 * through the paravirtual SIO).  path=NULL = eject + cold boot to BASIC. */
static inline long sys_xl_boot(const char *path, int drive) {
    return __syscall(SYS_xl_boot, (long)path, drive, 0);
}
/* Cold-reset the fabric 6502 KEEPING mounted media (a real power-cycle, fresh OS
 * image): basic!=0 -> BASIC on; basic=0 -> OPTION held across the coldstart so
 * the XL OS maps BASIC out (auto-released once sampled). */
static inline long sys_xl_reset(int basic) {
    return __syscall(SYS_xl_reset, basic, 0, 0);
}
/* Run a standalone Atari executable (.xex / DOS binary) on the fabric 6502: the
 * kernel boots the XL OS with a 1-sector fake disk, then (as the host, via the
 * GP0 debug facility) loads the segments and drives the INIT/RUN vectors -- the
 * way atari800 does it.  flags {bit0=turbo, bit1=hold}: turbo core (else fidelity,
 * cycle-exact default); hold halts at acid800 _testEnd ($1D93) on the result screen. */
static inline long sys_xexload(const char *path, int flags) {
    return __syscall(SYS_xexload, (long)path, flags, 0);
}
static inline long sys_plane_window(int plane, int x, int y, int w, int h, int scale, int en) {
    return __syscall(SYS_plane_window,
                     ((long)plane << 16) | ((long)(scale & 0xFF) << 8) | (en ? 1 : 0),
                     ((long)(uint16_t)x << 16) | (uint16_t)y,
                     ((long)(uint16_t)w << 16) | (uint16_t)h);
}
/* Block for the next input event (mouse/keyboard); timeout_ms < 0 = forever.  The
 * cursor sprite is moved kernel-side; `ev` is filled with the event. */
/* raw = 1: Enter/Space stay KEY events (typing into an emulator window) instead
 * of synthesizing mouse clicks; terminal-mouse reports still decode either way. */
static inline long sys_input(struct os_event *ev, int timeout_ms, int raw) { return __syscall(SYS_input, (long)ev, timeout_ms, raw); }
/* Inject one ASCII keystroke into the 6502's POKEY (Ctrl-C = Atari BREAK). */
static inline long sys_kbd_6502(int c) { return __syscall(SYS_kbd_6502, c, 0, 0); }
static inline long sys_cursor_shape(int n) { return __syscall(SYS_cursor_shape, n, 0, 0); }

#endif
