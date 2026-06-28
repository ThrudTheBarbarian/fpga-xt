/*
 * xtld_host.c — the XTOS host shim for the dynamic loader on real hardware.
 *
 * Wires xtld's portable callbacks to the A9 and brings up the shared-library
 * stack the same way the qemu testbed does, but on metal:
 *   - sync_caches -> Xil_DCacheFlushRange + Xil_ICacheInvalidateRange (the cache
 *     coherency qemu, caches-off, couldn't exercise; proven by HW-1 `ldtest`).
 *   - a pool allocator + pool _sbrk over the 480 MB OS region at 0x0200_0000,
 *     SEPARATE from the kernel's own (Vitis-newlib) 2 MB heap — so libc.so owns
 *     one big heap and the two newlibs never fight over _sbrk.
 *   - a bounded kernel export table (syscall primitives as functions + libgcc
 *     runtime helpers) that loaded modules resolve against; libc.so provides
 *     everything else, and libGEM/programs DT_NEEDED libc.so.
 *   - open_lib + file reads via the kernel's fopen (VFS -> FatFs on SD), so the
 *     .so's + fonts live on the SD card at /OS/Library + /OS/Fonts.
 */
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <malloc.h>
#include <string.h>
#include <stdio.h>
#include "xil_cache.h"
#include "xtld.h"
#include "xtld_test_so.h"

extern void outbyte(char c);                     /* Xilinx BSP low-level stdout */

/* ---- the OS pool: image loads + libc.so's malloc heap live here ----------- */
#define POOL_BASE 0x02000000u
#define POOL_END  0x20000000u
static char *g_pool;                             /* bump for loading .so images */
static char *g_brk, *g_brk_end;                  /* libc.so's _sbrk window */
static void *(*g_libc_memalign)(size_t, size_t);
static void  (*g_libc_free)(void *);

/* ---- kernel-exported syscall primitives (what libc.so imports) ------------ */
void *pool_sbrk(int incr)                        /* libc.so's _sbrk */
{
    if (!g_brk || g_brk + incr > g_brk_end) return (void *)-1;
    char *p = g_brk; g_brk += incr; return p;
}
static int  ld_swrite(int fd, const char *buf, int len)
{ if (fd == 1 || fd == 2) { for (int i = 0; i < len; i++) outbyte(buf[i]); return len; } return -1; }
void xtos_log(const char *s) { ld_swrite(1, s, (int)strlen(s)); }
static void ld_sexit(int code) { (void)code; printf("[xtld] loaded module called _exit\n"); for (;;) {} }

/* romfs-/SD-backed files for libc.so's fopen: delegate to the kernel's stdio
 * (Vitis newlib -> VFS -> FatFs). A small table maps fds 3+ to FILE*. */
#define NFILE 8
static FILE *g_file[NFILE];
static int   ld_sopen(const char *path, int flags, int mode)
{
    (void)flags; (void)mode;
    for (int i = 0; i < NFILE; i++) if (!g_file[i]) {
        FILE *f = fopen(path, "rb"); if (!f) return -1;
        g_file[i] = f; return 3 + i;
    }
    return -1;
}
static int fdx(int fd) { return (fd >= 3 && fd < 3 + NFILE && g_file[fd - 3]) ? fd - 3 : -1; }
static int  ld_sread(int fd, char *buf, int len)
{ int i = fdx(fd); if (i < 0) return -1; return (int)fread(buf, 1, (size_t)len, g_file[i]); }
static int  ld_slseek(int fd, int off, int whence)
{ int i = fdx(fd); if (i < 0) return -1; if (fseek(g_file[i], off, whence)) return -1; return (int)ftell(g_file[i]); }
static int  ld_sclose(int fd) { int i = fdx(fd); if (i < 0) return -1; fclose(g_file[i]); g_file[i] = NULL; return 0; }

static int  s_m1(void) { return -1; }            /* generic -1 stub */
static void s_noop(void) {}
static int  s_getpid(void) { return 1; }
static int  s_jpuc(int c, void *l) { (void)l; return c; }

/* ---- the bounded export table (syscall prims + libgcc helpers) ------------ */
#define K(sym) extern void sym(void);
K(__aeabi_idiv) K(__aeabi_uidiv) K(__aeabi_idivmod) K(__aeabi_uidivmod)
K(__aeabi_ldivmod) K(__aeabi_uldivmod) K(__aeabi_d2lz) K(__aeabi_l2d)
K(__aeabi_unwind_cpp_pr0) K(__ffsdi2) K(__aeabi_f2lz) K(__muldc3) K(__mulsc3)
#undef K

static uintptr_t ld_resolve(const char *name, void *u)
{
    (void)u;
    static const struct { const char *n; void *a; } tab[] = {
        {"xtos_log",(void*)xtos_log},
        /* syscall primitives libc.so imports */
        {"_sbrk",(void*)pool_sbrk},{"_write",(void*)ld_swrite},{"_read",(void*)ld_sread},
        {"_open",(void*)ld_sopen},{"_close",(void*)ld_sclose},{"_lseek",(void*)ld_slseek},
        {"_exit",(void*)ld_sexit},{"_getpid",(void*)s_getpid},{"_isatty",(void*)s_m1},
        {"_fstat",(void*)s_m1},{"_stat",(void*)s_m1},{"_kill",(void*)s_m1},
        {"_gettimeofday",(void*)s_m1},{"_times",(void*)s_m1},{"_link",(void*)s_m1},
        {"_unlink",(void*)s_m1},{"_fork",(void*)s_m1},{"_execve",(void*)s_m1},
        {"_fcntl",(void*)s_m1},{"_getentropy",(void*)s_m1},{"_mkdir",(void*)s_m1},
        {"_wait",(void*)s_m1},{"_init",(void*)s_noop},{"_fini",(void*)s_noop},
        {"_jp2uc_l",(void*)s_jpuc},{"_uc2jp_l",(void*)s_jpuc},
        {"regcomp",(void*)s_m1},{"regexec",(void*)s_m1},{"regfree",(void*)s_noop},
        {"sigprocmask",(void*)s_m1},
        /* libgcc runtime helpers (A9 has no HW divide; FreeType uses float) */
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

/* ---- xtld_host callbacks -------------------------------------------------- */
static void *ld_alloc(size_t size, size_t align, void *u)
{
    (void)u;
    if (g_libc_memalign) return g_libc_memalign(align ? align : 16, size);
    if (!g_pool) g_pool = (char *)POOL_BASE;      /* bootstrap bump (pre-libc.so) */
    uintptr_t a = ((uintptr_t)g_pool + (align - 1)) & ~(uintptr_t)(align - 1);
    g_pool = (char *)a + size;
    return (void *)a;
}
static void ld_free(void *p, void *u) { (void)u; if (g_libc_free) g_libc_free(p); }
static void ld_sync(void *addr, size_t len, void *u)
{ (void)u; Xil_DCacheFlushRange((INTPTR)addr, len); Xil_ICacheInvalidateRange((INTPTR)addr, len); }

static int read_file(const char *path, const uint8_t **out, uint32_t *outlen)
{
    FILE *f = fopen(path, "rb"); if (!f) return 0;
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    if (n <= 0) { fclose(f); return 0; }
    uint8_t *buf = ld_alloc((size_t)n, 16, NULL);
    size_t r = fread(buf, 1, (size_t)n, f); fclose(f);
    *out = buf; *outlen = (uint32_t)r; return r == (size_t)n;
}
static int ld_open_lib(const char *name, const uint8_t **data, uint32_t *len, void *u)
{ (void)u; char path[96]; snprintf(path, sizeof path, "/OS/Library/%s", name); return read_file(path, data, len); }

static xtld_host g_host = { .alloc = ld_alloc, .dealloc = ld_free, .sync_caches = ld_sync,
                            .resolve = ld_resolve, .open_lib = ld_open_lib, .user = NULL };

/* ---- HW-1: trivial embedded .so (loader + caches selftest) ---------------- */
void xtos_ld_selftest(void)
{
    xtld_obj *o = NULL; char err[80] = {0};
    int rc = xtld_load(xtld_test_so, xtld_test_so_len, &g_host, &o, err, sizeof err);
    if (rc != XTLD_OK) { printf("[ldtest] xtld_load FAILED rc=%d (%s)\n", rc, err); return; }
    xtld_run_init(o);
    int (*run)(int, int) = (int (*)(int, int))xtld_sym(o, "run");
    if (!run) { printf("[ldtest] symbol 'run' not found\n"); xtld_unload(o); return; }
    int r = run(20, 22);
    printf("[ldtest] loaded .so on the A9: run(20,22) = %d (expect 42) -> %s\n", r, r == 42 ? "PASS" : "FAIL");
    xtld_unload(o);
}

/* ---- HW-2: bring up libc.so from SD, then run a libc client --------------- */
static xtld_obj *g_libc;
static int libc_up(void)
{
    if (g_libc) return 0;
    const uint8_t *img; uint32_t len; char err[80] = {0};
    if (!read_file("/OS/Library/libc.so", &img, &len)) { printf("libc.so: not found on SD (/OS/Library/)\n"); return -1; }
    int rc = xtld_load(img, len, &g_host, &g_libc, err, sizeof err);
    if (rc != XTLD_OK) { printf("libc.so load FAILED rc=%d (%s)\n", rc, err); g_libc = NULL; return -1; }
    g_libc_memalign = (void *(*)(size_t, size_t))xtld_sym(g_libc, "memalign");
    g_libc_free     = (void (*)(void *))xtld_sym(g_libc, "free");
    uintptr_t brk = ((uintptr_t)g_pool + 0xFFFu) & ~0xFFFu;     /* page-align above image */
    g_brk = (char *)brk; g_brk_end = (char *)POOL_END;
    xtld_run_init(g_libc);
    printf("libc.so loaded + activated (image @ 0x%08lx, sbrk 0x%08lx..0x%08x)\n",
           (unsigned long)xtld_base(g_libc), (unsigned long)brk, POOL_END);
    return 0;
}

void xtos_libc_test(void)
{
    if (libc_up()) return;
    const uint8_t *img; uint32_t len; char err[80] = {0};
    if (!read_file("/OS/Library/libc_test.so", &img, &len)) { printf("libc_test.so not on SD\n"); return; }
    xtld_obj *o = NULL;
    if (xtld_load(img, len, &g_host, &o, err, sizeof err) != XTLD_OK) { printf("libc_test load FAILED: %s\n", err); return; }
    xtld_run_init(o);
    void (*entry)(int, char **) = (void (*)(int, char **))xtld_sym(o, "_app_entry");
    if (!entry) { printf("libc_test: no _app_entry\n"); xtld_unload(o); return; }
    char *argv[1] = { (char *)"libc_test" };
    entry(1, argv);
    xtld_unload(o);
}

/* ---- HW-3: load libGEM.so (real GEM/VDI + FreeType) and render to the live
 * HDMI compositor plane at 0x3000_0000 (the kernel is the client; calls the
 * loaded library via xtld_sym). libGEM pulls libm.so via open_lib and reuses the
 * already-loaded libc.so. Proves the dynamic graphics stack on real pixels. */
#define DESK_BASE   0x30000000u
#define DESK_W      1920
#define DESK_H      1080
#define DESK_STRIDE 2048                         /* words/row (8192 B), per the map */

void xtos_gem_demo(void)
{
    if (libc_up()) return;
    const uint8_t *img; uint32_t len; char err[80] = {0};
    if (!read_file("/OS/Library/libGEM.so", &img, &len)) { printf("libGEM.so not on SD\n"); return; }
    xtld_obj *gem = NULL;
    int rc = xtld_load(img, len, &g_host, &gem, err, sizeof err);   /* pulls libm.so + libc.so */
    if (rc != XTLD_OK) { printf("libGEM.so load FAILED rc=%d (%s)\n", rc, err); return; }
    xtld_run_init(gem);

    void  (*vdi_init)(void *)                 = (void (*)(void *))xtld_sym(gem, "vdi_init");
    void *(*font_face_open)(const char *)     = (void *(*)(const char *))xtld_sym(gem, "font_face_open");
    void  (*vdi_set_face)(void *)             = (void (*)(void *))xtld_sym(gem, "vdi_set_face");
    int   (*v_opnvwk)(void *)                 = (int (*)(void *))xtld_sym(gem, "v_opnvwk");
    void  (*vsf_color)(int, int)              = (void (*)(int, int))xtld_sym(gem, "vsf_color");
    void  (*vsf_interior)(int, int)           = (void (*)(int, int))xtld_sym(gem, "vsf_interior");
    void  (*vr_recfl)(int, const short *)     = (void (*)(int, const short *))xtld_sym(gem, "vr_recfl");
    void  (*vst_color)(int, int)              = (void (*)(int, int))xtld_sym(gem, "vst_color");
    int   (*vst_height)(int, int, int *, int *, int *, int *) =
          (int (*)(int, int, int *, int *, int *, int *))xtld_sym(gem, "vst_height");
    void  (*v_gtext)(int, int, int, const char *) =
          (void (*)(int, int, int, const char *))xtld_sym(gem, "v_gtext");
    if (!vdi_init || !font_face_open || !v_opnvwk || !v_gtext) { printf("libGEM: symbols missing\n"); return; }

    static struct { int w, h, stride; unsigned int *px; } desk;
    desk.w = DESK_W; desk.h = DESK_H; desk.stride = DESK_STRIDE; desk.px = (unsigned int *)DESK_BASE;

    vdi_init(&desk);
    void *face = font_face_open("/OS/Fonts/AovelSansRounded.ttf");
    if (!face) { printf("libGEM: font load FAILED (/OS/Fonts/AovelSansRounded.ttf)\n"); return; }
    vdi_set_face(face);

    int vh = v_opnvwk(&desk);
    short bg[4]  = { 0, 0, DESK_W - 1, DESK_H - 1 };  vsf_color(vh, 0); vsf_interior(vh, 1); vr_recfl(vh, bg);
    short box[4] = { 80, 80, 560, 400 };              vsf_color(vh, 1); vr_recfl(vh, box);
    vst_color(vh, 1); vst_height(vh, 110, 0, 0, 0, 0);
    v_gtext(vh, 640, 220, "Hello XTOS - from a loaded libGEM.so");

    Xil_DCacheFlushRange((INTPTR)DESK_BASE, DESK_STRIDE * DESK_H * 4);   /* present to compositor */
    printf("gemhw: rendered via loaded libGEM.so + FreeType -> HDMI plane\n");
}
