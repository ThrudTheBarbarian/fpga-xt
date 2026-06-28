/*
 * xtld — the XTOS dynamic loader (portable core).
 *
 * Loads an ELF ET_DYN image (PIE app or .so library) for arm32 (EM_ARM,
 * ELFCLASS32, little-endian) into a flat address space: copy PT_LOAD segments,
 * apply the three relocation types the model uses (R_ARM_RELATIVE /
 * R_ARM_GLOB_DAT / R_ARM_ABS32, plus R_ARM_JUMP_SLOT), resolve undefined
 * symbols via a caller-supplied resolver, and run DT_INIT_ARRAY.
 *
 * No OS dependencies: the host supplies allocation, cache maintenance, and
 * symbol resolution through xtld_host. The same code runs in the host testbed
 * (cache ops are no-ops, resolver is a test table) and, later, in the XTOS
 * kernel (kernel allocator + Xil_DCacheFlushRange/Xil_ICacheInvalidateRange +
 * the curated export table).
 *
 * See docs/OS/dynamic-loading.md §3/§5.
 */
#ifndef XTLD_H
#define XTLD_H

#include <stddef.h>
#include <stdint.h>

typedef struct xtld_obj xtld_obj;

typedef struct {
    /* Allocate `size` bytes aligned to `align` for the loaded image.
     * On target this is the loadable-image arena; on host, aligned malloc. */
    void *(*alloc)(size_t size, size_t align, void *user);
    /* Free a region returned by alloc (may be NULL if alloc never fails). */
    void (*dealloc)(void *ptr, void *user);
    /* Make `len` bytes at `addr` coherent for execution: D-cache flush +
     * I-cache invalidate. No-op on the host. */
    void (*sync_caches)(void *addr, size_t len, void *user);
    /* Resolve an undefined symbol by name to its absolute address, or 0 if
     * unknown. Tried after the loaded-object registry; 0 here too = load fails
     * with XTLD_E_UNDEF. This is the curated kernel export table. */
    uintptr_t (*resolve)(const char *name, void *user);
    /* Open a DT_NEEDED shared library by name -> its ELF image bytes (e.g. from
     * the filesystem). Return 1 on success. NULL = no shared-library support. */
    int (*open_lib)(const char *name, const uint8_t **data, uint32_t *len, void *user);
    void *user;
} xtld_host;

enum {
    XTLD_OK            =  0,
    XTLD_E_FORMAT      = -1,  /* not a valid ELF we accept */
    XTLD_E_CLASS       = -2,  /* not ELFCLASS32 / LSB / EM_ARM / ET_DYN */
    XTLD_E_NOMEM       = -3,  /* host alloc failed */
    XTLD_E_DYNAMIC     = -4,  /* missing / malformed PT_DYNAMIC */
    XTLD_E_RELOC       = -5,  /* unsupported relocation type */
    XTLD_E_UNDEF       = -6,  /* undefined symbol, resolver returned 0 */
    XTLD_E_TRUNCATED   = -7,  /* offsets run past the image buffer */
};

/* Load an ET_DYN image held entirely in `image[0..image_len)`.
 * On success *out receives a handle and XTLD_OK is returned.
 * On failure a negative XTLD_E_* is returned; if errbuf!=NULL a short
 * human message (e.g. the undefined symbol name) is written there. */
int  xtld_load(const uint8_t *image, size_t image_len,
               const xtld_host *host, xtld_obj **out,
               char *errbuf, size_t errlen);

/* Address of an exported (defined, dynsym) symbol, or 0 if not found. */
uintptr_t xtld_sym(const xtld_obj *obj, const char *name);

/* Run DT_INIT_ARRAY constructors (call once, after load). */
void xtld_run_init(const xtld_obj *obj);

/* The image's entry point (e_entry + load bias), or 0 if e_entry==0. */
uintptr_t xtld_entry(const xtld_obj *obj);

/* The load bias (where vaddr 0 landed). */
uintptr_t xtld_base(const xtld_obj *obj);

/* Span of the loaded image in bytes (for diagnostics / cache range). */
size_t xtld_span(const xtld_obj *obj);

/* Base address of the loaded image (runtime). text/rodata = [base, writable_va);
 * used for W^X (mark text read-only, the writable segment execute-never). */
uintptr_t xtld_image_base(const xtld_obj *obj);

/* The writable (data/bss) PT_LOAD segment's runtime VA + size — for per-process
 * private-data mapping (each process gets its own copy of these pages). */
void xtld_writable_range(const xtld_obj *obj, uintptr_t *va, uint32_t *size);

/* Number of DT_INIT_ARRAY constructors discovered (diagnostics). */
uint32_t xtld_init_count(const xtld_obj *obj);

/* Drop a reference; the object (and, transitively, nothing else for now) is
 * freed when its refcount hits zero. Shared libraries are loaded once and
 * refcounted across dependents. */
void xtld_unload(xtld_obj *obj);

void xtld_free(xtld_obj *obj);

const char *xtld_strerror(int code);

#endif /* XTLD_H */
