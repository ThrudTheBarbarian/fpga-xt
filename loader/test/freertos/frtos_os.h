/* XTOS-on-FreeRTOS OS layer (frtos_os.c). */
#ifndef FRTOS_OS_H
#define FRTOS_OS_H
#include <stdint.h>
#include <stddef.h>
#include "xtld.h"
struct xt_blit_cmd;   /* fwd — the /dev/blitter ABI lives in xtsys.h; do NOT include it
                       * here, or every kernel file pulls in the whole syscall ABI. */

/* T2-b: per-process heap window (mapped per-process to private physical by vm.c;
 * libc's _sbrk hands out of it for the current process). 1 section for now. */
#define XTOS_HEAP_VA   0x10000000u
#define XTOS_HEAP_SIZE 0x00800000u   /* 8 MB: GUI procs need several MB of backing surfaces.
                                      * (The desktop's full-screen back-buffer is NOT here — it
                                      * composites into the cacheable WALLPAPER_BASE region.) */
/* T2-c: synthetic copy-on-write demo window (one page, shared-RO -> private on
 * first write). The kernel never touches it, so no global TLB shadow on HW. */
#define XTOS_COW_VA    0x11000000u
#define XTOS_COW_SIZE  0x00001000u
/* per-process mmap window: files (romfs, page-aligned) mapped READ-ONLY + shared,
 * demand-paged on first touch. One section; bump-allocated per process. */
#define XTOS_MMAP_VA   0x12000000u
#define XTOS_MMAP_SIZE 0x00100000u
/* shared-memory window: pool-backed pages mapped PL0-RW into one or more spaces at a VA
 * allocated when the object is CREATED and recorded on it (so it is still the same VA in
 * every mapper -> portable pointers), refcounted, freed when the last mapper drops. The
 * IPC substrate for the fs service + mmap-style file pages (docs/OS/fs-pagecache.md), and
 * the backing store for GEM window surfaces.
 *
 * The window used to sit at 0x1300_0000 — INSIDE the page pool's identity range — and was
 * carved into NSHM fixed 1 MB slots, which capped every object at 1 MB. That cap was fatal
 * for a window server (a 640x400 backing store is already 1.02 MiB), and the placement was
 * worse: XTOS_POOL_FLOOR is the top of the per-process window band, dpage_raw SKIPS that
 * band, so every megabyte of shm VA cost a megabyte of DDR the pool could never use.
 *
 * It now lives in UNUSED VA above DDR (1 GB ends at 0x4000_0000) and below the MMIO the PL
 * and PS peripherals occupy (GP0 @0x43C0_xxxx, PS periphs @0xE000_0000, SLCR @0xF800_0000).
 * VA there is free, so the window can be large at zero cost in RAM. */
#define XTOS_SHM_VA    0x50000000u
#define XTOS_SHM_SIZE  0x10000000u   /* 256 MB of VA — costs no DDR; objects are section-allocated */
/* The page pool is IDENTITY-mapped, but the per-process windows OVERRIDE those VAs
 * per-process. So a pool page whose physical falls in the window band is reachable by its
 * identity VA ONLY in the master space — in a process's space that VA is its private
 * window, not the pool page. The fd page-cache fill runs in the CLIENT space and would
 * write the wrong page (corrupting the file AND spraying data into that process). So
 * dpage_raw SKIPS the band, and fd_page() has a fail-loud tripwire on it.
 *
 * The band must span every window that remaps a VA to DIFFERENT physical:
 *
 *     HEAP  0x1000_0000 + 8 MB   -> 0x1080_0000
 *     COW   0x1100_0000 + 4 KB
 *     MMAP  0x1200_0000 + 1 MB   -> 0x1210_0000   <- the top
 *
 * (The stack arena is static kernel BSS, identity-mapped, so it is not a window. The shm
 * window USED to be the top of this band, at 0x1300_0000–0x1400_0000; it has moved out to
 * unused VA above DDR, which is why the floor drops.)
 *
 * This must be defined from the WINDOWS, not from the shm window: shm now lives at
 * 0x5000_0000, and `SHM_VA + SHM_SIZE` would put the floor at 0x6000_0000 — the pool would
 * skip its entire range and starve on the first allocation.
 *
 * The band shrinks 64 MB -> 33 MB, handing ~31 MB of DDR back to the pool: frames whose
 * identity VA lies in 0x1210_0000..0x1400_0000 are no longer shadowed by anything, so they
 * are now usable. (vm.c calls the band "TEMPORARY"; the real fix is a physical page map.) */
#define XTOS_POOL_FLOOR (XTOS_MMAP_VA + XTOS_MMAP_SIZE)   /* 0x1210_0000 */
/* TTBR0 cacheable-walk attributes (short descriptor): inner+outer Write-Back
 * Write-Allocate, non-shared. OR'd into the table base whenever TTBR0 is written
 * (mmu_init, vm_switch) so page-table walks go through the D-cache and stay
 * coherent with our cacheable PTE writes. (IRGN[0]=bit6, RGN=bits[4:3].) */
#define XTOS_TTBR_ATTR 0x48u
void mmu_sync_caches(void *addr, unsigned long len, void *user);  /* xtld_host.sync_caches */

/* short critical section by masking IRQ — serialises the page allocator (abort
 * context) against kern_sbrk (task context) on this single core. Save/restore the
 * full control byte (read in the same mode) so it's safe from any context. */
static inline unsigned xt_irq_save(void)
{ unsigned f; __asm__ volatile("mrs %0,cpsr" : "=r"(f)); __asm__ volatile("cpsid i" ::: "memory"); return f; }
static inline void xt_irq_restore(unsigned f)
{ __asm__ volatile("msr cpsr_c,%0" :: "r"(f) : "memory"); }
void vm_set_libc(uintptr_t wva, uint32_t wsize, const void *snapshot);
void vm_cow_init(void);
void vm_cow_register(uint32_t va, uint32_t size, uint32_t src);
void vm_cow_reset_dynamic(void);    /* drop library COW ranges (keep synthetic+libc) for rebuild */
uint32_t vm_cow_count(void);
int  vm_cow_map(int idx, uint32_t va);
int  vm_cow_read_fault(int idx, uint32_t va);   /* READ permission fault in a COW range: stale-TLB / unseeded page */
int  vm_exec_fault(int idx, uint32_t va);       /* PREFETCH permission fault: stale-section-shadow -> TLBIALL + re-run */
int  vm_demand_map(int idx, uint32_t va);
uint32_t vm_mmap(int idx, uint32_t src, uint32_t size);   /* map a romfs file RO+shared -> VA */
uint32_t vm_mmap_install(int idx, void **pages, uint32_t npg, int writable, uint32_t fd, uint32_t foff);
int      vm_mmap_write_fault(int idx, uint32_t va);   /* RW mmap write-fault: flip RW + mark dirty */
int      vm_mmap_dirty_plan(int idx, uint32_t va, uint32_t *fd, void **pages, uint32_t *foffs, int max);
int  vm_mmap_fault(int idx, uint32_t va);                 /* demand-page an mmap'd file page */
int  vm_munmap(int idx, uint32_t va, uint32_t size);
int      vm_shm_create(uint32_t size, uint32_t flags);  /* flags: XT_SHM_* (xtsys.h) */            /* alloc pool pages for an shm -> id (-1 fail) */
uint32_t vm_shm_map(int idx, int id);             /* map shm `id` PL0-RW into space idx -> VA (0 fail) */
void    *vm_shm_kaddr(int id);                    /* shm's first page by pool IDENTITY addr (PL1, no map) */
void    *vm_page_alloc(void);                     /* raw pool page (fs page cache); identity, uncharged */
void     vm_page_free(void *p);                   /* return a vm_page_alloc page to the pool */
void     vm_shm_drop_space(int idx);              /* drop all shm refs a space held (reap) */
int      vm_shm_unmap(int idx, int id);           /* drop ONE mapping + ref, while alive (§11) */
uint32_t vm_shm_phys(int id, uint32_t *size);     /* physical base of a CONTIG surface (0 if not) */
int      frtos_current_pid(void);                 /* calling process's pid, or -1 in kernel ctx */
int      blit_declare(int id, uint32_t stride);   /* /dev/blitter: a surface's row stride */
long     blit_submit(const struct xt_blit_cmd *c, int priority);
uint32_t blit_seq(void);                          /* the engine's RETIRED sequence number */
uint32_t *vm_space_create(int idx, uint32_t prog_va, uint32_t prog_size, uint32_t prog_src);
void vm_space_destroy(int idx);     /* reclaim a dead space's private pages to the pool */
void vm_sync_loaded_sections(void); /* adopt master section splits into every space L1 (post-load) */
void vm_phys_init(uint32_t top);    /* announce the arena top; page pool grows down from it */
uint32_t vm_page_floor(void);       /* page-pool frontier = libc sbrk ceiling */
uint32_t vm_pages_free(void);       /* pages available now (free list + frontier gap) */
uint32_t vm_pages_inuse(void);      /* pages currently handed out (reclaim metric) */

void ksys_set_console(void (*w)(const char *, int));
void *frtos_alloc(size_t size, size_t align, void *user);
void  frtos_free(void *p, void *user);
void  frtos_activate_libc(xtld_obj *libc);   /* after the loader loads libc.so */
int  frtos_spawn(const uint8_t *image, uint32_t len, int argc, char **argv, const xtld_host *host);
int  frtos_spawn_path(const char *path, const xtld_host *host);
int  frtos_spawn_argv(const char *path, int argc, char **argv, const xtld_host *host);
/* SYS_spawn_fd: stdfds[3] = spawner fds for the child's 0/1/2 (pipe ends; -1 = console) */
int  frtos_spawn_argv_fds(const char *path, int argc, char **argv, char **envp,
                          const xtld_host *host, const int *stdfds);
/* procfs: snapshot proc-table slot idx (0 = free; else the pid) */
int  frtos_proc_snap(int idx, char *comm, int commsz, char *cmdl, int cmdsz,
                     int *cmdlen, int *state);
/* procfs: kernel resource limits -> /OS/proc/limits. cur = live now (scanned),
 * max = the compile-time table size, hwm = peak live count seen (0 where untracked). */
typedef struct {
    int proc_cur, proc_max, proc_hwm;   /* process table (g_proc[MAXPROC]) */
    int pipe_cur, pipe_max, pipe_hwm;   /* pipe pool (g_pipes[MAXPIPE]) */
    int prog_cur, prog_max;             /* cached program images (g_prog[MAXPROG]) */
    int fd_cur, fd_cap, fd_busiest;     /* open fds: total, per-process cap, busiest proc */
} xt_limits_t;
void frtos_limits(xt_limits_t *L);
int  frtos_spawn_host(const char *hostpath, int argc, char **argv, const xtld_host *host);
int  frtos_open_lib(const char *name, const uint8_t **data, uint32_t *len, void *user);
void frtos_lib_path_set(const char *const *dirs, int n);  /* loader lib search path (default /OS/library/) */
void frtos_on_loaded(xtld_obj *obj, void *user);   /* xtld_host.on_loaded: W^X + PL0 */
uintptr_t frtos_ksym(const char *name, void *user);
int  frtos_waitpid(int pid);
void frtos_fs_start(void);          /* stand up the fs service task + request channel */
uint32_t frtos_prog_loads(void);   /* distinct program images loaded (vs spawns) */
#endif
