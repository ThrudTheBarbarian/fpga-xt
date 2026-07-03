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
#define SYS_waitpid  0x102   /* (pid, flags) -> exit_code. flags bit0 = poll (WNOHANG):
                              * child still running -> -11 (-EAGAIN), no blocking;
                              * exited -> reap + exit_code as usual */
#define XT_WAIT_NB   1       /* the poll flag */
#define SYS_getpid   0x103   /* () -> pid */
#define SYS_spawn_fd 0x104   /* (path, argv, int fds[3]) -> pid: argv is NULL-terminated
                              * (argc counted kernel-side); the child's fd 0/1/2 come
                              * from the parent's fds (pipe ends; -1 = inherit console) */
#define SYS_kill     0x105   /* (pid, sig) -> 0: sig 0 = existence probe; any other sig
                              * marks the process killed — it dies at its next syscall
                              * or blocking-wait tick (no handlers; soft-signal system) */

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
#define SYS_stat     0x305   /* (path, struct xt_stat *) -> 0: follows symlinks */
#define SYS_lstat    0x306   /* (path, struct xt_stat *) -> 0: does NOT follow (the link itself) */
#define SYS_readlink 0x307   /* (path, buf, size) -> len: symlink target (no follow) */
#define SYS_symlink  0x308   /* (target, linkpath) -> 0: create a symlink */
#define SYS_unlink   0x309   /* (path) -> 0: remove a file/symlink */
#define SYS_readdir  0x30A   /* (path, index, struct xt_dirent *) -> 1 filled / 0 end / -1 err */
#define SYS_mkdir    0x30B   /* (path, mode) -> 0: create a directory */
#define SYS_chdir    0x30C   /* (path) -> 0: set the process cwd (must be a dir) */
#define SYS_getcwd   0x30D   /* (buf, size) -> len: the process cwd (absolute) */
#define SYS_rename   0x30E   /* (oldpath, newpath) -> 0 */
#define SYS_pipe     0x30F   /* (int fd[2]) -> 0: kernel ring-buffer pipe; fd[0]=read
                              * end, fd[1]=write end. Read blocks until data or all
                              * writers close (then 0 = EOF); write blocks while full,
                              * fails when all readers are gone. */
#define SYS_dup2     0x310   /* (oldfd, newfd) -> newfd: duplicate a PIPE end onto a
                              * chosen slot (refcounted); newfd must be free or a pipe */
#define SYS_fstat    0x311   /* (fd, struct xt_stat *) -> 0: fd metadata — pipes report
                              * XT_S_IFIFO, console 0/1/2 XT_S_IFCHR, files IFREG+size */
#define SYS_ioctl    0x312   /* (fd, req, argp) -> device-specific: char-device controls
                              * (Linux request codes, e.g. i2c-dev I2C_SLAVE/I2C_SMBUS);
                              * -1 on a non-device fd or an unsupported request */

/* stat result (SYS_stat / SYS_lstat / SYS_fstat). mode carries the type bits below. */
struct xt_stat { unsigned mode, size, mtime; };
#define XT_S_IFMT  0xF000u   /* type mask */
#define XT_S_IFREG 0x8000u   /* regular file */
#define XT_S_IFDIR 0x4000u   /* directory */
#define XT_S_IFLNK 0xA000u   /* symbolic link */
#define XT_S_IFIFO 0x1000u   /* pipe (SYS_fstat only) */
#define XT_S_IFCHR 0x2000u   /* character device / console (SYS_fstat only) */

/* one directory entry (SYS_readdir). Enumerate index = 0,1,2,... until it returns 0.
 * mode's type bits are a hint (dir vs not); lstat the entry for the authoritative type
 * (readdir doesn't magic-check every entry). */
struct xt_dirent { unsigned mode; char name[256]; };

/* time / timers — block 0x400. Peripherals are PL1-only, so libc's _gettimeofday
 * traps here; the kernel reads the A9 global timer (wall clock since boot — no RTC). */
#define SYS_gettimeofday 0x400 /* (struct timeval *tv) -> 0: fills {tv_sec, tv_usec} */

/* graphics / compositor — block 0x600. The OS owns the display plane; apps query
 * its descriptor and draw into it, then present (compositor on HW, ASCII on qemu). */
#define SYS_fb_info      0x600 /* (struct os_fbinfo *) -> 0 */
#define SYS_fb_present   0x601 /* () -> 0  (present the plane) */
#define SYS_fb_wallpaper 0x602 /* (struct os_fbinfo *) -> 0: OS-owned desk-sized WM
                                * backdrop buffer (WALLPAPER_BASE); no heap cost */

/* input / events — block 0x700. The kernel owns the HW cursor sprite + the serial
 * mouse; the desktop blocks here for the next event and the cursor moves kernel-side. */
#define SYS_input        0x700 /* (struct os_event *, timeout_ms) -> 0; blocks (<0 = forever) */

/* one input event (SYS_input); type values match the AES aes_event enum. */
struct os_event { int type, mx, my, button, key, shift; };
enum { OS_EV_NONE = 0, OS_EV_BTN_DOWN = 1, OS_EV_BTN_UP = 2, OS_EV_KEY = 3,
       OS_EV_MOTION = 5, OS_EV_TIMER = 6 };

#endif
