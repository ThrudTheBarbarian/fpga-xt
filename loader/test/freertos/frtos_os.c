/*
 * frtos_os.c — the XTOS syscall layer on the REAL FreeRTOS kernel.
 *
 * - svc #1 dispatch (from the chained vector) with the exit-via-thunk trick: a
 *   yielding op (vTaskDelete) cannot run in the SVC handler (it would nest
 *   svc #0), so exit redirects the task's resume PC to task_exit_thunk, which
 *   runs in task (System-mode) context and deletes cleanly.
 * - spawn (by image or by path via romfs) = load an ET_DYN (xtld) + xTaskCreate.
 * - per-process fd table: stdio (0/1/2) + read-only romfs files (open/read/
 *   close/lseek). waitpid blocks on a per-process semaphore.
 */
#include <stdint.h>
#include <string.h>
#include "FreeRTOS.h"
#include "task.h"
#include "semphr.h"
#include "queue.h"
#include "stream_buffer.h"
#include "ksys.h"      /* struct k_regs */
#include "xtsys.h"
#include "xtld.h"
#include "romfs.h"
#include "vfs.h"
#include "frtos_os.h"

#define MAXPROC 64
#define NFD     32      /* per process; 0/1/2 are stdio (a shell juggling pipeline +
                         * subshell-state pipes holds ~6 pipe ends at once; a network
                         * server multiplexing listeners + live connections wants more) */
#define FD_PATH_MAX 96  /* retained open path (for a writable mmap's independent write-back handle) */

typedef struct {
    int      open;
    int      pipei;  /* pipe fd: g_pipes index+1 (0 = not a pipe); pwrite = which end */
    int      pwrite;
    int      sock;   /* socket fd: net/sockets.c index+1 (0 = not a socket) */
    int      rpipe;  /* channel fd (SYS_svc_*): g_pipes index+1 we READ from  (0 = not a channel) */
    int      wpipe;  /* channel fd: g_pipes index+1 we WRITE to. A channel is bidirectional:
                      * two pipes under one fd, so read()/write()/poll() just work on it. */
    int      svc;    /* service listen fd: g_svc index+1 (0 = not a listener) */
    int      peer;   /* channel fd: the pid at the other end (SYS_chan_peer). The kernel knows who
                      * connected, so a server (gemd) can grant a capability to the process that
                      * actually asked, rather than to whatever pid that process CLAIMS to be. */
    int      con;    /* console alias (a shell's saved stdio parked on a high fd) */
    int      oflags; /* the VFS_O_* this fd was opened with (for reopen-by-path) */
    int      nonblock; /* O_NONBLOCK (via FIONBIO): a read that would block returns -EAGAIN */
    uint32_t pos;    /* logical read/write cursor (page store); the driver's vf.pos is fill scratch */
    uint32_t cpi;    /* cached page index (~0u = none) — backing-store only; in-memory fds read vf.data */
    void    *cpage;  /* the one cached page (pool identity addr), or NULL */
    int      cdirty; /* the cached page has unflushed writes */
    char     path[FD_PATH_MAX];  /* the path this fd was opened with */
    vfs_file vf;     /* VFS-backed: romfs / fatfs / ramfs / ... */
} fd_t;

/* ---- kernel pipes (SYS_pipe / SYS_spawn_fd) --------------------------------
 * A pipe is a FreeRTOS stream buffer (single-reader/single-writer ring — the
 * shell-pipeline shape) plus end refcounts. The fds holding an end live in
 * process fd tables (a child's stdio can be a pipe end via SYS_spawn_fd), so a
 * crashed process's ends release on reap and EOF/EPIPE propagate for free.
 * All pipe ops run in task context (they block / take the FreeRTOS heap). */
#define MAXPIPE     256
#define PIPE_BUF_SZ 4096
typedef struct {
    int used;
    volatile int readers, writers;
    StreamBufferHandle_t sb;
} kpipe_t;
static kpipe_t g_pipes[MAXPIPE];
static void k_pipe_close_end(fd_t *f);   /* impl below with the other pipe ops */

/* services (SYS_svc_*): table declared here because pipes_release() -- which runs on
 * process death, above -- must drop a dying server's unaccepted connects. */
#define MAXSVC      8
#define SVC_BACKLOG 8
typedef struct {
    int  used;
    char name[24];
    int  q[SVC_BACKLOG][3];   /* pending connects: {c2s pipe idx, s2c pipe idx, connector pid} */
    int  nq;
} svc_t;
static svc_t g_svc[MAXSVC];

/* init's pid. init(1) is the ULTIMATE REAPER: when a parent dies, its children are
 * re-parented here, and init's waitpid(-1) loop collects them. Without it, an orphan
 * whose parent registered a waitpid and then died keeps `waited` set forever -- and
 * reap_orphans() deliberately skips `waited` processes, so the slot is NEVER freed.
 * That is the "dead process still in ps" bug: not a missing reaper, a DANGLING CLAIM. */
static int g_init_pid = 0;
static int g_claim_init = 0;             /* "the next process spawned is init" — see proc_launch */
void frtos_claim_next_as_init(void) { g_claim_init = 1; }

/* The boot barrier. init(1) runs the boot scripts and then STAYS RESIDENT, so the kernel
 * cannot learn "the boot scripts are done" by waiting for init to exit -- it never does.
 * (It tried: shell_task's frtos_waitpid(init) blocked forever, the login shell and the
 * kernel menu never started, and the machine produced NO CONSOLE OUTPUT AT ALL. On the
 * board the desktop still came up, which hid it; under headless qemu, where there is no
 * desktop and the console IS the machine, it looked like a kernel that died before its
 * first write.) init calls SYS_boot_done instead, and shell_task waits for THAT. */
static volatile int g_boot_done = 0;    /* set by SYS_boot_done; waited on by shell_task */
static void k_chan_close(fd_t *f);        /* impl below with the service ops */

/* kernel-mailbox fs ops (impls with the fs task, below): displacing an open
 * file fd (dup2 restore) must flush + close through the SOLE FatFs driver */
enum { KFS_READFILE, KFS_LISTDIR, KFS_CLOSEALL, KFS_CLOSEFD,
       KFS_WRITEOPEN, KFS_WRITEBLOCK, KFS_WRITECLOSE, KFS_LOGWRITE };
static long kfs_call(int op, const char *path, void *buf, uint32_t len, void **out_buf);

typedef struct {
    int               used;
    int               pid;
    int               ppid;            /* spawner's pid (for SIGCHLD-on-exit) */
    TaskHandle_t      task;
    xtld_obj         *obj;
    uintptr_t         entry;
    SemaphoreHandle_t done;
    int               exit_code;
    volatile int      exited;         /* set by the exit thunk */
    volatile int      killed;         /* SYS_kill: die at the next syscall / blocking tick */
    volatile int      stopped;        /* SIGSTOP/SIGTSTP (^Z): park at the next syscall /
                                       * blocking tick until SIGCONT clears it (stop_park) */
    volatile int      waited;         /* a waitpid registered -> that caller will reap it */
    volatile int      reaping;        /* teardown claimed (one reaper only; slot not reusable yet) */
    TaskHandle_t      waiter;         /* PL0 waitpid task to notify on exit (0 = none/kernel waiter) */
    int               argc;
    char            **argv;
    char            **envp;           /* inherited environment (copied into this proc), or NULL */
    fd_t              fd[NFD];
    uint32_t         *l1;             /* per-process address space (vm.c), NULL=master */
    uint32_t          asid;           /* its ASID (slot+1; 0 = kernel/master) */
    uint32_t          heap_brk;       /* per-process heap (XTOS_HEAP_VA window) */
    uint32_t          heap_end;
    int               transient;      /* loaded outside the cache (runhost) -> unload on reap */
    int               strace;         /* log this proc's syscalls to klog (SYS_strace / name match) */
    void             *src;            /* the host ELF buffer to free on reap (transient) */
    StaticTask_t      tcb;            /* static TCB (stack from stackguard.c) */
    /* blocking-syscall deferral: saved PL0 exception context so the blocking part can
     * run in task context (PL1) and then sysret to PL0. dctx = {r0..r12, lr(=user PC),
     * sp_usr, spsr, r14_usr}; dnum/da* = the deferred syscall + args. dctx[16]=r14_usr
     * is used only by signal delivery (to save/restore the full interrupted context). */
    uint32_t          dctx[17];
    uint32_t          dnum;
    long              da0, da1, da2;
    char              cwd[256];       /* current working dir (absolute); relative paths resolve here */
    /* real signals: one authoritative disposition table + pending/blocked bitsets.
     * SYS_kill sets a pending bit; the kernel vectors it to sigact[].handler at the
     * next return-to-PL0 (see deliver_signals). killed/stopped above stay as the
     * uncatchable SIGKILL/SIGSTOP fast path. */
    struct xt_sigaction sigact[XT_NSIG];
    volatile uint32_t sig_pending;    /* signals raised, awaiting delivery */
    uint32_t          sig_blocked;    /* masked signals (rt_sigprocmask) */
    uint32_t          sig_trap;       /* userland __sig_trap stub (async delivery entry) */
    uint32_t          async_ctx[16];  /* r0..r15 of a PL0 task preempted with a signal pending */
    uint32_t          async_cpsr;     /* its CPSR (captured by the tick-return hook) */
    uint32_t          xtos_cursor;    /* next XTOS-broadcast seq this proc will receive
                                       * (see xtos_broadcast / SYS_xtos_recv); set = g_xtos_seq
                                       * at launch so a new app gets no historical events */
} proc_t;

static proc_t *proc_by_pid(int pid);     /* impl below with the waitpid family */
static long k_boot_done(proc_t *p);      /* SYS_boot_done — impl below, ditto */
/* a deliverable signal is pending -> a blocking syscall should unwind with -EINTR
 * (-4) so the kernel can vector the handler on the deferred return (deliver_deferred). */
static inline int sig_ready(proc_t *p) { return p && ((p->sig_pending & ~p->sig_blocked) != 0); }

/* raise a signal on a process from kernel context (SIGCHLD-on-exit, SIGWINCH):
 * mark it pending only if a real handler is installed (default/ignored = no-op;
 * SIGCHLD's default disposition is ignore, and waitpid has its own wakeup). It's
 * delivered at the target's next return-to-PL0 / EINTR of a blocked syscall. */
static inline void sig_raise(proc_t *t, int sig)
{
    if (!t || t->exited || sig <= 0 || sig >= XT_NSIG) return;
    unsigned long h = t->sigact[sig].handler;
    if (h != XT_SIG_DFL && h != XT_SIG_IGN) t->sig_pending |= (1u << sig);
}

static proc_t g_proc[MAXPROC];

/* live-count helpers + peak high-water marks for /OS/proc/limits. The peaks are
 * bumped at the claim sites (proc launch, pipe create) so they catch transients
 * between reads, not just what's live when someone happens to cat the file. */
static int g_proc_hwm, g_pipe_hwm;
static int proc_live(void) { int n = 0; for (int i = 0; i < MAXPROC; i++) if (g_proc[i].used) n++; return n; }
static int pipe_live(void) { int n = 0; for (int i = 0; i < MAXPIPE; i++) if (g_pipes[i].used) n++; return n; }
static void note_proc_hwm(void) { int n = proc_live(); if (n > g_proc_hwm) g_proc_hwm = n; }
static void note_pipe_hwm(void) { int n = pipe_live(); if (n > g_pipe_hwm) g_pipe_hwm = n; }

/* ---- XTOS system-message broadcast (OS -> GUI apps) -----------------------
 * A tiny global ring the kernel drops XTOS_* GEM messages into (SD insert/remove,
 * future system events). Each proc has a cursor; GUI apps drain via SYS_xtos_recv
 * (gem/aes evnt_multi calls it every event wait), turning them into normal AES
 * MU_MESAG events. Rare events, so 8 slots suffice; a proc that lags past the ring
 * just skips the overflowed ones. New procs start at the head (no history). The
 * kernel is generic here — it relays opaque 8-word messages; only sd.c + the app
 * know what XTOS_MEDIA_CHANGE means. */
#define XTOS_RING_N 8
static int16_t  g_xtos_ring[XTOS_RING_N][8];
static uint32_t g_xtos_seq;                         /* total broadcast (monotonic) */

void xtos_broadcast(const int16_t *m8)              /* enqueue one 8-word message */
{
    taskENTER_CRITICAL();
    for (int i = 0; i < 8; i++) g_xtos_ring[g_xtos_seq % XTOS_RING_N][i] = m8[i];
    g_xtos_seq++;
    taskEXIT_CRITICAL();
}
static long xtos_recv(proc_t *p, int16_t *out)      /* -> 1 filled out[8], 0 = none pending */
{
    if (!p || !out || p->xtos_cursor >= g_xtos_seq) return 0;
    if (g_xtos_seq - p->xtos_cursor > XTOS_RING_N)  /* lagged past the ring: jump to newest N */
        p->xtos_cursor = g_xtos_seq - XTOS_RING_N;
    const int16_t *m = g_xtos_ring[p->xtos_cursor % XTOS_RING_N];
    for (int i = 0; i < 8; i++) out[i] = m[i];
    p->xtos_cursor++;
    return 1;
}
static int    g_next_pid = 1;
static void (*g_console)(const char *, int);
static volatile int g_con_eof;           /* console hit EOF (drained qemu pipe) */
int frtos_console_eof(void) { return g_con_eof; }

void ksys_set_console(void (*w)(const char *, int)) { g_console = w; }

/* ---- console tty mode (ONE console, like the line discipline) -------------
 * cooked+echo by default; raw mode is set per-request (XT_TTY_SETMODE — vi,
 * hexedit, ...). The setter becomes the mode's owner: if it dies without
 * restoring, the console must not stay raw, so its exit puts cooked back. */
static struct { volatile unsigned canon, echo; } g_tty = { 1, 1 };
static volatile int g_tty_owner;                     /* pid of the last mode-setter */

/* ---- ^C / ^Z (ISIG): the foreground job -----------------------------------
 * No process groups; "foreground" = the LEAF of the live wait chain (the shell
 * waits vi, vi waits its :!cmd — the leaf is the :!cmd), derived from the
 * p->waiter links on each signal. NOT a push/pop stack: a parent's waitpid and
 * its child's own waitpid race (fg CONTs + waits the job before the shell's
 * waitpid-of-fg lands), so push ORDER lies — the waiter links don't. The login
 * shell is waited by a KERNEL task over a semaphore (waiter = 0), so it is
 * never a candidate: ^C at an idle prompt just clears the line, and ^Z cannot
 * strand the console. Flag writes only: callable from the uart ISR (a compute
 * loop dies/parks at its next syscall gate, not at its next console read) and
 * from the line discipline; idempotent. */
static proc_t *fg_leaf(void)
{
    for (int i = 0; i < MAXPROC; i++) {
        proc_t *c = &g_proc[i];
        if (!c->used || c->exited || !c->waiter) continue;
        int waits_another = 0;                 /* c waits a live proc itself -> not the leaf */
        for (int j = 0; j < MAXPROC && !waits_another; j++) {
            proc_t *o = &g_proc[j];
            if (o != c && o->used && !o->exited && o->waiter == c->task) waits_another = 1;
        }
        if (!waits_another) return c;
    }
    return 0;
}

int frtos_tty_sigint(void)
{
    if (!g_tty.canon) return 0;
    proc_t *t = fg_leaf();
    if (!t) return 0;
    t->killed = 1;
    return 1;
}

int frtos_tty_sigtstp(void)
{
    if (!g_tty.canon) return 0;
    proc_t *t = fg_leaf();
    if (!t) return 0;
    t->stopped = 1;
    return 1;
}

/* xtld_host.alloc/dealloc — the OS heap (newlib). Real free, so xtld_unload
 * actually reclaims. */
/* Allocation: a one-shot bootstrap bump (over the OS-heap base) loads libc.so;
 * once libc.so is up we switch to its memalign/free. After that, every .so /
 * program image comes from the one libc.so malloc and is freed on unload. */
extern char _heap_start[];                       /* 0x0200_0000 (linker) */
void klog(const char *s); void klog_u(unsigned v);  /* defined below; fwd-decl so the */
                                                    /* diagnostic klogs above the def compile */
static char *g_boot;
static void *(*g_libc_memalign)(size_t, size_t);
static void  (*g_libc_free)(void *);
static xtld_obj *g_libc_obj;                      /* libc.so — COW'd via a snapshot, not identity */

/* The loader allocates program/.so IMAGES from the KERNEL heap (kern_sbrk) — NOT via
 * libc malloc. libc's arena lives in libc.so's data, which is COW'd per-process; a PL0
 * spawn runs in the CALLER's space, so libc malloc would use the caller's arena + its
 * private heap VA, and the image would be shadowed in the child's space -> XN fault on
 * exec. kern_sbrk is global + identity-mapped (SEC_KDATA, capped below the per-process
 * windows) so images are space-independent + executable everywhere. Bump-only (no
 * per-image free); images are cached/long-lived, so that's fine for now. */
void *frtos_alloc(size_t size, size_t align, void *u)
{
    (void)u;
    if (align < 16) align = 16;
    if (g_libc_memalign) {                           /* post-bootstrap: the kernel heap */
        extern void *kern_sbrk(int);
        char *base = (char *)kern_sbrk((int)(size + align));
        if (base == (char *)-1) return 0;
        return (void *)(((uintptr_t)base + (align - 1)) & ~(uintptr_t)(align - 1));
    }
    if (!g_boot) g_boot = _heap_start;               /* bootstrap bump (libc.so itself) */
    uintptr_t a = ((uintptr_t)g_boot + (align - 1)) & ~(uintptr_t)(align - 1);
    g_boot = (char *)a + size;
    return (void *)a;
}
void frtos_free(void *p, void *u) { (void)p; (void)u; }  /* bump kernel heap: images are long-lived */

/* Called after the loader has loaded libc.so: grab its allocator, and point the
 * kernel's _sbrk just above libc.so's (bootstrap-pinned) image. */
/* fault diagnostics: which loaded object (and offset) an address falls in, so a
 * PC/return-addr in a crash dump maps to <object>+<hex offset> — feed that to
 * `arm-none-eabi-addr2line -e build/<object>` (or objdump) to name the function. */
static proc_t *cur_proc(void);   /* fwd (defined below) */
#define XTLD_FAULT_SCAN_MAX 16   /* == XTLD_MAX_OBJS; never unbounded in fault context */

void fault_symbolize(unsigned addr, void (*emit)(const char *, unsigned))
{
    proc_t *p = cur_proc();
    if (p && p->obj) {
        uintptr_t b = xtld_base(p->obj); size_t s = xtld_span(p->obj);
        if (addr >= b && addr < b + s) { emit(" [prog+", (unsigned)(addr - b)); return; }
    }
    if (g_libc_obj) {
        uintptr_t b = xtld_base(g_libc_obj); size_t s = xtld_span(g_libc_obj);
        if (addr >= b && addr < b + s) { emit(" [libc+", (unsigned)(addr - b)); return; }
    }
    /* Any OTHER loaded object — libGEM.so, libm.so, a dlopened module. Without
     * this the two cases above are the only ones named and everything else
     * prints "[??+<absolute addr>]", which is unusable: the absolute address
     * cannot be turned into a function without the load base, and the base is
     * not reported anywhere. A fault in libGEM.so is exactly as likely as one
     * in the program, so name it the same way. */
    /* BOUNDED and POINTER-CHECKED, because this runs in FAULT CONTEXT. Walking
     * the registry here once turned a single data abort in 'hdmimon' into a
     * fault storm and then a scheduler assert: the abort called fault_report,
     * which called this, which faulted inside xtld_base on an object pointer
     * that was not safe to dereference. A symbolizer that can itself fault
     * destroys the very report it exists to produce, so validate first and give
     * up quietly rather than chase a bad pointer. */
    for (int i = 0; i < XTLD_FAULT_SCAN_MAX; i++) {
        xtld_obj *o = xtld_object_at(i);
        if (!o) break;
        if ((uintptr_t)o < 0x00100000u || (uintptr_t)o >= 0x10000000u) break;
        uintptr_t b = xtld_base(o); size_t s = xtld_span(o);
        if (!b || !s) continue;
        if (addr < b || addr >= b + s) continue;
        const char *nm = xtld_soname(o);
        if (nm) {
            static char nb[40];
            unsigned k = 0;
            nb[k++] = ' '; nb[k++] = '[';
            while (*nm && k < sizeof nb - 3) nb[k++] = *nm++;
            nb[k++] = '+'; nb[k] = 0;
            emit(nb, (unsigned)(addr - b));
        } else {
            emit(" [obj+", (unsigned)(addr - b));
        }
        return;
    }
    emit(" [??+", addr);
}

void frtos_activate_libc(xtld_obj *libc)
{
    extern void sbrk_set_base(void *base, void *end);
    g_libc_obj = libc;
    g_libc_memalign = (void *(*)(size_t, size_t))xtld_sym(libc, "memalign");
    g_libc_free     = (void (*)(void *))xtld_sym(libc, "free");
    uintptr_t brk = ((uintptr_t)g_boot + 0xFFFu) & ~0xFFFu;   /* page-align past libc.so */
    /* Cap the kernel heap (where libc.so loads program/.so images) BELOW the per-process
     * VA windows (heap 0x1000_0000+, cow/mmap above). Those windows are overridden
     * per-process, so any .so loaded at >=0x1000_0000 would be SHADOWED by a process's
     * private heap and fault (XN) when executed. The page pool (per-process physical)
     * still owns 0x1000_0000-0x2000_0000 from the top down. */
    sbrk_set_base((void *)brk, (void *)XTOS_HEAP_VA);
}

/* The calling process's pid, or -1 in kernel context. /dev/blitter needs it: PRIORITY is
 * privileged (gemd only), and §13's fairness is per-PROCESS, not per-fd — an app with six
 * windows opens seven blitter fds, and round-robin over fds would reward opening windows. */
int frtos_current_pid(void)
{
    proc_t *p = cur_proc();
    return p ? p->pid : -1;
}

/* M7 gate: THE DISPLAY OWNER — the one PL0 process allowed at the plane. Latched by the
 * first SYS_fb_wallpaper caller (gemd by boot order), reset when that process dies. The
 * plane-touching syscalls (SYS_overlay, SYS_plane_window) and /dev/blitter's well-known
 * PLANE/WALLPAPER handles all check it. */
static int g_fb_owner_pid = -1;
int fb_owner_pid(void) { return g_fb_owner_pid; }

static proc_t *cur_proc(void)
{
    TaskHandle_t t = xTaskGetCurrentTaskHandle();
    for (int i = 0; i < MAXPROC; i++)
        if (g_proc[i].used && g_proc[i].task == t) return &g_proc[i];
    return NULL;
}

/* T2-b: called from traceTASK_SWITCHED_IN on every context switch — point TTBR0
 * at the incoming task's address space (its process's L1 table, or the master
 * table for the kernel/shell/idle tasks). vm_switch only flushes on a change. */
void xtos_vm_on_switch(void)
{
    extern void vm_switch(uint32_t *, uint32_t);
    TaskHandle_t t = xTaskGetCurrentTaskHandle();
    uint32_t *table = (uint32_t *)0; uint32_t asid = 0;   /* master (kernel) space */
    for (int i = 0; i < MAXPROC; i++)
        if (g_proc[i].used && g_proc[i].task == t) { table = g_proc[i].l1; asid = g_proc[i].asid; break; }
    vm_switch(table, asid);
}

/* T2-c: a data abort in the current process's heap window is a lazy page —
 * map a zero-filled page on demand and resume. Returns 1 (serviced, re-run) or
 * 0 (not a demand fault -> fatal, kill the task). Called from xt_vectors.S. */
int xtos_demand_fault(uint32_t dfar)
{
    proc_t *p = cur_proc();
    if (!p) return 0;
    int idx = (int)(p - g_proc);
    uint32_t dfsr; __asm__ volatile("mrc p15,0,%0,c5,c0,0" : "=r"(dfsr));
    int write = (dfsr >> 11) & 1u;                /* DFSR.WnR: 1 = write */
    /* lazy heap: a not-present fault (read or write) in the heap window -> map a
     * zero-filled (RW) page on demand. */
    if (dfar >= XTOS_HEAP_VA && dfar < XTOS_HEAP_VA + XTOS_HEAP_SIZE)
        return vm_demand_map(idx, dfar);
    /* mmap window: a READ fault demand-maps a romfs page RO; a WRITE fault flips a
     * WRITABLE backing-store page RW + marks it dirty (dirty-via-fault), else it's a
     * write to a read-only mapping -> fatal. Both are synchronous (no FatFs). */
    if (dfar >= XTOS_MMAP_VA && dfar < XTOS_MMAP_VA + XTOS_MMAP_SIZE)
        return write ? vm_mmap_write_fault(idx, dfar) : vm_mmap_fault(idx, dfar);
    /* copy-on-write: a WRITE permission fault to a registered shared-RO page ->
     * private copy. vm_cow_map gates on the COW range, so a write to read-only TEXT
     * (W^X, not a COW range) returns 0 = fatal. */
    if (write)
        return vm_cow_map(idx, dfar);
    /* READ permission fault in a COW range: a stale-TLB shadow (a lingering global
     * section entry over a page the table maps PL0-readable) or an unseeded page —
     * re-seed/invalidate and re-run instead of killing the task. HW-only; qemu never
     * takes this path. Returns 0 for a genuine wild read (not COW) -> stays fatal.
     * This is what crashed dropbear's exec path (scp / `ssh host cmd`) on a .got.plt
     * read even though the page was mapped RW. */
    return vm_cow_read_fault(idx, dfar);
}

/* PREFETCH-abort service (called from xt_vectors.S before the fatal path, mirroring
 * xt_dabt). A permission fault on an instruction fetch whose page the tables map
 * present + executable is a stale global SECTION TLB entry shadowing the split
 * coarse text mapping (see stale-section-tlb-shadow) — TLBIALL + re-run. A livelock
 * guard bails to fatal if the SAME PC keeps faulting (so a genuine unresolvable
 * fault still dies rather than spinning). Non-permission faults and not-executable
 * pages return 0 = fatal, so real W^X violations / wild jumps still get killed. */
int xtos_prefetch_fault(uint32_t pc)
{
    proc_t *p = cur_proc();
    if (!p) return 0;
    int idx = (int)(p - g_proc);
    uint32_t ifsr; __asm__ volatile("mrc p15,0,%0,c5,c0,1" : "=r"(ifsr));
    uint32_t fs = (((ifsr >> 10) & 1u) << 4) | (ifsr & 0xfu);   /* combined fault status */
    if (fs != 0x0fu) return 0;   /* not a page-perm stale-TLB fault (wild jump / section) -> fatal */
    static uint32_t last_pc; static int repeat;      /* livelock guard (rare path) */
    if (pc == last_pc) { if (++repeat > 8) { repeat = 0; return 0; } }
    else { last_pc = pc; repeat = 0; }
    return vm_exec_fault(idx, pc);
}

/* sys_sbrk — the PL1 implementation behind SYS_sbrk (libc's _sbrk is an svc stub).
 * Per-process: a process grows its OWN heap (XTOS_HEAP_VA window, mapped to private
 * physical by vm.c); the kernel/boot libc uses kern_sbrk (the shared pool). So each
 * process's malloc heap is its own. Runs at PL1 (in the svc handler). */
void *sys_sbrk(int incr)
{
    proc_t *p = cur_proc();
    if (p && p->heap_brk) {
        if (p->heap_brk + (uint32_t)incr > p->heap_end) return (void *)-1;
        void *r = (void *)p->heap_brk; p->heap_brk += (uint32_t)incr; return r;
    }
    extern void *kern_sbrk(int);
    return kern_sbrk(incr);
}

/* runs in TASK (System-mode) context — safe to call yielding FreeRTOS APIs.
 *
 * The task does NOT delete itself. Self-delete (vTaskDelete(NULL)) only marks the TCB
 * for deferred teardown by the IDLE task, so its lists aren't unlinked yet — but the
 * `done`/notify wake lets the waiter reap the proc slot and REUSE the static TCB/stack
 * immediately, while the old task is still linked in FreeRTOS's ready/termination
 * lists. That cross-links the lists (a reused TCB in two lists at once) and corrupts
 * scheduling. Instead the task marks itself exited, wakes the waiter, and SUSPENDS
 * itself. The waiter (frtos_reap) then calls vTaskDelete on THIS handle from another
 * task, which runs prvDeleteTCB inline — fully unlinking it from every list — before
 * the slot is freed. No self-delete, no IDLE teardown, no reuse-before-unlink. */
/* Release a dying process's pipe ends NOW (task context, before anyone waits):
 * EOF/EPIPE must reach the peer immediately — a pipeline reader blocks for EOF
 * BEFORE it waitpids, so leaving this to the reap would deadlock. File fds keep
 * waiting for the reap (they need the fs task). Idempotent vs fs_close_all. */
static void pipes_release(proc_t *p)
{
    for (int fd = 0; fd < NFD; fd++) {
        if (!p->fd[fd].open) continue;
        if (p->fd[fd].pipei) { k_pipe_close_end(&p->fd[fd]); continue; }
        /* Channel + service fds: same argument as pipes, and stronger. gemd learns a
         * client died by its channel hitting EOF (SIGCHLD only reaches the PARENT, and
         * the server is not the parent of an ssh-launched client). If we deferred this to
         * the reap, a dead client's window would linger until someone waitpid'd it -- and
         * nobody will. */
        if (p->fd[fd].rpipe || p->fd[fd].wpipe) { k_chan_close(&p->fd[fd]); continue; }
        if (p->fd[fd].svc) {
            svc_t *sv = &g_svc[p->fd[fd].svc - 1];
            taskENTER_CRITICAL();                    /* drop unaccepted connects, free their pipes */
            for (int i = 0; i < sv->nq; i++) {
                for (int k = 0; k < 2; k++) {
                    kpipe_t *pp = &g_pipes[sv->q[i][k]];
                    if (pp->used) { pp->used = 0; vStreamBufferDelete(pp->sb); pp->sb = 0; }
                }
            }
            sv->nq = 0; sv->used = 0;                /* the name is free again */
            taskEXIT_CRITICAL();
            p->fd[fd].open = 0; p->fd[fd].svc = 0;
            continue;
        }
        /* pty slave (char device): release NOW too, for the same reason. When an
         * interactive ssh shell exits, dropbear blocks reading the pty MASTER for
         * EOF — which only arrives once the slave's open count hits 0. If we left
         * that to the reap (fs_close_all), the reap would never run: it needs the
         * parent's waitpid, but the parent is blocked on the master. Deadlock →
         * the session (and the ssh client) hang. The pty close is a pure in-memory
         * refcount (dv_pty_close), safe in the dying task's context — unlike a
         * file, whose flush needs the fs task, so files still wait for the reap. */
        if (!p->fd[fd].con && !p->fd[fd].sock &&
            p->fd[fd].vf.chr && p->fd[fd].vf.close) {
            p->fd[fd].vf.close(&p->fd[fd].vf);
            p->fd[fd].open = 0;
        }
    }
}

static void tty_release(proc_t *p)
{
    if (p && g_tty_owner && p->pid == g_tty_owner) {
        g_tty.canon = 1; g_tty.echo = 1;
        g_tty_owner = 0;
    }
}

/* the cooked line buffer (shared: the read discipline fills/drains it; the tty
 * ioctls count its leftover as pending input) */
static char g_lbuf[256];
static int  g_lpos, g_llen, g_lsawcr;

extern int con_tty_avail(void);   /* buffered console bytes (uart1_rx.c; qemu -1 = unknown) */
extern int con_tty_wait(int ms);  /* wait for console input WITHOUT consuming (qemu: always 1) */

static long k_tty_ioctl(proc_t *p, unsigned req, void *arg)
{
    struct xt_ttymode *m = (struct xt_ttymode *)arg;
    switch (req) {
    case XT_TTY_GETMODE:
        if (!m) return -1;
        m->canon = g_tty.canon; m->echo = g_tty.echo;
        return 0;
    case XT_TTY_SETMODE:
        if (!m) return -1;
        g_tty.canon = m->canon ? 1u : 0u;
        g_tty.echo  = m->echo  ? 1u : 0u;
        g_tty_owner = p ? p->pid : 0;
        return 0;
    case XT_TTY_NREAD: {
        if (!arg) return -1;
        int n = g_llen - g_lpos;
        int a = con_tty_avail();
        *(int *)arg = n + (a > 0 ? a : 0);
        return 0;
    }
    case XT_TTY_INWAIT:                                  /* arg = timeout ms BY VALUE */
        if (g_llen - g_lpos > 0) return 1;
        return con_tty_wait((int)(intptr_t)arg);
    default: return -1;
    }
}

/* mark this process exited and park (task context only — the exit thunk, or
 * a deferral that must die in place, e.g. the SIGPIPE emulation) */
static void proc_exit_self(proc_t *p, int code)
{
    if (p) {
        p->exit_code = code;
        pipes_release(p);                            /* EOF to pipeline peers first */
        tty_release(p);                              /* raw-mode owner dies -> cooked */
        p->exited = 1;

        /* Re-parent this process's children to init(1) BEFORE we announce our death.
         * Two things must happen, and the second is the actual bug:
         *   - ppid -> init, so a future SIGCHLD/waitpid has somewhere real to go;
         *   - if a child's waiter was US, the claim dies with us. `waited` left set
         *     makes reap_orphans() skip that child FOREVER -- it is not a zombie
         *     waiting to be collected, it is a zombie nobody is ALLOWED to collect. */
        for (int i = 0; i < MAXPROC; i++) {
            proc_t *c = &g_proc[i];
            if (!c->used || c == p || c->ppid != p->pid) continue;
            c->ppid = g_init_pid ? g_init_pid : 0;
            if (c->waiter == p->task) { c->waiter = 0; c->waited = 0; }
        }

        sig_raise(proc_by_pid(p->ppid), XT_SIGCHLD); /* notify the parent (real async SIGCHLD) */
        if (p->waiter) xTaskNotifyGive(p->waiter);   /* wake a PL0 waitpid (task notification) */
        if (p->done)   xSemaphoreGive(p->done);      /* wake a kernel-task waitpid (shell_task) */
    }
    vTaskSuspend(NULL);                              /* park; the waiter deletes us via frtos_reap */
    for (;;) vTaskSuspend(NULL);                     /* never resumed */
}

static void task_exit_thunk(void)
{
    proc_t *p = cur_proc();
    proc_exit_self(p, p ? p->exit_code : 0);
}

/* Kernel blocking primitives OUTSIDE the pipe/pty loops (the UART ring q_read,
 * etc.) call this each poll so a kill/signal is honoured even though the task is
 * parked at PL1 (async-tick delivery can't reach a kernel-blocked task — it only
 * fires on return-to-PL0). Returns -4 (-EINTR) if a catchable signal is pending
 * (the caller unwinds; the deferral thunk then delivers the handler), never
 * returns on kill (proc_exit_self). Task context only. */
int xt_block_check(void)
{
    proc_t *p = cur_proc();
    if (p && p->killed) proc_exit_self(p, 137);   /* SIGKILL/default-terminate: die here */
    return sig_ready(p) ? -4 : 0;
}

/* SIGSTOP/SIGTSTP park (task context: the deferral thunk or a blocking-loop
 * tick). Wakes a blocked waitpid first — it reports "stopped" to the shell —
 * then polls the flag (no suspend/resume: a poll can't lose the SIGCONT race).
 * A SYS_kill that lands while stopped kills without needing a SIGCONT. */
static void stop_park(proc_t *p)
{
    if (!p || !p->stopped) return;
    if (p->waiter) xTaskNotifyGive(p->waiter);
    while (p->stopped && !p->killed) vTaskDelay(pdMS_TO_TICKS(20));
    if (p->killed) proc_exit_self(p, 137);          /* no return */
}

/* For a STACK OVERFLOW (DFAR in a guard page) the task's own stack is unusable,
 * so xt_vectors.S points its SP at this per-process emergency stack before running
 * the kill thunk. For any other fault the task's stack is fine -> return 0 (leave
 * SP alone, use today's path). */
uint32_t xtos_emerg_sp(void)
{
    uint32_t dfar; __asm__ volatile("mrc p15,0,%0,c6,c0,0" : "=r"(dfar));
    extern int stackguard_is_guard(unsigned);
    if (!stackguard_is_guard(dfar)) return 0;
    extern uint32_t stackguard_emerg_top(int);
    proc_t *p = cur_proc();
    return p ? stackguard_emerg_top((int)(p - g_proc)) : 0;
}

/* T2-a.2: the abort handler (xt_vectors.S) redirects a faulting task here — it
 * runs in the task's own (System-mode) context, so it can give the waitpid
 * semaphore (unblock the parent) and delete itself; the OS keeps running. */
void xtos_task_fault_exit(void)
{
    proc_t *p = cur_proc();
    if (p && !p->exited) {                          /* FIRST fault for this task */
        /* Mark exited BEFORE the cleanup below. If the task's state is corrupt enough
         * that pipes_release/tty_release themselves fault, the abort handler redirects
         * us straight back here — and now `exited` is set, so we skip the cleanup and
         * fall through to the park instead of re-running it forever (the loop that grew
         * the stack until the guard tripped, wedging the box). */
        p->exited = 1;
        p->exit_code = -1;
        sig_raise(proc_by_pid(p->ppid), XT_SIGCHLD);/* notify the parent (crashed child) */
        pipes_release(p);                           /* EOF to pipeline peers first */
        tty_release(p);                             /* raw-mode owner dies -> cooked */
        if (p->waiter) xTaskNotifyGive(p->waiter);  /* wake a PL0 waitpid */
        if (p->done)   xSemaphoreGive(p->done);     /* wake a kernel-task waitpid */
    }
    vTaskSuspend(NULL);                             /* park; the waiter reaps us (see task_exit_thunk) */
    for (;;) vTaskSuspend(NULL);
}

/* ---- file syscalls (dispatch through the VFS: romfs / fatfs / ...) ------ */
/* task id of the open in flight — opens run in the fs task, so a reentrant driver
 * (lockfs) that needs the *caller's* identity reads it here rather than cur-task. */
int g_fs_client = -1;

static long sys_open(proc_t *p, const char *path, int flags)
{
    if (!p) return -1;
    g_fs_client = (int)(p - g_proc);                                  /* holder id for lockfs */
    for (int fd = 3; fd < NFD; fd++) {
        if (!p->fd[fd].open) {
            if (vfs_open(path, flags, &p->fd[fd].vf) != 0) return -1;
            if (p->fd[fd].vf.chr == VFS_CHR_TTY) {      /* /OS/dev/tty: the console itself */
                memset(&p->fd[fd], 0, sizeof(fd_t));
                p->fd[fd].open = 1; p->fd[fd].con = 1;  /* console alias — existing routing */
                return fd;
            }
            /* O_APPEND: the logical cursor starts at EOF (single-writer append) */
            p->fd[fd].pos = (flags & VFS_O_APPEND) ? p->fd[fd].vf.size : 0;
            p->fd[fd].cpi = ~0u; p->fd[fd].cpage = 0;                      /* page store: empty */
            p->fd[fd].cdirty = 0;
            p->fd[fd].oflags = flags;                                      /* retained for reopen-by-path */
            p->fd[fd].pipei = 0; p->fd[fd].pwrite = 0; p->fd[fd].con = 0;  /* slot may have held a pipe/alias */
            int k = 0;                                                    /* retain path for mmap write-back */
            for (; path[k] && k < FD_PATH_MAX - 1; k++) p->fd[fd].path[k] = path[k];
            p->fd[fd].path[k] = 0;
            p->fd[fd].open = 1;
            return fd;
        }
    }
    return -1; /* -EMFILE */
}

/* non-deferred read fallback: valid file reads (fd>=3) go through the page store
 * (fs_read, deferred); this only ever sees stdin (fd 0, non-deferred path -> EOF) or
 * the unreadable stdio writers (fd 1/2) / bad fds. */
static long sys_read(proc_t *p, int fd, void *buf, uint32_t n)
{
    (void)p; (void)buf; (void)n;
    return (fd == 0) ? 0 : -1;
}

/* ---- pipe ops (task context only: they block / take the FreeRTOS heap) ---- */
static int fd_is_pipe(uint32_t fd)
{
    proc_t *p = cur_proc();
    return p && fd < NFD && p->fd[fd].open && p->fd[fd].pipei;
}

static int fd_is_sock(uint32_t fd)
{
    proc_t *p = cur_proc();
    return p && fd < NFD && p->fd[fd].open && p->fd[fd].sock;
}

/* ---- the socket syscall family (deferral ctx; netconn work in net/sockets.c).
 * fd wrapping/unwrapping lives here; blocking ops tick so kill/^C/^Z land. */
static int sock_tick(void *vp)
{
    proc_t *p = (proc_t *)vp;
    if (p->killed) proc_exit_self(p, 137);           /* no return */
    stop_park(p);
    return 0;
}

static int sock_fd_new(proc_t *p, int si)
{
    for (int fd = 3; fd < NFD; fd++)
        if (!p->fd[fd].open) {
            memset(&p->fd[fd], 0, sizeof(fd_t));
            p->fd[fd].open = 1;
            p->fd[fd].sock = si + 1;
            return fd;
        }
    return -1;
}

static long k_socket_call(proc_t *p)
{
    extern int  xt_sock_new(int);
    extern void xt_sock_close(int);
    extern int  xt_sock_connect(int, unsigned, unsigned);
    extern int  xt_sock_bind(int, unsigned, unsigned);
    extern int  xt_sock_listen(int, int);
    extern int  xt_sock_accept(int, unsigned *, unsigned *, int (*)(void *), void *, int);
    extern int  xt_sock_resolve(const char *, unsigned *);
    uint32_t fd = p->da0;
    switch (p->dnum) {
    case SYS_socket: {
        int si = xt_sock_new((int)p->da0);
        if (si < 0) return -1;
        int nfd = sock_fd_new(p, si);
        if (nfd < 0) { xt_sock_close(si); return -1; }
        return nfd;
    }
    case SYS_connect:
    case SYS_bind:
        if (fd >= NFD || !p->fd[fd].open || !p->fd[fd].sock) return -1;
        return (p->dnum == SYS_connect)
             ? xt_sock_connect(p->fd[fd].sock - 1, (unsigned)p->da1, (unsigned)p->da2)
             : xt_sock_bind(p->fd[fd].sock - 1, (unsigned)p->da1, (unsigned)p->da2);
    case SYS_listen:
        if (fd >= NFD || !p->fd[fd].open || !p->fd[fd].sock) return -1;
        return xt_sock_listen(p->fd[fd].sock - 1, (int)p->da1);
    case SYS_accept: {
        if (fd >= NFD || !p->fd[fd].open || !p->fd[fd].sock) return -1;
        unsigned peer[2] = { 0, 0 };
        int si = xt_sock_accept(p->fd[fd].sock - 1, &peer[0], &peer[1], sock_tick, p, (int)p->da2);
        if (si == -2) return -2;                   /* da2=1 nonblock, none pending (EAGAIN) */
        if (si < 0) return -1;
        int nfd = sock_fd_new(p, si);
        if (nfd < 0) { xt_sock_close(si); return -1; }
        if (p->da1) { unsigned *out = (unsigned *)p->da1; out[0] = peer[0]; out[1] = peer[1]; }
        return nfd;
    }
    case SYS_resolve: {
        /* the resolver runs in the LWIP THREAD: the name must live in kernel-
         * global memory, never client space (the kfs-path lesson) */
        static char nm[128];
        const char *s = (const char *)p->da0;
        if (!s || !p->da1) return -1;
        int i = 0;
        for (; s[i] && i < 127; i++) nm[i] = s[i];
        nm[i] = 0;
        unsigned ip = 0;
        if (xt_sock_resolve(nm, &ip) != 0) return -1;
        *(unsigned *)p->da1 = ip;
        return 0;
    }
    }
    return -1;
}

static long k_pipe_create(proc_t *p, int *out)
{
    if (!p || !out) return -1;
    int fda = -1, fdb = -1;
    for (int fd = 3; fd < NFD; fd++)
        if (!p->fd[fd].open) { if (fda < 0) fda = fd; else { fdb = fd; break; } }
    if (fdb < 0) return -1;                                 /* -EMFILE */
    int pi = -1;
    for (int i = 0; i < MAXPIPE; i++) if (!g_pipes[i].used) { pi = i; break; }
    if (pi < 0) return -1;
    g_pipes[pi].sb = xStreamBufferCreate(PIPE_BUF_SZ, 1);
    if (!g_pipes[pi].sb) return -1;
    g_pipes[pi].readers = 1; g_pipes[pi].writers = 1; g_pipes[pi].used = 1;
    note_pipe_hwm();                                        /* /OS/proc/limits peak */
    memset(&p->fd[fda], 0, sizeof(fd_t));
    memset(&p->fd[fdb], 0, sizeof(fd_t));
    p->fd[fda].open = 1; p->fd[fda].pipei = pi + 1; p->fd[fda].pwrite = 0;
    p->fd[fdb].open = 1; p->fd[fdb].pipei = pi + 1; p->fd[fdb].pwrite = 1;
    out[0] = fda; out[1] = fdb;
    return 0;
}

static void k_pipe_close_end(fd_t *f)
{
    kpipe_t *pp = &g_pipes[f->pipei - 1];
    int dead;
    taskENTER_CRITICAL();
    if (f->pwrite) { if (pp->writers > 0) pp->writers--; }
    else           { if (pp->readers > 0) pp->readers--; }
    dead = pp->used && pp->readers <= 0 && pp->writers <= 0;
    if (dead) pp->used = 0;
    taskEXIT_CRITICAL();
    f->open = 0; f->pipei = 0; f->pwrite = 0;
    if (dead) { vStreamBufferDelete(pp->sb); pp->sb = 0; }
}

/* blocking read: data if any, 0 (EOF) once all writers are gone and the ring is
 * drained. The timed receive doubles as the writer-exit wakeup (no wait queues). */
static void proc_exit_self(proc_t *p, int code);   /* fwd (task-context death) */

static long k_pipe_read(proc_t *p, int fd, char *buf, uint32_t n)
{
    kpipe_t *pp = &g_pipes[p->fd[fd].pipei - 1];
    if (!buf || !n) return 0;
    for (;;) {
        if (p->killed) proc_exit_self(p, 137);              /* SYS_kill lands here */
        if (sig_ready(p)) return -4;                        /* -EINTR: caught signal pending */
        stop_park(p);                                       /* ^Z lands here too */
        size_t got = xStreamBufferReceive(pp->sb, buf, n, pdMS_TO_TICKS(20));
        if (got > 0) return (long)got;
        if (pp->writers <= 0) {
            got = xStreamBufferReceive(pp->sb, buf, n, 0);  /* final drain */
            return (long)got;
        }
        if (p->fd[fd].nonblock) return -11;                 /* O_NONBLOCK, empty -> -EAGAIN */
    }
}

/* blocking write: park while the ring is full; error once no reader remains */
static long k_pipe_write(proc_t *p, int fd, const char *buf, uint32_t n)
{
    kpipe_t *pp = &g_pipes[p->fd[fd].pipei - 1];
    uint32_t sent = 0;
    if (!n) return 0;      /* zero-length write is a no-op, not EPIPE — dropbear's
                            * writechannel probes with len 0 + NULL buf, and a -1
                            * here trips the SIGPIPE kill below */
    if (!buf) return -1;
    while (sent < n) {
        if (p->killed) proc_exit_self(p, 137);                  /* SYS_kill lands here */
        if (sig_ready(p)) return sent ? (long)sent : -4;        /* -EINTR (or short write) */
        stop_park(p);                                           /* ^Z lands here too */
        if (pp->readers <= 0) return sent ? (long)sent : -1;    /* EPIPE-ish */
        sent += xStreamBufferSend(pp->sb, buf + sent, n - sent, pdMS_TO_TICKS(20));
    }
    return (long)sent;
}

/* ---- services: the rendezvous XTOS did not have ----------------------------
 * Pipes need shared ancestry, so a boot-script-launched server and an ssh-launched client
 * could not talk AT ALL -- which is precisely gemd's situation. Sockets are lwIP-only, so
 * a window server would have depended on DHCP coming up.
 *
 * A service is a NAME a process registers. Anyone may connect to it by that name. Connect
 * creates TWO pipes (client->server, server->client) and hands the client one BIDIRECTIONAL
 * fd; accept() hands the server the mirrored fd. After that it is just read()/write()/
 * poll()/close() -- deliberately BSD-shaped, so there is no new mental model.
 *
 * Death detection is free: a dying process releases its pipe ends, so the peer's read()
 * returns EOF. That matters because SIGCHLD only reaches the PARENT, and a window server
 * is not the parent of an ssh-launched client -- so signal-based reaping would simply not
 * fire for most clients. EOF fires for everyone. */
static int k_pipe_alloc(void)                       /* one pipe, refcounts left to caller */
{
    for (int i = 0; i < MAXPIPE; i++)
        if (!g_pipes[i].used) {
            g_pipes[i].sb = xStreamBufferCreate(PIPE_BUF_SZ, 1);
            if (!g_pipes[i].sb) return -1;
            g_pipes[i].readers = 1; g_pipes[i].writers = 1; g_pipes[i].used = 1;
            note_pipe_hwm();
            return i;
        }
    return -1;
}

static int fd_alloc_slot(proc_t *p)
{
    for (int fd = 3; fd < NFD; fd++) if (!p->fd[fd].open) return fd;
    return -1;                                       /* -EMFILE */
}

static long k_svc_register(proc_t *p, const char *name)
{
    if (!p || !name || !*name) return -1;
    for (int i = 0; i < MAXSVC; i++)                 /* one holder per name */
        if (g_svc[i].used && !strncmp(g_svc[i].name, name, sizeof g_svc[i].name - 1)) return -1;
    int si = -1;
    for (int i = 0; i < MAXSVC; i++) if (!g_svc[i].used) { si = i; break; }
    if (si < 0) return -1;
    int fd = fd_alloc_slot(p);
    if (fd < 0) return -1;
    memset(&g_svc[si], 0, sizeof g_svc[si]);
    for (unsigned i = 0; i + 1 < sizeof g_svc[si].name && name[i]; i++)   /* freestanding: no strncpy */
        g_svc[si].name[i] = name[i];
    g_svc[si].used = 1;
    memset(&p->fd[fd], 0, sizeof(fd_t));
    p->fd[fd].open = 1; p->fd[fd].svc = si + 1;
    return fd;
}

static long k_svc_connect(proc_t *p, const char *name)
{
    if (!p || !name) return -1;
    int si = -1;
    for (int i = 0; i < MAXSVC; i++)
        if (g_svc[i].used && !strncmp(g_svc[i].name, name, sizeof g_svc[i].name - 1)) { si = i; break; }
    if (si < 0) return -2;                           /* -ENOENT: no such service */
    if (g_svc[si].nq >= SVC_BACKLOG) return -11;     /* -EAGAIN: backlog full */
    int fd = fd_alloc_slot(p);
    if (fd < 0) return -1;
    int c2s = k_pipe_alloc(); if (c2s < 0) return -1;
    int s2c = k_pipe_alloc();
    if (s2c < 0) { g_pipes[c2s].used = 0; vStreamBufferDelete(g_pipes[c2s].sb); return -1; }
    memset(&p->fd[fd], 0, sizeof(fd_t));
    p->fd[fd].open = 1;
    p->fd[fd].rpipe = s2c + 1;                       /* client reads what the server sends */
    p->fd[fd].wpipe = c2s + 1;                       /* client writes to the server */
    p->fd[fd].peer  = 0;                             /* the client learns nothing about the server */
    taskENTER_CRITICAL();
    g_svc[si].q[g_svc[si].nq][0] = c2s;
    g_svc[si].q[g_svc[si].nq][1] = s2c;
    g_svc[si].q[g_svc[si].nq][2] = p->pid;           /* who is connecting — accept() hands it over */
    g_svc[si].nq++;
    taskEXIT_CRITICAL();
    return fd;
}

static long k_svc_accept(proc_t *p, int lfd)
{
    if (!p || lfd < 0 || lfd >= NFD || !p->fd[lfd].open || !p->fd[lfd].svc) return -1;
    svc_t *sv = &g_svc[p->fd[lfd].svc - 1];
    for (;;) {
        if (p->killed) proc_exit_self(p, 137);
        if (sig_ready(p)) return -4;                 /* -EINTR */
        stop_park(p);
        int c2s = -1, s2c = -1, cpid = 0;
        taskENTER_CRITICAL();
        if (sv->nq > 0) {
            c2s = sv->q[0][0]; s2c = sv->q[0][1]; cpid = sv->q[0][2];
            for (int i = 1; i < sv->nq; i++) {
                sv->q[i-1][0] = sv->q[i][0]; sv->q[i-1][1] = sv->q[i][1]; sv->q[i-1][2] = sv->q[i][2];
            }
            sv->nq--;
        }
        taskEXIT_CRITICAL();
        if (c2s >= 0) {
            int fd = fd_alloc_slot(p);
            if (fd < 0) return -1;
            memset(&p->fd[fd], 0, sizeof(fd_t));
            p->fd[fd].open = 1;
            p->fd[fd].rpipe = c2s + 1;               /* server reads what the client sends */
            p->fd[fd].wpipe = s2c + 1;
            p->fd[fd].peer  = cpid;                  /* SYS_chan_peer: who this really is */
            return fd;
        }
        if (p->fd[lfd].nonblock) return -11;         /* -EAGAIN */
        vTaskDelay(pdMS_TO_TICKS(10));
    }
}

/* channel read/write: same semantics as a pipe end, but the fd carries both directions. */
static long k_chan_read(proc_t *p, int fd, char *buf, uint32_t n)
{
    kpipe_t *pp = &g_pipes[p->fd[fd].rpipe - 1];
    if (!buf || !n) return 0;
    for (;;) {
        if (p->killed) proc_exit_self(p, 137);
        if (sig_ready(p)) return -4;
        stop_park(p);
        size_t got = xStreamBufferReceive(pp->sb, buf, n, pdMS_TO_TICKS(20));
        if (got > 0) return (long)got;
        if (pp->writers <= 0) {                      /* peer gone: drain, then EOF */
            got = xStreamBufferReceive(pp->sb, buf, n, 0);
            return (long)got;
        }
        if (p->fd[fd].nonblock) return -11;
    }
}

static long k_chan_write(proc_t *p, int fd, const char *buf, uint32_t n)
{
    kpipe_t *pp = &g_pipes[p->fd[fd].wpipe - 1];
    uint32_t sent = 0;
    if (!n) return 0;
    if (!buf) return -1;
    while (sent < n) {
        if (p->killed) proc_exit_self(p, 137);
        if (sig_ready(p)) return sent ? (long)sent : -4;
        stop_park(p);
        if (pp->readers <= 0) return sent ? (long)sent : -1;   /* peer gone */
        sent += xStreamBufferSend(pp->sb, buf + sent, n - sent, pdMS_TO_TICKS(20));
    }
    return (long)sent;
}

static void k_chan_close(fd_t *f)
{
    if (f->rpipe) {
        kpipe_t *pp = &g_pipes[f->rpipe - 1];
        int dead;
        taskENTER_CRITICAL();
        if (pp->readers > 0) pp->readers--;
        dead = pp->used && pp->readers <= 0 && pp->writers <= 0;
        if (dead) pp->used = 0;
        taskEXIT_CRITICAL();
        if (dead) { vStreamBufferDelete(pp->sb); pp->sb = 0; }
    }
    if (f->wpipe) {
        kpipe_t *pp = &g_pipes[f->wpipe - 1];
        int dead;
        taskENTER_CRITICAL();
        if (pp->writers > 0) pp->writers--;
        dead = pp->used && pp->readers <= 0 && pp->writers <= 0;
        if (dead) pp->used = 0;
        taskEXIT_CRITICAL();
        if (dead) { vStreamBufferDelete(pp->sb); pp->sb = 0; }
    }
    f->open = 0; f->rpipe = 0; f->wpipe = 0;
}

/* ---- poll(2) --------------------------------------------------------------
 * The other thing XTOS did not have. Without it a server with N clients plus an input
 * source has no single wait, and every design degenerates into a thread per client or a
 * spin. Level-triggered, scan-based: each pass asks every fd whether it is ready, and
 * sleeps 2 ms between passes. Not edge-triggered -- it does not need to be, and the
 * alternative (wiring a wait-queue into every writer) is a much larger change to the
 * pipe/socket/devfs paths. 2 ms is well under a frame; the GUI cannot tell. */
extern long xt_sock_avail(int);

static short poll_revents(proc_t *p, int fd, short events)
{
    if (fd < 0 || fd >= NFD || !p->fd[fd].open) return XT_POLLNVAL;
    fd_t *f = &p->fd[fd];
    short re = 0;

    if (f->svc) {                                    /* listen fd: readable == a pending connect */
        if (g_svc[f->svc - 1].nq > 0) re |= XT_POLLIN;
        return re & (events | XT_POLLERR | XT_POLLHUP | XT_POLLNVAL);
    }
    if (f->rpipe || f->wpipe) {                      /* channel */
        if (f->rpipe) {
            kpipe_t *pp = &g_pipes[f->rpipe - 1];
            if (xStreamBufferBytesAvailable(pp->sb) > 0) re |= XT_POLLIN;
            if (pp->writers <= 0) re |= XT_POLLIN | XT_POLLHUP;   /* EOF is readable */
        }
        if (f->wpipe) {
            kpipe_t *pp = &g_pipes[f->wpipe - 1];
            if (pp->readers <= 0) re |= XT_POLLERR;
            else if (xStreamBufferSpacesAvailable(pp->sb) > 0) re |= XT_POLLOUT;
        }
        return re & (events | XT_POLLERR | XT_POLLHUP | XT_POLLNVAL);
    }
    if (f->pipei) {                                  /* ordinary pipe end */
        kpipe_t *pp = &g_pipes[f->pipei - 1];
        if (!f->pwrite) {
            if (xStreamBufferBytesAvailable(pp->sb) > 0) re |= XT_POLLIN;
            if (pp->writers <= 0) re |= XT_POLLIN | XT_POLLHUP;
        } else {
            if (pp->readers <= 0) re |= XT_POLLERR;
            else if (xStreamBufferSpacesAvailable(pp->sb) > 0) re |= XT_POLLOUT;
        }
        return re & (events | XT_POLLERR | XT_POLLHUP | XT_POLLNVAL);
    }
    if (f->sock) {
        if (xt_sock_avail(f->sock - 1) > 0) re |= XT_POLLIN;
        re |= XT_POLLOUT;                            /* lwIP send blocks rather than refusing */
        return re & (events | XT_POLLERR | XT_POLLHUP | XT_POLLNVAL);
    }
    /* A char device that can SAY whether it has anything (vf.avail): /dev/input, and every
     * future device you can wait on. Without this the rule below ("always ready") makes a poller
     * spin and then BLOCK inside read() — a wedged server with a busy loop in front of it. */
    if (f->vf.chr && f->vf.avail) {
        if (f->vf.avail(&f->vf) > 0) re |= XT_POLLIN;
        re |= XT_POLLOUT;
        return re & (events | XT_POLLERR | XT_POLLHUP | XT_POLLNVAL);
    }
    /* VFS file / device node: regular files are always ready. */
    re |= (XT_POLLIN | XT_POLLOUT);
    return re & (events | XT_POLLERR | XT_POLLHUP | XT_POLLNVAL);
}

static long k_poll(proc_t *p, struct xt_pollfd *fds, int nfds, int timeout_ms)
{
    if (!p || (!fds && nfds) || nfds < 0 || nfds > NFD) return -1;
    int waited = 0;
    for (;;) {
        if (p->killed) proc_exit_self(p, 137);
        if (sig_ready(p)) return -4;                 /* -EINTR */
        stop_park(p);
        int ready = 0;
        for (int i = 0; i < nfds; i++) {
            fds[i].revents = poll_revents(p, fds[i].fd, fds[i].events);
            if (fds[i].revents) ready++;
        }
        if (ready) return ready;
        if (timeout_ms == 0) return 0;
        if (timeout_ms > 0 && waited >= timeout_ms) return 0;
        vTaskDelay(pdMS_TO_TICKS(2));
        waited += 2;
    }
}

/* ---- pseudoterminals (pty) — SSH interactive sessions ---------------------
 * A pty pair is two byte streams: master->slave (dropbear -> shell keystrokes) and
 * slave->master (shell output -> dropbear). PASS-THROUGH: no kernel line discipline; an
 * interactive shell (linenoise) sets raw mode and echoes/edits itself. Fixed BSD-style
 * pairs /dev/ptyp[0-3] (master) + /dev/ttyp[0-3] (slave) — the method dropbear's sshpty.c
 * falls back to with no /dev/ptmx. devfs exposes the nodes and calls these. canon/echo is
 * tracked for tcgetattr/tcsetattr but not enforced (pass-through). */
#define NPTY 4
#define PTY_BUF_SZ 4096
static struct {
    StreamBufferHandle_t m2s, s2m;
    uint16_t rows, cols;
    uint8_t  canon, echo, mopen, sopen;
    uint8_t  winch;              /* window size changed since the last slave read */
} g_pty[NPTY];

static int pty_ensure(int i)
{
    if (i < 0 || i >= NPTY) return -1;
    if (!g_pty[i].m2s) g_pty[i].m2s = xStreamBufferCreate(PTY_BUF_SZ, 1);
    if (!g_pty[i].s2m) g_pty[i].s2m = xStreamBufferCreate(PTY_BUF_SZ, 1);
    if (!g_pty[i].rows) { g_pty[i].rows = 24; g_pty[i].cols = 80; g_pty[i].canon = 1; g_pty[i].echo = 1; }
    return (g_pty[i].m2s && g_pty[i].s2m) ? 0 : -1;
}

/* mopen/sopen are OPEN COUNTS, not flags: an SSH pty child dup2's the slave onto 0/1/2 and
 * dropbear closes its own slave copy, so the slave END is "closed" (EOF to the master) only
 * when every holder has closed. Each fd inheriting the pty (spawn copy) bumps the count via
 * ondup -> xt_pty_open. */
void xt_pty_open(int i, int master)
{
    if (pty_ensure(i) != 0) return;
    if (master && !g_pty[i].mopen) {
        /* fresh master = a new session claiming the pair: drop anything a dead
         * session left in the streams, or it replays into the new session */
        xStreamBufferReset(g_pty[i].m2s);
        xStreamBufferReset(g_pty[i].s2m);
    }
    if (master) g_pty[i].mopen++; else g_pty[i].sopen++;
}
void xt_pty_close(int i, int master)
{
    if (i < 0 || i >= NPTY) return;
    if (master) { if (g_pty[i].mopen) g_pty[i].mopen--; }
    else        { if (g_pty[i].sopen) g_pty[i].sopen--; }
}
long xt_pty_read(int i, int master, void *buf, uint32_t n, int nonblock)
{
    if (pty_ensure(i) != 0 || !buf || !n) return 0;
    StreamBufferHandle_t sb = master ? g_pty[i].s2m : g_pty[i].m2s;
    proc_t *p = cur_proc();
    for (;;) {
        if (p && p->killed) proc_exit_self(p, 137);
        if (sig_ready(p)) return -4;                       /* -EINTR: caught signal pending */
        if (p) stop_park(p);
        if (!master && g_pty[i].winch) {
            /* terminal size changed: raise SIGWINCH on the reader. Only unwind with
             * -EINTR if it's actually DELIVERABLE (a handler is installed) — a process
             * with the default disposition (ignore) must NOT see EINTR, or its read
             * spuriously fails. This bit an ssh login shell (toysh, no SIGWINCH handler):
             * dropbear's initial TIOCSWINSZ set winch, the shell's first read EINTR'd,
             * and toysh (post-signal-rework, read no longer auto-retries) took it as
             * EOF and exited — the "first ssh always closes" bug (only the first, since
             * the pty then holds the client's size so later sessions don't change it). */
            g_pty[i].winch = 0;
            sig_raise(cur_proc(), XT_SIGWINCH);            /* pending only if a handler exists */
            if (sig_ready(p)) return -4;                   /* -EINTR to vector the handler */
        }
        size_t got = xStreamBufferReceive(sb, buf, n, pdMS_TO_TICKS(20));
        if (got > 0) return (long)got;
        if (!(master ? g_pty[i].sopen : g_pty[i].mopen)) return 0;   /* other end closed -> EOF */
        if (nonblock) return -11;                                    /* O_NONBLOCK, empty -> EAGAIN */
    }
}
long xt_pty_write(int i, int master, const void *buf, uint32_t n)
{
    if (pty_ensure(i) != 0) return -1;
    if (!n) return 0;              /* zero-length write is a no-op, not an error
                                    * (dropbear's writechannel probes with len 0
                                    * and a NULL buffer when its ring is empty) */
    if (!buf) return -1;
    StreamBufferHandle_t sb = master ? g_pty[i].m2s : g_pty[i].s2m;
    if (!(master ? g_pty[i].sopen : g_pty[i].mopen)) return (long)n;  /* reader gone: drop */
    const char *p = buf;
    uint32_t done = 0;
    proc_t *pr = cur_proc();
    while (done < n) {
        if (pr && pr->killed) proc_exit_self(pr, 137);
        if (sig_ready(pr)) return done ? (long)done : -4;   /* -EINTR (or short write) */
        if (!(master ? g_pty[i].sopen : g_pty[i].mopen)) break;
        if (!master && p[done] == '\n') {
            /* ONLCR — the one output-discipline rule an interactive terminal
             * needs: shell/program output writes bare \n, the ssh client's
             * terminal is raw, so \n must leave the slave as \r\n. Everything
             * else stays pass-through. */
            if (xStreamBufferSend(sb, "\r\n", 2, pdMS_TO_TICKS(20)) == 2) done++;
            continue;
        }
        uint32_t seg = n - done;
        if (!master)
            for (seg = 0; done + seg < n && p[done + seg] != '\n'; seg++) ;
        done += xStreamBufferSend(sb, p + done, seg, pdMS_TO_TICKS(20));
    }
    return (long)done;
}
int xt_pty_nread(int i, int master)
{
    if (i < 0 || i >= NPTY || !g_pty[i].m2s) return 0;
    int avail = (int)xStreamBufferBytesAvailable(master ? g_pty[i].s2m : g_pty[i].m2s);
    if (avail) return avail;
    /* EOF is "readable" for poll/select: once the other end has fully closed, a
     * read returns 0 (EOF) — report 1 pending byte so a poll wakes the reader to
     * collect it. Without this, dropbear's select never marks the pty master
     * readable after the shell exits, so it never reads the EOF and spins in its
     * poll loop forever (the session hangs). Mirrors the pipe FIONREAD at
     * writerless-EOF. The other end is "closed" only after it was opened (the
     * child holds the slave before dropbear's session loop polls), so this can't
     * fire a spurious EOF during setup. */
    if (master ? (g_pty[i].sopen == 0) : (g_pty[i].mopen == 0)) return 1;
    return 0;
}
long xt_pty_ioctl(int i, unsigned req, void *arg)
{
    if (i < 0 || i >= NPTY) return -1;
    switch (req) {
    case XT_TTY_GETMODE: { struct xt_ttymode *m = arg; if (m) { m->canon = g_pty[i].canon; m->echo = g_pty[i].echo; } return 0; }
    case XT_TTY_SETMODE: { struct xt_ttymode *m = arg; if (m) { g_pty[i].canon = m->canon ? 1 : 0; g_pty[i].echo = m->echo ? 1 : 0; } return 0; }
    case 0x5414u /*TIOCSWINSZ*/: { uint16_t *w = arg; if (w) {
        if (w[0] != g_pty[i].rows || w[1] != g_pty[i].cols) g_pty[i].winch = 1;
        g_pty[i].rows = w[0]; g_pty[i].cols = w[1]; } return 0; }
    case 0x5413u /*TIOCGWINSZ*/: { uint16_t *w = arg; if (w) { w[0] = g_pty[i].rows; w[1] = g_pty[i].cols; w[2] = w[3] = 0; } return 0; }
    case 0x540Eu /*TIOCSCTTY*/: return 0;
    default: return -1;
    }
}

/* dup2 for PIPE ends and the CONSOLE (the shell's save/restore-around-redirect
 * dance): copy the end onto a chosen slot, refcounted. A console source makes
 * the target a console alias; restoring an alias onto 0/1/2 just clears the
 * slot (closed stdio IS the console). File fds are not duplicable. */
static long k_dup2(proc_t *p, int oldfd, int newfd)
{
    if (!p || oldfd < 0 || oldfd >= NFD || newfd < 0 || newfd >= NFD) return -1;
    if (oldfd == newfd) return newfd;
    int old_con = (oldfd < 3 && !p->fd[oldfd].open) ||
                  (p->fd[oldfd].open && p->fd[oldfd].con);
    int old_pipe = p->fd[oldfd].open && p->fd[oldfd].pipei;
    int old_file = p->fd[oldfd].open && !p->fd[oldfd].pipei && !p->fd[oldfd].con;
    if (!old_con && !old_pipe && !old_file) return -1;
    if (p->fd[newfd].open) {                        /* displace whatever holds the slot */
        if (p->fd[newfd].pipei) k_pipe_close_end(&p->fd[newfd]);
        else if (p->fd[newfd].con) memset(&p->fd[newfd], 0, sizeof(fd_t));
        else kfs_call(KFS_CLOSEFD, 0, &p->fd[newfd], 0, 0);   /* file: flush + close */
    }
    if (old_con) {
        memset(&p->fd[newfd], 0, sizeof(fd_t));
        if (newfd >= 3) { p->fd[newfd].open = 1; p->fd[newfd].con = 1; }
        /* newfd < 3: leave closed — that IS the console */
        return newfd;
    }
    if (old_file) {
        /* MOVE the descriptor (page cache and driver state can't be shared);
         * the shell's redirect dance never needs two live copies, and its
         * follow-up close() of the source is a tolerated no-op */
        p->fd[newfd] = p->fd[oldfd];
        memset(&p->fd[oldfd], 0, sizeof(fd_t));
        return newfd;
    }
    kpipe_t *pp = &g_pipes[p->fd[oldfd].pipei - 1];
    p->fd[newfd] = p->fd[oldfd];
    taskENTER_CRITICAL();
    if (p->fd[newfd].pwrite) pp->writers++; else pp->readers++;
    taskEXIT_CRITICAL();
    return newfd;
}

/* fd metadata: enough for "is this a pipe/tty/file" probes (S_ISFIFO etc.)
 * and for "is this fd free" (the shell's high-fd allocator) — closed fds >= 3
 * FAIL here on purpose. */
static long k_fstat(proc_t *p, int fd, struct xt_stat *st)
{
    if (!p || fd < 0 || fd >= NFD || !st) return -1;
    if (p->fd[fd].open && p->fd[fd].pipei) { st->mode = XT_S_IFIFO; st->size = 0; st->mtime = 0; return 0; }
    if (p->fd[fd].open && p->fd[fd].sock)  { st->mode = XT_S_IFSOCK; st->size = 0; st->mtime = 0; return 0; }
    if (p->fd[fd].open && (p->fd[fd].con || p->fd[fd].vf.chr))
        { st->mode = XT_S_IFCHR; st->size = 0; st->mtime = 0; return 0; }
    if (p->fd[fd].open) { st->mode = XT_S_IFREG; st->size = p->fd[fd].vf.size; st->mtime = 0; return 0; }
    if (fd < 3) { st->mode = XT_S_IFCHR; st->size = 0; st->mtime = 0; return 0; }  /* console */
    return -1;
}

/* lseek is pure arithmetic on the LOGICAL cursor (fd.pos) + the file size captured at
 * open — no backing I/O, no fs task. The page store fills by page index independently,
 * so the driver's own position is irrelevant between fills. Runs inline (any context). */
static long sys_lseek(proc_t *p, int fd, long off, int whence)
{
    if (!p || fd < 3 || fd >= NFD || !p->fd[fd].open) return -1;
    if (p->fd[fd].pipei || p->fd[fd].con || p->fd[fd].vf.chr) return -1;    /* ESPIPE */
    fd_t *fdp = &p->fd[fd];
    long base = (whence == 1) ? (long)fdp->pos : (whence == 2) ? (long)fdp->vf.size : 0;
    long np = base + off;
    if (np < 0) return -1;
    /* seeking PAST EOF is legal (POSIX): a write there grows the file with
     * zero pages (fs_write), a read there returns 0 (EOF). SQLite grows its
     * db exactly this way — write page N at N*4096 into a shorter file. */
    fdp->pos = (uint32_t)np;
    return np;
}

static const xtld_host *g_khost;   /* kernel loader host (frtos_set_host); used by SYS_spawn */

/* ---- fs service task (step 3b: docs/OS/fs-pagecache.md) -------------------
 * One task owns the VFS metadata path, behind a per-client shm CONTROL CHANNEL (the §1
 * shm primitive — the reusable IPC substrate). Each proc SLOT gets one control page,
 * allocated once at startup and reused for the slot's life (no per-request alloc). The
 * client's deferral thunk (PL1, in the CLIENT's space) marshals the request into it —
 * crucially COPYING the path string out of client memory, which is mapped there but NOT
 * in the fs task's master space (a per-process-heap path would otherwise resolve to the
 * wrong physical). The fs task reaches the page by its pool IDENTITY address
 * (vm_shm_kaddr) and serves from the copy. The kernel queue is now just the DOORBELL
 * (carries the slot); the request DATA lives in shm.
 *
 * SCOPE (3b): open/lseek/close route here — metadata ops. read/write stay in the
 * caller's deferral thunk (its own space, where the user buffer is mapped) under
 * g_vfs_mtx until the demand-paged page store (3c) unifies the data path over the same
 * shm substrate and lets the lock retire. */
#define FS_PATH_MAX 256
#define FS_OP_GETPAGE 0x100          /* internal (not a SYS_ number): fill+return a file page */
#define FS_OP_MMAP    0x101          /* internal: eager-fill + map a backing-store file region */
#define FS_OP_MUNMAP  0x102          /* internal: write back dirty mmap pages, then unmap */
typedef struct {
    uint32_t          op;            /* SYS_open / SYS_close / FS_OP_GETPAGE / FS_OP_MMAP */
    uint32_t          fd;            /* close/getpage/mmap target */
    uint32_t          flags;         /* open: VFS_O_* flags */
    uint32_t          page;          /* getpage: file page index */
    uint32_t          wr;            /* getpage: 1 = for write (RMW/grow + flush-on-evict) */
    uint32_t          off;           /* mmap: file offset (page-aligned) */
    uint32_t          len;           /* mmap: length (0 = to EOF) */
    uint32_t          page_addr;     /* getpage: resident page addr / mmap: mapped VA (service -> client) */
    uint32_t          valid;         /* getpage: valid bytes in the page (service -> client) */
    volatile int32_t  result;        /* service -> client (0 ok, <0 err) */
    char              path[FS_PATH_MAX];   /* open/stat/...: marshalled path (identity-reachable) */
    char              path2[FS_PATH_MAX];  /* symlink target (in) / readlink target (out) */
    uint32_t          st[3];               /* stat/lstat result: mode, size, mtime */
} fs_ctl;

static QueueHandle_t g_fs_q;                 /* doorbell: slot indices; NULL until frtos_fs_start() */
static fs_ctl       *g_fs_ctl[MAXPROC];      /* per-slot control page (pool identity addr) */
static uint8_t      *g_fs_batch[MAXPROC];    /* per-slot SYS_getdents packing page (4 KB) */
#define FS_BATCH_BYTES 4096
static TaskHandle_t  g_fs_waiter[MAXPROC];   /* client task parked on each slot's request */

static long do_syscall(uint32_t num, long a0, long a1, long a2);   /* fallback (caller ctx) */
static void abspath(proc_t *p, const char *in, char *out);        /* cwd-relative -> absolute */

/* flush the fd's cached page to the backing if it has unwritten data (close / evict).
 * Writes the page's logical byte extent (a partial last page writes only up to size). */
static void fd_flush(fd_t *fdp)
{
    if (!fdp->cpage || !fdp->cdirty) return;
    uint32_t base = fdp->cpi << 12;
    uint32_t n = (fdp->vf.size > base) ? (fdp->vf.size - base) : 0;
    if (n > 0x1000u) n = 0x1000u;
    vfs_lseek(&fdp->vf, (long)base, 0);
    vfs_write(&fdp->vf, fdp->cpage, n);
    fdp->cdirty = 0;
}

/* free an fd's cached page back to the pool (close / reap), flushing it first so a
 * dirty page is never discarded. */
static void fd_drop_cache(fd_t *fdp)
{
    fd_flush(fdp);
    if (fdp->cpage) { vm_page_free(fdp->cpage); fdp->cpage = 0; }
    fdp->cpi = ~0u;
}

/* PAGE STORE (fs task): make file page `pi` of `slot`'s fd resident and return its
 * identity address + valid byte count. `forwrite` allows a page past EOF (a fresh zero
 * page, for growth) and means the caller will dirty it. In-memory (romfs) fds resolve to
 * vf.data with no pool page (read only); backing-store fds (fatfs/ramfs) hold one pooled
 * cache page — a re-touch of the same page is a hit, else the current page is flushed (if
 * dirty) and the new one filled (RMW: read existing content so a partial write preserves
 * the surrounding bytes). Fills/flushes go through vfs_*; for fatfs those take g_vfs_mtx
 * (open_lib_sd / sd_listdir are non-fs-task callers until they migrate — then it retires).
 * Returns 0 past EOF (read), on a write to an in-memory RO fd, or on pool exhaustion. */
static void *fd_getpage(int slot, int fd, uint32_t pi, uint32_t *valid, int forwrite)
{
    *valid = 0;
    if (fd < 0 || fd >= NFD || !g_proc[slot].fd[fd].open ||
        g_proc[slot].fd[fd].pipei || g_proc[slot].fd[fd].con)
        return 0;                        /* fd<3 allowed: file-redirected stdio */
    fd_t    *fdp  = &g_proc[slot].fd[fd];
    uint32_t size = fdp->vf.size, base = pi << 12;
    if (!forwrite && base >= size) return 0;                       /* read wholly past EOF */
    *valid = forwrite ? 0x1000u : ((size - base < 0x1000u) ? (size - base) : 0x1000u);
    if (fdp->vf.data) return forwrite ? 0 : (uint8_t *)fdp->vf.data + base;  /* in-memory (RO) */
    if (fdp->cpage && fdp->cpi == pi) return fdp->cpage;           /* cache hit */
    fd_flush(fdp);                                                 /* evict: don't lose the old page */
    if (!fdp->cpage) {
        fdp->cpage = vm_page_alloc(); if (!fdp->cpage) { *valid = 0; return 0; }
        /* TRIPWIRE: this page is filled by the CLIENT via its identity VA (fs_write);
         * if that VA lands in a per-process window band it's shadowed in the client's
         * space and the fill would corrupt the wrong page (see XTOS_POOL_FLOOR). The
         * pool is kept out of the band, but once frames come from arbitrary RAM (raised
         * process limit / dynamic paging) that no longer holds — so FAIL LOUD and refuse
         * the write rather than silently corrupt a file + smash another process. */
        if ((uintptr_t)fdp->cpage >= XTOS_HEAP_VA && (uintptr_t)fdp->cpage < XTOS_POOL_FLOOR) {
            klog("*** FATAL: fd page-cache page in the per-process window band ");
            klog_u((unsigned)(uintptr_t)fdp->cpage);
            klog(" — refusing the write (would corrupt) ***\r\n");
            vm_page_free(fdp->cpage); fdp->cpage = 0; *valid = 0; return 0;
        }
    }
    if (base < size) {                                            /* RMW: existing content */
        vfs_lseek(&fdp->vf, (long)base, 0);
        long got = vfs_read(&fdp->vf, fdp->cpage, 0x1000);
        if (got < 0) got = 0;
        if ((uint32_t)got < 0x1000u) memset((uint8_t *)fdp->cpage + got, 0, 0x1000u - (uint32_t)got);
    } else {
        memset(fdp->cpage, 0, 0x1000u);                          /* fresh page past EOF (growth) */
    }
    fdp->cpi = pi;
    return fdp->cpage;
}

/* serve one request in the FS TASK: explicit proc (cur_proc() here is the fs task, not
 * the client), path/args read from the slot's identity-mapped control page. */
/* mmap a backing-store (SD/ramfs) file region (fs task): EAGER-fill each page of
 * [off,off+len) into a fresh pool page (via the backing driver), then map them RO into
 * the client's window (vm_mmap_install). Eager, not demand, because the abort handler
 * can't drive FatFs — so the pages must be resident before the client touches them; it
 * also makes close-after-mmap safe (the data is copied). Sets c->page_addr = VA. Returns
 * 0 (ok) / -1. RW mmap (dirty-via-fault + write-back) is 3c-3b. */
#define MMAP_MAXPG 64                                        /* 256 KB cap per mmap for now */

/* Writable-mapping registry: a MAP_SHARED writable mmap must have its dirty pages written
 * back even if the client CLOSES the fd before munmap (POSIX: the mapping holds its own
 * reference). We can't lean on the client's fd, so record the file PATH per writable
 * mapping and re-open an INDEPENDENT handle at write-back time. Keyed by (slot, va). */
#define FS_MAXMAP 8   /* writable-mapping registry slots per proc; mirror vm.c NMMAP */
static struct { uint32_t va; uint8_t used; char path[FD_PATH_MAX]; } g_wrmap[MAXPROC][FS_MAXMAP];

/* write a writable mapping's DIRTY pages back to its file via a FRESH handle (independent
 * of any client fd). fs-task context. A partial last page is clamped to the file size. */
static void wrmap_flush(int slot, uint32_t va, const char *path)
{
    void    *pages[MMAP_MAXPG]; uint32_t foffs[MMAP_MAXPG]; uint32_t fd = 0;
    int nd = vm_mmap_dirty_plan(slot, va, &fd, pages, foffs, MMAP_MAXPG);
    if (nd <= 0) return;
    vfs_file f;
    if (vfs_open(path, VFS_O_WRONLY, &f) != 0) return;        /* open existing for write (no trunc) */
    uint32_t size = f.size;
    for (int i = 0; i < nd; i++) {
        uint32_t n = (size > foffs[i]) ? (size - foffs[i]) : 0;
        if (n > 0x1000u) n = 0x1000u;
        if (!n) continue;
        vfs_lseek(&f, (long)foffs[i], 0);
        vfs_write(&f, pages[i], n);
    }
    vfs_close(&f);
}

static long fd_mmap(int slot)
{
    fs_ctl *c = g_fs_ctl[slot];
    proc_t *p = &g_proc[slot];
    int     fd = (int)c->fd;
    if (fd < 3 || fd >= NFD || !p->fd[fd].open) return -1;
    fd_t    *fdp = &p->fd[fd];
    if (fdp->vf.data) return -1;                             /* in-memory handled inline (do_syscall) */
    uint32_t off = c->off, len = c->len, size = fdp->vf.size;
    if (off > size || (off & 0xFFFu)) return -1;             /* page-aligned offset, in bounds */
    if (len == 0) len = size - off;
    if (off + len > size || len == 0) return -1;
    uint32_t npg = (len + 0xFFFu) >> 12;
    if (npg > MMAP_MAXPG) return -1;
    void    *pages[MMAP_MAXPG];
    uint32_t k;
    for (k = 0; k < npg; k++) {
        pages[k] = vm_page_alloc();
        if (!pages[k]) break;
        vfs_lseek(&fdp->vf, (long)(off + k * 0x1000u), 0);
        long got = vfs_read(&fdp->vf, pages[k], 0x1000);
        if (got < 0) got = 0;
        if ((uint32_t)got < 0x1000u) memset((uint8_t *)pages[k] + got, 0, 0x1000u - (uint32_t)got);
    }
    if (k < npg) { for (uint32_t j = 0; j < k; j++) vm_page_free(pages[j]); return -1; }  /* pool exhausted */
    /* a writable fd -> a writable mapping (dirty-via-fault); else RO. fd + off recorded so
     * dirty pages can be written back at munmap. */
    int writable = fdp->vf.write != 0;
    uint32_t va = vm_mmap_install(slot, pages, npg, writable, (uint32_t)fd, off);
    if (!va) { for (k = 0; k < npg; k++) vm_page_free(pages[k]); return -1; }
    if (writable) {                                          /* record path so munmap can re-open (fd-independent) */
        for (int i = 0; i < FS_MAXMAP; i++)
            if (!g_wrmap[slot][i].used) {
                g_wrmap[slot][i].va = va; g_wrmap[slot][i].used = 1;
                int j = 0; for (; fdp->path[j] && j < FD_PATH_MAX - 1; j++) g_wrmap[slot][i].path[j] = fdp->path[j];
                g_wrmap[slot][i].path[j] = 0;
                break;
            }
    }
    c->page_addr = va;
    return 0;
}

/* unmap a mmap region (fs task): if it's a WRITABLE mapping, write its DIRTY pages back
 * first — via a FRESH handle re-opened from the recorded path, so it works even if the
 * client already closed the fd (POSIX MAP_SHARED). Then vm_munmap frees the pool pages +
 * clears the window. RO / romfs mappings have no registry entry -> just unmapped. */
static long fd_munmap(int slot)
{
    fs_ctl  *c  = g_fs_ctl[slot];
    uint32_t va = c->off, len = c->len;
    for (int i = 0; i < FS_MAXMAP; i++)
        if (g_wrmap[slot][i].used && g_wrmap[slot][i].va == va) {
            wrmap_flush(slot, va, g_wrmap[slot][i].path);
            g_wrmap[slot][i].used = 0;
            break;
        }
    return vm_munmap(slot, va, len);
}

/* ---- directory metadata cache --------------------------------------------
 * du/ls/find walk a tree by readdir + a stat per entry, and each stat re-walks the
 * FatFs path from root (reading SD directory sectors per component) — O(files x depth)
 * of the slowest operation there is. Cache the last few directories' full listings
 * (every entry's mode/size/mtime, which readdir_meta gets FREE from one enumeration
 * pass), and serve stat/lstat of a file from its parent dir's snapshot: the first stat
 * in a directory fills the cache (one sequential enumeration, no per-file walk), every
 * stat after is a memory hit. Invalidated per-directory on any write there. Lives in
 * (and is only touched by) the fs task, so it needs no locking. */
#define DCACHE_N     6           /* directories kept (LRU) */
#define DCACHE_ENTS  384         /* entries cached per dir; a bigger dir caches its first
                                  * DCACHE_ENTS and the rest just miss -> a real stat */
typedef struct {
    char            dir[FS_PATH_MAX];   /* absolute dir path, no trailing '/' (root = "/") */
    uint16_t        nents;
    uint8_t         valid;
    uint32_t        lru;
    struct vfs_dent e[DCACHE_ENTS];
} dcache_t;
static dcache_t  g_dcache[DCACHE_N];
static uint32_t  g_dcache_tick;

static int dstr_eq(const char *a, const char *b) { while (*a && *a == *b) { a++; b++; } return *a == *b; }

/* Canonicalize an absolute path for use as the dir-cache key: collapse //, drop "."
 * components, resolve "..", strip the trailing '/'. Without this, the SAME directory
 * keys differently depending on how it was named — `ls` (no arg) enumerates "." which
 * abspath()s to "/dir/.", while unlink's dcache_drop_parent normalizes the parent to
 * "/dir" — so the delete failed to invalidate the listing and `ls` showed stale
 * entries. Only affects key matching (never the FatFs path), so a miscanon can at
 * worst cause an extra cache miss/drop, never wrong data. */
static void dcache_norm(const char *in, char *out)
{
    int o = 0;
    out[o++] = '/';
    for (int i = 0; in[i]; ) {
        while (in[i] == '/') i++;
        if (!in[i]) break;
        int j = i; while (in[j] && in[j] != '/') j++;
        int len = j - i;
        if (len == 1 && in[i] == '.') { /* "." -> skip */ }
        else if (len == 2 && in[i] == '.' && in[i+1] == '.') {
            if (o > 1) { o--; while (o > 1 && out[o-1] != '/') o--; }   /* pop a segment */
        } else {
            if (out[o-1] != '/') out[o++] = '/';
            for (int k = i; k < j && o < FS_PATH_MAX - 1; k++) out[o++] = in[k];
        }
        i = j;
    }
    if (o > 1 && out[o-1] == '/') o--;
    out[o] = 0;
}

/* split an absolute path into parent dir (no trailing '/', root stays "/") + leaf name.
 * 0 ok; -1 if there's no leaf to look up (root, empty, or a bare relative name). */
static int path_split(const char *path, char *dir, int dsz, const char **leaf)
{
    int n = 0; while (path[n]) n++;
    while (n > 0 && path[n-1] == '/') n--;                 /* trim trailing slashes */
    if (n == 0) return -1;                                 /* "" or "/" -> no leaf */
    int s = n; while (s > 0 && path[s-1] != '/') s--;      /* s = index just past the last '/' */
    if (s == 0) return -1;                                 /* no directory component */
    int dl = (s == 1) ? 1 : s - 1;                         /* parent length (root keeps its '/') */
    if (dl >= dsz) return -1;
    int i = 0; for (; i < dl; i++) dir[i] = path[i]; dir[i] = 0;
    *leaf = path + s;
    return 0;
}

static dcache_t *dcache_find(const char *dir)
{
    char k[FS_PATH_MAX]; dcache_norm(dir, k);
    for (int i = 0; i < DCACHE_N; i++)
        if (g_dcache[i].valid && dstr_eq(g_dcache[i].dir, k)) return &g_dcache[i];
    return 0;
}
static void dcache_drop(const char *dir)
{
    char k[FS_PATH_MAX]; dcache_norm(dir, k);
    for (int i = 0; i < DCACHE_N; i++)
        if (g_dcache[i].valid && dstr_eq(g_dcache[i].dir, k)) g_dcache[i].valid = 0;
}
/* drop EVERY cached listing — SD hot-plug (a card swap invalidates all of them) */
void dcache_flush_all(void) { for (int i = 0; i < DCACHE_N; i++) g_dcache[i].valid = 0; }
/* a create/delete/rename/size-change at `path` makes its parent dir's snapshot stale */
static void dcache_drop_parent(const char *path)
{
    char dir[FS_PATH_MAX]; const char *leaf;
    if (path_split(path, dir, sizeof dir, &leaf) == 0) dcache_drop(dir);
}
static dcache_t *dcache_slot(void)      /* a free slot, else the LRU one */
{
    dcache_t *v = &g_dcache[0];
    for (int i = 0; i < DCACHE_N; i++) {
        if (!g_dcache[i].valid) return &g_dcache[i];
        if (g_dcache[i].lru < v->lru) v = &g_dcache[i];
    }
    return v;
}
/* enumerate `dir` (metadata) into a slot; 0 if the fs has no readdir_meta or dir isn't a
 * directory (caller then falls back to a real stat). */
static dcache_t *dcache_fill(const char *dir)
{
    struct vfs_dent d;
    long r = vfs_readdir_meta(dir, 0, &d);
    if (r < 0) return 0;                                   /* -2 unsupported / -1 not-a-dir */
    dcache_t *c = dcache_slot();
    c->valid = 0;                                          /* unusable while (re)filling */
    dcache_norm(dir, c->dir);                              /* canonical key (matches find/drop) */
    c->nents = 0;
    for (int idx = 0; r == 1; r = vfs_readdir_meta(dir, ++idx, &d)) {
        if (!d.name[0]) continue;                          /* over-long name: uncacheable, skip */
        if (c->nents >= DCACHE_ENTS) break;                /* dir bigger than the cache: the rest
                                                            * just miss -> a real stat, still correct */
        c->e[c->nents++] = d;
    }
    c->lru = ++g_dcache_tick;
    c->valid = 1;
    return c;
}
/* serve stat/lstat from the parent dir's cached snapshot. 0 = filled *st; -2 = not
 * answerable -> caller MUST fall back to vfs_stat/vfs_lstat. A miss NEVER means "no such
 * file" — the raw path may be "." / ".." / an over-long (uncached) name / a non-canonical
 * form the cache never keyed, so an authoritative ENOENT here would wrongly hide real
 * files. Only an exact-name hit on a fully-cached entry is served; everything else falls
 * through to the real (correct) stat. */
static int k_dstat(const char *path, int follow, struct xt_stat *st)
{
    char dir[FS_PATH_MAX]; const char *leaf;
    if (path_split(path, dir, sizeof dir, &leaf) != 0) return -2;
    if (leaf[0] == '.' && (!leaf[1] || (leaf[1] == '.' && !leaf[2]))) return -2;  /* "." / ".." */
    dcache_t *c = dcache_find(dir);
    if (!c) c = dcache_fill(dir);
    if (!c) return -2;
    c->lru = ++g_dcache_tick;
    for (int i = 0; i < c->nents; i++)
        if (dstr_eq(c->e[i].name, leaf)) {
            if (follow && (c->e[i].mode & XT_S_IFMT) == XT_S_IFLNK) return -2;   /* resolve target */
            st->mode = c->e[i].mode; st->size = c->e[i].size; st->mtime = c->e[i].mtime;
            return 0;
        }
    return -2;                                             /* miss -> real stat decides existence */
}

/* real filesystem capacity for statfs/df: FatFs f_getfree on HW (out = {total_sectors,
 * free_sectors, sector_bytes}); unavailable on qemu (romfs/ramfs has no fixed size) ->
 * -1, and the libc shim keeps its sensible defaults. */
static int k_statfs(uint32_t out[3])
{
#ifdef XT_HW
    extern int sd_statfs_raw(uint32_t[3]);
    return sd_statfs_raw(out);
#else
    (void)out; return -1;
#endif
}

static long fs_serve(int slot)
{
    proc_t *p = &g_proc[slot];
    fs_ctl *c = g_fs_ctl[slot];
    switch (c->op) {
    case SYS_open:
        if (c->flags & (VFS_O_WRONLY | VFS_O_RDWR | VFS_O_CREAT | VFS_O_TRUNC))
            dcache_drop_parent(c->path);                  /* create/truncate changes the dir listing */
        return sys_open(p, c->path, (int)c->flags);       /* path copied into the shm page */
    case SYS_close:
        /* A channel closes here too. Belt and braces: an explicit close() MUST release the
         * pipe ends, or the peer never sees EOF and a client that exits cleanly looks alive
         * forever -- which is exactly the bug this caught (only the client that DIED without
         * closing was detected; the two that closed politely were not). */
        if (p && c->fd >= 3 && c->fd < NFD && p->fd[c->fd].open &&
            (p->fd[c->fd].rpipe || p->fd[c->fd].wpipe)) { k_chan_close(&p->fd[c->fd]); return 0; }
        if (p && c->fd >= 3 && c->fd < NFD && p->fd[c->fd].open) {
            if (p->fd[c->fd].oflags & (VFS_O_WRONLY | VFS_O_RDWR))
                dcache_drop_parent(p->fd[c->fd].path);    /* a written file's size/mtime changed */
            fd_drop_cache(&p->fd[c->fd]);                 /* flush (if dirty) + free the cache page */
            vfs_close(&p->fd[c->fd].vf);
            p->fd[c->fd].open = 0;
        }
        return 0;
    case SYS_stat: case SYS_lstat: {                          /* path -> xt_stat (in st[]) */
        struct xt_stat s;
        int hit = k_dstat(c->path, c->op == SYS_stat, &s);   /* parent-dir snapshot fast path */
        long r = (hit == 0) ? 0                              /* miss -> the real stat decides */
               : (c->op == SYS_stat) ? vfs_stat(c->path, &s) : vfs_lstat(c->path, &s);
        if (r == 0) { c->st[0] = s.mode; c->st[1] = s.size; c->st[2] = s.mtime; }
        return r;
    }
    case SYS_statfs:   return k_statfs(c->st);                                /* total/free sectors -> st[] */
    case SYS_readlink: return vfs_readlink(c->path, c->path2, (int)c->len);   /* target -> path2 */
    case SYS_symlink:  dcache_drop_parent(c->path);                          /* new link in its dir */
                       return vfs_symlink(c->path2, c->path);                /* (target, linkpath) */
    case SYS_unlink:   dcache_drop_parent(c->path);                          /* entry removed */
                       return vfs_unlink(c->path);
    case SYS_readdir: {                                       /* entry name -> path2, type -> st[0] */
        unsigned mode = 0;
        long r = vfs_readdir(c->path, (int)c->off, c->path2, FS_PATH_MAX, &mode);
        c->st[0] = mode;
        return r;
    }
    case SYS_getdents: {                                     /* batch: entries+meta -> g_fs_batch */
        dcache_t *dc = dcache_find(c->path);
        if (!dc) dc = dcache_fill(c->path);
        if (!dc) return -1;                                 /* not enumerable -> shim falls back */
        dc->lru = ++g_dcache_tick;
        uint8_t *b = g_fs_batch[slot];
        uint32_t off = 0, count = 0, idx = c->off;
        for (; idx < dc->nents; idx++) {
            const char *nm = dc->e[idx].name;
            uint32_t nl = 0; while (nm[nl]) nl++;
            uint32_t reclen = (16 + nl + 1 + 3) & ~3u;      /* header(16) + name + NUL, 4-aligned */
            if (off + reclen > FS_BATCH_BYTES) break;       /* page full: the shim asks for more */
            *(uint32_t *)(b + off + 0)  = dc->e[idx].mode;
            *(uint32_t *)(b + off + 4)  = dc->e[idx].size;
            *(uint32_t *)(b + off + 8)  = dc->e[idx].mtime;
            *(uint16_t *)(b + off + 12) = (uint16_t)reclen;
            *(uint16_t *)(b + off + 14) = (uint16_t)nl;
            for (uint32_t k = 0; k < nl; k++) b[off + 16 + k] = nm[k];
            b[off + 16 + nl] = 0;
            off += reclen; count++;
        }
        c->st[0] = count;                                   /* records packed */
        c->st[1] = off;                                     /* bytes packed */
        return (long)count;
    }
    case SYS_mkdir:   dcache_drop_parent(c->path);           /* new dir appears in its parent */
                      return vfs_mkdir(c->path);
    case SYS_rename:  dcache_drop_parent(c->path);           /* entry leaves the old dir... */
                      dcache_drop_parent(c->path2);          /* ...and appears in the new one */
                      return vfs_rename(c->path, c->path2);  /* (old, new) both absolutized */
    case SYS_chdir: {                                         /* canonicalize + verify dir, set cwd */
        char canon[FS_PATH_MAX]; struct xt_stat s;
        if (vfs_resolve(c->path, canon, FS_PATH_MAX, 1) != 0) return -1;
        if (vfs_stat(canon, &s) != 0 || (s.mode & XT_S_IFMT) != XT_S_IFDIR) return -1;
        int i = 0; while (canon[i] && i < (int)sizeof g_proc[slot].cwd - 1) { g_proc[slot].cwd[i] = canon[i]; i++; }
        g_proc[slot].cwd[i] = 0;
        return 0;
    }
    case FS_OP_GETPAGE: {
        uint32_t valid = 0;
        void *pg = fd_getpage(slot, (int)c->fd, c->page, &valid, (int)c->wr);
        c->page_addr = (uint32_t)(uintptr_t)pg; c->valid = valid;
        return pg ? 0 : -1;
    }
    case FS_OP_MMAP:   return fd_mmap(slot);
    case FS_OP_MUNMAP: return fd_munmap(slot);
    default:        return -1;
    }
}

/* ---- kernel FatFs requests (open_lib_sd, sd_listdir) ----------------------
 * These KERNEL callers (no proc slot, so no per-slot control page) route their FatFs
 * through the fs task too, so it is the SOLE FatFs driver and g_vfs_mtx can retire. A
 * single mailbox serialized by g_kfs_mtx (the path is rare: a lib missing from the romfs,
 * or the boot dir listing). READFILE opens+allocates+reads a whole file; LISTDIR lists a
 * directory into the caller's buffer. The doorbell carries FS_KERNEL_JOB instead of a
 * slot. */
/* (the KFS op enum lives up with the pipe/fd helpers that use it) */
#define FS_KERNEL_JOB (-1)
static struct {
    int          op;
    const char  *path;
    void        *buf;      /* READFILE: fs task sets it (allocated); LISTDIR: caller's array */
    uint32_t     len;      /* LISTDIR: max entries / CLOSEALL: proc slot */
    long         result;
    TaskHandle_t waiter;
} g_kfs;
static SemaphoreHandle_t g_kfs_mtx;    /* serialize kernel callers of the single mailbox */
/* Completion signal for that mailbox.
 *
 * This was a TASK NOTIFICATION, and that is a lost-wakeup waiting to happen: a
 * task has exactly ONE notification value, shared by every user of it, and
 * ulTaskNotifyTake(pdTRUE,...) CLEARS it on return. So if any other notification
 * lands on the caller while it is parked here -- or two arrive before the take --
 * one wakeup is swallowed and the next take blocks for ever. The caller here is
 * the lwIP thread, and the symptom was tftpd writing a block to disk and then
 * never ACKing it ("Timeout waiting for block 23 ACK", 11776 bytes on the card):
 * the data was written, the wakeup was not delivered.
 *
 * A dedicated binary semaphore cannot be consumed by anyone else. Safe as a
 * single global because g_kfs_mtx already allows only one call in flight. */
static SemaphoreHandle_t g_kfs_done;

/* Four counters at the four points the kfs handshake can break, so a stall says
 * WHICH stage hung instead of merely that one did. Read via /OS/proc/kfs after a
 * transfer stalls -- the lwIP thread being blocked does not stop another task
 * reading them:
 *   queued == picked+1   -> the fs task never dequeued the job
 *   picked == served+1   -> vfs_write() is blocked inside the fs task
 *   served == returned+1 -> the completion signal was lost (the old bug)
 * Cheap enough to leave in: four increments per block. */
volatile unsigned g_kfs_queued, g_kfs_picked, g_kfs_served, g_kfs_returned;
volatile long     g_kfs_lastres;

/* Tear down every open fd of a dead proc: flush its dirty cache page, close the backing
 * file (free the FIL), free the cache page. MUST run in the fs task (the sole FatFs
 * driver post-3c-4), so reap routes here via KFS_CLOSEALL rather than doing FatFs from the
 * reaper's context. A killed proc's unflushed writes are still flushed here (harmless, and
 * more correct than dropping them). */
static void fs_close_all(int slot)
{
    if (slot < 0 || slot >= MAXPROC) return;
    proc_t *p = &g_proc[slot];
    for (int fd = 0; fd < NFD; fd++) {   /* from 0: a child's stdio can be pipe ends */
        if (!p->fd[fd].open) continue;
        if (p->fd[fd].pipei) { k_pipe_close_end(&p->fd[fd]); continue; }
        /* Channel + service fds: same argument as pipes, and stronger. gemd learns a
         * client died by its channel hitting EOF (SIGCHLD only reaches the PARENT, and
         * the server is not the parent of an ssh-launched client). If we deferred this to
         * the reap, a dead client's window would linger until someone waitpid'd it -- and
         * nobody will. */
        if (p->fd[fd].rpipe || p->fd[fd].wpipe) { k_chan_close(&p->fd[fd]); continue; }
        if (p->fd[fd].svc) {
            svc_t *sv = &g_svc[p->fd[fd].svc - 1];
            taskENTER_CRITICAL();                    /* drop unaccepted connects, free their pipes */
            for (int i = 0; i < sv->nq; i++) {
                for (int k = 0; k < 2; k++) {
                    kpipe_t *pp = &g_pipes[sv->q[i][k]];
                    if (pp->used) { pp->used = 0; vStreamBufferDelete(pp->sb); pp->sb = 0; }
                }
            }
            sv->nq = 0; sv->used = 0;                /* the name is free again */
            taskEXIT_CRITICAL();
            p->fd[fd].open = 0; p->fd[fd].svc = 0;
            continue;
        }  /* EOF/EPIPE propagate */
        if (p->fd[fd].sock) { extern void xt_sock_close(int);             /* netconn teardown */
                              xt_sock_close(p->fd[fd].sock - 1);
                              p->fd[fd].open = 0; p->fd[fd].sock = 0; continue; }
        if (p->fd[fd].con) { p->fd[fd].open = 0; p->fd[fd].con = 0; continue; }
        /* fd<3 falls through too: file-redirected stdio must flush + close */
        fd_drop_cache(&p->fd[fd]);       /* flush dirty page (if any) + free the cache page */
        vfs_close(&p->fd[fd].vf);
        p->fd[fd].open = 0;
    }
    /* process termination is an implicit munmap -> flush any still-active writable
     * mapping's dirty pages (POSIX MAP_SHARED). Runs before vm_space_destroy, so the
     * mmap descriptors are still live for the dirty plan. */
    for (int i = 0; i < FS_MAXMAP; i++)
        if (g_wrmap[slot][i].used) {
            wrmap_flush(slot, g_wrmap[slot][i].va, g_wrmap[slot][i].path);
            g_wrmap[slot][i].used = 0;
        }
}

static vfs_file *g_kfs_wf;             /* the net file drop's open upload (fs task only) */

/* ---- kernel diagnostic log (klog) -----------------------------------------
 * The [sd]/[net]/[tftp]/[hdmi] boot chatter goes HERE, not the console: klog
 * appends to a RAM buffer (works pre-scheduler too), and a low-priority logger
 * task flushes it to /tmp/system.log (ramfs, fresh each boot) once /tmp is
 * mounted. RAM-backed on purpose: logging must never write the SD, or an
 * SD-op diagnostic line would re-trigger the flush and self-sustain a storm.
 * Keeps the console clean for the [ OK ]/[FAIL] boot-script status. */
/* CIRCULAR diagnostic buffer: keeps the LATEST KLOG_CAP bytes, so a long-running
 * or high-volume producer (e.g. strace) doesn't lose the most recent output
 * (which is usually what you want — the tail before a hang/crash). The wrap logic
 * lives in klog_put; klog_snapshot linearizes the ring into read order so procfs
 * (/proc/kmsg) and the SD flush stay simple single-segment readers. */
#define KLOG_CAP 32768
static char           g_klog[KLOG_CAP];
static volatile uint32_t g_klog_head;         /* next write index (wraps) */
static volatile int      g_klog_wrapped;      /* has it wrapped at least once? */
static char           g_klog_lin[KLOG_CAP];   /* linearized snapshot for readers */

static inline void klog_put(char c)
{
    g_klog[g_klog_head++] = c;
    if (g_klog_head >= KLOG_CAP) { g_klog_head = 0; g_klog_wrapped = 1; }
}

void klog(const char *s)
{
    unsigned f = xt_irq_save();               /* frtos_os.h (static inline) */
    while (*s) klog_put(*s++);
    xt_irq_restore(f);
}
/* bounded append (SYS_klog from PL0): copy exactly `n` bytes, no NUL scan of a
 * user pointer. Returns bytes accepted (the ring never rejects — it wraps). */
long klog_write(const char *s, uint32_t n)
{
    if (!s) return -1;
    unsigned f = xt_irq_save();
    for (uint32_t i = 0; i < n; i++) klog_put(s[i]);
    xt_irq_restore(f);
    return (long)n;
}
void klog_u(unsigned v)
{
    char b[12]; int n = 0;
    if (!v) { klog("0"); return; }
    while (v && n < 11) { b[n++] = (char)('0' + v % 10); v /= 10; }
    char o[12]; int k = 0;
    while (n) o[k++] = b[--n];
    o[k] = 0; klog(o);
}

/* the live diagnostic buffer -> /OS/proc/kmsg (dmesg) and the SD flush. Linearize
 * the ring into read order (oldest→newest) in g_klog_lin. Works even with no SD. */
int klog_snapshot(const char **p)
{
    unsigned f = xt_irq_save();
    int len;
    if (!g_klog_wrapped) {
        for (uint32_t i = 0; i < g_klog_head; i++) g_klog_lin[i] = g_klog[i];
        len = (int)g_klog_head;
    } else {
        uint32_t tail = KLOG_CAP - g_klog_head, k = 0;
        for (uint32_t i = 0; i < tail; i++) g_klog_lin[k++] = g_klog[g_klog_head + i];
        for (uint32_t i = 0; i < g_klog_head; i++) g_klog_lin[k++] = g_klog[i];
        len = KLOG_CAP;
    }
    xt_irq_restore(f);
    *p = g_klog_lin;
    return len;
}

/* flush the whole ring to the SD (truncate+rewrite each pass — the ring holds the
 * latest KLOG_CAP bytes). Fails silently until the SD mount exists, so it retries. */
static int g_klog_flushed_seq = -1;
static void klog_sync(void)
{
    int seq = (int)(g_klog_head + (g_klog_wrapped ? KLOG_CAP : 0));  /* changed? */
    if (seq == g_klog_flushed_seq) return;
    const char *p; int len = klog_snapshot(&p);
    if (kfs_call(KFS_LOGWRITE, 0, (void *)p, (uint32_t)len, 0) == (long)len)
        g_klog_flushed_seq = seq;
}

/* dmesg -c (a write to /proc/kmsg): drop everything logged so far, so a test run's
 * output starts from a clean ring. Resetting the flushed seq forces the next logger
 * pass to rewrite /tmp/system.log too — a cleared ring stays cleared everywhere. */
void klog_clear(void)
{
    unsigned f = xt_irq_save();
    g_klog_head = 0;
    g_klog_wrapped = 0;
    xt_irq_restore(f);
    g_klog_flushed_seq = -1;
}

static void logger_task(void *arg)
{
    (void)arg;
    for (;;) { klog_sync(); vTaskDelay(pdMS_TO_TICKS(1000)); }
}


void klog_start(void) { xTaskCreate(logger_task, "logd", 512, 0, 1, 0); }

static long kfs_serve(void)
{
    switch (g_kfs.op) {
    case KFS_READFILE: {                                /* open + alloc + read a whole file */
        extern void puts0(const char *); extern void putu(unsigned);
        vfs_file f;
        g_kfs.buf = 0;
        if (vfs_open(g_kfs.path, 0, &f) != 0) return -1;   /* routine: spawn probes miss here */
        if (f.size == 0 || !f.read)
            { puts0("[fs] READFILE empty/unreadable\n"); if (f.close) f.close(&f); return -1; }
        void *buf = frtos_alloc(f.size, 16, NULL);
        if (!buf) { puts0("[fs] READFILE: kernel heap exhausted\n");
                    if (f.close) f.close(&f); return -1; }
        long got = f.read(&f, buf, f.size);
        if (f.close) f.close(&f);
        if (got != (long)f.size) {                     /* buf leaks (rare); kernel heap is bump anyway */
            puts0("[fs] READFILE short read "); putu((unsigned)got);
            puts0("/"); putu(f.size); puts0("\n");
            return -1;
        }
        g_kfs.buf = buf;
        return (long)f.size;
    }
    case KFS_LISTDIR: {
        extern int sd_listdir_raw(const char *, char (*)[32], int);
        return sd_listdir_raw(g_kfs.path, (char (*)[32])g_kfs.buf, (int)g_kfs.len);
    }
    case KFS_CLOSEALL: fs_close_all((int)g_kfs.len); return 0;   /* reap: close a dead proc's fds */
    case KFS_WRITEOPEN: {                               /* net file drop: streamed whole-file write */
        static vfs_file wf;                             /* ONE upload at a time (tftp's model too) */
        if (g_kfs_wf) { vfs_close(g_kfs_wf); g_kfs_wf = 0; }   /* stale half-finished upload */
        if (vfs_open(g_kfs.path, VFS_O_WRONLY | VFS_O_CREAT | VFS_O_TRUNC, &wf) != 0) return -1;
        if (!wf.write) { vfs_close(&wf); return -1; }
        g_kfs_wf = &wf;
        return 0;
    }
    case KFS_WRITEBLOCK:
        if (!g_kfs_wf) return -1;
        return vfs_write(g_kfs_wf, g_kfs.buf, g_kfs.len);
    case KFS_WRITECLOSE:
        if (g_kfs_wf) { vfs_close(g_kfs_wf); g_kfs_wf = 0; }
        return 0;
    case KFS_LOGWRITE: {                                /* rewrite /tmp/system.log (ramfs — no SD churn) */
        vfs_file lf;                                    /* RAM-backed: logging never touches the boot disk,
                                                         * so SD-op diagnostics can't feed back into the flush */
        if (vfs_open("/tmp/system.log", VFS_O_WRONLY | VFS_O_CREAT | VFS_O_TRUNC, &lf) != 0)
            return -1;
        long w = lf.write ? vfs_write(&lf, g_kfs.buf, g_kfs.len) : -1;
        vfs_close(&lf);
        return w;
    }
    case KFS_CLOSEFD: {                                 /* flush + close a caller's fd_t */
        fd_t *d = (fd_t *)g_kfs.buf;
        fd_drop_cache(d);
        vfs_close(&d->vf);
        memset(d, 0, sizeof *d);
        return 0;
    }
    }
    return -1;
}

static void fs_task(void *arg)
{
    (void)arg;
    for (;;) {
        int slot;
        if (xQueueReceive(g_fs_q, &slot, pdMS_TO_TICKS(500)) != pdTRUE) {
            extern void sd_hotplug_poll(void);         /* idle: watch for SD removal/insert */
            sd_hotplug_poll();
            continue;
        }
        if (slot == FS_KERNEL_JOB) {                   /* kernel mailbox request */
            g_kfs_picked++;
            g_kfs.result = kfs_serve();
            g_kfs_lastres = g_kfs.result;
            g_kfs_served++;
            xSemaphoreGive(g_kfs_done);
        } else {
            g_fs_ctl[slot]->result = fs_serve(slot);
            xTaskNotifyGive(g_fs_waiter[slot]);        /* wake the parked client */
        }
    }
}

/* kernel-side entry: post a FatFs request to the fs task and block. Serialized by
 * g_kfs_mtx; for READFILE the allocated buffer comes back via *out_buf (read before the
 * mutex is dropped). Callable from any task context (shell_task, a spawn deferral). */
static long kfs_call(int op, const char *path, void *buf, uint32_t len, void **out_buf)
{
    /* the fs task runs in the MASTER space: a path in CLIENT memory (e.g. the
     * exec path of an SD program spawn, marshalled in the client's deferral)
     * is mapped HERE but resolves to the wrong physical THERE — copy it into
     * this kernel-global buffer (serialized by g_kfs_mtx) like fs_meta does. */
    static char kpath[128];
    if (!g_fs_q || !g_kfs_mtx || !g_kfs_done) return -1;
    xSemaphoreTake(g_kfs_mtx, portMAX_DELAY);
    if (path) {
        int i = 0;
        for (; path[i] && i < (int)sizeof kpath - 1; i++) kpath[i] = path[i];
        kpath[i] = 0;
        path = kpath;
    }
    g_kfs.op = op; g_kfs.path = path; g_kfs.buf = buf; g_kfs.len = len; g_kfs.result = -1;
    g_kfs.waiter = xTaskGetCurrentTaskHandle();
    int job = FS_KERNEL_JOB;
    g_kfs_queued++;
    xQueueSend(g_fs_q, &job, portMAX_DELAY);
    xSemaphoreTake(g_kfs_done, portMAX_DELAY);
    g_kfs_returned++;
    long r = g_kfs.result;
    if (out_buf) *out_buf = g_kfs.buf;
    xSemaphoreGive(g_kfs_mtx);
    return r;
}

/* boot dir listing -> the fs task (sd_listdir_raw is the raw FatFs enumerate in sd.c). */
int sd_listdir(const char *dir, char out[][32], int max)
{
    return (int)kfs_call(KFS_LISTDIR, dir, out, (uint32_t)max, 0);
}

/* the net file drop (tftpd.c): streamed writes + whole-file reads through the
 * fs task. Kernel-task callers only (the lwIP thread). */
long frtos_net_writeopen(const char *path) { return kfs_call(KFS_WRITEOPEN, path, 0, 0, 0); }
long frtos_net_writeblock(const void *buf, unsigned len)
{ return kfs_call(KFS_WRITEBLOCK, 0, (void *)buf, len, 0); }
long frtos_net_writeclose(void) { return kfs_call(KFS_WRITECLOSE, 0, 0, 0, 0); }
long frtos_net_readfile(const char *path, const void **data)
{
    void *buf = 0;
    long sz = kfs_call(KFS_READFILE, path, 0, 0, &buf);
    if (sz < 0 || !buf) return -1;
    *data = buf;
    return sz;
}

/* deferral_thunk (client TASK context) -> hand a routed metadata op to the fs task.
 * Marshal into the slot's control page (copying the path out of client memory, mapped
 * HERE), ring the doorbell, park. Fallback (fs task not up) runs the op inline via
 * do_syscall — cur_proc() is the client here, so that's still correct. */
static long fs_call(proc_t *p)
{
    int     slot = (int)(p - g_proc);
    fs_ctl *c = (slot >= 0 && slot < MAXPROC) ? g_fs_ctl[slot] : 0;
    if (!g_fs_q || !c) return do_syscall(p->dnum, p->da0, p->da1, p->da2);
    c->op = p->dnum;
    if (p->dnum == SYS_open) {
        abspath(p, (const char *)p->da0, c->path);   /* resolve relative paths against cwd */
        c->flags = (uint32_t)p->da1;                 /* open flags (VFS_O_*) */
    } else {                                         /* close */
        c->fd = (uint32_t)p->da0;
    }
    c->result = -1;
    g_fs_waiter[slot] = xTaskGetCurrentTaskHandle();
    xQueueSend(g_fs_q, &slot, portMAX_DELAY);
    ulTaskNotifyTake(pdTRUE, portMAX_DELAY);   /* index 0: free here (not a waitpid waiter) */
    return c->result;
}

/* copy a client PL0 string into an fs-ctl path field (mapped here in the deferral). */
static void cp_path(char *dst, const char *src)
{
    int i = 0;
    if (src) while (src[i] && i < FS_PATH_MAX - 1) { dst[i] = src[i]; i++; }
    dst[i] = 0;
}

/* absolutize a client path against the process cwd: absolute paths pass through,
 * relative ones become cwd + "/" + path. Normalisation (./..) is done by the VFS
 * resolver, so this just concatenates. */
static void abspath(proc_t *p, const char *in, char *out)
{
    int o = 0;
    if (!in) in = "";
    if (in[0] != '/' && p) {
        const char *c = p->cwd;
        while (c[o] && o < FS_PATH_MAX - 2) { out[o] = c[o]; o++; }
        if (o == 0 || out[o-1] != '/') out[o++] = '/';
    }
    int i = 0; while (in[i] && o < FS_PATH_MAX - 1) { out[o++] = in[i++]; }
    out[o] = 0;
    if (o == 0) { out[0] = '/'; out[1] = 0; }
}

/* deferral (client TASK ctx) -> route a path-based metadata op (stat/lstat/readlink/
 * symlink/unlink) to the fs task. Marshal input paths out of client memory, ring, park,
 * then copy the stat struct / readlink target back into the client's buffer (mapped here). */
static long fs_meta(proc_t *p)
{
    int     slot = (int)(p - g_proc);
    fs_ctl *c = (slot >= 0 && slot < MAXPROC) ? g_fs_ctl[slot] : 0;
    if (!g_fs_q || !c) return do_syscall(p->dnum, p->da0, p->da1, p->da2);
    c->op = p->dnum;
    if (p->dnum == SYS_symlink) {
        abspath(p, (const char *)p->da1, c->path);            /* linkpath (where to create) */
        cp_path(c->path2, (const char *)p->da0);              /* target (stored verbatim) */
    } else if (p->dnum == SYS_rename) {
        abspath(p, (const char *)p->da0, c->path);            /* oldpath */
        abspath(p, (const char *)p->da1, c->path2);           /* newpath */
    } else {
        abspath(p, (const char *)p->da0, c->path);            /* primary path (cwd-relative) */
        if (p->dnum == SYS_readlink) {
            uint32_t sz = (uint32_t)p->da2; if (sz > FS_PATH_MAX) sz = FS_PATH_MAX;
            c->len = sz;                                      /* clamp target buffer to path2 */
        } else if (p->dnum == SYS_readdir) {
            c->off = (uint32_t)p->da1;                        /* entry index */
        }
    }
    c->result = -1;
    g_fs_waiter[slot] = xTaskGetCurrentTaskHandle();
    xQueueSend(g_fs_q, &slot, portMAX_DELAY);
    ulTaskNotifyTake(pdTRUE, portMAX_DELAY);
    if (c->result >= 0) {                                     /* results -> client memory */
        if (p->dnum == SYS_stat || p->dnum == SYS_lstat) {
            struct xt_stat *u = (struct xt_stat *)p->da1;
            if (u) { u->mode = c->st[0]; u->size = c->st[1]; u->mtime = c->st[2]; }
        } else if (p->dnum == SYS_readlink) {
            char *ub = (char *)p->da1; uint32_t usz = (uint32_t)p->da2;
            long n = c->result; if (n > (long)usz) n = (long)usz;
            for (long i = 0; i < n; i++) ub[i] = c->path2[i];
        } else if (p->dnum == SYS_readdir && c->result == 1) {
            struct xt_dirent *u = (struct xt_dirent *)p->da2;
            if (u) { u->mode = c->st[0];
                     int i = 0; while (c->path2[i] && i < 255) { u->name[i] = c->path2[i]; i++; } u->name[i] = 0; }
        } else if (p->dnum == SYS_statfs) {           /* total/free sectors + sector size -> client u32[3] */
            uint32_t *u = (uint32_t *)p->da1;
            if (u) { u[0] = c->st[0]; u[1] = c->st[1]; u[2] = c->st[2]; }
        }
    }
    return c->result;
}

/* deferral (client TASK ctx) -> SYS_getdents: the fs task packs a directory slice (from
 * its cached snapshot) into the slot's batch page; here (client space) we copy that page
 * into the caller's buffer. Returns the record count (0 = end, -1 = not batch-enumerable). */
static long fs_getdents(proc_t *p)
{
    int     slot = (int)(p - g_proc);
    fs_ctl *c = (slot >= 0 && slot < MAXPROC) ? g_fs_ctl[slot] : 0;
    if (!g_fs_q || !c) return -1;                        /* no fs task -> shim uses readdir/stat */
    c->op = p->dnum;
    abspath(p, (const char *)p->da0, c->path);           /* directory (cwd-relative -> absolute) */
    c->off = (uint32_t)p->da1;                           /* start entry index */
    c->result = -1;
    g_fs_waiter[slot] = xTaskGetCurrentTaskHandle();
    xQueueSend(g_fs_q, &slot, portMAX_DELAY);
    ulTaskNotifyTake(pdTRUE, portMAX_DELAY);
    if (c->result < 0) return -1;
    uint8_t *ub = (uint8_t *)p->da2;                     /* caller's buffer (>= FS_BATCH_BYTES) */
    uint32_t bytes = c->st[1];
    if (bytes > FS_BATCH_BYTES) bytes = FS_BATCH_BYTES;
    if (ub) for (uint32_t i = 0; i < bytes; i++) ub[i] = g_fs_batch[slot][i];
    return c->result;                                    /* record count */
}

/* client side of the page store (deferral thunk = client TASK context): ask the fs task
 * to make file page `pi` resident (for read, or `forwrite` = RMW/grow) and hand back its
 * identity address + valid bytes. Fallback (no fs task) fills inline — correct in any ctx. */
static uint8_t *fs_getpage(int slot, int fd, uint32_t pi, uint32_t *valid, int forwrite)
{
    fs_ctl *c = (slot >= 0 && slot < MAXPROC) ? g_fs_ctl[slot] : 0;
    if (!g_fs_q || !c) return (uint8_t *)fd_getpage(slot, fd, pi, valid, forwrite);
    c->op = FS_OP_GETPAGE; c->fd = (uint32_t)fd; c->page = pi; c->wr = (uint32_t)forwrite;
    c->page_addr = 0; c->valid = 0;
    g_fs_waiter[slot] = xTaskGetCurrentTaskHandle();
    xQueueSend(g_fs_q, &slot, portMAX_DELAY);
    ulTaskNotifyTake(pdTRUE, portMAX_DELAY);
    *valid = c->valid;
    return (uint8_t *)(uintptr_t)c->page_addr;
}

/* read over the page store (deferral thunk, in the CLIENT's space -> buf is mapped
 * HERE). One memcpy per page straight from the resident page to the user buffer. An
 * in-memory fd copies from vf.data with no fs-task hop; an SD fd fetches each page from
 * the service. The logical cursor fd.pos advances by bytes delivered. */
static long fs_read(proc_t *p)
{
    int      slot = (int)(p - g_proc);
    int      fd   = (int)p->da0;
    uint8_t *buf  = (uint8_t *)p->da1;
    uint32_t n    = (uint32_t)p->da2;
    if (fd < 0 || fd >= NFD || !p->fd[fd].open || p->fd[fd].pipei || p->fd[fd].con ||
        p->fd[fd].vf.chr)
        return -1;                       /* fd<3 allowed: `< file` redirected stdin */
    fd_t    *fdp  = &p->fd[fd];
    uint32_t size = fdp->vf.size, pos = fdp->pos, done = 0;
    while (done < n && pos < size) {
        uint32_t pi = pos >> 12, off = pos & 0xFFFu, valid;
        const uint8_t *page;
        if (fdp->vf.data) {                                    /* in-memory: inline, no fs task */
            uint32_t base = pi << 12;
            valid = (size - base < 0x1000u) ? (size - base) : 0x1000u;
            page  = (const uint8_t *)fdp->vf.data + base;
        } else {
            page = fs_getpage(slot, fd, pi, &valid, 0);
            if (!page) break;
        }
        if (off >= valid) break;
        uint32_t want = valid - off; if (want > n - done) want = n - done;
        memcpy(buf + done, page + off, want);
        done += want; pos += want;
    }
    fdp->pos = pos;
    return (long)done;
}

/* write over the page store (deferral thunk, client space -> buf is mapped HERE). One
 * memcpy per page straight into the resident (RMW-filled or fresh) page; the fs task
 * flushes dirty pages on eviction/close. In-memory (romfs) fds are read-only. Growth:
 * writing past EOF gets fresh zero pages and bumps the logical size. */
static long fs_write(proc_t *p)
{
    int            slot = (int)(p - g_proc);
    int            fd   = (int)p->da0;
    const uint8_t *buf  = (const uint8_t *)p->da1;
    uint32_t       n    = (uint32_t)p->da2;
    if (fd < 0 || fd >= NFD || !p->fd[fd].open || p->fd[fd].pipei || p->fd[fd].con ||
        p->fd[fd].vf.chr)
        return -1;                       /* fd<3 allowed: `> file` redirected stdout */
    fd_t *fdp = &p->fd[fd];
    if (!fdp->vf.write) return -1;                         /* read-only fd (romfs / RO open) */
    uint32_t pos = fdp->pos, done = 0;
    while (done < n) {
        uint32_t pi = pos >> 12, off = pos & 0xFFFu, valid;
        uint8_t *page = fs_getpage(slot, fd, pi, &valid, 1);
        if (!page) break;
        uint32_t want = 0x1000u - off; if (want > n - done) want = n - done;
        memcpy(page + off, buf + done, want);
        done += want; pos += want;
        if (pos > fdp->vf.size) fdp->vf.size = pos;        /* growth: extend logical size */
        fdp->cdirty = 1;                                   /* the fs task flushes on evict/close */
    }
    fdp->pos = pos;
    return (long)done;
}

/* mmap of a backing-store (SD/ramfs) file -> hand to the fs task, which eager-fills the
 * region into pool pages and maps them into THIS client's window (by slot/idx). Deferred
 * because the fill needs FatFs + must not race the fs task's page cache. Returns the VA. */
static long fs_mmap(proc_t *p)
{
    int     slot = (int)(p - g_proc);
    fs_ctl *c = (slot >= 0 && slot < MAXPROC) ? g_fs_ctl[slot] : 0;
    if (!g_fs_q || !c) return -1;
    c->op = FS_OP_MMAP; c->fd = (uint32_t)p->da0; c->len = (uint32_t)p->da1; c->off = (uint32_t)p->da2;
    c->page_addr = 0; c->result = -1;
    g_fs_waiter[slot] = xTaskGetCurrentTaskHandle();
    xQueueSend(g_fs_q, &slot, portMAX_DELAY);
    ulTaskNotifyTake(pdTRUE, portMAX_DELAY);
    return (c->result == 0) ? (long)c->page_addr : -1;
}

/* munmap -> fs task (it may need to write dirty pages back through FatFs). RO/romfs
 * mappings just get unmapped there. Fallback (no fs task) unmaps inline, no write-back. */
static long fs_munmap(proc_t *p)
{
    int     slot = (int)(p - g_proc);
    fs_ctl *c = (slot >= 0 && slot < MAXPROC) ? g_fs_ctl[slot] : 0;
    if (!g_fs_q || !c) return vm_munmap(slot, (uint32_t)p->da0, (uint32_t)p->da1);
    c->op = FS_OP_MUNMAP; c->off = (uint32_t)p->da0; c->len = (uint32_t)p->da1;
    c->result = -1;
    g_fs_waiter[slot] = xTaskGetCurrentTaskHandle();
    xQueueSend(g_fs_q, &slot, portMAX_DELAY);
    ulTaskNotifyTake(pdTRUE, portMAX_DELAY);
    return c->result;
}

/* stand up the fs service: per-slot shm control pages (the IPC substrate — one page
 * each, kept for the system's life), the doorbell queue, and the owning task. From main
 * before the scheduler, so it's ready before any PL0 open. Priority 4 (> procs at 3) so
 * a queued request is served promptly, then it blocks again. 8192-word stack:
 * FatFs/xsdps metadata walks are stack-hungry, like the shell task. */
void frtos_fs_start(void)
{
    /* one control page per slot. These are reached ONLY by identity address —
     * the client's deferral thunk (PL1, client space) and the fs task (master)
     * both use g_fs_ctl[slot] directly, never a per-space VA mapping — so they
     * take plain pool pages, NOT scarce shm slots (NSHM). fs_ctl is < 1 page. */
    for (int s = 0; s < MAXPROC; s++) {
        g_fs_ctl[s] = (fs_ctl *)vm_page_alloc();
        if (!g_fs_ctl[s]) { if (g_console) g_console("[fs] ctl page alloc failed\n", 27); return; }
        g_fs_batch[s] = (uint8_t *)vm_page_alloc();      /* SYS_getdents packing page (4 KB) */
        if (!g_fs_batch[s]) { if (g_console) g_console("[fs] batch page alloc failed\n", 29); return; }
    }
    g_fs_q = xQueueCreate(MAXPROC + 2, sizeof(int));   /* client slots + a kernel job */
    if (!g_fs_q) { if (g_console) g_console("[fs] queue create failed\n", 25); return; }
    g_kfs_mtx = xSemaphoreCreateMutex();
    if (!g_kfs_mtx) { if (g_console) g_console("[fs] kfs mutex failed\n", 22); vQueueDelete(g_fs_q); g_fs_q = 0; return; }
    g_kfs_done = xSemaphoreCreateBinary();
    if (!g_kfs_done) { if (g_console) g_console("[fs] kfs done-sem failed\n", 25);
                       vSemaphoreDelete(g_kfs_mtx); g_kfs_mtx = 0;
                       vQueueDelete(g_fs_q); g_fs_q = 0; return; }
    if (xTaskCreate(fs_task, "fs", 8192, NULL, 4, NULL) != pdPASS) {
        if (g_console) g_console("[fs] task create failed\n", 24);
        vQueueDelete(g_fs_q); g_fs_q = 0;
    }
}

/* ---- blocking-syscall deferral -------------------------------------------
 * A blocking syscall (waitpid, stdin read) can't run in the SVC handler — its
 * yield (svc #0) would nest inside svc #1. So k_syscall_dispatch saves the PL0
 * caller's full exception frame in p->dctx and redirects the resume to
 * deferral_thunk, which runs at PL1 (System) in TASK context (return 1, like the
 * exit thunk). The thunk does the blocking work, then __sysret (svc #2) restores
 * p->dctx with the result in r0 and returns to PL0. cur_dctx() hands the asm
 * svc #2 path the saved frame ({r0..r12, lr=PC, sp_usr, spsr}). */
void *cur_dctx(void) { proc_t *p = cur_proc(); return p ? p->dctx : (void *)0; }

static long do_syscall(uint32_t num, long a0, long a1, long a2);   /* run the normal handler in task ctx */

void deferral_thunk(void)                 /* PL1 (System), task context */
{
    extern void __sysret(long);
    extern int  con_tty_readc(void);
    proc_t *p = cur_proc();
    long r = -1;
    if (p) {
        stop_park(p);                                      /* ^Z/SIGSTOP: park before dispatch;
                                                            * the syscall runs after SIGCONT */
        if (p->dnum == SYS_spawn) {                        /* may load libs from the SD (FatFs) */
            r = frtos_spawn_argv((const char *)p->da0, (int)p->da1, (char **)p->da2, g_khost);
        } else if (p->dnum == SYS_spawn_fd) {              /* spawn + wire child stdio to pipe ends */
            char **av = (char **)p->da1; int ac = 0;
            while (av && av[ac]) ac++;
            const int *aux = (const int *)p->da2;          /* struct xt_spawn_aux {int fds[4]; char **envp;} */
            char **envp = aux ? *(char ***)(aux + 4) : NULL;
            r = frtos_spawn_argv_fds((const char *)p->da0, ac, av, envp, g_khost, aux);
        } else if (p->dnum == SYS_pipe) {                  /* allocate a pipe + two end fds */
            r = k_pipe_create(p, (int *)p->da0);
        } else if (p->dnum == SYS_svc_register) {
            r = k_svc_register(p, (const char *)p->da0);
        } else if (p->dnum == SYS_svc_connect) {
            r = k_svc_connect(p, (const char *)p->da0);
        } else if (p->dnum == SYS_svc_accept) {
            r = k_svc_accept(p, (int)p->da0);
        } else if (p->dnum == SYS_poll) {
            r = k_poll(p, (struct xt_pollfd *)p->da0, (int)p->da1, (int)p->da2);
        } else if ((p->dnum == SYS_read || p->dnum == SYS_write) &&
                   p->da0 < NFD && p->fd[p->da0].open &&
                   (p->fd[p->da0].rpipe || p->fd[p->da0].wpipe)) {
            if (p->dnum == SYS_read)
                r = k_chan_read(p, (int)p->da0, (char *)p->da1, (uint32_t)p->da2);
            else {
                /* NO SIGPIPE ON A CHANNEL. A pipe write with no reader kills the writer, which
                 * is right for a shell pipeline -- and CATASTROPHIC for a service. It would mean
                 * any client that disconnects while the server is mid-reply EXECUTES THE SERVER.
                 * gemd must survive client death (§3, §9); that is the whole point of it being
                 * the arbiter. A dead peer is an ERROR RETURN here, and the server notices the
                 * hangup the same way it notices everything else: EOF on the next read. */
                r = k_chan_write(p, (int)p->da0, (const char *)p->da1, (uint32_t)p->da2);
            }
        } else if ((p->dnum == SYS_read || p->dnum == SYS_write) &&
                   p->da0 < NFD && p->fd[p->da0].open && p->fd[p->da0].pipei) {
            if (p->dnum == SYS_read)
                r = k_pipe_read(p, (int)p->da0, (char *)p->da1, (uint32_t)p->da2);
            else {
                r = k_pipe_write(p, (int)p->da0, (const char *)p->da1, (uint32_t)p->da2);
                /* SIGPIPE semantics: writing a pipe with no readers kills the
                 * writer (128+13). stdio-buffered writers never check errors —
                 * without this, `yes | head` style pipelines spin forever. */
                if (r < 0) proc_exit_self(p, 141);    /* no return */
            }
        } else if ((p->dnum == SYS_read || p->dnum == SYS_write) &&
                   p->da0 < NFD && p->fd[p->da0].open && p->fd[p->da0].vf.chr) {
            /* char device: unbounded stream — the driver directly, no page store */
            fd_t *cf = &p->fd[p->da0];
            if (p->dnum == SYS_read)
                r = cf->vf.read ? cf->vf.read(&cf->vf, (void *)p->da1, (uint32_t)p->da2) : -1;
            else
                r = cf->vf.write ? cf->vf.write(&cf->vf, (const void *)p->da1, (uint32_t)p->da2) : -1;
        } else if (p->dnum >= SYS_socket && p->dnum <= SYS_resolve) {
            r = k_socket_call(p);                          /* the socket family (net/sockets.c) */
        } else if ((p->dnum == SYS_read || p->dnum == SYS_write) &&
                   p->da0 < NFD && p->fd[p->da0].open && p->fd[p->da0].sock) {
            extern long xt_sock_recv(int, void *, unsigned, int (*)(void *), void *, int);
            extern long xt_sock_send(int, const void *, unsigned);
            int si = p->fd[p->da0].sock - 1;
            if (p->dnum == SYS_read)
                r = xt_sock_recv(si, (void *)p->da1, (unsigned)p->da2, sock_tick, p,
                                 p->fd[p->da0].nonblock);
            else
                r = xt_sock_send(si, (const void *)p->da1, (unsigned)p->da2);
        } else if (p->dnum == SYS_recvfrom &&
                   p->da0 < NFD && p->fd[p->da0].open && p->fd[p->da0].sock) {
            extern long xt_sock_recvfrom(int, void *, unsigned, unsigned *, unsigned *,
                                         int (*)(void *), void *);
            unsigned *a = (unsigned *)p->da2;              /* a[0]=len in, a[1]=ip, a[2]=port out */
            r = a ? xt_sock_recvfrom(p->fd[p->da0].sock - 1, (void *)p->da1, a[0],
                                     &a[1], &a[2], sock_tick, p) : -1;
        } else if (p->dnum == SYS_close &&
                   p->da0 < NFD && p->fd[p->da0].open && p->fd[p->da0].sock) {
            extern void xt_sock_close(int);
            xt_sock_close(p->fd[p->da0].sock - 1);
            p->fd[p->da0].open = 0; p->fd[p->da0].sock = 0;
            r = 0;
        } else if (p->dnum == SYS_ioctl && p->da0 < NFD && p->fd[p->da0].open &&
                   (p->da1 == XT_FIONBIO || (p->da1 == XT_FIONREAD && p->fd[p->da0].pipei))) {
            /* FIONBIO on any fd: set/clear O_NONBLOCK. FIONREAD on a pipe: buffered bytes
             * (accurate poll — an empty pipe is NOT readable, unlike the always-ready
             * fallback). */
            fd_t *cf = &p->fd[p->da0];
            if (p->da1 == XT_FIONBIO) {
                cf->nonblock = cf->vf.nonblock = (p->da2 && *(int *)p->da2) ? 1 : 0;
                r = 0;
            } else {
                /* FIONREAD on a pipe: buffered bytes; returns 1 (not 0) when the
                 * pipe is drained AND writerless — poll must report READABLE then
                 * (the read gives EOF), or a select()-driven reader never learns
                 * the writer went away. */
                kpipe_t *pp = &g_pipes[cf->pipei - 1];
                int avail = (int)xStreamBufferBytesAvailable(pp->sb);
                if (p->da2) *(int *)p->da2 = avail;
                r = (!avail && pp->writers <= 0) ? 1 : 0;
            }
        } else if (p->dnum == SYS_ioctl && p->da0 < NFD &&
                   p->fd[p->da0].open && p->fd[p->da0].sock) {
            extern long xt_sock_avail(int);                /* FIONREAD = poll readability */
            extern int  xt_ifreq_ioctl(unsigned, void *);  /* SIOCGIF* = ifconfig display */
            extern int  xt_sock_endpoint(int, int, unsigned *, unsigned *);
            if (p->da1 == XT_FIONREAD && p->da2)
                r = (*(int *)p->da2 = (int)xt_sock_avail(p->fd[p->da0].sock - 1), 0);
            else if ((p->da1 == XT_SIOCGPEER || p->da1 == XT_SIOCGNAME) && p->da2) {
                /* getpeername/getsockname: u32[2] out = {ip_be32, port} */
                unsigned *o = (unsigned *)p->da2;
                r = xt_sock_endpoint(p->fd[p->da0].sock - 1,
                                     p->da1 == XT_SIOCGPEER, &o[0], &o[1]);
            }
            else if ((p->da1 & 0xFF00u) == 0x8900u)        /* SIOCGIF* interface queries */
                r = xt_ifreq_ioctl((unsigned)p->da1, (void *)p->da2);
            else
                r = -1;
        } else if (p->dnum == SYS_ioctl) {                 /* device controls (tty modes, i2c, ...) */
            uint32_t ifd = p->da0;
            int is_con = (ifd < 3 && !(ifd < NFD && p->fd[ifd].open)) ||   /* raw console stdio */
                         (ifd < NFD && p->fd[ifd].open && p->fd[ifd].con); /* console alias */
            if (is_con)
                r = k_tty_ioctl(p, (unsigned)p->da1, (void *)p->da2);
            else {
                fd_t *cf = (ifd < NFD && p->fd[ifd].open) ? &p->fd[ifd] : 0;
                r = (cf && cf->vf.chr && cf->vf.ioctl)
                    ? cf->vf.ioctl(&cf->vf, (unsigned)p->da1, (void *)p->da2) : -1;
            }
        } else if (p->dnum == SYS_net_up) {
            /* boot-script networking bring-up (/bin/netup); idempotent */
            extern void net_init(void);
            net_init(); r = 0;
        } else if (p->dnum == SYS_close &&
                   p->da0 < NFD && p->fd[p->da0].open && p->fd[p->da0].pipei) {
            k_pipe_close_end(&p->fd[p->da0]); r = 0;
        } else if (p->dnum == SYS_dup2) {                  /* pipe-end duplication */
            r = k_dup2(p, (int)p->da0, (int)p->da1);
        } else if (p->dnum == SYS_waitpid && (p->da1 & XT_WAIT_PEEK)) {  /* peek: no reap */
            extern int frtos_waitpid_peek(int); r = frtos_waitpid_peek((int)p->da0);
        } else if (p->dnum == SYS_waitpid && (p->da1 & 1)) {   /* poll (WNOHANG) */
            extern int frtos_waitpid_poll(int); r = frtos_waitpid_poll((int)p->da0);
        } else if (p->dnum == SYS_waitpid) {               /* blocks until the child exits */
            extern int frtos_waitpid_notify(int); r = frtos_waitpid_notify((int)p->da0);
        } else if (p->dnum == SYS_read &&
                   ((p->da0 == 0 && !p->fd[0].open) ||   /* fd0 open = redirected file stdin */
                    (p->da0 < NFD && p->fd[p->da0].open && p->fd[p->da0].con))) {
            /* stdin (or a console alias): the tty line discipline — the console
             * is a raw UART, so ECHO / backspace-erase / CR->NL live HERE, once,
             * for every program (a shell expects a cooked tty). One console =
             * one line buffer; reads drain it, empty refills. Raw mode
             * (XT_TTY_SETMODE canon=0 — vi, hexedit) bypasses all of it. */
            char *buf = (char *)p->da1;
            if (!buf || p->da2 == 0) r = 0;
            else if (!g_tty.canon) {
                /* raw: bytes verbatim as they arrive — no line buffer, no erase.
                 * ONE mapping survives: this console's Enter is CRLF, so a \n
                 * directly after a \r is swallowed (else every Enter inserts two
                 * lines in vi). The CR-seen flag is g_lsawcr, SHARED with the
                 * cooked path: vi eats the \r of its final :wq raw, exits, and
                 * the trailing \n must not become an empty line at the shell.
                 * Serve cooked leftover first; else block until one deliverable
                 * byte arrives, then drain what's already buffered so escape
                 * sequences arrive in one read where possible. */
                uint32_t want = (uint32_t)p->da2, k = 0;
                while (k < want && g_lpos < g_llen) buf[k++] = g_lbuf[g_lpos++];
                while (!k && !g_con_eof) {
                    int c = con_tty_readc();
                    if (c < 0) { g_con_eof = 1; break; }  /* EOF (qemu pipe drained) */
                    for (;;) {
                        int swallow = (g_lsawcr && c == '\n');
                        g_lsawcr = (c == '\r');
                        if (!swallow) buf[k++] = (char)c;
                        if (k >= want || con_tty_avail() <= 0) break;
                        c = con_tty_readc();
                        if (c < 0) { g_con_eof = 1; break; }
                    }
                }
                if (k && g_tty.echo && g_console) g_console(buf, (int)k);
                r = (long)k;                              /* 0 = EOF */
            }
            else {
                if (g_lpos >= g_llen) {                   /* refill: read+echo a line */
                    g_lpos = g_llen = 0;
                    for (;;) {
                        int c = con_tty_readc();
                        if (c < 0) { g_con_eof = 1; break; }   /* EOF (qemu pipe drained) */
                        if (c == 3 || c == 26) {          /* ^C kills / ^Z stops the fg job;
                                                           * either drops the pending line */
                            g_llen = 0;
                            if (g_console) g_console(c == 3 ? "^C\n" : "^Z\n", 3);
                            if (c == 3) {
                                frtos_tty_sigint();       /* no-ops if the ISR already fired */
                                if (p->killed)            /* WE are the target: die here — a
                                                           * phantom line must not escape the
                                                           * dying read */
                                    proc_exit_self(p, 137);
                            } else {
                                frtos_tty_sigtstp();
                                if (p->stopped) {         /* WE are the target: park INSIDE the
                                                           * read; after fg it keeps reading —
                                                           * no phantom empty line (sqlite's
                                                           * REPL would take it as input) */
                                    stop_park(p);
                                    continue;
                                }
                            }
                            g_lbuf[g_llen++] = '\n';      /* not the target (idle prompt):
                                                           * empty line -> the reader reprompts */
                            break;
                        }
                        if (c == 4 && g_llen == 0)        /* ^D at line start: EOF for THIS
                                                           * read (r = 0) — cooked readers
                                                           * (sqlite, cat) exit cleanly; the
                                                           * raw linenoise prompt handles its
                                                           * own ^D. Not sticky (g_con_eof
                                                           * stays clear). */
                            break;
                        if (g_lsawcr) {                   /* CRLF: the CR already became NL */
                            g_lsawcr = 0;
                            if (c == '\n') continue;
                        }
                        if (c == '\r') { g_lsawcr = 1; c = '\n'; }   /* terminals send CR (or CRLF) */
                        if (c == 8 || c == 127) {         /* backspace/DEL: erase */
                            if (g_llen > 0) { g_llen--; if (g_console) g_console("\b \b", 3); }
                            continue;
                        }
                        if (g_llen < (int)sizeof g_lbuf) {
                            char ec = (char)c;
                            g_lbuf[g_llen++] = ec;
                            if (g_console) g_console(&ec, 1);
                        }
                        if (c == '\n') break;
                    }
                }
                uint32_t avail = (uint32_t)(g_llen - g_lpos);
                uint32_t n = (uint32_t)p->da2 < avail ? (uint32_t)p->da2 : avail;
                if (n) { memcpy(buf, g_lbuf + g_lpos, n); g_lpos += (int)n; }
                r = (long)n;                              /* 0 = EOF */
            }
        } else if (p->dnum == SYS_read) {
            /* file read over the page store, in the CLIENT's space (buf is mapped here);
             * pages are filled by the fs task, copied out one memcpy each. */
            r = fs_read(p);
        } else if (p->dnum == SYS_write && p->da0 < NFD &&
                   p->fd[p->da0].open && !p->fd[p->da0].con) {
            /* file write over the page store (client space, buf mapped here); pages are
             * dirtied in place and flushed by the fs task on evict/close. CONSOLE
             * writes fall through to do_syscall — normally inline, they only land
             * here when the stop gate (^Z) force-defers every syscall. */
            r = fs_write(p);
        } else if (p->dnum == SYS_open || p->dnum == SYS_close) {
            /* metadata ops (no client data buffer) -> the fs service task owns them. */
            r = fs_call(p);
        } else if (p->dnum == SYS_stat || p->dnum == SYS_lstat || p->dnum == SYS_readlink ||
                   p->dnum == SYS_symlink || p->dnum == SYS_unlink || p->dnum == SYS_readdir ||
                   p->dnum == SYS_mkdir || p->dnum == SYS_chdir || p->dnum == SYS_rename ||
                   p->dnum == SYS_statfs) {
            /* path metadata + symlinks + dir enumeration + mkdir/chdir/rename: fs task walks FatFs. */
            r = fs_meta(p);
        } else if (p->dnum == SYS_getdents) {              /* batch dir read (entries + metadata) */
            r = fs_getdents(p);
        } else if (p->dnum == SYS_mmap) {
            /* mmap a backing-store file: the fs task eager-fills + maps it into our space. */
            r = fs_mmap(p);
        } else if (p->dnum == SYS_munmap) {
            /* munmap: the fs task writes back dirty pages (if any) then unmaps. */
            r = fs_munmap(p);
        } else if (p->dnum == SYS_input) {
            /* Block for the next input event. THE QUEUE IS THE SOURCE OF TRUTH (input_dev.c):
             * one decoder task drains the serial lane and everybody — this syscall and
             * /OS/dev/input — is a view on the same queue, so there is never a second reader
             * racing it for bytes. Kept for programs that predate the fd; a window server must
             * use /OS/dev/input, because THIS cannot be polled alongside anything else.
             * da2 = raw-keys mode (typing into an emulator window). */
            extern int  xt_input_pop(struct os_event *, int);
            extern void xt_input_set_raw(int);
            extern void xt_input_pos(int *, int *);
            struct os_event *ev = (struct os_event *)p->da0;
            if (!ev) { r = -1; }
            else {
                memset(ev, 0, sizeof *ev);
                xt_input_set_raw((int)p->da2);
                if (!xt_input_pop(ev, (int)p->da1)) {          /* timeout: the old contract */
                    ev->type = OS_EV_TIMER;
                    xt_input_pos(&ev->mx, &ev->my);
                }
                r = 0;
            }
        } else {
            r = do_syscall(p->dnum, p->da0, p->da1, p->da2);
        }
    }
    if (p && p->strace) { extern void strace_ret(uint32_t, long); strace_ret(p->dnum, r); }
    if (p) {
        p->dctx[0] = (uint32_t)r;         /* result into dctx[0] (.Lsysret no longer stores it) */
        extern void deliver_deferred(proc_t *);
        if (p->sig_pending & ~p->sig_blocked) deliver_deferred(p);   /* inject a pending handler */
    }
    __sysret(r);                          /* never returns */
}

/* defer the blocking syscalls; the rest run inline in do_syscall. Returns 1 to make
 * the vector resume deferral_thunk at PL1 (System). */
static int defer_syscall(struct k_regs *regs, uint32_t num)
{
    proc_t *p = cur_proc();
    if (!p) { regs->r[0] = (uint32_t)-1; return 0; }       /* no proc -> can't defer */
    for (int i = 0; i < 13; i++) p->dctx[i] = regs->r[i];
    p->dctx[13] = regs->lr;                                /* user resume PC */
    uint32_t spsr, spu, lru;
    __asm__ volatile("mrs %0, spsr" : "=r"(spsr));
    __asm__ volatile("cps #0x1f\n\tmov %0, sp\n\tmov %1, lr\n\tcps #0x13" : "=r"(spu), "=r"(lru) :: "memory"); /* sp_usr + r14_usr */
    p->dctx[14] = spu; p->dctx[15] = spsr; p->dctx[16] = lru;
    p->dnum = num; p->da0 = regs->r[0]; p->da1 = regs->r[1]; p->da2 = regs->r[2];
    regs->lr = (uint32_t)(uintptr_t)deferral_thunk;
    return 1;
}

static long do_syscall(uint32_t num, long a0, long a1, long a2)
{
    proc_t *p = cur_proc();
    switch (num) {
    case SYS_abi_version: return XTOS_ABI_VERSION;           /* () -> frozen-ABI version */
    case SYS_write:                                          /* (fd, buf, len) */
        if (g_console && a1 &&
            ((a0 == 1 || a0 == 2) ||
             (p && a0 >= 3 && a0 < NFD && p->fd[a0].open && p->fd[a0].con)))
        { g_console((const char *)a1, (int)a2); return a2; }
        return -1;
    case SYS_getpid: return p ? p->pid : 0;
    case SYS_envp:   return p ? (long)(uintptr_t)p->envp : 0;   /* inherited env (shim seeds environ) */
    case SYS_reboot: {                                       /* (cmd) -> no return: PS soft reset */
        volatile uint32_t *slcr = (volatile uint32_t *)0xF8000000u;
        __asm__ volatile("cpsid if");                        /* mask interrupts */
        slcr[0x008 / 4] = 0xDF0Du;                            /* SLCR unlock */
        slcr[0x200 / 4] = 0x1u;                              /* PSS_RST_CTRL: soft reboot */
        for (;;) { }                                         /* the reset lands here */
    }
    case SYS_kill: {                                         /* (pid, sig): flags only — inline-safe */
        proc_t *t = proc_by_pid((int)a0);
        if (!t || t->exited) return -1;                      /* ESRCH-ish */
        int sig = (int)a1;
        if (sig == 0) return 0;                              /* existence probe */
        if (sig == XT_SIGCONT) { t->stopped = 0; return 0; } /* resume (stop_park polls) */
        if (sig == XT_SIGSTOP || sig == XT_SIGTSTP) { t->stopped = 1; return 0; }
        /* catchable signal with a real handler installed -> mark pending; the
         * kernel vectors it to the handler at the target's next return-to-PL0
         * (syscall-return / timer-tick). SIGKILL(9) is never catchable. */
        if (sig > 0 && sig < XT_NSIG && sig != 9 && t->sigact[sig].handler != XT_SIG_DFL) {
            if (t->sigact[sig].handler == XT_SIG_IGN) return 0;   /* ignored */
            t->sig_pending |= (1u << sig);
            return 0;
        }
        t->killed = 1;                                       /* default disposition = terminate */
        return 0;
    }
    case SYS_rt_sigaction: {                                 /* (sig, const act, old) */
        if (!p) return -1;
        int sig = (int)a0;
        if (sig <= 0 || sig >= XT_NSIG || sig == 9 || sig == XT_SIGSTOP) return -1;
        struct xt_sigaction *old = (struct xt_sigaction *)a2;
        if (old) *old = p->sigact[sig];
        const struct xt_sigaction *act = (const struct xt_sigaction *)a1;
        if (act) { p->sigact[sig] = *act; if (act->trap) p->sig_trap = (uint32_t)act->trap; }
        return 0;
    }
    case SYS_rt_sigprocmask: {                               /* (how, const set, old) */
        if (!p) return -1;
        uint32_t *old = (uint32_t *)a2;
        if (old) *old = p->sig_blocked;
        const uint32_t *set = (const uint32_t *)a1;
        if (set) {
            if (a0 == XT_SIG_BLOCK)        p->sig_blocked |= *set;
            else if (a0 == XT_SIG_UNBLOCK) p->sig_blocked &= ~*set;
            else                           p->sig_blocked = *set;   /* SETMASK */
            p->sig_blocked &= ~((1u << 9) | (1u << XT_SIGSTOP));     /* KILL/STOP unblockable */
        }
        return 0;
    }
    case SYS_open:   return sys_open(p, (const char *)a0, (int)a1);   /* (path, flags) */
    case SYS_read:   return sys_read(p, (int)a0, (void *)a1, (uint32_t)a2);
    case SYS_close:  if (p && a0 >= 3 && a0 < NFD && p->fd[a0].open &&
                         (p->fd[a0].rpipe || p->fd[a0].wpipe)) { k_chan_close(&p->fd[a0]); return 0; }
                     if (p && a0 >= 3 && a0 < NFD && p->fd[a0].open && p->fd[a0].svc) {
                         svc_t *sv = &g_svc[p->fd[a0].svc - 1];
                         taskENTER_CRITICAL(); sv->nq = 0; sv->used = 0; taskEXIT_CRITICAL();
                         p->fd[a0].open = 0; p->fd[a0].svc = 0; return 0;
                     }
                     if (p && a0 >= 3 && a0 < NFD && p->fd[a0].open && !p->fd[a0].pipei) {
                         if (p->fd[a0].con) { p->fd[a0].open = 0; p->fd[a0].con = 0; return 0; }
                         fd_drop_cache(&p->fd[a0]);        /* pipe fds close via the deferred path */
                         vfs_close(&p->fd[a0].vf);
                         p->fd[a0].open = 0;
                     } return 0;
    case SYS_lseek:  return sys_lseek(p, (int)a0, a1, (int)a2);
    case SYS_fstat:  return k_fstat(p, (int)a0, (struct xt_stat *)a1);   /* inline: table read */
    case SYS_statfs:   return k_statfs((uint32_t *)a1);                              /* FatFs f_getfree (HW) */
    case SYS_getdents: return -1;                     /* always deferred to fs_getdents; no inline path */
    case SYS_stat:     return vfs_stat((const char *)a0, (struct xt_stat *)a1);      /* follows symlinks */
    case SYS_lstat:    return vfs_lstat((const char *)a0, (struct xt_stat *)a1);     /* the link itself */
    case SYS_readlink: return vfs_readlink((const char *)a0, (char *)a1, (int)a2);
    case SYS_symlink:  return vfs_symlink((const char *)a0, (const char *)a1);
    case SYS_unlink:   return vfs_unlink((const char *)a0);
    case SYS_readdir: {
        struct xt_dirent *o = (struct xt_dirent *)a2;
        unsigned mode = 0;
        long r = vfs_readdir((const char *)a0, (int)a1, o ? o->name : 0, 256, &mode);
        if (o && r == 1) o->mode = mode;
        return r;
    }
    case SYS_getcwd: {                                       /* inline: just reads the process cwd */
        char *buf = (char *)a0; uint32_t sz = (uint32_t)a1;
        if (!p || !buf || sz == 0) return -1;
        int i = 0; while (p->cwd[i] && i < (int)sz - 1) { buf[i] = p->cwd[i]; i++; } buf[i] = 0;
        return i;
    }
    case SYS_mkdir:  { char ap[FS_PATH_MAX]; abspath(p, (const char *)a0, ap); return vfs_mkdir(ap); }
    case SYS_rename: { char a[FS_PATH_MAX], b[FS_PATH_MAX]; abspath(p, (const char *)a0, a); abspath(p, (const char *)a1, b); return vfs_rename(a, b); }
    case SYS_chdir:  {                                       /* fallback (no fs task): stat + set cwd */
        char ap[FS_PATH_MAX], canon[FS_PATH_MAX]; struct xt_stat s;
        abspath(p, (const char *)a0, ap);
        if (!p || vfs_resolve(ap, canon, FS_PATH_MAX, 1) != 0) return -1;
        if (vfs_stat(canon, &s) != 0 || (s.mode & XT_S_IFMT) != XT_S_IFDIR) return -1;
        int i = 0; while (canon[i] && i < (int)sizeof p->cwd - 1) { p->cwd[i] = canon[i]; i++; } p->cwd[i] = 0;
        return 0;
    }
    case SYS_sbrk:   { extern void *sys_sbrk(int); return (long)sys_sbrk((int)a0); }  /* libc malloc */
    case SYS_mmap: {                                         /* (fd, len, off) -> VA, RO file map */
        int fd = (int)a0; uint32_t len = (uint32_t)a1, off = (uint32_t)a2;
        if (!p || fd < 3 || fd >= NFD || !p->fd[fd].open) return -1;
        vfs_file *f = &p->fd[fd].vf;
        if (!f->data) return -1;                             /* only in-memory (romfs) files mmappable */
        if (off > f->size) return -1;
        if (len == 0) len = f->size - off;
        if (off + len > f->size) return -1;
        uint32_t src = (uint32_t)(uintptr_t)f->data + off;   /* identity-mapped backing */
        if (src & 0xFFFu) return -1;                          /* file must be page-aligned */
        return (long)vm_mmap((int)(p - g_proc), src, len);
    }
    case SYS_munmap:                                         /* (addr, len) */
        return p ? vm_munmap((int)(p - g_proc), (uint32_t)a0, (uint32_t)a1) : -1;
    case SYS_shm_create:                                     /* (size, flags) -> id */
        return p ? vm_shm_create((int)(p - g_proc), (uint32_t)a0, (uint32_t)a1) : -1;
    case SYS_shm_map:    return p ? (long)vm_shm_map((int)(p - g_proc), (int)a0) : 0;  /* (id) -> VA */
    case SYS_shm_unmap:  return p ? vm_shm_unmap((int)(p - g_proc), (int)a0) : -1;    /* (id) -> 0 */
    case SYS_shm_grant: {                                    /* (id, pid) -> 0: owner grants map rights */
        if (!p) return -1;
        proc_t *t = proc_by_pid((int)a1);
        if (!t) return -1;                                   /* no such process */
        return vm_shm_grant((int)(p - g_proc), (int)a0, (int)(t - g_proc));
    }
    case SYS_chan_peer: {                                    /* (channel fd) -> peer pid */
        int fd = (int)a0;
        if (!p || fd < 0 || fd >= NFD || !p->fd[fd].open) return -1;
        if (!p->fd[fd].rpipe && !p->fd[fd].wpipe) return -1; /* not a channel */
        return p->fd[fd].peer ? p->fd[fd].peer : -1;
    }
    case SYS_fb_info: {                                      /* (struct os_fbinfo *) */
        extern void fb_info(int *, int *, int *, uint32_t *);
        struct { int w, h, stride; uint32_t addr; } *fi = (void *)a0;
        if (!fi) return -1;
        fb_info(&fi->w, &fi->h, &fi->stride, &fi->addr);
        return 0;
    }
    case SYS_fb_present: { extern void fb_present(void); fb_present(); return 0; }
    case SYS_xl_window: {                                    /* (x<<16|y, w<<16|h, scale) */
        extern void xl_window_set(int, int, int, int, int);
        xl_window_set((int)((uint32_t)a0 >> 16), (int)(a0 & 0xFFFF),
                      (int)((uint32_t)a1 >> 16), (int)(a1 & 0xFFFF), (int)a2);
        return 0;
    }
    case SYS_overlay: {                                     /* (x<<16|y, w<<16|h, en) -> drag-overlay */
        extern void overlay_set(int, int, int, int, int);
        if (frtos_current_pid() != g_fb_owner_pid) return -1;   /* M7 gate: the display
                                                                 * owner's plane, only */
        overlay_set((int)a2, (int)((uint32_t)a0 >> 16), (int)(a0 & 0xFFFF),
                    (int)((uint32_t)a1 >> 16), (int)(a1 & 0xFFFF));
        return 0;
    }
    case SYS_xl_boot: {                                     /* (path, drive) — task ctx (SD reads) */
        extern int xl_boot(const char *, int);
        return xl_boot((const char *)a0, (int)a1);
    }
    case SYS_xexload: {                                     /* (path, flags) — task ctx (SD reads) */
        extern int xex_boot(const char *, int, int);
        int flags = (int)a1;
        return xex_boot((const char *)a0, flags & 1, (flags >> 1) & 1);  /* turbo, hold */
    }
    case SYS_plane_grab: {                                  /* (plane_id, buf) -> (w<<16)|h */
        const uint32_t XL_W = 320, XL_H = 192;              /* XL_SRC_W x XL_SRC_H (RTL) */
        if ((int)a0 != XT_PLANE_XL) return -22;             /* 6502/XL plane only (m68k later) */
        uint32_t *dst = (uint32_t *)a1;
        if (!dst) return -14;
        /* DIAG4 (XT_BLK_DIAG+0x0C) = the XL plane's live compositor read address = the
         * base of the triple-buffer slot currently on screen; snap to the 1 MB slot grid
         * so the grab is the exact displayed frame (tear-free), fall back to slot 0. The
         * planes are PL0-NONE (M7 gate) — this PL1 copy is how userland reaches them. */
        uint32_t base = (*(volatile uint32_t *)0x43C0040Cu) & 0xFFF00000u;
        if (base != 0x31000000u && base != 0x31100000u && base != 0x31200000u)
            base = 0x31000000u;
        const volatile uint32_t *src = (const volatile uint32_t *)base;
        for (uint32_t i = 0; i < XL_W * XL_H; i++) dst[i] = src[i];
        return (long)((XL_W << 16) | XL_H);
    }
    case SYS_plane_window: {                                /* (plane<<16|scale<<8|en, x<<16|y, w<<16|h) */
        extern long plane_window_set(int, int, int, int, int, int, int);
        if (frtos_current_pid() != g_fb_owner_pid) return -1;   /* M7 gate: plane placement
                                                                 * is the display owner's */
        return plane_window_set((int)(((uint32_t)a0 >> 16) & 0xFFFFu),
                                (int)(int16_t)((uint32_t)a1 >> 16),   /* x/y SIGNED: a window */
                                (int)(int16_t)(a1 & 0xFFFF),          /* may hang off an edge */
                                (int)(int16_t)((uint32_t)a2 >> 16),
                                (int)(int16_t)(a2 & 0xFFFF),
                                (int)(((uint32_t)a0 >> 8) & 0xFFu),
                                (int)((uint32_t)a0 & 0xFFu));
    }
    case SYS_cursor_shape: {                                 /* (shape) -> HW cursor glyph */
#ifdef XT_HW
        extern void cursor_set_shape(int);
        cursor_set_shape((int)a0);
#endif
        return 0;
    }
    case SYS_kbd_6502: {                                     /* (ascii) -> keystroke to POKEY */
        extern int  kbd_6502_pace(int);
        extern void kbd_6502_inject(int);
        int pace = kbd_6502_pace((int)a0);    /* >=0: ms to meter BEFORE the key; -1: no Atari key */
        if (pace < 0) return -1;
        if (pace) {                           /* meter to keyboard pace (single KBCODE latch, no FIFO);
                                               * blocks THIS task -> back-pressures the paste ring drain.
                                               * The gap PRECEDES the key so a doubled char clears the
                                               * KEYDEL debounce before its repeat is injected. */
            TickType_t t = pdMS_TO_TICKS((uint32_t)pace);
            vTaskDelay(t ? t : 1);
        }
        kbd_6502_inject((int)a0);
        return 0;
    }
    case SYS_fb_wallpaper: {                                 /* (struct os_fbinfo *) */
        extern void fb_wallpaper_info(int *, int *, int *, uint32_t *);
        struct { int w, h, stride; uint32_t addr; } *fi = (void *)a0;
        if (!fi) return -1;
        fb_wallpaper_info(&fi->w, &fi->h, &fi->stride, &fi->addr);
        /* THE M7 GATE'S KEY: the first caller becomes THE DISPLAY OWNER — the whole
         * band is PL0-none in the master (mmu.c), and this grants the plane / DRAG /
         * wallpaper sections back into exactly one space (vm_map_fb_band). gemd is
         * first by boot order; first-caller-wins is the XT_BLIT_PRIORITY shape, and
         * the kernel still knows nothing about window servers — only that ONE process
         * composites the display. Everyone else gets the numbers and no mapping (the
         * desktop reads fb sizes; a deref would fault). Owner death resets the latch
         * (proc teardown below) so a restarted gemd claims again. */
        { proc_t *q = cur_proc();
          if (q) {
              if (g_fb_owner_pid < 0) {
                  g_fb_owner_pid = q->pid;
                  vm_map_fb_band((int)(q - g_proc));
              } else if (g_fb_owner_pid == q->pid)
                  vm_map_fb_band((int)(q - g_proc));   /* idempotent re-ask */
          } }
        return 0;
    }
    case SYS_spawn:                                          /* (path, argc, argv) -> pid */
        /* Safe from the SVC handler: the caller is a proc (priority 3) and proc_launch
         * makes the child the SAME priority, so xTaskCreate does not yield (no svc nest). */
        return frtos_spawn_argv((const char *)a0, (int)a1, (char **)a2, g_khost);
    case SYS_gettimeofday: {                                 /* (struct timeval *tv) */
        extern void gtimer_timeofday(uint32_t *, uint32_t *);
        /* newlib timeval: 64-bit time_t tv_sec @0, 32-bit suseconds_t tv_usec @8.
         * Write tv_sec as a full 64-bit value (high word 0 — uptime fits 32 bits). */
        extern uint32_t xt_wallclock_off(void);
        uint32_t *tv = (uint32_t *)a0;
        uint32_t sec, usec;
        if (!tv) return -1;
        gtimer_timeofday(&sec, &usec);
        sec += xt_wallclock_off();          /* unix epoch once SNTP synced (0 before) */
        tv[0] = sec;    /* tv_sec  low  */
        tv[1] = 0;      /* tv_sec  high */
        tv[2] = usec;   /* tv_usec @ byte offset 8 */
        return 0;
    }
    case SYS_settime: {                                     /* (unix_sec) */
        extern void xt_wallclock_set(uint32_t);
        xt_wallclock_set((uint32_t)a0);     /* sntp -s / clock_settime; hourly SNTP re-sync wins later */
        return 0;
    }
    case SYS_klog: {                                        /* (buf, len) -> dmesg ring */
        extern long klog_write(const char *, uint32_t);
        return klog_write((const char *)a0, (uint32_t)a1);
    }
    case SYS_devmem: {                                      /* (addr, val, write|size<<8) -> value: DEBUG peek/poke */
        /* a2: bit0 = write, bits[15:8] = access size 1/2/4 (0 => word, back-compat).
         * The access runs HERE, in the kernel (PL1), sized: a byte/half poke to an
         * unaligned Device address (the SALLY ROM window $43C0_xxxx, sub-word GP0
         * regs) no longer alignment-faults — a fault that used to be fatal and kill
         * the caller. PL1 also reaches the M7-gated plane band (SEC_PLANE_K = PL1-RW
         * in every process table). No bounds check — DEBUG tool, by design. */
        unsigned long q = (unsigned long)a0;
        int      wr = (int)(a2 & 1u);
        unsigned sz = (unsigned)((a2 >> 8) & 0xFFu);
        switch (sz) {
        case 1: { volatile uint8_t  *p = (volatile uint8_t  *)q; if (wr) *p = (uint8_t)a1;  return (long)(uint8_t)*p; }
        case 2: { volatile uint16_t *p = (volatile uint16_t *)q; if (wr) *p = (uint16_t)a1; return (long)(uint16_t)*p; }
        default:{ volatile uint32_t *p = (volatile uint32_t *)q; if (wr) *p = (uint32_t)a1; return (long)(uint32_t)*p; }
        }
    }
    case SYS_boot_done: return k_boot_done(p);              /* () -> 0: init ran every boot script */
    case SYS_strace: { if (p) p->strace = a0 ? 1 : 0; return 0; }   /* /bin/strace */
    case SYS_xtos_recv:                                     /* (int16 msg[8]) -> 1 dequeued, 0 none */
        return a0 ? xtos_recv(p, (int16_t *)a0) : 0;
    case SYS_nanosleep: {                                   /* (usec) — real yield, not a spin */
        TickType_t ticks = pdMS_TO_TICKS((uint32_t)a0 / 1000u);
        vTaskDelay(ticks ? ticks : 1);      /* >=1 tick so other tasks (net RX pump) run */
        return 0;
    }
    case SYS_getrandom: {                                   /* (buf, len, flags) -> bytes / -errno */
        extern void xt_random_bytes(void *, uint32_t);
        extern int  xt_random_is_hw(void), xt_random_hw_present(void), xt_random_gather(void);
        void *buf = (void *)a0;
        uint32_t len = (uint32_t)a1;
        if (!buf) return -22;                               /* -EINVAL */
        /* Where a TRNG exists, an uninitialised pool is a WAIT, not a result:
         * block (bounded) for a gather, and say -EAGAIN to a caller who asked
         * not to wait — the Linux contract, and the one dropbear's dbrandom.c
         * is written against (GRND_NONBLOCK probe, then a blocking retry). The
         * bound matters: a TRNG that never goes fresh is a hardware fault, and
         * waiting on it forever would wedge every caller of uuidgen, so the
         * last word is -EIO. Clock-seeded bytes are never returned in place of
         * hardware ones — that substitution is the bug this replaces.
         *
         * On qemu there is no TRNG to wait for, so neither branch applies and
         * the pool serves what it has. */
        if (xt_random_hw_present() && !xt_random_is_hw()) {
            if ((uint32_t)a2 & GRND_NONBLOCK) return -11;   /* -EAGAIN */
            for (int tries = 0; tries < 8 && !xt_random_is_hw(); tries++) {
                if (xt_random_gather() == 0) break;
                vTaskDelay(pdMS_TO_TICKS(10));              /* task ctx: a real yield */
            }
            if (!xt_random_is_hw()) return -5;              /* -EIO */
        }
        xt_random_bytes(buf, len);
        return (long)len;
    }
    default:         return -38;                             /* -ENOSYS */
    }
}

/* An open fd whose VFS backing is NOT in memory (vf.data == NULL) is an SD/FatFs file:
 * its I/O must run in task context. Console fds (0/1/2) and in-memory romfs files stay
 * inline. */
static int fd_is_sd(uint32_t fd)
{
    proc_t *p = cur_proc();
    return p && fd >= 3 && fd < NFD && p->fd[fd].open && !p->fd[fd].vf.data
        && !p->fd[fd].pipei && !p->fd[fd].con && !p->fd[fd].vf.chr;
        /* pipes/aliases/char devices have no backing store */
}

static int fd_is_con(uint32_t fd)
{
    proc_t *p = cur_proc();
    return p && fd < NFD && p->fd[fd].open && p->fd[fd].con;
}

/* POLICY — does this syscall have to run in TASK context (via the deferral thunk)
 * rather than inline in the SVC handler? A syscall can't run inline if it BLOCKS (its
 * svc-#0 yield would nest inside this svc) or if it drives FatFs/SD, whose polled
 * transfers only work with IRQs enabled and the scheduler live (the context sd_init
 * runs in — inline we're in an exception with IRQs masked). Everything the deferral
 * covers is centralized here, so a new filesystem syscall is one line, not a new bug. */
static int needs_task_ctx(struct k_regs *regs, uint32_t num)
{
    uint32_t fd = regs->r[0];
    switch (num) {
    case SYS_waitpid: return 1;                    /* blocks on the child */
    case SYS_spawn:   return 1;                    /* may load a DT_NEEDED lib from the SD */
    case SYS_spawn_fd: return 1;                   /* spawn + pipe-end refcounts */
    case SYS_pipe:    return 1;                    /* takes the FreeRTOS heap (stream buffer) */
    case SYS_svc_register: return 1;               /* fd alloc */
    case SYS_svc_connect:  return 1;               /* takes the FreeRTOS heap (two stream buffers) */
    case SYS_svc_accept:   return 1;               /* BLOCKS until a client connects */
    case SYS_poll:         return 1;               /* BLOCKS until an fd is ready */
    case SYS_open:    return 1;                    /* may walk a FatFs directory path */
    case SYS_xl_boot: return 1;                    /* reads the OS ROMs + the ATR off the SD */
    case SYS_xexload: return 1;                    /* reads the OS ROMs + the .xex off the SD */
    case SYS_read: {                               /* stdin + pipes + channels block */
        if (fd_is_con(fd)) return 1;               /* console alias: con_tty_readc path */
        proc_t *q = cur_proc();
        if (q && fd < NFD && q->fd[fd].open) return 1;   /* pipe or file, any slot (incl. `< file` stdin) */
        return fd == 0;                            /* raw console stdin */
    }
    case SYS_write: {
        if (fd_is_con(fd)) return 0;               /* console alias: inline like fd 1/2 */
        proc_t *q = cur_proc();
        return q && fd < NFD && q->fd[fd].open;    /* pipe or file, any slot (incl. `> file` stdout) */
    }
    case SYS_close:   return fd_is_sd(fd) || fd_is_pipe(fd) || fd_is_sock(fd);
                                                   /* backing-store/pipe/socket close -> task ctx */
    case SYS_ioctl:   return 1;                    /* device controls may poll HW for ms (i2c) */
    case SYS_socket: case SYS_connect: case SYS_bind:
    case SYS_listen: case SYS_accept: case SYS_resolve:
    case SYS_recvfrom:
        return 1;                                  /* netconn calls block in lwIP */
    case SYS_nanosleep: return 1;                  /* vTaskDelay must run in task ctx */
    case SYS_getrandom: return 1;                  /* may vTaskDelay between gather retries */
    case SYS_net_up:  return 1;                    /* xTaskCreate (kernel heap) -> task ctx */
    case SYS_statfs:  return 1;                    /* fs task queries FatFs f_getfree */
    case SYS_getdents: return 1;                   /* fs task packs the dir batch page */
    case SYS_dup2:    return 1;                    /* may close a displaced pipe end */
    case SYS_mmap:    return fd_is_sd(fd);          /* backing-store mmap -> fs task eager-fill (romfs inline) */
    case SYS_munmap:  return 1;                     /* may write dirty pages back (FatFs) -> task ctx */
    case SYS_input:   return 1;                     /* blocks on the serial ring for the next event */
    case SYS_stat: case SYS_lstat: case SYS_readlink:
    case SYS_symlink: case SYS_unlink: case SYS_readdir:
    case SYS_mkdir: case SYS_chdir: case SYS_rename: return 1;    /* path metadata -> FatFs -> fs task */
    /* SYS_getcwd falls through to inline (default 0) — it only reads the process cwd */
    default:          return 0;                    /* lseek (inline)/getpid/sbrk/fb/gettimeofday */
    }
}

/* called from the chained SVC vector with the saved register block. Returns 1 for
 * the exit case (the vector then resumes task_exit_thunk at PL1 — see xt_vectors.S),
 * 0 otherwise. */
/* ---- strace: log a traced process's syscalls to klog (dmesg) --------------
 * A single chokepoint (this dispatcher) makes it cheap. Enable per process by
 * name via g_strace_name (matched at spawn -> p->strace), or globally. The line
 * is "strace pid sys<hex> <a0> <a1> <a2>"; returns are logged by the inline and
 * deferred paths. Read it with `dmesg` / /proc/kmsg. */
const char *g_strace_name;                /* substring of argv0 basename to trace; NULL = off */
static void strace_hex(char *b, int *k, uint32_t v)
{
    for (int i = 7; i >= 0; i--) { unsigned d = (v >> (i * 4)) & 0xF; b[(*k)++] = (char)(d < 10 ? '0' + d : 'a' + d - 10); }
}
/* map a syscall number to a short name for readable traces (common ones; others
 * print as sys<hex>). Keep in step with xtsys.h. */
static const char *strace_name(uint32_t n)
{
    switch (n) {
    case SYS_write: return "write";     case SYS_read: return "read";
    case SYS_open: return "open";       case SYS_close: return "close";
    case SYS_lseek: return "lseek";     case SYS_ioctl: return "ioctl";
    case SYS_fstat: return "fstat";     case SYS_stat: return "stat";
    case SYS_waitpid: return "waitpid"; case SYS_spawn: return "spawn";
    case SYS_spawn_fd: return "spawn_fd"; case SYS_exit: return "exit";
    case SYS_getpid: return "getpid";   case SYS_pipe: return "pipe";
    case SYS_dup2: return "dup2";       case SYS_kill: return "kill";
    case SYS_nanosleep: return "nanosleep"; case SYS_gettimeofday: return "gettimeofday";
    case SYS_klog: return "klog";       case SYS_devmem: return "devmem";
    case SYS_getrandom: return "getrandom";
    case SYS_boot_done: return "boot_done";
    case SYS_getcwd: return "getcwd";
    case SYS_socket: return "socket";   case SYS_accept: return "accept";
    case SYS_recvfrom: return "recvfrom"; case SYS_readdir: return "readdir";
    case SYS_envp: return "envp";       case SYS_strace: return "strace";
    case SYS_connect: return "connect"; case SYS_bind: return "bind";
    case SYS_listen: return "listen";
    default: return 0;
    }
}
static void strace_log(int pid, const char *tag, uint32_t num, uint32_t a0, uint32_t a1, uint32_t a2)
{
    char b[96]; int k = 0;
    for (const char *t = "strace "; *t; t++) b[k++] = *t;
    for (const char *t = tag; *t; t++) b[k++] = *t;
    b[k++] = ' '; { unsigned v = (unsigned)pid; char d[8]; int n = 0; do { d[n++] = (char)('0' + v % 10); v /= 10; } while (v && n < 7); while (n) b[k++] = d[--n]; }
    b[k++] = ' ';
    const char *nm = strace_name(num);
    if (nm) { for (const char *t = nm; *t; t++) b[k++] = *t; }
    else { for (const char *t = "sys"; *t; t++) b[k++] = *t; strace_hex(b, &k, num); }
    b[k++] = '('; strace_hex(b, &k, a0);
    b[k++] = ','; strace_hex(b, &k, a1);
    b[k++] = ','; strace_hex(b, &k, a2);
    b[k++] = ')'; b[k++] = '\n'; b[k] = 0;
    klog(b);
}
/* called from the deferred-syscall thunk tail to log the (possibly blocking) return */
void strace_ret(uint32_t num, long r)
{
    proc_t *p = cur_proc();
    if (!p || !p->strace) return;
    char b[64]; int k = 0; for (const char *t = "strace  = "; *t; t++) b[k++] = *t;
    const char *nm = strace_name(num);
    if (nm) { for (const char *t = nm; *t; t++) b[k++] = *t; } else { strace_hex(b, &k, num); }
    b[k++] = ' '; if (r < 0) { b[k++] = '-'; strace_hex(b, &k, (uint32_t)(-r)); } else strace_hex(b, &k, (uint32_t)r);
    b[k++] = '\n'; b[k] = 0; klog(b);
}

/* ---- real signal delivery -------------------------------------------------
 * deliver_signals() takes a normalized snapshot of the interrupted user context
 * (r[0..15], *cpsr), and if a deliverable signal is pending with a real handler,
 * pushes an xt_sigframe on the user stack and re-points r[]/cpsr to enter the
 * handler; the caller writes the modified r[]/cpsr back to its return frame. The
 * hidden userland trampoline (sa.restorer) runs the handler then SYS_sigreturn,
 * which restores the saved frame. Called at BOTH the syscall-return path (sync +
 * EINTR) and the timer-tick return (async). */
static int deliver_signals(proc_t *p, uint32_t r[16], uint32_t *cpsr, int syscall_ret)
{
    if (!p) return 0;
    uint32_t deliverable = p->sig_pending & ~p->sig_blocked;
    if (!deliverable) return 0;
    int sig = __builtin_ctz(deliverable);
    struct xt_sigaction *sa = &p->sigact[sig];
    if (sa->handler == XT_SIG_DFL || sa->handler == XT_SIG_IGN || !sa->restorer)
        { p->sig_pending &= ~(1u << sig); return 0; }   /* no catchable handler here */
    p->sig_pending &= ~(1u << sig);
    uint32_t sp = (r[13] - (uint32_t)sizeof(struct xt_sigframe)) & ~7u;
    struct xt_sigframe *f = (struct xt_sigframe *)(uintptr_t)sp;
    for (int i = 0; i < 15; i++) f->r[i] = r[i];
    /* SA_RESTART: if this delivery interrupts a blocking syscall that made no
     * progress (its saved r0 == -EINTR marker), restore XT_ERESTARTSYS instead so
     * userland __syscall re-issues the svc once the handler returns (POSIX restart).
     * Only on the deferred syscall-return path (syscall_ret); async/tick delivery of
     * a CPU-bound loop has a real r0 we must never touch. */
    if (syscall_ret && (sa->flags & XT_SA_RESTART) && f->r[0] == (uint32_t)-4)
        f->r[0] = (uint32_t)XT_ERESTARTSYS;
    f->pc = r[15]; f->cpsr = *cpsr; f->signo = (uint32_t)sig; f->saved_mask = p->sig_blocked;
    p->sig_blocked |= sa->mask;
    if (!(sa->flags & XT_SA_NODEFER)) p->sig_blocked |= (1u << sig);
    r[0] = (uint32_t)sig; r[13] = sp; r[14] = (uint32_t)sa->restorer; r[15] = (uint32_t)sa->handler;
    *cpsr &= ~0x20u;                                     /* ARM state for the handler */
    return 1;
}

/* SVC-mode helpers: read/write the banked User/System sp+lr. Safe only from a
 * PL1 exception mode (SVC/IRQ) whose banked sp differs from the user's. */
static inline void rd_usr_sp_lr(uint32_t *sp, uint32_t *lr)
{ __asm__ volatile("cps #0x1f\n\tmov %0, sp\n\tmov %1, lr\n\tcps #0x13" : "=r"(*sp), "=r"(*lr) :: "memory"); }
static inline void wr_usr_sp_lr(uint32_t sp, uint32_t lr)
{ __asm__ volatile("cps #0x1f\n\tmov sp, %0\n\tmov lr, %1\n\tcps #0x13" :: "r"(sp), "r"(lr) : "memory"); }

/* inline syscall-return delivery: context = regs (r0..r12, lr=PC) + banked sp/lr + SPSR */
static void deliver_inline(proc_t *p, struct k_regs *regs)
{
    uint32_t r[16], cpsr;
    for (int i = 0; i < 13; i++) r[i] = regs->r[i];
    r[15] = regs->lr;
    rd_usr_sp_lr(&r[13], &r[14]);
    __asm__ volatile("mrs %0, spsr" : "=r"(cpsr));
    if (deliver_signals(p, r, &cpsr, 0)) {             /* sync return: not a blocked-syscall restart */
        for (int i = 0; i < 13; i++) regs->r[i] = r[i];
        regs->lr = r[15];
        wr_usr_sp_lr(r[13], r[14]);
        __asm__ volatile("msr spsr_cxsf, %0" :: "r"(cpsr));
    }
}

/* deferred (blocking) syscall-return delivery: context lives in p->dctx. dctx[0]
 * must already hold the syscall result (the frame saves it as r0 for sigreturn). */
void deliver_deferred(proc_t *p)
{
    uint32_t r[16], cpsr;
    for (int i = 0; i < 13; i++) r[i] = p->dctx[i];
    r[13] = p->dctx[14]; r[14] = p->dctx[16]; r[15] = p->dctx[13]; cpsr = p->dctx[15];
    if (deliver_signals(p, r, &cpsr, 1)) {             /* blocked-syscall return: eligible for SA_RESTART */
        for (int i = 0; i < 13; i++) p->dctx[i] = r[i];
        p->dctx[13] = r[15]; p->dctx[14] = r[13]; p->dctx[16] = r[14]; p->dctx[15] = cpsr;
    }
}

/* async delivery (task #9): called from portRESTORE_CONTEXT for the task about to
 * resume. If it's a PL0 proc with a pending deliverable signal, capture its full
 * interrupted context (from the portSAVE_CONTEXT frame) into async_ctx and redirect
 * its resume PC to the userland __sig_trap stub, which traps into SYS_sig_async to
 * run the handler. This is what delivers a signal into a pure CPU-bound loop that
 * never makes a syscall. Safe no-op for kernel tasks / nothing pending / non-PL0.
 * Frame layout (portASM.S portSAVE/RESTORE_CONTEXT): [FPUflag][opt FPU 65w]
 * [nesting][r0-r12,r14][PC][CPSR]. */
void xt_sig_async_hook(uint32_t *sp)
{
    proc_t *p = cur_proc();
    if (!p || !p->sig_trap) return;
    if (!(p->sig_pending & ~p->sig_blocked)) return;
    uint32_t off = 1;                        /* FPU flag word */
    if (sp[0]) off += 65;                    /* FPSCR(1) + D16-31(32) + D0-15(32) */
    off += 1;                                /* critical nesting */
    uint32_t *rg = &sp[off];                 /* r0..r12 (13), then r14 */
    uint32_t cpsr = sp[off + 15];
    if ((cpsr & 0x1f) != 0x10) return;       /* not User(PL0) mode -> leave it */
    uint32_t fwords = off + 16;              /* whole frame size (words), through CPSR */
    for (int i = 0; i < 13; i++) p->async_ctx[i] = rg[i];
    p->async_ctx[13] = (uint32_t)(uintptr_t)(sp + fwords);  /* r13/sp (implicit in the frame) */
    p->async_ctx[14] = rg[13];               /* r14 */
    p->async_ctx[15] = sp[off + 14];         /* r15/PC */
    p->async_cpsr = cpsr;
    sp[off + 14] = p->sig_trap;              /* resume at __sig_trap instead of the real PC */
}

/* SYS_sigreturn (inline): restore the interrupted context from the frame the
 * trampoline hands us; the normal .Lsyscall `movs pc, lr` resumes it. */
static void do_sigreturn(proc_t *p, struct k_regs *regs, long frameptr)
{
    const struct xt_sigframe *f = (const struct xt_sigframe *)(uintptr_t)frameptr;
    for (int i = 0; i < 13; i++) regs->r[i] = f->r[i];
    regs->lr = f->pc;
    wr_usr_sp_lr(f->r[13], f->r[14]);
    __asm__ volatile("msr spsr_cxsf, %0" :: "r"(f->cpsr));
    if (p) p->sig_blocked = f->saved_mask;
}

int k_syscall_dispatch(struct k_regs *regs)
{
    uint32_t insn = *((volatile uint32_t *)(regs->lr - 4));
    if ((insn & 0x00ffffff) != 1) { regs->r[0] = (uint32_t)-1; return 0; }

    uint32_t num = regs->r[7];
    { proc_t *tp = cur_proc();
      if (tp && tp->strace) strace_log(tp->pid, "sys", num, regs->r[0], regs->r[1], regs->r[2]); }
    /* SYS_kill: a marked process dies at its next syscall, whatever it was */
    {
        proc_t *kp = cur_proc();
        if (kp && kp->killed && num != SYS_exit) {
            kp->exit_code = 137;                           /* 128 + SIGKILL */
            regs->lr = (uint32_t)(uintptr_t)task_exit_thunk;
            return 1;
        }
        /* stopped (^Z / SIGSTOP): force the syscall through the deferral so it
         * parks in task context (stop_park at the thunk's top), then runs the
         * syscall normally after SIGCONT */
        if (kp && kp->stopped && num != SYS_exit)
            return defer_syscall(regs, num);
    }
    if (num == SYS_exit) {
        proc_t *p = cur_proc();
        if (p) p->exit_code = (int)regs->r[0];
        regs->lr = (uint32_t)(uintptr_t)task_exit_thunk;   /* resume the thunk (at PL1) */
        return 1;
    }
    if (num == SYS_sigreturn) {                            /* restore the interrupted context */
        do_sigreturn(cur_proc(), regs, (long)regs->r[0]);
        return 0;
    }
    if (num == SYS_sig_async) {                            /* deliver from the captured PL0 ctx */
        proc_t *p = cur_proc();
        if (p) {
            uint32_t r[16], cpsr;
            for (int i = 0; i < 16; i++) r[i] = p->async_ctx[i];
            cpsr = p->async_cpsr;
            deliver_signals(p, r, &cpsr, 0);               /* -> handler, or unchanged = resume as-is */
            for (int i = 0; i < 13; i++) regs->r[i] = r[i];
            regs->lr = r[15];
            wr_usr_sp_lr(r[13], r[14]);
            __asm__ volatile("msr spsr_cxsf, %0" :: "r"(cpsr));
        }
        return 0;
    }
    if (needs_task_ctx(regs, num)) return defer_syscall(regs, num);   /* run in task ctx */
    regs->r[0] = (uint32_t)do_syscall(num, regs->r[0], regs->r[1], regs->r[2]);
    { proc_t *tp = cur_proc();
      if (tp && tp->strace) strace_ret(num, (long)(int)regs->r[0]); }
    /* deliver a pending signal on the way back to PL0 (sync path) */
    { proc_t *dp = cur_proc();
      if (dp && (dp->sig_pending & ~dp->sig_blocked)) deliver_inline(dp, regs); }
    return 0;
}

/* task body: run constructors (PL1), then drop to USER mode (PL0) and run the
 * program entry. Init runs PER PROCESS (classic exec semantics): the image is
 * shared/loaded once, but each instance's .init_array writes land in its own COW
 * copy. enter_user_and_run never returns — when entry returns (or calls exit) it
 * traps back via svc SYS_exit, which deletes the task (at PL1, see xt_vectors.S). */
static void app_main(void *arg)
{
    proc_t *p = (proc_t *)arg;
    extern void enter_user_and_run(void (*)(int, char **), int, char **);
    xtld_run_init(p->obj);
    enter_user_and_run((void (*)(int, char **))p->entry, p->argc, p->argv);
}

/* copy argv (pointer array + strings) into `buf` — which must be PL0-readable, so
 * the program can read its own args at PL0. We use the top of the task's stack
 * (stackguard arena, PL0-RW). Returns the argv array (= buf) or NULL (argc<=0 or
 * doesn't fit). The caller's argv (the shell's line buffer) is read at PL1. */
static char **copy_argv(int argc, char **argv, void *buf, uint32_t bufsz)
{
    if (argc <= 0 || !argv) return NULL;
    uint32_t need = (uint32_t)(argc + 1) * sizeof(char *);
    for (int i = 0; i < argc; i++) need += (uint32_t)strlen(argv[i]) + 1;
    if (need > bufsz) return NULL;
    char **out = (char **)buf;
    char *str = (char *)buf + (uint32_t)(argc + 1) * sizeof(char *);
    for (int i = 0; i < argc; i++) {
        out[i] = str;
        uint32_t n = (uint32_t)strlen(argv[i]) + 1;
        memcpy(str, argv[i], n);
        str += n;
    }
    out[argc] = NULL;
    return out;
}

/* ---- program cache: load an image ONCE, share it across spawns ------------
 * The same program spawned N times keeps ONE relocated copy. Its text/rodata/GOT
 * are shared READ-ONLY (W^X, one physical copy — "mmap-exec"); each instance gets
 * its own data/bss via copy-on-write from the post-init pristine image. */
#ifndef MAXPROG
#define MAXPROG 32             /* distinct cached images. > MAXPROC so an idle image is
                                * always evictable; overridable (-DMAXPROG=N) for tests. */
#endif
typedef struct {
    const uint8_t *image;     /* romfs bytes = cache key */
    xtld_obj      *obj;
    uintptr_t      entry;
    uintptr_t      wva;       /* writable (data/bss) seg — COW per-process */
    uint32_t       wsize;
    uint32_t       lru;       /* last-use tick (for eviction) */
} prog_t;
static prog_t   g_prog[MAXPROG];
static int      g_prog_n;
static uint32_t g_prog_loads;            /* distinct images actually loaded (vs spawns) */
static uint32_t g_prog_tick;             /* monotonic use counter */
static uint32_t g_prog_evicts;           /* images evicted (diagnostics) */
uint32_t frtos_prog_loads(void) { return g_prog_loads; }
uint32_t frtos_prog_evicts(void) { return g_prog_evicts; }

/* Give every shared LIBRARY per-process data: register its writable (data/bss)
 * range for copy-on-write. A library's data is never written by the kernel, so the
 * COW source is the library image itself (identity — it stays pristine after its
 * one-time load-init). libc is the exception: the kernel mutates its malloc arena,
 * so libc COWs from a boot snapshot (vm_set_libc) instead — skip it here. Programs
 * have no soname (their data is the per-space program range, not a global one).
 * REBUILT from the live object list each call (after any load or unload), so a
 * library freed by an eviction stops being a COW range. */
static void register_lib_cow(void)
{
    vm_cow_reset_dynamic();                  /* keep synthetic+libc, drop the library ranges */
    int n = xtld_object_count();
    for (int i = 0; i < n; i++) {
        xtld_obj *o = xtld_object_at(i);
        if (!o || o == g_libc_obj || !xtld_soname(o)) continue;   /* libc / program -> skip */
        uintptr_t wva; uint32_t wsz;
        xtld_writable_range(o, &wva, &wsz);
        if (wva && wsz) vm_cow_register((uint32_t)wva, wsz, (uint32_t)wva);  /* identity src */
    }
}

/* is this cached image backing a live process? (don't evict one that's running) */
static int prog_in_use(const prog_t *pr)
{
    for (int i = 0; i < MAXPROC; i++)
        if (g_proc[i].used && g_proc[i].obj == pr->obj) return 1;
    return 0;
}

/* Evict the least-recently-used IDLE cached image to make room. xtld_unload runs
 * its destructors and releases its DT_NEEDED libraries (a library freed when its
 * last dependent goes); mmu_unprotect restores the freed image's pages to identity
 * RWX so the RAM is safe to reuse; register_lib_cow drops any now-freed library's
 * COW range. Returns 1 if an image was evicted. */
static int prog_evict(void)
{
    int victim = -1; uint32_t best = 0xFFFFFFFFu;
    for (int i = 0; i < g_prog_n; i++)
        if (!prog_in_use(&g_prog[i]) && g_prog[i].lru < best) { best = g_prog[i].lru; victim = i; }
    if (victim < 0) return 0;                /* every cached image is live (needs MAXPROG>MAXPROC) */

    extern void mmu_unprotect(uint32_t, uint32_t);
    xtld_obj *obj = g_prog[victim].obj;
    mmu_unprotect((uint32_t)xtld_image_base(obj), (uint32_t)xtld_span(obj));
    xtld_unload(obj);                        /* fini + transitive dep release + free image */
    g_prog[victim] = g_prog[--g_prog_n];     /* compact the cache */
    register_lib_cow();                      /* a transitively-freed library must leave the COW set */
    g_prog_evicts++;
    return 1;
}

static prog_t *prog_get(const uint8_t *image, uint32_t len, const xtld_host *host)
{
    for (int i = 0; i < g_prog_n; i++)
        if (g_prog[i].image == image) { g_prog[i].lru = ++g_prog_tick; return &g_prog[i]; }
    if (g_prog_n >= MAXPROG && !prog_evict()) return NULL;   /* full + nothing evictable */

    xtld_obj *obj = NULL; char err[64] = {0};
    int rc = xtld_load(image, len, host, &obj, err, sizeof err);
    if (rc != XTLD_OK) {
        if (g_console) { g_console("  xtld_load err: ", 17); g_console(err, (int)strlen(err));
            const char *s = xtld_strerror(rc); g_console(" rc=", 4); g_console(s, (int)strlen(s)); g_console("\n", 1); }
        return NULL;
    }
    uintptr_t entry = xtld_sym(obj, "_app_entry");   /* C/asm programs */
    if (!entry) entry = xtld_sym(obj, "main");        /* xtc / plain main(argc,argv) */
    if (!entry) return NULL;

    register_lib_cow();   /* this load may have pulled in new shared libs -> COW their data */

    /* W^X + PL0 protection was applied by frtos_on_loaded (the xtld on_loaded hook)
     * as the image was relocated: text RO+X (PL0-RX), writable seg RW+XN (PL0-none
     * in the master; the owner gets PL0-RW per-process via COW). Constructors run
     * PER PROCESS in app_main, so the cached image's data stays the pristine COW
     * template. */
    { uintptr_t wva; uint32_t wsz; xtld_writable_range(obj, &wva, &wsz);
      prog_t *pr = &g_prog[g_prog_n++];
      pr->image = image; pr->obj = obj; pr->entry = entry; pr->wva = wva; pr->wsize = wsz;
      pr->lru = ++g_prog_tick;
      g_prog_loads++;
      return pr;
    }
}

/* common tail: give slot `slot` a private address space for `obj` and start its
 * task. Shared by frtos_spawn (cached romfs programs) and frtos_spawn_host
 * (transient host-loaded ELFs). */
#define ARGV_WORDS 256   /* reserved at the top of the task stack for argv (PL0-RW) */
static int proc_launch(int slot, xtld_obj *obj, uintptr_t entry,
                       uint32_t wva, uint32_t wsz, int argc, char **argv,
                       char **envp, const int *stdfds)
{
    proc_t *p = &g_proc[slot];
    for (int i = 0; i < NFD; i++) { p->fd[i].open = 0; p->fd[i].pipei = 0; }
    /* SYS_spawn_fd: wire the child's stdio to the spawner's pipe ends, and
     * inherit the spawner's OTHER pipe fds at the same slots unless masked
     * out (stdfds[3] = do-not-inherit bitmask — the cloexec analogue; the
     * subshell-state fd relies on surviving exec). Copies share the pipe
     * object; each end is refcounted so EOF tracks every holder. */
    if (stdfds) {
        proc_t *par = cur_proc();
        unsigned nomask = (unsigned)stdfds[3];
        for (int i = 0; par && i < NFD; i++) {
            /* stdio: explicit parent fd, or -1 = inherit the parent's CURRENT
             * slot i (a shell that redirected its own stdin passes that on —
             * exec semantics); others: same-slot inherit unless masked out */
            int pfd = (i < 3) ? (stdfds[i] >= 0 ? stdfds[i] : i)
                              : ((nomask & (1u << i)) ? -1 : i);
            if (pfd >= 0 && pfd < NFD && par->fd[pfd].open && par->fd[pfd].pipei) {
                kpipe_t *pp = &g_pipes[par->fd[pfd].pipei - 1];
                p->fd[i] = par->fd[pfd];
                taskENTER_CRITICAL();
                if (p->fd[i].pwrite) pp->writers++; else pp->readers++;
                taskEXIT_CRITICAL();
            } else if (i < 3 && pfd >= 0 && pfd < NFD && par->fd[pfd].open &&
                       !par->fd[pfd].con && par->fd[pfd].vf.chr) {
                /* char device (pty slave, /dev/*): COPY, don't move — an SSH pty child
                 * dup2's the SAME slave onto 0/1/2, so several child slots must point at
                 * it (a char device has no page cache to race, unlike a FIL). Notify the
                 * driver of the extra reference so its open count (pty EOF tracking) stays
                 * right. The parent keeps its copy and closes it after the spawn. */
                p->fd[i] = par->fd[pfd];
                if (p->fd[i].vf.ondup) p->fd[i].vf.ondup(&p->fd[i].vf);
            } else if (i < 3 && pfd >= 0 && pfd < NFD && par->fd[pfd].open &&
                       !par->fd[pfd].con) {
                /* file-redirected stdio (`cmd > file`): MOVE the descriptor —
                 * FIL, cursor and cache page travel with it. Two live handles
                 * would race at close (FatFs rewrites the dir entry from each
                 * FIL's view; the parent's stale post-truncate state closing
                 * last wiped the child's output). The parent's restore step
                 * only re-points its stdio at the console anyway. */
                p->fd[i] = par->fd[pfd];
                memset(&par->fd[pfd], 0, sizeof(fd_t));
            }
            /* console / console-alias / closed sources all mean: leave the
             * child's slot closed (stdio falls back to the console) */
        }
    }
    p->obj = obj; p->entry = entry; p->exit_code = 0; p->exited = 0; p->waited = 0; p->waiter = 0; p->pid = g_next_pid++;
    /* init's identity is claimed HERE, at pid assignment — not by the caller once spawn
     * returns. The child task is created below at a priority that preempts shell_task, so
     * it can run to its first syscall BEFORE frtos_spawn_argv returns: an init that told
     * the kernel "boot scripts done" in that window was refused (g_init_pid still 0), and
     * the console waited for a signal that had already been sent and thrown away. */
    if (g_claim_init) { g_claim_init = 0; g_init_pid = p->pid; }
    p->killed = 0;                       /* slot reuse must not inherit a SYS_kill */
    p->stopped = 0;                      /* ...nor a SIGSTOP */
    p->sig_pending = 0; p->sig_blocked = 0; p->sig_trap = 0;   /* exec resets signal state */
    for (int si = 0; si < XT_NSIG; si++) { p->sigact[si].handler = XT_SIG_DFL; p->sigact[si].mask = 0; p->sigact[si].flags = 0; p->sigact[si].restorer = 0; p->sigact[si].trap = 0; }
    /* inherit the spawner's cwd (a shell's children run where the shell is);
     * a spawn from kernel context starts at the root */
    proc_t *parent = cur_proc();
    p->ppid = (parent && parent != p) ? parent->pid : 0;   /* for SIGCHLD-on-exit */
    if (parent && parent != p) {
        int i = 0;
        while (parent->cwd[i] && i < (int)sizeof p->cwd - 1) { p->cwd[i] = parent->cwd[i]; i++; }
        p->cwd[i] = 0;
        if (!p->cwd[0]) { p->cwd[0] = '/'; p->cwd[1] = 0; }
    } else { p->cwd[0] = '/'; p->cwd[1] = 0; }
    /* an explicit spawn-spec cwd (xt_spawn_aux.cwd, offset 20 = word 5) overrides
     * inheritance: a vfork-window chdir records the child's intended cwd there
     * instead of moving the PARENT. NULL = inherit (above). */
    if (stdfds) {
        const char *scwd = *(const char *const *)((const int *)stdfds + 5);
        if (scwd) { int i = 0; while (scwd[i] && i < (int)sizeof p->cwd - 1) { p->cwd[i] = scwd[i]; i++; } p->cwd[i] = 0; }
    }
    p->done = xSemaphoreCreateBinary();
    if (!p->done) return -1;
    /* T2-b/c: private address space — demand heap + COW(libc data, synthetic, and
     * this program's own data/bss at its identity load VA). */
    p->l1 = vm_space_create(slot, wva, wsz, wva);
    p->asid = (uint32_t)slot + 1u;
    p->heap_brk = XTOS_HEAP_VA; p->heap_end = XTOS_HEAP_VA + XTOS_HEAP_SIZE;    /* private heap */
    p->used = 1;
    p->xtos_cursor = g_xtos_seq;                            /* start fresh: no historical XTOS events */
    note_proc_hwm();                                        /* /OS/proc/limits peak */
    /* name the task after the program (basename of argv[0]) so fault reports and
     * task listings identify it — FreeRTOS copies the name into the TCB. */
    const char *nm = (argc > 0 && argv && argv[0]) ? argv[0] : "app";
    for (const char *q = nm; *q; q++) if (*q == '/') nm = q + 1;
    /* strace: trace this proc if a parent is traced (children inherit -> `strace
     * sshd` covers sshd-session + the shell) or its basename matches g_strace_name. */
    { proc_t *par = cur_proc(); p->strace = (par && par->strace) ? 1 : 0; }
    if (!p->strace && g_strace_name) {
        for (const char *a = nm; *a; a++) { const char *x = a, *y = g_strace_name;
            while (*x && *y && *x == *y) { x++; y++; } if (!*y) { p->strace = 1; break; } } }
    extern StackType_t *stackguard_stack(int, uint32_t *);
    uint32_t depth; StackType_t *stk = stackguard_stack(slot, &depth);
    /* carve argv out of the TOP of the task stack (PL0-RW) so the program can read
     * its args at PL0; the rest of the stack stays the FreeRTOS-managed region. */
    p->argc = argc;
    if (argc > 0) { depth -= ARGV_WORDS;
        p->argv = copy_argv(argc, argv, stk + depth, ARGV_WORDS * sizeof(StackType_t)); }
    else p->argv = NULL;
    /* copy the inherited environment into another PL0-RW stack slab so the child
     * reads it at PL0 (SYS_envp); the shim seeds `environ` from it at load. */
    p->envp = NULL;
    if (envp && envp[0]) {
        int envc = 0; while (envp[envc]) envc++;
        depth -= ARGV_WORDS;
        p->envp = copy_argv(envc, envp, stk + depth, ARGV_WORDS * sizeof(StackType_t));
    }
    /* xTaskCreateStatic returns the handle (unlike xTaskCreate's out-param), and
     * the new task is higher priority than us — it would run (and look itself up via
     * cur_proc) BEFORE p->task is assigned. Suspend the scheduler so the assignment
     * lands first. */
    vTaskSuspendAll();
    p->task = xTaskCreateStatic(app_main, nm, depth, p, 3, stk, &p->tcb);
    xTaskResumeAll();
    if (!p->task) { vSemaphoreDelete(p->done); p->used = 0; return -1; }
    return p->pid;
}

static void reap_orphans(void);

/* procfs snapshot: fill slot idx's identity (best-effort — the table can
 * mutate underneath; /OS/proc content is a moment-in-time view anyway).
 * Returns the pid, or 0 if the slot is free. */
int frtos_proc_snap(int idx, char *comm, int commsz, char *cmdl, int cmdsz,
                    int *cmdlen, int *state)
{
    if (idx < 0 || idx >= MAXPROC || !g_proc[idx].used) return 0;
    proc_t *p = &g_proc[idx];
    int pid = p->pid;
    const char *nm = (p->argc > 0 && p->argv && p->argv[0]) ? p->argv[0] : "?";
    for (const char *q = nm; *q; q++) if (*q == '/') nm = q + 1;   /* basename */
    int i = 0;
    while (nm[i] && i < commsz - 1) { comm[i] = nm[i]; i++; }
    comm[i] = 0;
    int c = 0;
    for (int a = 0; a < p->argc && p->argv && c < cmdsz - 1; a++) {
        const char *s = p->argv[a];
        while (s && *s && c < cmdsz - 1) cmdl[c++] = *s++;
        if (c < cmdsz - 1) cmdl[c++] = 0;                          /* NUL-joined */
    }
    if (state) *state = p->exited ? 'Z' : (p->stopped ? 'T' : 'S');
    if (cmdsz > 0 && c == 0) cmdl[c++] = 0;
    if (cmdlen) *cmdlen = c;
    return pid ? pid : -1;
}

/* /OS/proc/limits: current use of each fixed-size kernel pool. Current counts are
 * scanned live (no accounting to drift); hwm is the peak the claim sites recorded. */
void frtos_limits(xt_limits_t *L)
{
    int fdc = 0, busiest = 0;
    for (int i = 0; i < MAXPROC; i++) {
        if (!g_proc[i].used) continue;
        int n = 0;                                        /* explicitly-allocated slots: any
                                                           * occupancy marker (stdio 0/1/2 route
                                                           * to the console implicitly, unmarked) */
        for (int f = 0; f < NFD; f++) {
            fd_t *fd = &g_proc[i].fd[f];
            if (fd->open || fd->pipei || fd->sock || fd->con) n++;
        }
        fdc += n;
        if (n > busiest) busiest = n;
    }
    int pc = proc_live(), pp = pipe_live();
    if (pc > g_proc_hwm) g_proc_hwm = pc;                  /* also catch a read-time peak */
    if (pp > g_pipe_hwm) g_pipe_hwm = pp;
    L->proc_cur = pc;  L->proc_max = MAXPROC;  L->proc_hwm = g_proc_hwm;
    L->pipe_cur = pp;  L->pipe_max = MAXPIPE;  L->pipe_hwm = g_pipe_hwm;
    L->prog_cur = g_prog_n; L->prog_max = MAXPROG;
    L->fd_cur = fdc;   L->fd_cap = NFD;         L->fd_busiest = busiest;
}

/* Atomically claim a free proc slot: mark it used + running (exited/waited/reaping
 * cleared) so a concurrent reap_orphans/spawn can't grab or reap it mid-setup. The
 * spawn fills the rest; proc_launch clears the slot again on failure. Returns -1 if
 * the table is full. */
static int alloc_slot(void)
{
    int slot = -1;
    taskENTER_CRITICAL();
    for (int i = 0; i < MAXPROC; i++)
        if (!g_proc[i].used) {
            g_proc[i].used = 1; g_proc[i].exited = 0; g_proc[i].waited = 0; g_proc[i].reaping = 0;
            g_proc[i].xtos_cursor = g_xtos_seq;             /* start fresh: no historical XTOS events */
            slot = i; break;
        }
    taskEXIT_CRITICAL();
    if (slot >= 0) note_proc_hwm();                        /* /OS/proc/limits peak */
    return slot;
}

static int frtos_spawn_fds(const uint8_t *image, uint32_t len, int argc, char **argv,
                           char **envp, const xtld_host *host, const int *stdfds)
{
    reap_orphans();                              /* clean up exited '&'/orphan children first */
    int slot = alloc_slot();
    if (slot < 0) return -1;

    prog_t *prog = prog_get(image, len, host);    /* load-once (shared text + COW data) */
    if (!prog) { g_proc[slot].used = 0; return -1; }
    g_proc[slot].transient = 0; g_proc[slot].src = 0;
    return proc_launch(slot, prog->obj, prog->entry, (uint32_t)prog->wva, prog->wsize, argc, argv, envp, stdfds);
}

int frtos_spawn(const uint8_t *image, uint32_t len, int argc, char **argv,
                const xtld_host *host)
{
    return frtos_spawn_fds(image, len, argc, argv, NULL, host, 0);
}

/* Load + run an ELF read from the HOST filesystem over semihosting (runhost) — for
 * a test harness that drops many libc-linked binaries in a host folder without
 * rebuilding the romfs. NOT cached: loaded fresh, and unloaded + the buffer freed
 * when the process is reaped (frtos_waitpid), so 300 runs don't accumulate.
 * DT_NEEDED libs (libc.so/libm/libGEM) still resolve from the embedded romfs. */
int frtos_spawn_host(const char *hostpath, int argc, char **argv, const xtld_host *host)
{
    long h = hostfs_open(hostpath);
    if (h < 0) { if (g_console) { g_console("runhost: cannot open ", 21);
        g_console(hostpath, (int)strlen(hostpath)); g_console("\n", 1); } return -1; }
    long len = hostfs_len(h);
    if (len <= 0) { hostfs_close(h); return -1; }
    uint8_t *buf = host->alloc((size_t)len, 16, host->user);
    if (!buf) { hostfs_close(h); return -1; }
    long got = hostfs_read(h, buf, len);
    hostfs_close(h);
    if (got != len) { host->dealloc(buf, host->user); return -1; }

    reap_orphans();                              /* clean up exited '&'/orphan children first */
    int slot = alloc_slot();
    if (slot < 0) { host->dealloc(buf, host->user); return -1; }

    xtld_obj *obj = NULL; char err[64] = {0};
    int rc = xtld_load(buf, (size_t)len, host, &obj, err, sizeof err);
    if (rc != XTLD_OK) {
        if (g_console) { g_console("  xtld_load err: ", 17); g_console(err, (int)strlen(err));
            const char *s = xtld_strerror(rc); g_console(" rc=", 4); g_console(s, (int)strlen(s)); g_console("\n", 1); }
        host->dealloc(buf, host->user); return -1;
    }
    uintptr_t entry = xtld_sym(obj, "_app_entry");
    if (!entry) entry = xtld_sym(obj, "main");
    if (!entry) { xtld_unload(obj); host->dealloc(buf, host->user); return -1; }
    register_lib_cow();                          /* may have pulled in new shared libs */
    /* W^X + PL0 protection already applied by frtos_on_loaded (xtld on_loaded hook). */
    uintptr_t wva; uint32_t wsz; xtld_writable_range(obj, &wva, &wsz);

    g_proc[slot].transient = 1; g_proc[slot].src = buf;
    int pid = proc_launch(slot, obj, entry, (uint32_t)wva, wsz, argc, argv, NULL, 0);
    if (pid < 0) {                               /* launch failed: undo the load */
        extern void mmu_unprotect(uint32_t, uint32_t);
        mmu_unprotect((uint32_t)xtld_image_base(obj), (uint32_t)xtld_span(obj));
        xtld_unload(obj); register_lib_cow(); host->dealloc(buf, host->user);
    }
    return pid;
}

int frtos_spawn_path(const char *path, const xtld_host *host)
{
    return frtos_spawn_argv(path, 0, NULL, host);
}

static int has_prefix(const char *s, const char *p) { while (*p) if (*s++ != *p++) return 0; return 1; }

/* SD program images, cached by path: a program that misses the romfs is read
 * whole off the card (KFS_READFILE resolves symlinks — the /OS/bin applet links
 * point at one toybox) into the kernel heap ONCE and kept — the heap is a bump
 * allocator (no free) and xtld copies segments at load, so one resident image
 * serves every subsequent spawn. A binary updated on the card is picked up at
 * the next boot. */
#define SDPROG_MAX 24
static struct { char path[64]; const uint8_t *data; uint32_t len; } g_sdprog[SDPROG_MAX];
static int g_nsdprog;

static int sd_prog_lookup(const char *path, const uint8_t **data, uint32_t *len)
{
    for (int i = 0; i < g_nsdprog; i++) {
        const char *a = g_sdprog[i].path, *b = path;
        while (*a && *a == *b) { a++; b++; }
        if (*a == 0 && *b == 0) { *data = g_sdprog[i].data; *len = g_sdprog[i].len; return 1; }
    }
    void *buf = 0;
    long sz = kfs_call(KFS_READFILE, path, 0, 0, &buf);
    if (sz <= 0 || !buf) return 0;                     /* not on the SD (or no SD) */
    if (g_nsdprog < SDPROG_MAX) {
        int i = 0;
        for (; path[i] && i < 63; i++) g_sdprog[g_nsdprog].path[i] = path[i];
        g_sdprog[g_nsdprog].path[i] = 0;
        g_sdprog[g_nsdprog].data = (const uint8_t *)buf;
        g_sdprog[g_nsdprog].len  = (uint32_t)sz;
        g_nsdprog++;
    }
    *data = (const uint8_t *)buf; *len = (uint32_t)sz;
    return 1;
}

int frtos_spawn_argv_fds(const char *path, int argc, char **argv,
                         char **envp, const xtld_host *host, const int *stdfds)
{
    const uint8_t *data; uint32_t size;
    /* search order: the romfs (mounted at /System; accept /System/bin/x for the
     * romfs-internal /bin/x), then the SD by full path (/OS/bin/x), then the
     * /bin/x -> /OS/bin/x convention (a #!/bin/sh shebang finds the SD toysh
     * when the romfs carries no shell). System programs win so a stray .so on
     * the card can't shadow them. */
    if (!romfs_lookup(path, &data, &size) &&
        !(has_prefix(path, "/System/") && romfs_lookup(path + 7, &data, &size)) &&
        !sd_prog_lookup(path, &data, &size)) {
        char alt[64];
        if (!has_prefix(path, "/bin/")) return -1;
        int i = 0;
        const char *pfx = "/OS";
        while (pfx[i]) { alt[i] = pfx[i]; i++; }
        for (int j = 0; path[j] && i < 63; j++) alt[i++] = path[j];
        alt[i] = 0;
        if (!sd_prog_lookup(alt, &data, &size)) return -1;
    }
    return frtos_spawn_fds(data, size, argc, argv, envp, host, stdfds);
}

int frtos_spawn_argv(const char *path, int argc, char **argv, const xtld_host *host)
{
    return frtos_spawn_argv_fds(path, argc, argv, NULL, host, 0);
}

/* g_khost (declared above do_syscall) is the kernel loader host — set by main once
 * built, so SYS_spawn from PL0 launches programs with the same host (libc/libgcc/...). */
void frtos_set_host(const xtld_host *h) { g_khost = h; }

/* xtld_host.resolve: the BOUNDED kernel export table loaded modules resolve
 * against — syscall primitives (for libc.so), libgcc runtime helpers (the A9 has
 * no HW divide), and the kernel's own bare_libc mem/str fns (for the
 * inline-syscall test programs that do not yet DT_NEEDED libc.so). It does NOT
 * grow per-library: libGEM and programs get libc from libc.so, not here. */
#define K(sym) extern void sym(void);
/* _sbrk is now an svc stub in syscalls.c (its impl is sys_sbrk, behind SYS_sbrk) */
K(_sbrk)
K(_write) K(_read) K(_exit) K(_close) K(_lseek) K(_fstat) K(_isatty)
K(_open) K(_stat) K(_kill) K(_getpid) K(_gettimeofday) K(_times) K(_link)
K(_unlink) K(_fork) K(_execve) K(_fcntl) K(_getentropy) K(_getrandom) K(_mkdir)
K(_init) K(_fini) K(_jp2uc_l) K(_uc2jp_l) K(_wait)
extern int regcomp(void*,const void*,int); extern int regexec(const void*,const void*,unsigned,void*,int);
extern void regfree(void*); extern int sigprocmask(int,const void*,void*);
K(__aeabi_idiv) K(__aeabi_uidiv) K(__aeabi_idivmod) K(__aeabi_uidivmod)
K(__aeabi_ldivmod) K(__aeabi_uldivmod) K(__aeabi_d2lz) K(__aeabi_l2d)
K(__aeabi_unwind_cpp_pr0) K(__ffsdi2) K(__aeabi_f2lz) K(__muldc3) K(__mulsc3)
/* soft-double/float runtime — Lua (lua_Number = double) leans on these heavily */
K(__aeabi_dadd) K(__aeabi_dsub) K(__aeabi_dmul) K(__aeabi_ddiv) K(__aeabi_dneg)
K(__aeabi_dcmpeq) K(__aeabi_dcmplt) K(__aeabi_dcmple) K(__aeabi_dcmpge) K(__aeabi_dcmpgt) K(__aeabi_dcmpun)
K(__aeabi_d2iz) K(__aeabi_d2uiz) K(__aeabi_i2d) K(__aeabi_ui2d) K(__aeabi_d2f) K(__aeabi_f2d)
K(__aeabi_ul2d) K(__aeabi_d2ulz)
K(__aeabi_fadd) K(__aeabi_fsub) K(__aeabi_fmul) K(__aeabi_fdiv)
K(__aeabi_fcmpeq) K(__aeabi_fcmplt) K(__aeabi_fcmple) K(__aeabi_fcmpge) K(__aeabi_fcmpgt)
K(__aeabi_f2iz) K(__aeabi_i2f) K(__aeabi_ui2f) K(__aeabi_f2uiz)
K(__aeabi_l2f) K(__aeabi_ul2f) K(__aeabi_f2ulz)
#undef K

uintptr_t frtos_ksym(const char *name, void *u)
{
    (void)u;
    static const struct { const char *n; void *a; } tab[] = {
        /* bare_libc (kernel's own) — for the inline-syscall test programs */
        {"memcpy",(void*)memcpy},{"memset",(void*)memset},{"memmove",(void*)memmove},
        {"memcmp",(void*)memcmp},{"strlen",(void*)strlen},{"strcmp",(void*)strcmp},
        /* syscall primitives libc.so imports */
        {"_sbrk",(void*)_sbrk},{"_write",(void*)_write},{"_read",(void*)_read},
        {"_exit",(void*)_exit},{"_close",(void*)_close},{"_lseek",(void*)_lseek},
        {"_fstat",(void*)_fstat},{"_isatty",(void*)_isatty},{"_open",(void*)_open},
        {"_stat",(void*)_stat},{"_kill",(void*)_kill},{"_getpid",(void*)_getpid},
        {"_gettimeofday",(void*)_gettimeofday},{"_times",(void*)_times},
        {"_link",(void*)_link},{"_unlink",(void*)_unlink},{"_fork",(void*)_fork},
        {"_execve",(void*)_execve},{"_fcntl",(void*)_fcntl},{"_getentropy",(void*)_getentropy},
        {"_getrandom",(void*)_getrandom},
        {"_mkdir",(void*)_mkdir},{"_init",(void*)_init},{"_fini",(void*)_fini},
        {"_jp2uc_l",(void*)_jp2uc_l},{"_uc2jp_l",(void*)_uc2jp_l},{"_wait",(void*)_wait},
        {"regcomp",(void*)regcomp},{"regexec",(void*)regexec},
        {"regfree",(void*)regfree},{"sigprocmask",(void*)sigprocmask},
        /* libgcc runtime helpers */
        {"__aeabi_idiv",(void*)__aeabi_idiv},{"__aeabi_uidiv",(void*)__aeabi_uidiv},
        {"__aeabi_idivmod",(void*)__aeabi_idivmod},{"__aeabi_uidivmod",(void*)__aeabi_uidivmod},
        {"__aeabi_ldivmod",(void*)__aeabi_ldivmod},{"__aeabi_uldivmod",(void*)__aeabi_uldivmod},
        {"__aeabi_d2lz",(void*)__aeabi_d2lz},{"__aeabi_l2d",(void*)__aeabi_l2d},
        {"__aeabi_unwind_cpp_pr0",(void*)__aeabi_unwind_cpp_pr0},{"__ffsdi2",(void*)__ffsdi2},
        {"__aeabi_f2lz",(void*)__aeabi_f2lz},{"__muldc3",(void*)__muldc3},{"__mulsc3",(void*)__mulsc3},
        {"__aeabi_dadd",(void*)__aeabi_dadd},{"__aeabi_dsub",(void*)__aeabi_dsub},
        {"__aeabi_dmul",(void*)__aeabi_dmul},{"__aeabi_ddiv",(void*)__aeabi_ddiv},{"__aeabi_dneg",(void*)__aeabi_dneg},
        {"__aeabi_dcmpeq",(void*)__aeabi_dcmpeq},{"__aeabi_dcmplt",(void*)__aeabi_dcmplt},
        {"__aeabi_dcmple",(void*)__aeabi_dcmple},{"__aeabi_dcmpge",(void*)__aeabi_dcmpge},
        {"__aeabi_dcmpgt",(void*)__aeabi_dcmpgt},{"__aeabi_dcmpun",(void*)__aeabi_dcmpun},
        {"__aeabi_d2iz",(void*)__aeabi_d2iz},{"__aeabi_d2uiz",(void*)__aeabi_d2uiz},
        {"__aeabi_i2d",(void*)__aeabi_i2d},{"__aeabi_ui2d",(void*)__aeabi_ui2d},
        {"__aeabi_d2f",(void*)__aeabi_d2f},{"__aeabi_f2d",(void*)__aeabi_f2d},
        {"__aeabi_ul2d",(void*)__aeabi_ul2d},{"__aeabi_d2ulz",(void*)__aeabi_d2ulz},
        {"__aeabi_fadd",(void*)__aeabi_fadd},{"__aeabi_fsub",(void*)__aeabi_fsub},
        {"__aeabi_fmul",(void*)__aeabi_fmul},{"__aeabi_fdiv",(void*)__aeabi_fdiv},
        {"__aeabi_fcmpeq",(void*)__aeabi_fcmpeq},{"__aeabi_fcmplt",(void*)__aeabi_fcmplt},
        {"__aeabi_fcmple",(void*)__aeabi_fcmple},{"__aeabi_fcmpge",(void*)__aeabi_fcmpge},
        {"__aeabi_fcmpgt",(void*)__aeabi_fcmpgt},
        {"__aeabi_f2iz",(void*)__aeabi_f2iz},{"__aeabi_i2f",(void*)__aeabi_i2f},
        {"__aeabi_ui2f",(void*)__aeabi_ui2f},{"__aeabi_f2uiz",(void*)__aeabi_f2uiz},
        {"__aeabi_l2f",(void*)__aeabi_l2f},{"__aeabi_ul2f",(void*)__aeabi_ul2f},
        {"__aeabi_f2ulz",(void*)__aeabi_f2ulz},
    };
    for (unsigned i = 0; i < sizeof tab / sizeof tab[0]; i++)
        if (!strcmp(name, tab[i].n)) return (uintptr_t)tab[i].a;
    return 0;
}

/* xtld_host.on_loaded: apply W^X + PL0 protection to a freshly-relocated module,
 * before its constructors run or anyone calls into it. Text/rodata/GOT -> RO+X
 * (PL0-RX, so a PL0 program can execute it); writable seg -> RW+XN and PL0-none in
 * the master (the owner process gets PL0-RW per-process via COW). Applies to libc,
 * every shared library, and programs alike — they all live in the (PL0-none) heap
 * region and would otherwise be execute-never / PL0-unreachable. */
void frtos_on_loaded(xtld_obj *obj, void *u)
{
    (void)u;
    extern void mmu_protect(uint32_t, uint32_t, int, int);
    uintptr_t ibase = xtld_image_base(obj), wva; uint32_t wsz;
    xtld_writable_range(obj, &wva, &wsz);
    if (ibase && wva > ibase) mmu_protect((uint32_t)ibase, (uint32_t)(wva - ibase), 1, 0); /* text RO+X */
    if (wva && wsz)           mmu_protect((uint32_t)wva, wsz, 0, 1);                         /* data RW+XN, PL0-none */
    vm_sync_loaded_sections();   /* adopt the section splits into every space so no stale
                                  * global SECTION entry can shadow this module's code (HW) */
}

/* xtld_host.open_lib: map a DT_NEEDED soname to /OS/library/<name> in the romfs */
/* Loader library search path (LD_LIBRARY_PATH-style). Resolution is path-driven, not
 * a hardcoded dir, so a debug session can later prepend a directory of -Og -g
 * libraries (e.g. /OS/library/Debug/) and have a debuggee's DT_NEEDED resolve there
 * first. Entries must end in '/'; searched in order, first hit wins. Default is just
 * the system library dir. (Per-process scoping arrives with the env/debugger work;
 * for now this is the global hook — the indirection is what we're reserving.) */
#define LIBPATH_MAX 4
static const char *g_libpath[LIBPATH_MAX] = { "/Library/" };
static int         g_libpath_n = 1;

void frtos_lib_path_set(const char *const *dirs, int n)
{
    if (n < 1) { g_libpath[0] = "/Library/"; g_libpath_n = 1; return; }
    if (n > LIBPATH_MAX) n = LIBPATH_MAX;
    for (int i = 0; i < n; i++) g_libpath[i] = dirs[i];
    g_libpath_n = n;
}

/* Read /OS/library/<name> off the SD (FatFs) into a persistent kernel-heap buffer.
 * The loader COPIES segments out of this buffer during xtld_load, so it's only
 * needed for the load; but a library is loaded once (deduped by soname) and never
 * unloaded, so we don't free it — matching the cached-image model (frtos_free is a
 * no-op). Returns 1 with *data/*len on success, 0 otherwise. Runs only when a lib
 * misses in the romfs, so the common case (libc/libm from /System/Library) never
 * touches the SD. */
static int open_lib_sd(const char *name, const uint8_t **data, uint32_t *len)
{
    char path[96];
    const char *pfx = "/OS/library/";
    int i = 0;
    while (pfx[i] && i < (int)sizeof(path) - 1) { path[i] = pfx[i]; i++; }
    for (int j = 0; name[j] && i < (int)sizeof(path) - 1; j++) path[i++] = name[j];
    path[i] = 0;

    /* the fs task opens+allocs+reads the file (so it stays the sole FatFs driver). */
    void *buf = 0;
    long sz = kfs_call(KFS_READFILE, path, 0, 0, &buf);
    if (sz <= 0 || !buf) return 0;                          /* not on the SD (or no SD) */
    *data = (const uint8_t *)buf; *len = (uint32_t)sz;
    return 1;
}

/* Resolve a DT_NEEDED soname: search /System/Library (romfs, in-memory, used in
 * place) first via g_libpath, then /OS/library on the SD (read into RAM). System
 * libraries win so a stray .so on the card can't shadow libc; the card is for
 * ADDING libraries, not overriding the base system. */
int frtos_open_lib(const char *name, const uint8_t **data, uint32_t *len, void *u)
{
    (void)u;
    char path[80];
    for (int k = 0; k < g_libpath_n; k++) {
        const char *pfx = g_libpath[k];
        int i = 0;
        while (pfx[i] && i < (int)sizeof(path) - 1) { path[i] = pfx[i]; i++; }
        int j = 0;
        while (name[j] && i < (int)sizeof(path) - 1) path[i++] = name[j++];
        path[i] = 0;
        if (romfs_lookup(path, data, len)) return 1;   /* search order: first hit wins */
    }
    return open_lib_sd(name, data, len);               /* fall back to /OS/library on the SD */
}

static proc_t *proc_by_pid(int pid)
{
    for (int i = 0; i < MAXPROC; i++)
        if (g_proc[i].used && g_proc[i].pid == pid) return &g_proc[i];
    return NULL;
}

/* reap an exited child: reclaim its resources + slot, return its exit code. Runs in
 * the WAITER's context (never the child's), so vTaskDelete(child) here is a non-self
 * delete -> prvDeleteTCB runs inline and fully unlinks the child from every FreeRTOS
 * list before its static TCB/stack can be reused by the next spawn.
 *
 * CONCURRENCY: a waiter (waitpid) and reap_orphans (any spawner) can target the same
 * proc; without a guard both would vSemaphoreDelete(p->done) -> heap double-free. Claim
 * the teardown atomically via `reaping`; the loser returns. The slot stays used==1 (not
 * reusable) until teardown finishes, so a concurrent slot-search can't grab it either. */
static int frtos_reap(proc_t *p)
{
    taskENTER_CRITICAL();
    if (!p->used || p->reaping) { taskEXIT_CRITICAL(); return -1; }   /* someone else has it */
    p->reaping = 1;
    taskEXIT_CRITICAL();

    int code = p->exit_code;
    /* Close any fd the dead proc left open (abnormal exit — a normal exit already fclosed
     * them). Route through the fs task, the sole FatFs driver (3c-4): doing the flush /
     * f_close from the reaper's context would race it. Reading .open here is just a flag
     * check (no FatFs). Direct fallback when the fs task isn't up (host_test). */
    { int slot = (int)(p - g_proc), any = 0;
      for (int fd = 0; fd < NFD; fd++) if (p->fd[fd].open) { any = 1; break; }   /* from 0: redirected stdio */
      for (int i = 0; !any && i < FS_MAXMAP; i++) if (g_wrmap[slot][i].used) any = 1;  /* writable map, fd maybe closed */
      if (any) { if (g_fs_q) kfs_call(KFS_CLOSEALL, 0, 0, (uint32_t)slot, 0);
                 else        fs_close_all(slot); } }
    if (p->task) { vTaskDelete(p->task); p->task = 0; }   /* the child parked in vTaskSuspend */
    if (p->done) { vSemaphoreDelete(p->done); p->done = 0; }
    if (g_fb_owner_pid == p->pid) g_fb_owner_pid = -1;    /* M7 gate: a dead display owner
                                                           * frees the claim — a restarted
                                                           * gemd re-latches on its first
                                                           * SYS_fb_wallpaper */
    vm_space_destroy((int)(p - g_proc));         /* reclaim its private pages to the pool */
    if (p->transient) {
        extern void mmu_unprotect(uint32_t, uint32_t);
        mmu_unprotect((uint32_t)xtld_image_base(p->obj), (uint32_t)xtld_span(p->obj));
        xtld_unload(p->obj);
        register_lib_cow();
        if (p->src) { frtos_free(p->src, NULL); p->src = 0; }
        p->transient = 0;
    }
    p->used = 0; p->reaping = 0;
    return code;
}

/* Reap any exited child that nobody will waitpid (a backgrounded '&' command, or an
 * orphan whose parent exited). Swept lazily at spawn time — those children parked
 * themselves in vTaskSuspend on exit and would otherwise leak their slot + static TCB.
 * `waited` is set by a waitpid caller, so a foreground child mid-wait is left alone.
 * Runs yield-free (vTaskDelete of a non-current task), so it's safe from the spawn
 * path even when that path is the inline SYS_spawn in the SVC handler. */
static void reap_orphans(void)
{
    for (int i = 0; i < MAXPROC; i++)
        if (g_proc[i].used && g_proc[i].exited && !g_proc[i].waited)
            frtos_reap(&g_proc[i]);
}

/* PL0 waitpid, driven by the syscall-deferral thunk (System-mode task context). A real
 * block on a task notification: the child (task_exit_thunk) marks itself exited, sends
 * the notification, and parks in vTaskSuspend; we wake, then reap it (which deletes its
 * parked task). The child never self-deletes, so its FreeRTOS lists are unlinked before
 * its static TCB/stack is reused — see task_exit_thunk + frtos_reap. */
/* waitpid(-1): reap ANY exited child. This is init's whole job. It also collects the
 * re-parented orphans, which is what stops them accumulating in ps forever. */
static int frtos_waitany(proc_t *self)
{
    if (!self) return -1;
    for (;;) {
        if (self->killed) proc_exit_self(self, 137);
        if (sig_ready(self)) return -4;                  /* -EINTR */
        for (int i = 0; i < MAXPROC; i++) {
            proc_t *c = &g_proc[i];
            if (c->used && c->exited && c->ppid == self->pid && !c->reaping) {
                int pid = c->pid;
                frtos_reap(c);
                return pid;
            }
        }
        int kids = 0;
        for (int i = 0; i < MAXPROC; i++)
            if (g_proc[i].used && g_proc[i].ppid == self->pid && &g_proc[i] != self) kids++;
        if (!kids) return -1;                            /* -ECHILD: nothing to wait for */
        vTaskDelay(pdMS_TO_TICKS(20));
    }
}

int frtos_waitpid_notify(int pid)
{
    if (pid < 0) return frtos_waitany(cur_proc());       /* waitpid(-1): any child */
    proc_t *p = proc_by_pid(pid);
    if (!p) return -1;
    p->waited = 1;
    p->waiter = xTaskGetCurrentTaskHandle();      /* task_exit_thunk notifies this task */
    while (!p->exited && !p->stopped) ulTaskNotifyTake(pdTRUE, portMAX_DELAY);
    if (!p->exited) {                             /* stopped, not dead: report it, don't reap —
                                                   * fg waits it again after SIGCONT */
        p->waiter = 0;
        p->waited = 0;
        return XT_WAIT_STOPPED;
    }
    return frtos_reap(p);
}

/* the non-blocking form (WNOHANG): the exit thunk set p->exited before waking
 * anyone, so "is it still running" is just that flag. Marking it waited on the
 * first poll reserves the slot — the lazy orphan sweep (reap_orphans) skips
 * waited children, so the exit status survives until the poller collects it. */
int frtos_waitpid_poll(int pid)
{
    proc_t *p = proc_by_pid(pid);
    if (!p) return -1;                            /* no such child (or already reaped) */
    p->waited = 1;
    if (!p->exited) return -11;                   /* -EAGAIN: still running */
    return frtos_reap(p);
}

/* non-reaping peek (XT_WAIT_PEEK): does this child exist and has it exited? Used
 * by the shim's synchronous-SIGCHLD probe — it must NOT reap (dropbear reaps to
 * collect the status). Marks `waited` so reap_orphans won't steal the zombie
 * before dropbear's own waitpid runs. 1 = exited, 0 = running, -1 = gone. */
int frtos_waitpid_peek(int pid)
{
    proc_t *p = proc_by_pid(pid);
    if (!p) return -1;
    p->waited = 1;
    return p->exited ? 1 : 0;
}

/* SYS_boot_done — init(1) only. */
static long k_boot_done(proc_t *p)
{
    if (!p || p->pid != g_init_pid) return -1;   /* -EPERM: only init(1) opens the console */
    g_boot_done = 1;
    return 0;
}

/* shell_task's side of the boot barrier: block until init says the boot scripts are done.
 *
 * Two escapes, because a console you cannot reach is worse than a boot script that did
 * not run:
 *   - init died (crashed, or an old init that predates SYS_boot_done): stop waiting.
 *   - a boot script hung: come up anyway after `timeout_ms`, and say so. A wedged daemon
 *     or desktop must never cost the machine its console.
 * Returns 1 if the boot scripts completed, 0 if we gave up on them. */
int frtos_wait_boot(int initpid, int timeout_ms)
{
    for (int waited = 0; !g_boot_done; waited += 20) {
        proc_t *p = proc_by_pid(initpid);
        if (!p || p->exited) return 0;                    /* no init -> nothing is coming */
        if (timeout_ms > 0 && waited >= timeout_ms) return 0;
        vTaskDelay(pdMS_TO_TICKS(20));
    }
    return 1;
}

/* waitpid for a KERNEL task waiter (shell_task) — blocks on the child's `done`
 * semaphore rather than a task notification. */
int frtos_waitpid(int pid)
{
    proc_t *p = proc_by_pid(pid);
    if (!p) return -1;
    p->waited = 1;
    xSemaphoreTake(p->done, portMAX_DELAY);    /* yields via svc #0 until exit */
    return frtos_reap(p);
}

