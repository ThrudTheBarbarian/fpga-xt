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
#include "frtos_os.h"

#define MAXPROC 8
#define NFD     8       /* per process; 0/1/2 are stdio */

typedef struct {
    int            open;
    const uint8_t *data;
    uint32_t       size;
    uint32_t       pos;
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

void *frtos_alloc(size_t size, size_t align, void *u)
{
    (void)u;
    if (g_libc_memalign) return g_libc_memalign(align ? align : 16, size);
    if (!g_boot) g_boot = _heap_start;           /* bootstrap bump (libc.so only) */
    uintptr_t a = ((uintptr_t)g_boot + (align - 1)) & ~(uintptr_t)(align - 1);
    g_boot = (char *)a + size;
    return (void *)a;
}
void frtos_free(void *p, void *u) { (void)u; if (g_libc_free) g_libc_free(p); }

/* Called after the loader has loaded libc.so: grab its allocator, and point the
 * kernel's _sbrk just above libc.so's (bootstrap-pinned) image. */
void frtos_activate_libc(xtld_obj *libc)
{
    extern void sbrk_set_base(void *base, void *end);
    g_libc_obj = libc;
    g_libc_memalign = (void *(*)(size_t, size_t))xtld_sym(libc, "memalign");
    g_libc_free     = (void (*)(void *))xtld_sym(libc, "free");
    uintptr_t brk = ((uintptr_t)g_boot + 0xFFFu) & ~0xFFFu;   /* page-align past libc.so */
    sbrk_set_base((void *)brk, (void *)0x20000000u);
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
    /* lazy heap: a not-present fault (read or write) in the heap window -> map a
     * zero-filled page on demand. */
    if (dfar >= XTOS_HEAP_VA && dfar < XTOS_HEAP_VA + XTOS_HEAP_SIZE)
        return vm_demand_map(idx, dfar);
    /* copy-on-write: a WRITE permission fault to a registered shared-RO page ->
     * private copy. DFSR.WnR (bit 11) = 1 for a write. vm_cow_map gates on the COW
     * range, so a write to read-only TEXT (W^X, not a COW range) returns 0 = fatal. */
    uint32_t dfsr; __asm__ volatile("mrc p15,0,%0,c5,c0,0" : "=r"(dfsr));
    if (dfsr & (1u << 11))
        return vm_cow_map(idx, dfar);
    return 0;
}

/* libc.so's _sbrk — per-process: a process grows its OWN heap (XTOS_HEAP_VA
 * window, mapped to private physical by vm.c); the kernel/boot libc uses
 * kern_sbrk (the shared pool). So each process's malloc heap is its own. */
void *_sbrk(int incr)
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

/* ---- file syscalls (non-yielding; romfs is in memory) ------------------ */
static long sys_open(proc_t *p, const char *path)
{
    const uint8_t *data; uint32_t size;
    if (!p || !romfs_lookup(path, &data, &size)) return -1;
    for (int fd = 3; fd < NFD; fd++) {
        if (!p->fd[fd].open) {
            p->fd[fd] = (fd_t){ .open = 1, .data = data, .size = size, .pos = 0 };
            return fd;
        }
    }
    return -1; /* -EMFILE */
}

static long sys_read(proc_t *p, int fd, void *buf, uint32_t n)
{
    if (fd == 0) return 0;                       /* stdin: EOF for now */
    if (!p || fd < 3 || fd >= NFD || !p->fd[fd].open) return -1;
    fd_t *f = &p->fd[fd];
    uint32_t avail = f->size - f->pos;
    if (n > avail) n = avail;
    for (uint32_t i = 0; i < n; i++) ((uint8_t *)buf)[i] = f->data[f->pos + i];
    f->pos += n;
    return (long)n;
}

static long sys_lseek(proc_t *p, int fd, long off, int whence)
{
    if (!p || fd < 3 || fd >= NFD || !p->fd[fd].open) return -1;
    fd_t *f = &p->fd[fd];
    long base = (whence == 1) ? (long)f->pos : (whence == 2) ? (long)f->size : 0;
    long np = base + off;
    if (np < 0 || np > (long)f->size) return -1;
    f->pos = (uint32_t)np;
    return np;
}

static long do_syscall(uint32_t num, long a0, long a1, long a2)
{
    proc_t *p = cur_proc();
    switch (num) {
    case SYS_write:                                          /* (fd, buf, len) */
        if ((a0 == 1 || a0 == 2) && g_console && a1) { g_console((const char *)a1, (int)a2); return a2; }
        return -1;
    case SYS_getpid: return p ? p->pid : 0;
    case SYS_open:   return sys_open(p, (const char *)a0);   /* (path, flags) */
    case SYS_read:   return sys_read(p, (int)a0, (void *)a1, (uint32_t)a2);
    case SYS_close:  if (p && a0 >= 3 && a0 < NFD) p->fd[a0].open = 0; return 0;
    case SYS_lseek:  return sys_lseek(p, (int)a0, a1, (int)a2);
    case SYS_fb_info: {                                      /* (struct os_fbinfo *) */
        extern void fb_info(int *, int *, int *, uint32_t *);
        struct { int w, h, stride; uint32_t addr; } *fi = (void *)a0;
        if (!fi) return -1;
        fb_info(&fi->w, &fi->h, &fi->stride, &fi->addr);
        return 0;
    }
    case SYS_fb_present: { extern void fb_present(void); fb_present(); return 0; }
    default:         return -38;                             /* -ENOSYS */
    }
}

/* called from the chained SVC vector with the saved register block */
void k_syscall_dispatch(struct k_regs *regs)
{
    uint32_t insn = *((volatile uint32_t *)(regs->lr - 4));
    if ((insn & 0x00ffffff) != 1) { regs->r[0] = (uint32_t)-1; return; }

    uint32_t num = regs->r[7];
    if (num == SYS_exit) {
        proc_t *p = cur_proc();
        if (p) p->exit_code = (int)regs->r[0];
        regs->lr = (uint32_t)(uintptr_t)task_exit_thunk;   /* resume in task ctx */
        return;
    }
    regs->r[0] = (uint32_t)do_syscall(num, regs->r[0], regs->r[1], regs->r[2]);
}

/* task body: run constructors + the loaded entry; finish here if it returns. Init
 * runs PER PROCESS (classic exec semantics): the image is shared/loaded once, but
 * each instance's .init_array writes land in its own COW copy of the data, started
 * from the pristine file-loaded image. */
static void app_main(void *arg)
{
    proc_t *p = (proc_t *)arg;
    xtld_run_init(p->obj);
    ((void (*)(int, char **))p->entry)(p->argc, p->argv);   /* argc/argv */
    if (p->done) xSemaphoreGive(p->done);
    vTaskDelete(NULL);
}

/* copy argv (strings + pointer array) into memory owned by the child, since the
 * caller's buffer (e.g. the shell's line) is reused. Returns NULL for argc<=0. */
static char **copy_argv(int argc, char **argv, const xtld_host *host)
{
    if (argc <= 0 || !argv) return NULL;
    uint32_t total = (uint32_t)(argc + 1) * sizeof(char *);
    for (int i = 0; i < argc; i++) total += (uint32_t)strlen(argv[i]) + 1;
    char *block = host->alloc(total, sizeof(char *), host->user);
    if (!block) return NULL;
    char **out = (char **)block;
    char *str = block + (uint32_t)(argc + 1) * sizeof(char *);
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

    /* W^X (once): text/rodata/GOT -> read-only+executable, writable seg ->
     * read-write+execute-never, in the master table. vm_space_create clones the
     * master per process, so every space inherits the protection (and shares the
     * RO text physical). Code can't be modified; data can't be executed. */
    { extern void mmu_protect(uint32_t, uint32_t, int, int);
      uintptr_t ibase = xtld_image_base(obj), wva; uint32_t wsz;
      xtld_writable_range(obj, &wva, &wsz);
      if (ibase && wva > ibase) mmu_protect((uint32_t)ibase, (uint32_t)(wva - ibase), 1, 0);  /* text: RO+X */
      if (wva && wsz)           mmu_protect((uint32_t)wva, wsz, 0, 1);                          /* data: RW+XN */
      /* NB: constructors run PER PROCESS in app_main, not here — so the cached
       * image's data stays the pristine file-loaded COW template. */
      prog_t *pr = &g_prog[g_prog_n++];
      pr->image = image; pr->obj = obj; pr->entry = entry; pr->wva = wva; pr->wsize = wsz;
      pr->lru = ++g_prog_tick;
      g_prog_loads++;
      return pr;
    }
}

int frtos_spawn(const uint8_t *image, uint32_t len, int argc, char **argv,
                const xtld_host *host)
{
    int slot = -1;
    for (int i = 0; i < MAXPROC; i++) if (!g_proc[i].used) { slot = i; break; }
    if (slot < 0) return -1;
    proc_t *p = &g_proc[slot];

    prog_t *prog = prog_get(image, len, host);    /* load-once (shared text + COW data) */
    if (!prog) return -1;

    for (int i = 0; i < NFD; i++) p->fd[i].open = 0;
    p->obj = prog->obj; p->entry = prog->entry; p->exit_code = 0; p->pid = g_next_pid++;
    p->argc = argc; p->argv = copy_argv(argc, argv, host);
    p->done = xSemaphoreCreateBinary();
    if (!p->done) return -1;
    /* T2-b/c: private address space — demand heap + COW(libc data, synthetic, and
     * this program's own data/bss at its identity load VA). */
    p->l1 = vm_space_create(slot, (uint32_t)prog->wva, prog->wsize, (uint32_t)prog->wva);
    p->asid = (uint32_t)slot + 1u;
    p->heap_brk = XTOS_HEAP_VA; p->heap_end = XTOS_HEAP_VA + XTOS_HEAP_SIZE;    /* private heap */
    p->used = 1;
    /* name the task after the program (basename of argv[0]) so fault reports and
     * task listings identify it — FreeRTOS copies the name into the TCB. */
    const char *nm = (argc > 0 && argv && argv[0]) ? argv[0] : "app";
    for (const char *q = nm; *q; q++) if (*q == '/') nm = q + 1;
    { extern StackType_t *stackguard_stack(int, uint32_t *);
      uint32_t depth; StackType_t *stk = stackguard_stack(slot, &depth);
      /* xTaskCreateStatic returns the handle (unlike xTaskCreate's out-param), and
       * the new task is higher priority than us — it would run (and look itself up
       * via cur_proc) BEFORE p->task is assigned. Suspend the scheduler so the
       * assignment lands first. */
      vTaskSuspendAll();
      p->task = xTaskCreateStatic(app_main, nm, depth, p, 3, stk, &p->tcb);
      xTaskResumeAll();
      if (!p->task) { vSemaphoreDelete(p->done); p->used = 0; return -1; } }
    return p->pid;
}

int frtos_spawn_path(const char *path, const xtld_host *host)
{
    return frtos_spawn_argv(path, 0, NULL, host);
}

int frtos_spawn_argv(const char *path, int argc, char **argv, const xtld_host *host)
{
    const uint8_t *data; uint32_t size;
    if (!romfs_lookup(path, &data, &size)) return -1;
    return frtos_spawn(data, size, argc, argv, host);
}

/* xtld_host.resolve: the BOUNDED kernel export table loaded modules resolve
 * against — syscall primitives (for libc.so), libgcc runtime helpers (the A9 has
 * no HW divide), and the kernel's own bare_libc mem/str fns (for the
 * inline-syscall test programs that do not yet DT_NEEDED libc.so). It does NOT
 * grow per-library: libGEM and programs get libc from libc.so, not here. */
#define K(sym) extern void sym(void);
/* _sbrk is defined in this file (per-process), not external */
K(_write) K(_read) K(_exit) K(_close) K(_lseek) K(_fstat) K(_isatty)
K(_open) K(_stat) K(_kill) K(_getpid) K(_gettimeofday) K(_times) K(_link)
K(_unlink) K(_fork) K(_execve) K(_fcntl) K(_getentropy) K(_mkdir)
K(_init) K(_fini) K(_jp2uc_l) K(_uc2jp_l) K(_wait)
extern int regcomp(void*,const void*,int); extern int regexec(const void*,const void*,unsigned,void*,int);
extern void regfree(void*); extern int sigprocmask(int,const void*,void*);
K(__aeabi_idiv) K(__aeabi_uidiv) K(__aeabi_idivmod) K(__aeabi_uidivmod)
K(__aeabi_ldivmod) K(__aeabi_uldivmod) K(__aeabi_d2lz) K(__aeabi_l2d)
K(__aeabi_unwind_cpp_pr0) K(__ffsdi2) K(__aeabi_f2lz) K(__muldc3) K(__mulsc3)
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
    };
    for (unsigned i = 0; i < sizeof tab / sizeof tab[0]; i++)
        if (!strcmp(name, tab[i].n)) return (uintptr_t)tab[i].a;
    return 0;
}

/* xtld_host.open_lib: map a DT_NEEDED soname to /OS/Library/<name> in the romfs */
int frtos_open_lib(const char *name, const uint8_t **data, uint32_t *len, void *u)
{
    (void)u;
    char path[64];
    const char *pfx = "/OS/Library/";
    int i = 0;
    while (pfx[i]) { path[i] = pfx[i]; i++; }
    int j = 0;
    while (name[j] && i < (int)sizeof(path) - 1) path[i++] = name[j++];
    path[i] = 0;
    return romfs_lookup(path, data, len);
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
    p->used = 0;                                 /* reap the slot (cached image stays resident) */
    return code;
}
