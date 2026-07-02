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
#include "ksys.h"      /* struct k_regs */
#include "xtsys.h"
#include "xtld.h"
#include "romfs.h"
#include "vfs.h"
#include "frtos_os.h"

#define MAXPROC 8
#define NFD     8       /* per process; 0/1/2 are stdio */
#define FD_PATH_MAX 96  /* retained open path (for a writable mmap's independent write-back handle) */

typedef struct {
    int      open;
    uint32_t pos;    /* logical read/write cursor (page store); the driver's vf.pos is fill scratch */
    uint32_t cpi;    /* cached page index (~0u = none) — backing-store only; in-memory fds read vf.data */
    void    *cpage;  /* the one cached page (pool identity addr), or NULL */
    int      cdirty; /* the cached page has unflushed writes */
    char     path[FD_PATH_MAX];  /* the path this fd was opened with */
    vfs_file vf;     /* VFS-backed: romfs / fatfs / ramfs / ... */
} fd_t;

typedef struct {
    int               used;
    int               pid;
    TaskHandle_t      task;
    xtld_obj         *obj;
    uintptr_t         entry;
    SemaphoreHandle_t done;
    int               exit_code;
    volatile int      exited;         /* set by the exit thunk */
    volatile int      waited;         /* a waitpid registered -> that caller will reap it */
    volatile int      reaping;        /* teardown claimed (one reaper only; slot not reusable yet) */
    TaskHandle_t      waiter;         /* PL0 waitpid task to notify on exit (0 = none/kernel waiter) */
    int               argc;
    char            **argv;
    fd_t              fd[NFD];
    uint32_t         *l1;             /* per-process address space (vm.c), NULL=master */
    uint32_t          asid;           /* its ASID (slot+1; 0 = kernel/master) */
    uint32_t          heap_brk;       /* per-process heap (XTOS_HEAP_VA window) */
    uint32_t          heap_end;
    int               transient;      /* loaded outside the cache (runhost) -> unload on reap */
    void             *src;            /* the host ELF buffer to free on reap (transient) */
    StaticTask_t      tcb;            /* static TCB (stack from stackguard.c) */
    /* blocking-syscall deferral: saved PL0 exception context so the blocking part can
     * run in task context (PL1) and then sysret to PL0. dctx = {r0..r12, lr(=user PC),
     * sp_usr, spsr}; dnum/da* = the deferred syscall + args. */
    uint32_t          dctx[16];
    uint32_t          dnum;
    long              da0, da1, da2;
} proc_t;

static proc_t g_proc[MAXPROC];
static int    g_next_pid = 1;
static void (*g_console)(const char *, int);

void ksys_set_console(void (*w)(const char *, int)) { g_console = w; }

/* xtld_host.alloc/dealloc — the OS heap (newlib). Real free, so xtld_unload
 * actually reclaims. */
/* Allocation: a one-shot bootstrap bump (over the OS-heap base) loads libc.so;
 * once libc.so is up we switch to its memalign/free. After that, every .so /
 * program image comes from the one libc.so malloc and is freed on unload. */
extern char _heap_start[];                       /* 0x0200_0000 (linker) */
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
    return 0;
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
static void task_exit_thunk(void)
{
    proc_t *p = cur_proc();
    if (p) {
        p->exited = 1;
        if (p->waiter) xTaskNotifyGive(p->waiter);   /* wake a PL0 waitpid (task notification) */
        if (p->done)   xSemaphoreGive(p->done);      /* wake a kernel-task waitpid (shell_task) */
    }
    vTaskSuspend(NULL);                              /* park; the waiter deletes us via frtos_reap */
    for (;;) vTaskSuspend(NULL);                     /* never resumed */
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
    if (p) {                                        /* killed by a fault */
        p->exit_code = -1;
        p->exited = 1;
        if (p->waiter) xTaskNotifyGive(p->waiter);  /* wake a PL0 waitpid */
        if (p->done)   xSemaphoreGive(p->done);     /* wake a kernel-task waitpid */
    }
    vTaskSuspend(NULL);                             /* park; the waiter reaps us (see task_exit_thunk) */
    for (;;) vTaskSuspend(NULL);
}

/* ---- file syscalls (dispatch through the VFS: romfs / fatfs / ...) ------ */
static long sys_open(proc_t *p, const char *path, int flags)
{
    if (!p) return -1;
    for (int fd = 3; fd < NFD; fd++) {
        if (!p->fd[fd].open) {
            if (vfs_open(path, flags, &p->fd[fd].vf) != 0) return -1;
            p->fd[fd].pos = 0; p->fd[fd].cpi = ~0u; p->fd[fd].cpage = 0;   /* page store: empty */
            p->fd[fd].cdirty = 0;
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

/* lseek is pure arithmetic on the LOGICAL cursor (fd.pos) + the file size captured at
 * open — no backing I/O, no fs task. The page store fills by page index independently,
 * so the driver's own position is irrelevant between fills. Runs inline (any context). */
static long sys_lseek(proc_t *p, int fd, long off, int whence)
{
    if (!p || fd < 3 || fd >= NFD || !p->fd[fd].open) return -1;
    fd_t *fdp = &p->fd[fd];
    long base = (whence == 1) ? (long)fdp->pos : (whence == 2) ? (long)fdp->vf.size : 0;
    long np = base + off;
    if (np < 0 || np > (long)fdp->vf.size) return -1;
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
    char              path[FS_PATH_MAX];   /* open: marshalled path (identity-reachable) */
} fs_ctl;

static QueueHandle_t g_fs_q;                 /* doorbell: slot indices; NULL until frtos_fs_start() */
static fs_ctl       *g_fs_ctl[MAXPROC];      /* per-slot control page (pool identity addr) */
static TaskHandle_t  g_fs_waiter[MAXPROC];   /* client task parked on each slot's request */

static long do_syscall(uint32_t num, long a0, long a1, long a2);   /* fallback (caller ctx) */

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
    if (fd < 3 || fd >= NFD || !g_proc[slot].fd[fd].open) return 0;
    fd_t    *fdp  = &g_proc[slot].fd[fd];
    uint32_t size = fdp->vf.size, base = pi << 12;
    if (!forwrite && base >= size) return 0;                       /* read wholly past EOF */
    *valid = forwrite ? 0x1000u : ((size - base < 0x1000u) ? (size - base) : 0x1000u);
    if (fdp->vf.data) return forwrite ? 0 : (uint8_t *)fdp->vf.data + base;  /* in-memory (RO) */
    if (fdp->cpage && fdp->cpi == pi) return fdp->cpage;           /* cache hit */
    fd_flush(fdp);                                                 /* evict: don't lose the old page */
    if (!fdp->cpage) { fdp->cpage = vm_page_alloc(); if (!fdp->cpage) { *valid = 0; return 0; } }
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

static long fs_serve(int slot)
{
    proc_t *p = &g_proc[slot];
    fs_ctl *c = g_fs_ctl[slot];
    switch (c->op) {
    case SYS_open:  return sys_open(p, c->path, (int)c->flags);   /* path copied into the shm page */
    case SYS_close:
        if (p && c->fd >= 3 && c->fd < NFD && p->fd[c->fd].open) {
            fd_drop_cache(&p->fd[c->fd]);                 /* flush (if dirty) + free the cache page */
            vfs_close(&p->fd[c->fd].vf);
            p->fd[c->fd].open = 0;
        }
        return 0;
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
enum { KFS_READFILE, KFS_LISTDIR, KFS_CLOSEALL };
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

/* Tear down every open fd of a dead proc: flush its dirty cache page, close the backing
 * file (free the FIL), free the cache page. MUST run in the fs task (the sole FatFs
 * driver post-3c-4), so reap routes here via KFS_CLOSEALL rather than doing FatFs from the
 * reaper's context. A killed proc's unflushed writes are still flushed here (harmless, and
 * more correct than dropping them). */
static void fs_close_all(int slot)
{
    if (slot < 0 || slot >= MAXPROC) return;
    proc_t *p = &g_proc[slot];
    for (int fd = 3; fd < NFD; fd++) {
        if (!p->fd[fd].open) continue;
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

static long kfs_serve(void)
{
    switch (g_kfs.op) {
    case KFS_READFILE: {                                /* open + alloc + read a whole file */
        vfs_file f;
        g_kfs.buf = 0;
        if (vfs_open(g_kfs.path, 0, &f) != 0) return -1;
        if (f.size == 0 || !f.read) { if (f.close) f.close(&f); return -1; }
        void *buf = frtos_alloc(f.size, 16, NULL);
        if (!buf) { if (f.close) f.close(&f); return -1; }
        long got = f.read(&f, buf, f.size);
        if (f.close) f.close(&f);
        if (got != (long)f.size) return -1;            /* buf leaks (rare); kernel heap is bump anyway */
        g_kfs.buf = buf;
        return (long)f.size;
    }
    case KFS_LISTDIR: {
        extern int sd_listdir_raw(const char *, char (*)[32], int);
        return sd_listdir_raw(g_kfs.path, (char (*)[32])g_kfs.buf, (int)g_kfs.len);
    }
    case KFS_CLOSEALL: fs_close_all((int)g_kfs.len); return 0;   /* reap: close a dead proc's fds */
    }
    return -1;
}

static void fs_task(void *arg)
{
    (void)arg;
    for (;;) {
        int slot;
        if (xQueueReceive(g_fs_q, &slot, portMAX_DELAY) != pdTRUE) continue;
        if (slot == FS_KERNEL_JOB) {                   /* kernel mailbox request */
            g_kfs.result = kfs_serve();
            xTaskNotifyGive(g_kfs.waiter);
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
    if (!g_fs_q || !g_kfs_mtx) return -1;
    xSemaphoreTake(g_kfs_mtx, portMAX_DELAY);
    g_kfs.op = op; g_kfs.path = path; g_kfs.buf = buf; g_kfs.len = len; g_kfs.result = -1;
    g_kfs.waiter = xTaskGetCurrentTaskHandle();
    int job = FS_KERNEL_JOB;
    xQueueSend(g_fs_q, &job, portMAX_DELAY);
    ulTaskNotifyTake(pdTRUE, portMAX_DELAY);
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
        const char *src = (const char *)p->da0;   /* client PL0 path — reachable in this space */
        int i = 0;
        if (src) while (src[i] && i < FS_PATH_MAX - 1) { c->path[i] = src[i]; i++; }
        c->path[i] = 0;
        c->flags = (uint32_t)p->da1;              /* open flags (VFS_O_*) */
    } else {                                      /* close */
        c->fd = (uint32_t)p->da0;
    }
    c->result = -1;
    g_fs_waiter[slot] = xTaskGetCurrentTaskHandle();
    xQueueSend(g_fs_q, &slot, portMAX_DELAY);
    ulTaskNotifyTake(pdTRUE, portMAX_DELAY);   /* index 0: free here (not a waitpid waiter) */
    return c->result;
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
    if (fd < 3 || fd >= NFD || !p->fd[fd].open) return -1;
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
    if (fd < 3 || fd >= NFD || !p->fd[fd].open) return -1;
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
    for (int s = 0; s < MAXPROC; s++) {
        int id = vm_shm_create(sizeof(fs_ctl));
        g_fs_ctl[s] = (id >= 0) ? (fs_ctl *)vm_shm_kaddr(id) : 0;
        if (!g_fs_ctl[s]) { if (g_console) g_console("[fs] shm ctl alloc failed\n", 26); return; }
    }
    g_fs_q = xQueueCreate(MAXPROC + 2, sizeof(int));   /* client slots + a kernel job */
    if (!g_fs_q) { if (g_console) g_console("[fs] queue create failed\n", 25); return; }
    g_kfs_mtx = xSemaphoreCreateMutex();
    if (!g_kfs_mtx) { if (g_console) g_console("[fs] kfs mutex failed\n", 22); vQueueDelete(g_fs_q); g_fs_q = 0; return; }
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
    extern int  sh_readc(void);
    proc_t *p = cur_proc();
    long r = -1;
    if (p) {
        if (p->dnum == SYS_spawn) {                        /* may load libs from the SD (FatFs) */
            r = frtos_spawn_argv((const char *)p->da0, (int)p->da1, (char **)p->da2, g_khost);
        } else if (p->dnum == SYS_waitpid) {               /* blocks until the child exits */
            extern int frtos_waitpid_notify(int); r = frtos_waitpid_notify((int)p->da0);
        } else if (p->dnum == SYS_read && p->da0 == 0) {   /* stdin: one blocking console char */
            char *buf = (char *)p->da1;
            if (buf && p->da2 > 0) { int c = sh_readc(); if (c < 0) r = 0; else { buf[0] = (char)c; r = 1; } }
            else r = 0;
        } else if (p->dnum == SYS_read) {
            /* file read over the page store, in the CLIENT's space (buf is mapped here);
             * pages are filled by the fs task, copied out one memcpy each. */
            r = fs_read(p);
        } else if (p->dnum == SYS_write) {
            /* file write over the page store (client space, buf mapped here); pages are
             * dirtied in place and flushed by the fs task on evict/close. */
            r = fs_write(p);
        } else if (p->dnum == SYS_open || p->dnum == SYS_close) {
            /* metadata ops (no client data buffer) -> the fs service task owns them. */
            r = fs_call(p);
        } else if (p->dnum == SYS_mmap) {
            /* mmap a backing-store file: the fs task eager-fills + maps it into our space. */
            r = fs_mmap(p);
        } else if (p->dnum == SYS_munmap) {
            /* munmap: the fs task writes back dirty pages (if any) then unmaps. */
            r = fs_munmap(p);
        } else if (p->dnum == SYS_input) {
            /* block for the next input event (serial mouse/keyboard); cursor moves
             * kernel-side.  Runs here in task context so sh_readc may block. */
            extern int input_next_event(void *, int);
            r = input_next_event((void *)p->da0, (int)p->da1);
        } else {
            r = do_syscall(p->dnum, p->da0, p->da1, p->da2);
        }
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
    uint32_t spsr, spu;
    __asm__ volatile("mrs %0, spsr" : "=r"(spsr));
    __asm__ volatile("cps #0x1f\n\tmov %0, sp\n\tcps #0x13" : "=r"(spu) :: "memory"); /* read sp_usr */
    p->dctx[14] = spu; p->dctx[15] = spsr;
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
        if ((a0 == 1 || a0 == 2) && g_console && a1) { g_console((const char *)a1, (int)a2); return a2; }
        return -1;
    case SYS_getpid: return p ? p->pid : 0;
    case SYS_open:   return sys_open(p, (const char *)a0, (int)a1);   /* (path, flags) */
    case SYS_read:   return sys_read(p, (int)a0, (void *)a1, (uint32_t)a2);
    case SYS_close:  if (p && a0 >= 3 && a0 < NFD && p->fd[a0].open) {
                         fd_drop_cache(&p->fd[a0]);
                         vfs_close(&p->fd[a0].vf);
                         p->fd[a0].open = 0;
                     } return 0;
    case SYS_lseek:  return sys_lseek(p, (int)a0, a1, (int)a2);
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
    case SYS_shm_create: return vm_shm_create((uint32_t)a0);            /* (size) -> id */
    case SYS_shm_map:    return p ? (long)vm_shm_map((int)(p - g_proc), (int)a0) : 0;  /* (id) -> VA */
    case SYS_fb_info: {                                      /* (struct os_fbinfo *) */
        extern void fb_info(int *, int *, int *, uint32_t *);
        struct { int w, h, stride; uint32_t addr; } *fi = (void *)a0;
        if (!fi) return -1;
        fb_info(&fi->w, &fi->h, &fi->stride, &fi->addr);
        return 0;
    }
    case SYS_fb_present: { extern void fb_present(void); fb_present(); return 0; }
    case SYS_fb_wallpaper: {                                 /* (struct os_fbinfo *) */
        extern void fb_wallpaper_info(int *, int *, int *, uint32_t *);
        struct { int w, h, stride; uint32_t addr; } *fi = (void *)a0;
        if (!fi) return -1;
        fb_wallpaper_info(&fi->w, &fi->h, &fi->stride, &fi->addr);
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
        uint32_t *tv = (uint32_t *)a0;
        uint32_t sec, usec;
        if (!tv) return -1;
        gtimer_timeofday(&sec, &usec);
        tv[0] = sec;    /* tv_sec  low  */
        tv[1] = 0;      /* tv_sec  high */
        tv[2] = usec;   /* tv_usec @ byte offset 8 */
        return 0;
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
    return p && fd >= 3 && fd < NFD && p->fd[fd].open && !p->fd[fd].vf.data;
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
    case SYS_open:    return 1;                    /* may walk a FatFs directory path */
    case SYS_read:    return fd == 0 || (fd >= 3 && fd < NFD);  /* stdin blocks; file read -> page store */
    case SYS_write:   return fd >= 3 && fd < NFD;   /* file write -> page store (console 1/2 inline) */
    case SYS_close:   return fd_is_sd(fd);          /* backing-store close -> task ctx (romfs inline) */
    case SYS_mmap:    return fd_is_sd(fd);          /* backing-store mmap -> fs task eager-fill (romfs inline) */
    case SYS_munmap:  return 1;                     /* may write dirty pages back (FatFs) -> task ctx */
    case SYS_input:   return 1;                     /* blocks on the serial ring for the next event */
    default:          return 0;                    /* lseek (inline)/getpid/sbrk/fb/gettimeofday */
    }
}

/* called from the chained SVC vector with the saved register block. Returns 1 for
 * the exit case (the vector then resumes task_exit_thunk at PL1 — see xt_vectors.S),
 * 0 otherwise. */
int k_syscall_dispatch(struct k_regs *regs)
{
    uint32_t insn = *((volatile uint32_t *)(regs->lr - 4));
    if ((insn & 0x00ffffff) != 1) { regs->r[0] = (uint32_t)-1; return 0; }

    uint32_t num = regs->r[7];
    if (num == SYS_exit) {
        proc_t *p = cur_proc();
        if (p) p->exit_code = (int)regs->r[0];
        regs->lr = (uint32_t)(uintptr_t)task_exit_thunk;   /* resume the thunk (at PL1) */
        return 1;
    }
    if (needs_task_ctx(regs, num)) return defer_syscall(regs, num);   /* run in task ctx */
    regs->r[0] = (uint32_t)do_syscall(num, regs->r[0], regs->r[1], regs->r[2]);
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
                       uint32_t wva, uint32_t wsz, int argc, char **argv)
{
    proc_t *p = &g_proc[slot];
    for (int i = 0; i < NFD; i++) p->fd[i].open = 0;
    p->obj = obj; p->entry = entry; p->exit_code = 0; p->exited = 0; p->waited = 0; p->waiter = 0; p->pid = g_next_pid++;
    p->done = xSemaphoreCreateBinary();
    if (!p->done) return -1;
    /* T2-b/c: private address space — demand heap + COW(libc data, synthetic, and
     * this program's own data/bss at its identity load VA). */
    p->l1 = vm_space_create(slot, wva, wsz, wva);
    p->asid = (uint32_t)slot + 1u;
    p->heap_brk = XTOS_HEAP_VA; p->heap_end = XTOS_HEAP_VA + XTOS_HEAP_SIZE;    /* private heap */
    p->used = 1;
    /* name the task after the program (basename of argv[0]) so fault reports and
     * task listings identify it — FreeRTOS copies the name into the TCB. */
    const char *nm = (argc > 0 && argv && argv[0]) ? argv[0] : "app";
    for (const char *q = nm; *q; q++) if (*q == '/') nm = q + 1;
    extern StackType_t *stackguard_stack(int, uint32_t *);
    uint32_t depth; StackType_t *stk = stackguard_stack(slot, &depth);
    /* carve argv out of the TOP of the task stack (PL0-RW) so the program can read
     * its args at PL0; the rest of the stack stays the FreeRTOS-managed region. */
    p->argc = argc;
    if (argc > 0) { depth -= ARGV_WORDS;
        p->argv = copy_argv(argc, argv, stk + depth, ARGV_WORDS * sizeof(StackType_t)); }
    else p->argv = NULL;
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
            slot = i; break;
        }
    taskEXIT_CRITICAL();
    return slot;
}

int frtos_spawn(const uint8_t *image, uint32_t len, int argc, char **argv,
                const xtld_host *host)
{
    reap_orphans();                              /* clean up exited '&'/orphan children first */
    int slot = alloc_slot();
    if (slot < 0) return -1;

    prog_t *prog = prog_get(image, len, host);    /* load-once (shared text + COW data) */
    if (!prog) { g_proc[slot].used = 0; return -1; }
    g_proc[slot].transient = 0; g_proc[slot].src = 0;
    return proc_launch(slot, prog->obj, prog->entry, (uint32_t)prog->wva, prog->wsize, argc, argv);
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
    int pid = proc_launch(slot, obj, entry, (uint32_t)wva, wsz, argc, argv);
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

int frtos_spawn_argv(const char *path, int argc, char **argv, const xtld_host *host)
{
    const uint8_t *data; uint32_t size;
    /* programs live in the romfs (mounted at /System); accept a /System/bin/x path
     * (-> romfs-internal /bin/x) as well as a bare romfs-internal path. (/OS/bin on
     * the SD is a Stage-3 search target once SD .so loading lands.) */
    if (!romfs_lookup(path, &data, &size)) {
        if (!has_prefix(path, "/System/") || !romfs_lookup(path + 7, &data, &size))
            return -1;
    }
    return frtos_spawn(data, size, argc, argv, host);
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
K(_unlink) K(_fork) K(_execve) K(_fcntl) K(_getentropy) K(_mkdir)
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

/* xtld_host.open_lib: map a DT_NEEDED soname to /OS/Library/<name> in the romfs */
/* Loader library search path (LD_LIBRARY_PATH-style). Resolution is path-driven, not
 * a hardcoded dir, so a debug session can later prepend a directory of -Og -g
 * libraries (e.g. /OS/Library/Debug/) and have a debuggee's DT_NEEDED resolve there
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

/* Read /OS/Library/<name> off the SD (FatFs) into a persistent kernel-heap buffer.
 * The loader COPIES segments out of this buffer during xtld_load, so it's only
 * needed for the load; but a library is loaded once (deduped by soname) and never
 * unloaded, so we don't free it — matching the cached-image model (frtos_free is a
 * no-op). Returns 1 with *data/*len on success, 0 otherwise. Runs only when a lib
 * misses in the romfs, so the common case (libc/libm from /System/Library) never
 * touches the SD. */
static int open_lib_sd(const char *name, const uint8_t **data, uint32_t *len)
{
    char path[96];
    const char *pfx = "/OS/Library/";
    int i = 0;
    while (pfx[i] && i < (int)sizeof(path) - 1) { path[i] = pfx[i]; i++; }
    for (int j = 0; name[j] && i < (int)sizeof(path) - 1; j++) path[i++] = name[j];
    path[i] = 0;

    /* the fs task opens+allocs+reads the file (so it stays the sole FatFs driver). */
    void *buf = 0;
    long sz = kfs_call(KFS_READFILE, path, 0, 0, &buf);
    if (sz <= 0 || !buf) return 0;                         /* not on the SD (or no SD) */
    *data = (const uint8_t *)buf; *len = (uint32_t)sz;
    return 1;
}

/* Resolve a DT_NEEDED soname: search /System/Library (romfs, in-memory, used in
 * place) first via g_libpath, then /OS/Library on the SD (read into RAM). System
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
    return open_lib_sd(name, data, len);               /* fall back to /OS/Library on the SD */
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
      for (int fd = 3; fd < NFD; fd++) if (p->fd[fd].open) { any = 1; break; }
      for (int i = 0; !any && i < FS_MAXMAP; i++) if (g_wrmap[slot][i].used) any = 1;  /* writable map, fd maybe closed */
      if (any) { if (g_fs_q) kfs_call(KFS_CLOSEALL, 0, 0, (uint32_t)slot, 0);
                 else        fs_close_all(slot); } }
    if (p->task) { vTaskDelete(p->task); p->task = 0; }   /* the child parked in vTaskSuspend */
    if (p->done) { vSemaphoreDelete(p->done); p->done = 0; }
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
int frtos_waitpid_notify(int pid)
{
    proc_t *p = proc_by_pid(pid);
    if (!p) return -1;
    p->waited = 1;
    p->waiter = xTaskGetCurrentTaskHandle();      /* task_exit_thunk notifies this task */
    while (!p->exited) ulTaskNotifyTake(pdTRUE, portMAX_DELAY);
    return frtos_reap(p);
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

