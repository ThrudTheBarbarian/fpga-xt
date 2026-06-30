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
#include "ksys.h"      /* struct k_regs */
#include "xtsys.h"
#include "xtld.h"
#include "romfs.h"
#include "vfs.h"
#include "frtos_os.h"

#define MAXPROC 8
#define NFD     8       /* per process; 0/1/2 are stdio */

typedef struct {
    int      open;
    vfs_file vf;     /* VFS-backed: romfs / fatfs / minixfs-later */
} fd_t;

typedef struct {
    int               used;
    int               pid;
    TaskHandle_t      task;
    xtld_obj         *obj;
    uintptr_t         entry;
    SemaphoreHandle_t done;
    int               exit_code;
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
    /* mmap'd file (read-only): a READ fault -> map the file page RO on demand. A
     * WRITE to it is illegal (it's a read-only mapping) -> fatal. */
    if (dfar >= XTOS_MMAP_VA && dfar < XTOS_MMAP_VA + XTOS_MMAP_SIZE)
        return write ? 0 : vm_mmap_fault(idx, dfar);
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

/* runs in TASK (System-mode) context — safe to call yielding FreeRTOS APIs */
static void task_exit_thunk(void)
{
    proc_t *p = cur_proc();
    if (p && p->done) xSemaphoreGive(p->done);
    vTaskDelete(NULL);
    for (;;) {}
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
    if (p) { p->exit_code = -1; if (p->done) xSemaphoreGive(p->done); }   /* killed */
    vTaskDelete(NULL);
    for (;;) {}
}

/* ---- file syscalls (dispatch through the VFS: romfs / fatfs / ...) ------ */
static long sys_open(proc_t *p, const char *path)
{
    if (!p) return -1;
    for (int fd = 3; fd < NFD; fd++) {
        if (!p->fd[fd].open) {
            if (vfs_open(path, &p->fd[fd].vf) != 0) return -1;
            p->fd[fd].open = 1;
            return fd;
        }
    }
    return -1; /* -EMFILE */
}

static long sys_read(proc_t *p, int fd, void *buf, uint32_t n)
{
    if (fd == 0) return 0;                       /* stdin: EOF for now */
    if (!p || fd < 3 || fd >= NFD || !p->fd[fd].open) return -1;
    vfs_file *vf = &p->fd[fd].vf;
    return vf->read ? vf->read(vf, buf, n) : -1;
}

static long sys_lseek(proc_t *p, int fd, long off, int whence)
{
    if (!p || fd < 3 || fd >= NFD || !p->fd[fd].open) return -1;
    vfs_file *vf = &p->fd[fd].vf;
    return vf->lseek ? vf->lseek(vf, off, whence) : -1;
}

static const xtld_host *g_khost;   /* kernel loader host (frtos_set_host); used by SYS_spawn */

static long do_syscall(uint32_t num, long a0, long a1, long a2)
{
    proc_t *p = cur_proc();
    switch (num) {
    case SYS_abi_version: return XTOS_ABI_VERSION;           /* () -> frozen-ABI version */
    case SYS_write:                                          /* (fd, buf, len) */
        if ((a0 == 1 || a0 == 2) && g_console && a1) { g_console((const char *)a1, (int)a2); return a2; }
        return -1;
    case SYS_getpid: return p ? p->pid : 0;
    case SYS_open:   return sys_open(p, (const char *)a0);   /* (path, flags) */
    case SYS_read:   return sys_read(p, (int)a0, (void *)a1, (uint32_t)a2);
    case SYS_close:  if (p && a0 >= 3 && a0 < NFD && p->fd[a0].open) {
                         vfs_file *vf = &p->fd[a0].vf; if (vf->close) vf->close(vf);
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
    case SYS_fb_info: {                                      /* (struct os_fbinfo *) */
        extern void fb_info(int *, int *, int *, uint32_t *);
        struct { int w, h, stride; uint32_t addr; } *fi = (void *)a0;
        if (!fi) return -1;
        fb_info(&fi->w, &fi->h, &fi->stride, &fi->addr);
        return 0;
    }
    case SYS_fb_present: { extern void fb_present(void); fb_present(); return 0; }
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
    p->obj = obj; p->entry = entry; p->exit_code = 0; p->pid = g_next_pid++;
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

int frtos_spawn(const uint8_t *image, uint32_t len, int argc, char **argv,
                const xtld_host *host)
{
    int slot = -1;
    for (int i = 0; i < MAXPROC; i++) if (!g_proc[i].used) { slot = i; break; }
    if (slot < 0) return -1;

    prog_t *prog = prog_get(image, len, host);    /* load-once (shared text + COW data) */
    if (!prog) return -1;
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

    int slot = -1;
    for (int i = 0; i < MAXPROC; i++) if (!g_proc[i].used) { slot = i; break; }
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
    return 0;
}

int frtos_waitpid(int pid)
{
    proc_t *p = NULL;
    for (int i = 0; i < MAXPROC; i++)
        if (g_proc[i].used && g_proc[i].pid == pid) { p = &g_proc[i]; break; }
    if (!p) return -1;

    xSemaphoreTake(p->done, portMAX_DELAY);    /* yields via svc #0 until exit */
    int code = p->exit_code;
    vSemaphoreDelete(p->done);
    vm_space_destroy((int)(p - g_proc));         /* reclaim its private pages to the pool */
    /* a transient (runhost) image isn't cached: unload it now (fini + transitive lib
     * release), restore its master pages, and free the host ELF buffer + argv. */
    if (p->transient) {
        extern void mmu_unprotect(uint32_t, uint32_t);
        mmu_unprotect((uint32_t)xtld_image_base(p->obj), (uint32_t)xtld_span(p->obj));
        xtld_unload(p->obj);
        register_lib_cow();                      /* drop any now-freed library's COW range */
        if (p->src) { frtos_free(p->src, NULL); p->src = 0; }  /* argv lives on the task stack now */
        p->transient = 0;
    }
    p->used = 0;                                 /* reap the slot (cached image stays resident) */
    return code;
}
