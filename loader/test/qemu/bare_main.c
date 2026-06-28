/*
 * bare_main.c — bare-metal harness that EXECUTES loaded code under
 * qemu-system-arm: runs the constructor, calls exported functions, and
 * exercises a cross-call from loaded code back into the host. Shared
 * runtime (semihosting/libc/alloc) is in bare_rt.c.
 */
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include "xtld.h"
#include "bare_rt.h"
#include "testlib_so.h"

/* ---- the "kernel" side the loaded code resolves against ---------------- */
static void host_log_fn(const char *m) { puts0("    [host_log] "); puts0(m); puts0("\n"); }
static volatile unsigned host_counter_var = 0xABCD;
static uintptr_t resolve(const char *n, void *u)
{
    (void)u;
    if (strcmp(n, "host_log") == 0)     return (uintptr_t)&host_log_fn;
    if (strcmp(n, "host_counter") == 0) return (uintptr_t)&host_counter_var;
    return 0;
}

/* ---- test -------------------------------------------------------------- */
static int fails;
#define OK(cond, msg) do { if (cond) puts0("  ok   " msg "\n"); \
    else { puts0("  FAIL " msg "\n"); fails++; } } while (0)

int main(void)
{
    puts0("=== xtld qemu (bare-metal arm) execution test ===\n");

    xtld_host host = { .alloc = bump, .dealloc = NULL, .sync_caches = NULL,
                       .resolve = resolve, .user = NULL };
    xtld_obj *obj = NULL;
    char err[64] = {0};
    int rc = xtld_load(testlib_so, testlib_so_len, &host, &obj, err, sizeof err);
    if (rc != XTLD_OK) {
        puts0("load failed: "); puts0(xtld_strerror(rc));
        puts0(" ("); puts0(err); puts0(")\n"); sh_exit(2);
    }
    puts0("loaded ok\n");

    unsigned (*add)(unsigned, unsigned) = (unsigned (*)(unsigned, unsigned))xtld_sym(obj, "add");
    unsigned (*greet)(void)             = (unsigned (*)(void))xtld_sym(obj, "greet");
    unsigned *g_value                   = (unsigned *)xtld_sym(obj, "g_value");

    OK(add && greet && g_value, "resolved add/greet/g_value");
    OK(g_value && *g_value == 0x1234, "pre-init g_value == 0x1234");

    xtld_run_init(obj);   /* EXECUTES the constructor -> g_value = 0xCAFE */
    OK(g_value && *g_value == 0xCAFE, "post-init g_value == 0xCAFE (ctor ran)");

    OK(add && add(2, 3) == 5, "add(2,3) == 5 (call into loaded code)");

    unsigned g = greet ? greet() : 0;  /* loaded code calls host_log + add */
    OK(g == 42, "greet() == 42 (loaded code cross-called host_log + add)");
    puts0("  greet() returned "); putu(g); puts0("\n");

    puts0(fails ? "RESULT: FAIL\n" : "RESULT: PASS\n");
    sh_exit(fails ? 1 : 0);
    return 0;
}
