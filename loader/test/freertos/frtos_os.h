/* XTOS-on-FreeRTOS OS layer (frtos_os.c). */
#ifndef FRTOS_OS_H
#define FRTOS_OS_H
#include <stdint.h>
#include <stddef.h>
#include "xtld.h"

/* T2-b: per-process heap window (mapped per-process to private physical by vm.c;
 * libc's _sbrk hands out of it for the current process). 1 section for now. */
#define XTOS_HEAP_VA   0x10000000u
#define XTOS_HEAP_SIZE 0x00800000u   /* 8 MB: GUI procs need several MB of backing surfaces */
/* T2-c: synthetic copy-on-write demo window (one page, shared-RO -> private on
 * first write). The kernel never touches it, so no global TLB shadow on HW. */
#define XTOS_COW_VA    0x11000000u
#define XTOS_COW_SIZE  0x00001000u
/* per-process mmap window: files (romfs, page-aligned) mapped READ-ONLY + shared,
 * demand-paged on first touch. One section; bump-allocated per process. */
#define XTOS_MMAP_VA   0x12000000u
#define XTOS_MMAP_SIZE 0x00100000u
/* shared-memory window: pool-backed pages mapped PL0-RW into one or more spaces at a
 * per-id VA slot (same VA in every mapper -> portable pointers), refcounted, freed
 * when the last mapper drops. The IPC substrate for the fs service + mmap-style file
 * pages (docs/OS/fs-pagecache.md). NSHM ids, one 1 MB VA slot each. */
#define XTOS_SHM_VA    0x13000000u
#define XTOS_SHM_SIZE  0x01000000u   /* 16 MB window = NSHM * 1 MB slots */
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
int  vm_demand_map(int idx, uint32_t va);
uint32_t vm_mmap(int idx, uint32_t src, uint32_t size);   /* map a file RO+shared -> VA */
int  vm_mmap_fault(int idx, uint32_t va);                 /* demand-page an mmap'd file page */
int  vm_munmap(int idx, uint32_t va, uint32_t size);
int      vm_shm_create(uint32_t size);            /* alloc pool pages for an shm -> id (-1 fail) */
uint32_t vm_shm_map(int idx, int id);             /* map shm `id` PL0-RW into space idx -> VA (0 fail) */
void    *vm_shm_kaddr(int id);                    /* shm's first page by pool IDENTITY addr (PL1, no map) */
void     vm_shm_drop_space(int idx);              /* drop all shm refs a space held (reap) */
uint32_t *vm_space_create(int idx, uint32_t prog_va, uint32_t prog_size, uint32_t prog_src);
void vm_space_destroy(int idx);     /* reclaim a dead space's private pages to the pool */
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
int  frtos_spawn_host(const char *hostpath, int argc, char **argv, const xtld_host *host);
int  frtos_open_lib(const char *name, const uint8_t **data, uint32_t *len, void *user);
void frtos_lib_path_set(const char *const *dirs, int n);  /* loader lib search path (default /OS/Library/) */
void frtos_on_loaded(xtld_obj *obj, void *user);   /* xtld_host.on_loaded: W^X + PL0 */
uintptr_t frtos_ksym(const char *name, void *user);
int  frtos_waitpid(int pid);
void frtos_fs_start(void);          /* stand up the fs service task + request channel */
uint32_t frtos_prog_loads(void);   /* distinct program images loaded (vs spawns) */
#endif
