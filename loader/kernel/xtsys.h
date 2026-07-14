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
#include <stdint.h>   /* uint16_t / int32_t — used by struct xt_blit_cmd below.
                      * Freestanding-safe (C99 requires stdint.h in a freestanding impl). */

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
#define XT_WAIT_PEEK 2       /* with NB: report exited (1) / running (0) / gone (-1) WITHOUT
                              * reaping — for a synchronous SIGCHLD "did a child exit?" probe */
#define SYS_getpid   0x103   /* () -> pid */
#define SYS_spawn_fd 0x104   /* (path, argv, int fds[3]) -> pid: argv is NULL-terminated
                              * (argc counted kernel-side); the child's fd 0/1/2 come
                              * from the parent's fds (pipe ends; -1 = inherit console) */
#define SYS_strace   0x108   /* (on) -> 0: set/clear this process's syscall-trace flag;
                              * children inherit it. Traced syscalls go to the kernel log
                              * (dmesg / /proc/kmsg). Used by /bin/strace. */
/* SYS_kill signal values with non-kill semantics (Linux numbers). Everything
 * else (9, 15, ...) kills at the target's next syscall boundary. */
/* NOTE: these MUST match newlib's arm signal.h — the shim passes newlib numbers
 * straight to SYS_kill. (Were Linux 18/19/20; that mis-mapped kill -STOP/-CONT.) */
#define XT_SIGSTOP 17        /* park it at its next syscall boundary (uncatchable) */
#define XT_SIGTSTP 18        /* stop from tty (what ^Z sends) */
#define XT_SIGCONT 19        /* resume a stopped process */
#define XT_SIGCHLD 20        /* to the parent on child exit */
#define XT_SIGWINCH 28       /* controlling terminal size changed */
/* SYS_waitpid: the child stopped (^Z/SIGSTOP) rather than exited — it is NOT
 * reaped; wait it again after XT_SIGCONT (that's what fg does). */
#define XT_WAIT_STOPPED (-12)
#define SYS_kill     0x105   /* (pid, sig) -> 0: sig 0 = existence probe; any other sig
                              * marks the process killed — it dies at its next syscall
                              * or blocking-wait tick (no handlers; soft-signal system) */
#define SYS_envp     0x107   /* () -> char **: the environment array the parent handed us at
                              * spawn (copied into this process's memory, NULL-terminated), or
                              * 0 if none. The libc shim seeds `environ` from it at load. */

/* ---- real signals (kernel-authoritative disposition + async delivery) ------
 * One disposition table per process in the kernel; SYS_kill marks a signal
 * pending; the kernel builds a frame on the target's user stack and vectors it
 * to the handler at the next return-to-PL0 (syscall-return OR timer-tick =
 * async), then a hidden sigreturn trampoline restores the interrupted context.
 * Signal numbers are the Linux ones (SIGKILL 9, SIGUSR1 10, SIGUSR2 12, SIGPIPE
 * 13, SIGCHLD 17, plus the STOP/CONT/TSTP above). SIGKILL(9)/SIGSTOP(19) are
 * uncatchable. */
#define SYS_rt_sigaction   0x109  /* (sig, const xt_sigaction *act, xt_sigaction *old) -> 0 */
#define SYS_rt_sigprocmask 0x10A  /* (how, const u32 *set, u32 *old) -> 0; how: 0=BLOCK 1=UNBLOCK 2=SET */
#define SYS_sigreturn      0x10B  /* (xt_sigframe *) -> no return: restore the saved context */
#define SYS_sig_async      0x10C  /* () -> no return: deliver from the async-captured context
                                   * (the __sig_trap stub the tick-return hook redirects to) */
#define SYS_xtos_recv      0x10D  /* (int16 msg[8]) -> 1 if an XTOS system message was
                                   * dequeued into msg (drain in a loop until 0), else 0.
                                   * GUI apps drain this each evnt_multi (see gem/aes). */

/* XTOS system-event GEM messages (msg[0]) — the OS broadcasting hardware/system state
 * to GUI apps, delivered via SYS_xtos_recv and surfaced as normal AES MU_MESAG events.
 * These values are the app-facing ABI; they MUST match gem/aes/aes.h's XTOS_* enum
 * (that header is portable — SDL testbed — so it can't include this one). */
#define XT_XTOS_BASE           0x4000
#define XT_XTOS_MEDIA_CHANGE   0x4000  /* msg[3]=present(1)/gone(0), msg[4]=volume(0=SD) */

#define XT_NSIG      32
#define XT_SIG_DFL   0            /* default disposition (kill / ignore per signal) */
#define XT_SIG_IGN   1            /* ignore */
#define XT_SA_RESTART   0x10000000 /* restart the interrupted syscall instead of EINTR */
#define XT_SA_NODEFER   0x40000000 /* don't auto-block the signal during its handler */
/* Transient result the kernel restores as r0 when an SA_RESTART handler interrupts
 * a blocked syscall: __syscall() (usys.h) loops on it and re-issues the svc AFTER
 * the handler has run. Never reaches a caller (the loop eats it) and, being outside
 * the small -errno range, can't be mistaken for one if it ever leaked. */
#define XT_ERESTARTSYS  (-514)
#define XT_SIG_BLOCK 0
#define XT_SIG_UNBLOCK 1
#define XT_SIG_SETMASK 2

/* kernel-ABI disposition (the shim maps POSIX struct sigaction to/from this).
 * restorer = the userland sigreturn trampoline the kernel vectors the handler's
 * return to (Linux SA_RESTORER style); trap = the __sig_trap stub the async
 * (tick-return) path redirects a preempted PL0 task to. The shim fills both. */
struct xt_sigaction { unsigned long handler; unsigned int mask; unsigned int flags; unsigned long restorer; unsigned long trap; };

/* the frame the kernel pushes on the target's user stack before vectoring to a
 * handler; SYS_sigreturn (from the trampoline) restores from it. r[0..14] =
 * r0..r14 of the interrupted context, pc = r15, then cpsr; signo is the handler
 * arg (also delivered in r0); saved_mask is the sig_blocked to restore. */
struct xt_sigframe {
    unsigned int r[15];      /* r0..r14 */
    unsigned int pc;         /* r15 resume PC */
    unsigned int cpsr;
    unsigned int signo;
    unsigned int saved_mask;
    unsigned int _pad[2];    /* keep the frame 8-byte aligned */
};

/* memory — block 0x200 */
#define SYS_mmap     0x200   /* (fd, len, off) -> VA: map a file RO + shared, demand-paged */
#define SYS_munmap   0x201   /* (addr, len) -> 0 */
#define SYS_sbrk     0x202   /* (incr) -> old break: grow the per-process heap (libc malloc) */
#define SYS_shm_create 0x203 /* (size, flags) -> id: allocate a shared-memory object.
                              * flags: XT_SHM_* below; 0 = the classic pool-backed object.
                              * The number is FROZEN; `flags` went into the already-free a1,
                              * so old callers (which passed a literal 0) keep their meaning. */
#define SYS_shm_map    0x204 /* (id) -> VA: map an shm object PL0-RW into this process */
#define SYS_shm_unmap  0x205 /* (id) -> 0: drop THIS process's mapping + ref. Frees the object
                              * when the last mapper drops it.
                              * Until this existed the ONLY nref-- was at process DEATH, so a
                              * LIVE process could never release a surface: every window resize
                              * and every window close leaked its buffer AND its id, forever.
                              * The gemd design (Rocks RESPONSIBILITIES.md §11 "refcount, do not
                              * handshake") is built on either side being able to drop while both
                              * are alive — gemd hands the client a new surface on resize and
                              * drops its ref on the old; the client maps the new and drops the
                              * old; refcount -> 0 -> freed. No handshake, nobody blocks. */
#define SYS_shm_grant  0x206 /* (id, pid) -> 0: the OWNER of an XT_SHM_OWNED object lets ONE other
                              * process map it. Owner-only, and a grantee cannot re-grant, so the
                              * capability does not spread. This is what makes a surface id a
                              * CAPABILITY rather than a name: gemd creates a window's surface and
                              * grants it to exactly the client that asked for the window.
                              * (vm_shm_map had NO ownership check: ANY process could map ANY of
                              * the 256 ids and read or scribble on another client's window.) */

/* shm_create flags (a1).  UNKNOWN BITS ARE REJECTED, never ignored — see below. */
#define XT_SHM_OWNED   (1u << 1) /* the id is a CAPABILITY: only the creator, and the processes the
                                  * creator SYS_shm_grant's, may map it. Every gemd surface is
                                  * created with this. It is opt-in rather than the default because
                                  * plain shm is also how a process shares a buffer with its own
                                  * children (shmtest) and how the fs page cache is reached — those
                                  * have no owner/grant handshake and would break. A window has one,
                                  * and a window is the thing worth protecting. */
#define XT_SHM_CONTIG  (1u << 0) /* physically contiguous + PL-visible (plv_alloc): the
                                  * blitter/compositor are DMA engines with NO MMU and read
                                  * physical addresses, so anything the PL touches must be
                                  * contiguous. NOT YET IMPLEMENTED — the kernel REJECTS it
                                  * (see XT_SHM_SUPPORTED) rather than quietly handing back a
                                  * scattered pool object, which the PL would then read as
                                  * garbage. A loud -1 beats silent corruption. */

/* The bits this kernel actually honours.  vm_shm_create() fails any request carrying a bit
 * outside this mask.  That is deliberate: it is what lets the flag word grow without a new
 * syscall number, because a program built against a NEWER flag set gets a clean failure on
 * an OLDER kernel instead of silently different memory. Widen this as each flag lands. */
#define XT_SHM_SUPPORTED (XT_SHM_CONTIG | XT_SHM_OWNED)

/* ---- /dev/blitter (Rocks RESPONSIBILITIES.md §13) ---------------------------
 * The blitter is a DMA engine with NO MMU — it takes PHYSICAL addresses — so raw register
 * access IS arbitrary physical write. It is therefore a DEVICE, and the kernel mediates.
 *
 * COMMANDS NAME SURFACES BY HANDLE (an shm id), NEVER BY ADDRESS. The driver resolves
 * id -> physical itself and bounds-checks every rect against that surface's own
 * allocation, so a client cannot even EXPRESS an out-of-bounds blit. Only XT_SHM_CONTIG
 * surfaces may be named: a pool-backed shm is 2048 unrelated frames and the engine, which
 * accumulates base+stride, would walk straight off the first page.
 *
 *   fd = open("/dev/blitter")
 *   ioctl(fd, XT_BLIT_DECLARE, &(struct xt_blit_surf){id, stride})   once per surface
 *   write(fd, cmds, n * sizeof cmd)   -> the retire SEQ of the last command
 *   ioctl(fd, XT_BLIT_SEQ, &seq)      -> what the engine has actually RETIRED
 *
 * The seq is a FENCE, and it is not optional. gemd holds PRIORITY, so it can composite a
 * window whose own draws have not retired yet. "I posted damage" must therefore mean "my
 * pixels are in memory", and only a fence can say that — with a queued engine, drawing was
 * never synchronous; priority merely exposes an assumption that was already false. */
#define XT_BLIT_FILL   1        /* rect fill with `color` */
#define XT_BLIT_COPY   2        /* block blit: src rect -> dst rect (1:1) */
#define XT_BLIT_SCALE  3        /* scaled blit: src sw x sh -> dst dw x dh (nearest, or
                                 * bilinear with XT_BLITF_BILINEAR). Verified on silicon.
                                 * Needs the bitstream with the seg_cx fix (2026-07-13) --
                                 * before it, a scaled blit inherited the previous command's
                                 * burst column and landed in the wrong place. */
#define XT_BLITF_BLEND    (1u<<0)  /* alpha-blend over the destination (not replace) */
#define XT_BLITF_BILINEAR (1u<<1)  /* SCALE only: bilinear taps, else nearest-neighbour */

/* Well-known surface handles: the two FIXED kernel regions that are not shm. The driver
 * knows their base/stride/size itself — no DECLARE. WALLPAPER is the kernel's CACHED
 * back-buffer: the driver cleans the source rect to DDR before the engine reads it, and
 * REFUSES it as a destination (engine writes vs CPU cached reads would need an invalidate
 * protocol nobody has yet). PRE-M7 any opener may name these — PL0 can map the plane
 * anyway; the M7 gate must restrict them along with SEC_PLANE. */
#define XT_BLIT_SURF_PLANE      (-2)   /* the scan-out plane (uncached; compositor reads it) */
#define XT_BLIT_SURF_WALLPAPER  (-3)   /* the wallpaper back-buffer (cached; SOURCE only) */

struct xt_blit_cmd {
    uint16_t op;         /* XT_BLIT_* */
    uint16_t flags;      /* XT_BLITF_* */
    int32_t  dst_id;     /* surface HANDLE. Never an address. */
    int32_t  src_id;     /* HANDLE; ignored for FILL */
    uint16_t dx, dy, dw, dh;
    uint16_t sx, sy;
    uint16_t sw, sh;     /* SCALE: source extent. COPY/FILL: ignored. */
    uint32_t color;      /* FILL: RGBA-8888 */
};
struct xt_blit_surf { int32_t id; uint32_t stride; };   /* stride in BYTES per row */

#define XT_BLIT_DECLARE  0xB100  /* (struct xt_blit_surf *) -> 0: tell the driver a stride */
#define XT_BLIT_SEQ      0xB101  /* (uint32_t *) -> 0: the RETIRED sequence number */
#define XT_BLIT_PRIORITY 0xB102  /* () -> 0: this fd jumps the queue. gemd only. */

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
#define SYS_statfs   0x313   /* (path, u32 out[3]) -> 0: filesystem capacity for df/statvfs.
                              * out[0] = total sectors, out[1] = free sectors, out[2] = sector
                              * bytes (FatFs f_getfree). -1 where there's no sized fs (qemu). */
#define SYS_getdents 0x314   /* (path, index, buf) -> count: batch directory read WITH metadata,
                              * so a tree walk (du/ls/find) fetches a whole directory in one
                              * syscall instead of a readdir + a stat per entry. Fills buf (>= 4096
                              * bytes) with `count` packed records from entry `index` onward;
                              * 0 = end, -1 = not batch-enumerable (caller falls back to readdir).
                              * Each record (4-byte aligned): u32 mode, u32 size, u32 mtime,
                              * u16 reclen (whole record), u16 namelen, char name[namelen] + NUL. */
/* sockets — block 0x320 (IPv4, netconn-backed; addresses are be32 ip + host-order
 * port, no sockaddr marshalling at the syscall boundary — the libc shim owns
 * struct sockaddr). read/write/close/fstat work on socket fds; SYS_ioctl
 * FIONREAD polls readability. */
#define SYS_socket   0x320   /* (type: 1 = TCP, 2 = UDP) -> fd */
#define SYS_connect  0x321   /* (fd, ip_be32, port) -> 0 */
#define SYS_bind     0x322   /* (fd, ip_be32, port) -> 0 */
#define SYS_listen   0x323   /* (fd, backlog) -> 0 */
#define SYS_accept   0x324   /* (fd, u32 peer[2] out: ip_be32 + port) -> new fd */
#define SYS_resolve  0x325   /* (name, u32 *ip_be32) -> 0: DNS via the kernel (lwIP) */
#define SYS_recvfrom 0x326   /* (fd, buf, u32 a[3]) -> n: datagram recv with source.
                              * a[0] = buflen (in); a[1] = src ip_be32 (out);
                              * a[2] = src port host-order (out). RAW/ICMP sockets get
                              * the IP header stripped (payload at offset 0). */
#define XT_SOCK_TCP 1
#define XT_SOCK_UDP 2
#define XT_SOCK_RAW 3
#define XT_FIONREAD  0x541Bu /* SYS_ioctl: bytes readable now (socket or pipe fd) */
#define XT_FIONBIO   0x5421u /* SYS_ioctl: set/clear the fd's non-blocking flag (argp = int*;
                              * nonzero = O_NONBLOCK). A nonblock read that would block
                              * returns -EAGAIN instead. The libc shim maps fcntl(F_SETFL,
                              * O_NONBLOCK) onto this. */

#define SYS_reboot   0x106   /* (cmd) -> no return: Zynq PS soft reset (SLCR). cmd is the
                              * Linux RB_* value; all map to a warm PS reset here. On a
                              * JTAG-loaded image the boot ROM then waits per the boot-mode
                              * pins (needs a re-load); an SD/BOOT.BIN image re-boots. */

#define SYS_ioctl    0x312   /* (fd, req, argp) -> device-specific: char-device controls
                              * (Linux request codes, e.g. i2c-dev I2C_SLAVE/I2C_SMBUS)
                              * and the console tty modes below; -1 on a non-device fd
                              * or an unsupported request */

/* console tty controls (SYS_ioctl on stdin/a console-alias fd). The line
 * discipline is kernel-side; these switch it. Cooked (canon=1) = line-buffered
 * with echo/erase/CR->NL; raw (canon=0) = bytes as they arrive, verbatim.
 * The kernel restores cooked+echo if the mode-setting process dies. */
#define XT_TTY_GETMODE 0x7401 /* (struct xt_ttymode *) -> 0 */
#define XT_TTY_SETMODE 0x7402 /* (struct xt_ttymode *) -> 0 */
#define XT_TTY_NREAD   0x7403 /* (int *) -> 0: bytes immediately readable */
#define XT_TTY_INWAIT  0x7404 /* (timeout_ms BY VALUE; <0 = forever) -> 1 input
                               * ready / 0 timeout — poll(2) for the console */
struct xt_ttymode { unsigned canon, echo; };

/* stat result (SYS_stat / SYS_lstat / SYS_fstat). mode carries the type bits below. */
struct xt_stat { unsigned mode, size, mtime; };
#define XT_S_IFMT  0xF000u   /* type mask */
#define XT_S_IFREG 0x8000u   /* regular file */
#define XT_S_IFDIR 0x4000u   /* directory */
#define XT_S_IFLNK 0xA000u   /* symbolic link */
#define XT_S_IFIFO 0x1000u   /* pipe (SYS_fstat only) */
#define XT_S_IFCHR 0x2000u   /* character device / console (SYS_fstat only) */
#define XT_S_IFSOCK 0xC000u  /* socket (SYS_fstat only) */

/* one directory entry (SYS_readdir). Enumerate index = 0,1,2,... until it returns 0.
 * mode's type bits are a hint (dir vs not); lstat the entry for the authoritative type
 * (readdir doesn't magic-check every entry). */
struct xt_dirent { unsigned mode; char name[256]; };

/* time / timers — block 0x400. Peripherals are PL1-only, so libc's _gettimeofday
 * traps here; the kernel reads the A9 global timer (wall clock since boot — no RTC). */
#define SYS_gettimeofday 0x400 /* (struct timeval *tv) -> 0: fills {tv_sec, tv_usec} */
#define SYS_nanosleep    0x402 /* (usec) -> 0: block the caller ~usec via vTaskDelay — a REAL
                                * scheduler yield, not a busy-spin, so other tasks (esp. the
                                * network RX pump) run while a process sleeps/polls. */
#define SYS_settime      0x401 /* (unix_sec) -> 0: set the wall clock (sntp -s / clock_settime).
                                * The hourly kernel SNTP re-sync will overwrite it at its next
                                * poll — this is a manual nudge, not a persistent RTC. */
#define SYS_klog         0x403 /* (buf, len) -> bytes: append to the kernel diagnostic log
                                * (dmesg / /proc/kmsg + /OS/var/log/system.log). Lets PL0
                                * boot daemons log without cluttering the console. */
#define SYS_devmem       0x404 /* (addr, val, write) -> word: peek/poke a 32-bit physical
                                * word (kernel MMU is identity-mapped, reaches GP0/DDR/periph).
                                * DEBUG poke tool (/bin/mem) — no bounds check, by design. */
#define SYS_boot_done    0x405 /* () -> 0: init(1) has run every boot script and is about to go
                                * resident as the reaper. The kernel's shell_task blocks on THIS
                                * before it starts the login shell — it cannot waitpid(init),
                                * because a resident init never exits. (It tried, and the machine
                                * came up with no console at all — see docs/OS/gemd-plan.md.)
                                * init(1) only; anyone else gets -EPERM. */

/* networking control — block 0x800. Bringing the stack up is a BOOT-SCRIPT decision
 * (/boot/20-Networking runs /bin/netup), not kernel magic. */
#define SYS_net_up       0x800 /* () -> 0: start GEM0 + lwIP + DHCP/mDNS/SNTP (idempotent);
                                * async — DHCP/link come up in the background */
/* socket peer/name queries (SYS_ioctl on a socket fd; arg = u32[2] out: ip_be32, port) */
#define XT_SIOCGPEER 0x8901u   /* remote address (getpeername) */
#define XT_SIOCGNAME 0x8902u   /* local address (getsockname) */

/* graphics / compositor — block 0x600. The OS owns the display plane; apps query
 * its descriptor and draw into it, then present (compositor on HW, ASCII on qemu). */
#define SYS_fb_info      0x600 /* (struct os_fbinfo *) -> 0 */
#define SYS_fb_present   0x601 /* () -> 0  (present the plane) */
#define SYS_fb_wallpaper 0x602 /* (struct os_fbinfo *) -> 0: OS-owned desk-sized WM
                                * backdrop buffer (WALLPAPER_BASE); no heap cost */
#define SYS_xl_window    0x603 /* (x<<16|y, w<<16|h, scale) -> 0: place the XL
                                * emulation plane at an on-screen rect (the desktop
                                * frames the live emulation in a window's work
                                * area); scale = 1..5 integer zoom, 0 = hide */
#define SYS_overlay      0x604 /* (x<<16|y, w<<16|h, en) -> 0: place/hide the drag-overlay
                                * plane (pixels = DRAG_BASE, client-filled). Move = re-call
                                * with new x/y — no plane redraw. Tear-free window drag. */

/* ---- services + multiplexing — block 0x500 ---------------------------------
 * The rendezvous XTOS did not have. Pipes need shared ancestry (SYS_spawn_fd), so two
 * unrelated processes -- a boot-script-launched server and an ssh-launched client --
 * could not talk at all. Sockets are lwIP-only, so a window server would have depended
 * on DHCP. This is the missing primitive, and it is deliberately BSD-shaped: register is
 * bind+listen, then connect/accept, then ordinary read/write on the returned fd.
 *
 * A channel fd is BIDIRECTIONAL (two kernel pipes under one fd). It is an ordinary fd:
 * read(), write(), close(), poll(). A dying process releases its ends, so the peer sees
 * EOF -- death detection is free and works for clients that are nobody's child (which
 * SIGCHLD does not: it only reaches the parent).
 */
#define SYS_svc_register 0x500 /* (const char *name) -> listen fd. One holder per name. */
#define SYS_svc_connect  0x501 /* (const char *name) -> channel fd (bidirectional) */
#define SYS_svc_accept   0x502 /* (listen fd) -> channel fd; blocks until a client connects */

/* poll(2). The other thing XTOS did not have: a way to wait on several fds at once.
 * Without it a server with N clients plus an input source has no single wait, and every
 * design degenerates into either one-thread-per-client or a polling loop. Works on pipes,
 * channels, sockets and device nodes. */
#define SYS_poll         0x503 /* (struct xt_pollfd *, nfds, timeout_ms) -> n ready
                                * timeout <0 = forever, 0 = poll and return */
#define SYS_chan_peer    0x504 /* (channel fd) -> the pid at the OTHER end (-1 if not a channel /
                                * unknown). The kernel knows who connected; the client does not
                                * have to say, and so cannot lie. gemd needs a TRUSTWORTHY peer
                                * identity to SYS_shm_grant a window's surface to exactly the
                                * process that asked for it — a pid carried in the client's own
                                * message would be a capability handed out on the say-so of the
                                * process being granted it. */
#define XT_POLLIN   0x0001     /* readable (or EOF -- read() then returns 0) */
#define XT_POLLOUT  0x0004     /* writable without blocking */
#define XT_POLLERR  0x0008
#define XT_POLLHUP  0x0010     /* peer closed */
#define XT_POLLNVAL 0x0020     /* fd not open */
struct xt_pollfd { int fd; short events; short revents; };

/* input / events — block 0x700. The kernel owns the HW cursor sprite + the serial
 * mouse; the desktop blocks here for the next event and the cursor moves kernel-side. */
#define SYS_input        0x700 /* (struct os_event *, timeout_ms) -> 0; blocks (<0 = forever) */
#define SYS_kbd_6502     0x701 /* (ascii) -> 0 / -1 no such Atari key: inject one keystroke
                                * into the 6502's POKEY (KBCODE down + release; ^C = BREAK) */

/* one input event (SYS_input, and one read() record from /OS/dev/input); type values match the
 * AES aes_event enum. `wheel` is the signed notch count for OS_EV_WHEEL (>0 = away from the
 * user / scroll up). Kernel and userland share this header and ship together — a record-size
 * change is a lockstep rebuild, not a protocol negotiation. */
struct os_event { int type, mx, my, button, key, shift, wheel; };
enum { OS_EV_NONE = 0, OS_EV_BTN_DOWN = 1, OS_EV_BTN_UP = 2, OS_EV_KEY = 3,
       OS_EV_MOTION = 5, OS_EV_TIMER = 6, OS_EV_WHEEL = 7 };

/* /OS/dev/input — INPUT AS A POLLABLE FD, which SYS_input (a blocking syscall) can never be.
 * A window server has to wait on input AND on its client channels in ONE poll(); with a blocking
 * syscall it cannot, and every alternative degenerates into a thread per source. read() delivers
 * whole `struct os_event` records (as many as are queued); poll() is readable only when one is
 * actually waiting. The kernel publishes events on a device and knows nothing about who consumes
 * them — there is deliberately NO kernel-side "post input to the window server" path, because
 * that would put window-server policy in the kernel (RESPONSIBILITIES.md §2). */
#define XT_INPUT_RAW 0x7501u   /* ioctl: arg != 0 -> raw keys (Enter/Space stop being clicks) */

#endif
