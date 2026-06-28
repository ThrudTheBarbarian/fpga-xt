/*
 * xtld_host.c — the XTOS host shim for the dynamic loader on real hardware.
 *
 * Wires xtld's portable callbacks to the A9: memalign/free, and crucially the
 * Xilinx cache maintenance ops — the real reason the loader must be proven on
 * metal. On qemu the caches were off; here DDR is cacheable, so freshly-copied
 * + relocated code must be cleaned out of the D-cache and the stale I-cache
 * lines invalidated before it can be executed, or it runs garbage.
 *
 * xtos_ld_selftest() (HW-1) loads + runs a trivial embedded .so to prove
 * relocations + cache coherency on the A9 before libc.so/libGEM.so go on top.
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

/* kernel-exported to loaded modules (HW-1: the test .so calls this) */
void xtos_log(const char *s) { printf("%s", s); }

static void *ld_alloc(size_t size, size_t align, void *u)
{ (void)u; return memalign(align ? align : 16, size); }

static void ld_free(void *p, void *u) { (void)u; free(p); }

static void ld_sync(void *addr, size_t len, void *u)
{
    (void)u;
    Xil_DCacheFlushRange((INTPTR)addr, len);        /* push code to DDR */
    Xil_ICacheInvalidateRange((INTPTR)addr, len);   /* drop stale I-cache lines */
}

static uintptr_t ld_resolve(const char *name, void *u)
{
    (void)u;
    if (!strcmp(name, "xtos_log")) return (uintptr_t)xtos_log;
    if (!strcmp(name, "memcpy"))   return (uintptr_t)memcpy;
    if (!strcmp(name, "memset"))   return (uintptr_t)memset;
    return 0;
}

void xtos_ld_selftest(void)
{
    xtld_host host = { .alloc = ld_alloc, .dealloc = ld_free, .sync_caches = ld_sync,
                       .resolve = ld_resolve, .open_lib = NULL, .user = NULL };
    xtld_obj *o = NULL;
    char err[80] = {0};

    int rc = xtld_load(xtld_test_so, xtld_test_so_len, &host, &o, err, sizeof err);
    if (rc != XTLD_OK) { printf("[ldtest] xtld_load FAILED rc=%d (%s)\n", rc, err); return; }
    xtld_run_init(o);

    int (*run)(int, int) = (int (*)(int, int))xtld_sym(o, "run");
    if (!run) { printf("[ldtest] symbol 'run' not found\n"); xtld_unload(o); return; }

    int r = run(20, 22);
    printf("[ldtest] loaded .so on the A9: run(20,22) = %d (expect 42) -> %s\n",
           r, r == 42 ? "PASS" : "FAIL");
    xtld_unload(o);
}
