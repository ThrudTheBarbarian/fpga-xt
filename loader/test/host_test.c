/*
 * host_test.c — host testbed for the xtld loader.
 *
 * Loads an arm32 ET_DYN (test/testlib.so) on the (arm64) host and VERIFIES the
 * load by inspecting relocated data — no ARM code is executed. Checks all three
 * relocation types, symbol resolution against a host-supplied table, exported
 * symbol lookup, and init_array discovery.
 */
#include "../xtld.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ---- host services handed to the loader -------------------------------- */

static void host_log_fn(const char *msg) { printf("    [loaded code would log] %s\n", msg); }
static volatile unsigned host_counter_var = 0xABCD;

static void *h_alloc(size_t size, size_t align, void *u)
{
    (void)u;
    void *p = NULL;
    if (align < sizeof(void *)) align = sizeof(void *);
    /* round size up to a multiple of align (aligned_alloc requirement) */
    size = (size + align - 1) & ~(align - 1);
    if (posix_memalign(&p, align, size) != 0) return NULL;
    return p;
}
static void h_free(void *p, void *u) { (void)u; free(p); }
static void h_sync(void *a, size_t n, void *u) { (void)a; (void)n; (void)u; /* no-op on host */ }

static uintptr_t h_resolve(const char *name, void *u)
{
    (void)u;
    if (strcmp(name, "host_log") == 0)     return (uintptr_t)&host_log_fn;
    if (strcmp(name, "host_counter") == 0) return (uintptr_t)&host_counter_var;
    return 0;
}

/* ---- test harness ------------------------------------------------------ */

static int fails = 0;
#define CHECK(cond, fmt, ...) do {                                   \
        if (cond) { printf("  ok   " fmt "\n", ##__VA_ARGS__); }      \
        else      { printf("  FAIL " fmt "\n", ##__VA_ARGS__); fails++; } \
    } while (0)

static uint8_t *read_file(const char *path, size_t *len)
{
    FILE *f = fopen(path, "rb");
    if (!f) { perror(path); return NULL; }
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    uint8_t *buf = malloc(n);
    if (fread(buf, 1, n, f) != (size_t)n) { fclose(f); free(buf); return NULL; }
    fclose(f);
    *len = (size_t)n;
    return buf;
}

int main(int argc, char **argv)
{
    const char *path = argc > 1 ? argv[1] : "test/testlib.so";
    size_t len;
    uint8_t *image = read_file(path, &len);
    if (!image) return 2;
    printf("loading %s (%zu bytes)\n", path, len);

    xtld_host host = {
        .alloc = h_alloc, .dealloc = h_free, .sync_caches = h_sync,
        .resolve = h_resolve, .user = NULL,
    };

    xtld_obj *obj = NULL;
    char err[128] = {0};
    int rc = xtld_load(image, len, &host, &obj, err, sizeof err);
    if (rc != XTLD_OK) {
        printf("xtld_load failed: %s (%s)\n", xtld_strerror(rc), err);
        return 1;
    }
    printf("loaded at base=%#lx span=%#zx entry=%#lx init_count=%u\n",
           (unsigned long)xtld_base(obj), xtld_span(obj),
           (unsigned long)xtld_entry(obj), xtld_init_count(obj));

    uintptr_t base = xtld_base(obj), span = xtld_span(obj);
    uintptr_t a_value   = xtld_sym(obj, "g_value");
    uintptr_t a_selfptr = xtld_sym(obj, "g_selfptr");
    uintptr_t a_relptr  = xtld_sym(obj, "g_relptr");
    uintptr_t a_logptr  = xtld_sym(obj, "g_logptr");
    uintptr_t a_ctrptr  = xtld_sym(obj, "g_ctrptr");
    uintptr_t a_add     = xtld_sym(obj, "add");

    CHECK(a_value && a_selfptr && a_relptr && a_logptr && a_ctrptr && a_add,
          "dynsym lookup found all exported symbols");

    /* R_ARM_RELATIVE: g_relptr -> static s_hidden, i.e. base + offset */
    uint32_t relptr = a_relptr ? *(uint32_t *)a_relptr : 0;
    CHECK(relptr >= (uint32_t)base && relptr < (uint32_t)(base + span),
          "R_ARM_RELATIVE: g_relptr=%#x within image (bias applied)", relptr);

    /* R_ARM_ABS32 (defined sym): g_selfptr should point at the in-image g_value */
    uint32_t selfptr = a_selfptr ? *(uint32_t *)a_selfptr : 0;
    CHECK(selfptr == (uint32_t)a_value,
          "R_ARM_ABS32 (defined): g_selfptr=%#x -> &g_value=%#x", selfptr, (uint32_t)a_value);

    /* symbolic reloc vs imported function */
    uint32_t logptr = a_logptr ? *(uint32_t *)a_logptr : 0;
    CHECK(logptr == (uint32_t)(uintptr_t)&host_log_fn,
          "sym reloc (func): g_logptr=%#x -> host_log=%#x",
          logptr, (uint32_t)(uintptr_t)&host_log_fn);

    /* symbolic reloc vs imported data */
    uint32_t ctrptr = a_ctrptr ? *(uint32_t *)a_ctrptr : 0;
    CHECK(ctrptr == (uint32_t)(uintptr_t)&host_counter_var,
          "sym reloc (data): g_ctrptr=%#x -> host_counter=%#x",
          ctrptr, (uint32_t)(uintptr_t)&host_counter_var);

    /* data not clobbered; ctor did NOT run (we never execute ARM) */
    uint32_t value = a_value ? *(uint32_t *)a_value : 0;
    CHECK(value == 0x1234, "data intact: g_value=%#x (ctor not run)", value);

    /* exported function address lands inside the loaded image */
    CHECK(a_add >= base && a_add < base + span,
          "exported fn add=%#lx within image [%#lx,%#lx)",
          (unsigned long)a_add, (unsigned long)base, (unsigned long)(base + span));

    /* init_array discovered (the ctor) */
    CHECK(xtld_init_count(obj) >= 1, "init_array discovered (count=%u)", xtld_init_count(obj));

    xtld_free(obj);
    free(image);
    printf(fails ? "\n%d check(s) FAILED\n" : "\nall checks passed\n", fails);
    return fails ? 1 : 0;
}
