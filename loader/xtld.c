/*
 * xtld — the XTOS dynamic loader (portable core). See xtld.h.
 *
 * Deliberately minimal, matching the co-designed relocation model in
 * docs/OS/dynamic-loading.md §3: eager binding, no lazy PLT, three relocation
 * types. ARM uses REL (Elf32_Rel) — addends live in-place at the target.
 */
#include "xtld.h"
#include <string.h>

/* ---- ELF32 little-endian definitions (only what we use) ---------------- */

typedef uint32_t Elf32_Addr;
typedef uint32_t Elf32_Word;
typedef int32_t  Elf32_Sword;
typedef uint16_t Elf32_Half;
typedef uint32_t Elf32_Off;

typedef struct {
    unsigned char e_ident[16];
    Elf32_Half e_type;
    Elf32_Half e_machine;
    Elf32_Word e_version;
    Elf32_Addr e_entry;
    Elf32_Off  e_phoff;
    Elf32_Off  e_shoff;
    Elf32_Word e_flags;
    Elf32_Half e_ehsize;
    Elf32_Half e_phentsize;
    Elf32_Half e_phnum;
    Elf32_Half e_shentsize;
    Elf32_Half e_shnum;
    Elf32_Half e_shstrndx;
} Elf32_Ehdr;

typedef struct {
    Elf32_Word p_type;
    Elf32_Off  p_offset;
    Elf32_Addr p_vaddr;
    Elf32_Addr p_paddr;
    Elf32_Word p_filesz;
    Elf32_Word p_memsz;
    Elf32_Word p_flags;
    Elf32_Word p_align;
} Elf32_Phdr;

typedef struct {
    Elf32_Sword d_tag;
    Elf32_Word  d_val; /* union d_val / d_ptr */
} Elf32_Dyn;

typedef struct {
    Elf32_Word    st_name;
    Elf32_Addr    st_value;
    Elf32_Word    st_size;
    unsigned char st_info;
    unsigned char st_other;
    Elf32_Half    st_shndx;
} Elf32_Sym;

typedef struct {
    Elf32_Addr r_offset;
    Elf32_Word r_info;
} Elf32_Rel;

#define EI_CLASS 4
#define EI_DATA  5
#define ELFCLASS32  1
#define ELFDATA2LSB 1
#define ET_DYN  3
#define EM_ARM  40

#define PT_LOAD    1
#define PT_DYNAMIC 2

#define DT_NULL          0
#define DT_NEEDED        1
#define DT_HASH          4
#define DT_STRTAB        5
#define DT_SYMTAB        6
#define DT_STRSZ        10
#define DT_SYMENT       11
#define DT_REL          17
#define DT_RELSZ        18
#define DT_RELENT       19
#define DT_PLTREL       20
#define DT_JMPREL       23
#define DT_PLTRELSZ      2
#define DT_INIT_ARRAY   25
#define DT_INIT_ARRAYSZ 27
#define DT_SONAME       14

#define SHN_UNDEF 0

#define ELF32_R_SYM(i)  ((i) >> 8)
#define ELF32_R_TYPE(i) ((i) & 0xff)
#define ELF32_ST_BIND(i) ((i) >> 4)
#define STB_WEAK 2

#define R_ARM_ABS32     2
#define R_ARM_GLOB_DAT  21
#define R_ARM_JUMP_SLOT 22
#define R_ARM_RELATIVE  23

#define PAGE 0x1000u

/* ---- handle ------------------------------------------------------------ */

struct xtld_obj {
    xtld_host host;
    uint8_t  *image;       /* allocated load region */
    size_t    span;        /* its size */
    uintptr_t bias;        /* load bias: where vaddr (min_aligned) landed */
    Elf32_Addr entry;      /* e_entry */

    const Elf32_Sym *symtab;
    const char      *strtab;
    uint32_t         symcount;

    const Elf32_Addr *init_array;
    uint32_t          init_count;

    const char       *soname;     /* DT_SONAME — registry key, or NULL */
    int               refcount;

    uintptr_t wseg_va;            /* writable (data/bss) PT_LOAD: runtime VA + size, */
    uint32_t  wseg_size;          /* for per-process private-data mapping (vm.c) */
};

/* ---- loaded-object registry (for cross-module symbol resolution + dedup) -- */

#define XTLD_MAX_OBJS 16
static xtld_obj *g_objs[XTLD_MAX_OBJS];
static int       g_nobjs;

static xtld_obj *reg_find(const char *soname)
{
    if (!soname) return NULL;
    for (int i = 0; i < g_nobjs; i++)
        if (g_objs[i]->soname && strcmp(g_objs[i]->soname, soname) == 0)
            return g_objs[i];
    return NULL;
}

static uintptr_t reg_resolve(const char *name)
{
    for (int i = 0; i < g_nobjs; i++) {
        uintptr_t a = xtld_sym(g_objs[i], name);
        if (a) return a;
    }
    return 0;
}

/* ---- small helpers ----------------------------------------------------- */

static int u_align(size_t v, size_t a) { return a ? (size_t)((v + a - 1) & ~(a - 1)) : v; }

static void copy_err(char *buf, size_t len, const char *msg)
{
    if (!buf || !len) return;
    size_t n = strlen(msg);
    if (n >= len) n = len - 1;
    memcpy(buf, msg, n);
    buf[n] = 0;
}

/* ---- load -------------------------------------------------------------- */

int xtld_load(const uint8_t *image, size_t image_len,
              const xtld_host *host, xtld_obj **out,
              char *errbuf, size_t errlen)
{
    if (errbuf && errlen) errbuf[0] = 0;
    if (!image || image_len < sizeof(Elf32_Ehdr) || !host || !out)
        return XTLD_E_FORMAT;

    const Elf32_Ehdr *eh = (const Elf32_Ehdr *)image;
    if (!(eh->e_ident[0] == 0x7f && eh->e_ident[1] == 'E' &&
          eh->e_ident[2] == 'L' && eh->e_ident[3] == 'F'))
        return XTLD_E_FORMAT;
    if (eh->e_ident[EI_CLASS] != ELFCLASS32 ||
        eh->e_ident[EI_DATA]  != ELFDATA2LSB)
        return XTLD_E_CLASS;
    if (eh->e_type != ET_DYN || eh->e_machine != EM_ARM)
        return XTLD_E_CLASS;
    if ((size_t)eh->e_phoff + (size_t)eh->e_phnum * eh->e_phentsize > image_len)
        return XTLD_E_TRUNCATED;

    const Elf32_Phdr *ph = (const Elf32_Phdr *)(image + eh->e_phoff);

    /* 1. compute the span over PT_LOAD segments */
    Elf32_Addr min_v = 0xffffffffu, max_v = 0;
    Elf32_Addr dyn_vaddr = 0; uint32_t dyn_sz = 0;
    int have_load = 0, have_dyn = 0;
    for (int i = 0; i < eh->e_phnum; i++) {
        const Elf32_Phdr *p = &ph[i];
        if (p->p_type == PT_LOAD) {
            have_load = 1;
            if (p->p_vaddr < min_v) min_v = p->p_vaddr;
            if (p->p_vaddr + p->p_memsz > max_v) max_v = p->p_vaddr + p->p_memsz;
        } else if (p->p_type == PT_DYNAMIC) {
            have_dyn = 1; dyn_vaddr = p->p_vaddr; dyn_sz = p->p_memsz;
        }
    }
    if (!have_load) return XTLD_E_FORMAT;
    if (!have_dyn)  return XTLD_E_DYNAMIC;

    Elf32_Addr lo = min_v & ~(PAGE - 1);
    size_t span = u_align(max_v - lo, PAGE);

    /* 2. allocate the image region */
    uint8_t *base = host->alloc ? host->alloc(span, PAGE, host->user) : NULL;
    if (!base) return XTLD_E_NOMEM;
    memset(base, 0, span);
    uintptr_t bias = (uintptr_t)base - lo;

    /* 3. copy PT_LOAD segments (bss is already zero), noting the writable one */
    uintptr_t wseg_va = 0; uint32_t wseg_size = 0;
    for (int i = 0; i < eh->e_phnum; i++) {
        const Elf32_Phdr *p = &ph[i];
        if (p->p_type != PT_LOAD) continue;
        if ((size_t)p->p_offset + p->p_filesz > image_len) {
            if (host->dealloc) host->dealloc(base, host->user);
            return XTLD_E_TRUNCATED;
        }
        memcpy((void *)(bias + p->p_vaddr), image + p->p_offset, p->p_filesz);
        if (p->p_flags & 0x2 /* PF_W */) { wseg_va = bias + p->p_vaddr; wseg_size = p->p_memsz; }
    }

    /* 4. parse PT_DYNAMIC (its contents now live in the loaded image) */
    const Elf32_Dyn *dyn = (const Elf32_Dyn *)(bias + dyn_vaddr);
    (void)dyn_sz;
    const Elf32_Sym *symtab = NULL;
    const char      *strtab = NULL;
    const Elf32_Rel *rel = NULL;       uint32_t rel_sz = 0, rel_ent = sizeof(Elf32_Rel);
    const Elf32_Rel *jmprel = NULL;    uint32_t jmprel_sz = 0;
    const Elf32_Addr *init_array = NULL; uint32_t init_sz = 0;
    const uint32_t  *hash = NULL;
    uint32_t soname_off = 0; int have_soname = 0;
    uint32_t needed_off[16]; int nneeded = 0;

    for (const Elf32_Dyn *d = dyn; d->d_tag != DT_NULL; d++) {
        switch (d->d_tag) {
        case DT_SYMTAB:        symtab = (const Elf32_Sym *)(bias + d->d_val); break;
        case DT_STRTAB:        strtab = (const char *)(bias + d->d_val); break;
        case DT_HASH:          hash = (const uint32_t *)(bias + d->d_val); break;
        case DT_REL:           rel = (const Elf32_Rel *)(bias + d->d_val); break;
        case DT_RELSZ:         rel_sz = d->d_val; break;
        case DT_RELENT:        rel_ent = d->d_val; break;
        case DT_JMPREL:        jmprel = (const Elf32_Rel *)(bias + d->d_val); break;
        case DT_PLTRELSZ:      jmprel_sz = d->d_val; break;
        case DT_INIT_ARRAY:    init_array = (const Elf32_Addr *)(bias + d->d_val); break;
        case DT_INIT_ARRAYSZ:  init_sz = d->d_val; break;
        case DT_SONAME:        soname_off = d->d_val; have_soname = 1; break;
        case DT_NEEDED:        if (nneeded < 16) needed_off[nneeded++] = d->d_val; break;
        default: break;
        }
    }
    if (!symtab || !strtab) {
        if (host->dealloc) host->dealloc(base, host->user);
        return XTLD_E_DYNAMIC;
    }
    /* symbol count from the SysV hash table (nchain). Built with
     * --hash-style=sysv so DT_HASH is present. */
    uint32_t symcount = hash ? hash[1] /* nchain */ : 0;
    const char *soname = have_soname ? (strtab + soname_off) : NULL;

    /* 4b. load DT_NEEDED shared libraries BEFORE relocating, so this object's
     * imports resolve against them. Each is loaded once (deduped by soname) and
     * refcounted; a freshly-loaded dep is initialised before we use it. */
    for (int k = 0; k < nneeded; k++) {
        const char *depname = strtab + needed_off[k];
        xtld_obj *dep = reg_find(depname);
        if (dep) { dep->refcount++; continue; }
        const uint8_t *dimg = NULL; uint32_t dlen = 0;
        if (!host->open_lib || !host->open_lib(depname, &dimg, &dlen, host->user)) {
            copy_err(errbuf, errlen, depname);
            if (host->dealloc) host->dealloc(base, host->user);
            return XTLD_E_UNDEF;
        }
        int drc = xtld_load(dimg, dlen, host, &dep, errbuf, errlen);
        if (drc != XTLD_OK) {
            if (host->dealloc) host->dealloc(base, host->user);
            return drc;
        }
        xtld_run_init(dep);
    }

    /* 5. apply relocations: DT_REL then DT_JMPREL (both Elf32_Rel) */
    const Elf32_Rel *tables[2] = { rel, jmprel };
    uint32_t sizes[2]          = { rel_sz, jmprel_sz };
    for (int t = 0; t < 2; t++) {
        const Elf32_Rel *r = tables[t];
        if (!r) continue;
        uint32_t n = sizes[t] / rel_ent;
        for (uint32_t i = 0; i < n; i++, r = (const Elf32_Rel *)((const uint8_t *)r + rel_ent)) {
            uint32_t type = ELF32_R_TYPE(r->r_info);
            uint32_t si   = ELF32_R_SYM(r->r_info);
            uint32_t *P   = (uint32_t *)(bias + r->r_offset);
            uint32_t  A   = *P;  /* in-place addend (REL) */

            if (type == R_ARM_RELATIVE) {
                *P = (uint32_t)bias + A;
                continue;
            }
            if (type == R_ARM_ABS32 || type == R_ARM_GLOB_DAT ||
                type == R_ARM_JUMP_SLOT) {
                const Elf32_Sym *s = &symtab[si];
                const char *name = strtab + s->st_name;
                uint32_t S;
                if (s->st_shndx != SHN_UNDEF) {
                    S = (uint32_t)bias + s->st_value;   /* defined here */
                } else {
                    /* loaded libraries first (NEEDED + everything resident),
                     * then the kernel export table */
                    uintptr_t r2 = reg_resolve(name);
                    if (!r2 && host->resolve) r2 = host->resolve(name, host->user);
                    if (!r2 && ELF32_ST_BIND(s->st_info) != STB_WEAK) {
                        copy_err(errbuf, errlen, name);
                        if (host->dealloc) host->dealloc(base, host->user);
                        return XTLD_E_UNDEF;
                    }
                    S = (uint32_t)r2;   /* weak unresolved -> 0 (allowed) */
                }
                /* ABS32 keeps the in-place addend. GLOB_DAT/JUMP_SLOT *set* the
                 * slot to S: their in-place value is not an addend — for
                 * JUMP_SLOT it's the lazy PLT-stub address, which must be
                 * overwritten, not added. (Thumb T-bit not handled — A32
                 * codegen; see dynamic-loading.md.) */
                *P = (type == R_ARM_ABS32) ? (S + A) : S;
                continue;
            }
            copy_err(errbuf, errlen, "unsupported reloc type");
            if (host->dealloc) host->dealloc(base, host->user);
            return XTLD_E_RELOC;
        }
    }

    /* 6. cache maintenance so the image is coherent for execution */
    if (host->sync_caches) host->sync_caches(base, span, host->user);

    /* 7. publish the handle. Stored inside the host heap, not the image. */
    xtld_obj *obj = host->alloc ? host->alloc(sizeof(*obj), 16, host->user) : NULL;
    if (!obj) { if (host->dealloc) host->dealloc(base, host->user); return XTLD_E_NOMEM; }
    memset(obj, 0, sizeof(*obj));
    obj->host       = *host;
    obj->image      = base;
    obj->span       = span;
    obj->bias       = bias;
    obj->entry      = eh->e_entry;
    obj->wseg_va    = wseg_va;
    obj->wseg_size  = wseg_size;
    obj->symtab     = symtab;
    obj->strtab     = strtab;
    obj->symcount   = symcount;
    obj->init_array = init_array;
    obj->init_count = init_array ? init_sz / sizeof(Elf32_Addr) : 0;
    obj->soname     = soname;
    obj->refcount   = 1;
    if (g_nobjs < XTLD_MAX_OBJS) g_objs[g_nobjs++] = obj;   /* register for resolution + dedup */
    *out = obj;
    return XTLD_OK;
}

uintptr_t xtld_sym(const xtld_obj *obj, const char *name)
{
    if (!obj || !name) return 0;
    for (uint32_t i = 0; i < obj->symcount; i++) {
        const Elf32_Sym *s = &obj->symtab[i];
        if (s->st_shndx == SHN_UNDEF) continue;
        if (strcmp(obj->strtab + s->st_name, name) == 0)
            return obj->bias + s->st_value;
    }
    return 0;
}

void xtld_run_init(const xtld_obj *obj)
{
    if (!obj || !obj->init_array) return;
    for (uint32_t i = 0; i < obj->init_count; i++) {
        /* .init_array entries carry R_ARM_RELATIVE relocations, so by now they
         * are already absolute runtime addresses — do NOT add the bias again. */
        Elf32_Addr fn = obj->init_array[i];
        if (fn == 0 || fn == 0xffffffffu) continue;
        ((void (*)(void))(uintptr_t)fn)();
    }
}

uintptr_t xtld_entry(const xtld_obj *obj)
{
    return (obj && obj->entry) ? obj->bias + obj->entry : 0;
}

uintptr_t xtld_base(const xtld_obj *obj) { return obj ? obj->bias : 0; }
size_t    xtld_span(const xtld_obj *obj) { return obj ? obj->span : 0; }

void xtld_writable_range(const xtld_obj *obj, uintptr_t *va, uint32_t *size)
{
    if (va)   *va   = obj ? obj->wseg_va : 0;
    if (size) *size = obj ? obj->wseg_size : 0;
}
uint32_t  xtld_init_count(const xtld_obj *obj) { return obj ? obj->init_count : 0; }

void xtld_unload(xtld_obj *obj)
{
    if (!obj) return;
    if (--obj->refcount > 0) return;             /* still in use */
    for (int i = 0; i < g_nobjs; i++)            /* drop from the registry */
        if (g_objs[i] == obj) { g_objs[i] = g_objs[--g_nobjs]; break; }
    /* (DT_FINI_ARRAY + transitive dep unload are follow-ups.) */
    xtld_free(obj);
}

void xtld_free(xtld_obj *obj)
{
    if (!obj) return;
    void (*dealloc)(void *, void *) = obj->host.dealloc;
    void *user = obj->host.user;
    if (dealloc) { dealloc(obj->image, user); dealloc(obj, user); }
}

const char *xtld_strerror(int code)
{
    switch (code) {
    case XTLD_OK:          return "ok";
    case XTLD_E_FORMAT:    return "not a valid ELF";
    case XTLD_E_CLASS:     return "not ELFCLASS32/LSB/EM_ARM/ET_DYN";
    case XTLD_E_NOMEM:     return "allocation failed";
    case XTLD_E_DYNAMIC:   return "missing/malformed PT_DYNAMIC";
    case XTLD_E_RELOC:     return "unsupported relocation type";
    case XTLD_E_UNDEF:     return "undefined symbol";
    case XTLD_E_TRUNCATED: return "image truncated";
    default:               return "unknown error";
    }
}
