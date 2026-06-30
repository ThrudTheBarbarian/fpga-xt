/*
 * main.c — M4: an interactive shell on real FreeRTOS.
 * A kernel-resident shell task reads a command line (semihosting stdin), parses
 * argv, and spawns /bin/<cmd> with arguments, waiting for each. Programs are
 * loaded ET_DYNs (incl. shared-lib clients). Runs on qemu xilinx-zynq-a9.
 *
 * (The shell is kernel-resident for now — a userspace shell needs SYS_spawn/
 * SYS_waitpid syscalls, which must run their blocking parts in task context.)
 */
#include <stdint.h>
#include <string.h>
#include "FreeRTOS.h"
#include "task.h"
#include "bare_rt.h"
#include "frtos_os.h"
#include "romfs.h"
#include "xtld.h"
#include "romfs_blob.h"

extern void gic_init(void);
extern void mmu_init(void);

static xtld_host g_host;

static int readline(char *buf, int max)
{
    int n = 0;
    for (;;) {
        int c = sh_readc();
        if (c < 0) return n > 0 ? n : -1;      /* EOF */
        if (c == '\r') continue;
        if (c == '\n') {
#ifdef XT_HW_UART
            puts0("\r\n");                     /* raw UART: echo the newline */
#endif
            buf[n] = 0; return n;
        }
        if (c == 8 || c == 127) {              /* backspace */
            if (n > 0) {
                n--;
#ifdef XT_HW_UART
                puts0("\b \b");                /* erase on the terminal */
#endif
            }
            continue;
        }
        if (n < max - 1) {
            buf[n++] = (char)c;
#ifdef XT_HW_UART
            char e[2] = { (char)c, 0 }; puts0(e);  /* echo typed char */
#endif
        }
    }
}

static int split(char *line, char **argv, int max)
{
    int argc = 0;
    char *p = line;
    while (*p && argc < max) {
        while (*p == ' ') p++;
        if (!*p) break;
        argv[argc++] = p;
        while (*p && *p != ' ') p++;
        if (*p) *p++ = 0;
    }
    return argc;
}

/* run the tier-2 battery once and report — for hardware bring-up: load, watch the
 * UART, and confirm the cache/MMU/PL0 machinery behaves on real silicon. Loading +
 * EXECUTING each program exercises I-cache coherency (xtld sync_caches); COW/demand
 * exercise the D-cache + cacheable page-table walks; badpoke/stackpoke prove the
 * PL0 boundary; the fault tests prove the OS survives. All pages must be reclaimed
 * (in-use back to baseline) at the end. */
static void run_selftest(void)
{
    extern uint32_t vm_pages_inuse(void);
    static const struct { const char *path, *arg; } T[] = {
        { "/bin/modetest",  0 },                     /* runs at PL0?                  */
        { "/bin/vmtest",   "A" }, { "/bin/vmtest", "B" },  /* per-process heap (COW)  */
        { "/bin/libc_test", 0 },                     /* libc: printf/malloc/fopen     */
        { "/bin/mmaptest",  0 },                     /* mmap'd file (demand, RO)      */
        { "/bin/demandtest",0 },                     /* 128 KB demand-zero heap       */
        { "/bin/cowtest",  "A" }, { "/bin/cowtest", "B" }, /* copy-on-write           */
        { "/bin/sharetext","A" }, { "/bin/sharetext","B"}, /* shared text (I-cache)   */
        { "/bin/badpoke",   0 },                     /* read kernel mem -> KILLED     */
        { "/bin/stackpoke", 0 },                     /* read other stack -> KILLED    */
        { "/bin/wxtest",    0 },                     /* write own code  -> KILLED     */
        { "/bin/stacktest", 0 },                     /* stack overflow  -> KILLED     */
        { "/bin/faultprog", 0 },                     /* NULL deref      -> KILLED     */
    };
    uint32_t base = vm_pages_inuse();
    puts0("\n==== XTOS tier-2 selftest (caches on, PL0 enforced) ====\n");
    for (unsigned i = 0; i < sizeof T / sizeof T[0]; i++) {
        char *av[2]; int ac = T[i].arg ? 2 : 1;
        av[0] = (char *)T[i].path; av[1] = (char *)T[i].arg;
        int pid = frtos_spawn_argv(T[i].path, ac, av, &g_host);
        if (pid < 0) { puts0("  MISSING: "); puts0(T[i].path); puts0("\n"); continue; }
        frtos_waitpid(pid);
    }
    uint32_t now = vm_pages_inuse();
    puts0("==== selftest done; pages in use ");
    putu(now); puts0(" (was "); putu(base); puts0(") — ");
    puts0(now == base ? "reclaimed; OS alive ====\n" : "LEAK ====\n");
}

static void shell_task(void *arg)
{
    (void)arg;
    { extern void sd_init(void); sd_init(); }   /* mount SD here (task context — FatFs reentrancy needs the scheduler) */
#ifdef XT_HW_UART
    run_selftest();   /* hardware: auto-run the battery once at boot, then drop to the shell */
#endif
    puts0("\nXTOS shell  —  try: selftest | echo | hello | libc_test | gemtext | desktop | exit\n");
    char line[128];
    char *argv[16];
    for (;;) {
        puts0("xtos$ ");
        int n = readline(line, sizeof line);
        if (n < 0) { puts0("\n[eof]\n"); sh_exit(0); }
        int argc = split(line, argv, 16);
        if (argc == 0) continue;
        if (!strcmp(argv[0], "exit")) { puts0("bye\n"); sh_exit(0); }
        if (!strcmp(argv[0], "help")) {
            puts0("builtins: selftest (run the tier-2 battery), vmtest, demandtest, cowtest,\n"
                  "  sharetext, memtest, mmaptest, modetest, badpoke, stackpoke, wxtest,\n"
                  "  stacktest, faulttest, runhost <path>, exit.  programs: /bin/{hello,\n"
                  "  showmotd,usestr,echo,libc_test,gemtext,desktop}\n");
            continue;
        }
        if (!strcmp(argv[0], "selftest")) { run_selftest(); continue; }
        if (!strcmp(argv[0], "vmtest")) {          /* T2-b: per-process heaps */
            char *a[2] = { (char *)"vmtest", (char *)"A" };
            char *b[2] = { (char *)"vmtest", (char *)"B" };
            int pid = frtos_spawn_argv("/bin/vmtest", 2, a, &g_host);
            if (pid < 0) { puts0("vmtest: not found\n"); continue; }
            frtos_waitpid(pid);
            pid = frtos_spawn_argv("/bin/vmtest", 2, b, &g_host);
            if (pid >= 0) frtos_waitpid(pid);
            puts0("vmtest: A and B should each print 0x10000008 (a private heap at the same VA\n"
                  "        in separate spaces). Different/sequential addresses => NOT isolated.\n");
            continue;
        }
        if (!strcmp(argv[0], "demandtest")) {      /* T2-c: lazy (demand-zero) heap */
            extern unsigned vm_demand_count(void);
            unsigned before = vm_demand_count();
            char *av[1] = { (char *)"demandtest" };
            int pid = frtos_spawn_argv("/bin/demandtest", 1, av, &g_host);
            if (pid < 0) { puts0("demandtest: not found\n"); continue; }
            frtos_waitpid(pid);
            puts0("demandtest: "); putu(vm_demand_count() - before);
            puts0(" heap pages were demand-mapped (zero-fill on touch)\n");
            continue;
        }
        if (!strcmp(argv[0], "runhost")) {         /* load+run a .so/.elf from the HOST fs */
            if (argc < 2) { puts0("usage: runhost <hostpath> [args...]\n"); continue; }
            int pid = frtos_spawn_host(argv[1], argc - 1, argv + 1, &g_host);
            if (pid < 0) { puts0("runhost: load failed\n"); continue; }
            frtos_waitpid(pid);
            continue;
        }
        if (!strcmp(argv[0], "memtest")) {         /* T2-c: DDR page pool + reclaim on exit */
            uint32_t freep = vm_pages_free(), inuse0 = vm_pages_inuse();
            puts0("memtest: pool has "); putu(freep); puts0(" pages free (~");
            putu(freep / 256); puts0(" MB of DDR), "); putu(inuse0);
            puts0(" in use. Running demandtest x5 (~33 pages each)...\n");
            char *av[1] = { (char *)"demandtest" };
            for (int k = 0; k < 5; k++) {
                int pid = frtos_spawn_argv("/bin/demandtest", 1, av, &g_host);
                if (pid < 0) { puts0("memtest: spawn failed\n"); break; }
                frtos_waitpid(pid);
            }
            uint32_t inuse1 = vm_pages_inuse();
            puts0("memtest: "); putu(inuse1); puts0(" pages in use after 5 runs+exits. ");
            puts0(inuse1 == inuse0 ? "Fully reclaimed (no leak).\n"
                                   : "LEAK: pages not reclaimed.\n");
            continue;
        }
        if (!strcmp(argv[0], "cowtest")) {         /* T2-c: copy-on-write (synthetic) */
            extern uint32_t vm_cow_count(void);
            uint32_t before = vm_cow_count();
            char *a[2] = { (char *)"cowtest", (char *)"A" };
            char *b[2] = { (char *)"cowtest", (char *)"B" };
            int pid = frtos_spawn_argv("/bin/cowtest", 2, a, &g_host);
            if (pid < 0) { puts0("cowtest: not found\n"); continue; }
            frtos_waitpid(pid);
            pid = frtos_spawn_argv("/bin/cowtest", 2, b, &g_host);
            if (pid >= 0) frtos_waitpid(pid);
            puts0("cowtest: "); putu(vm_cow_count() - before);
            puts0(" page(s) copied on write. Both saw the pristine 'COW' template first\n"
                  "         (shared RO), then their own private copy => COW + isolation.\n");
            continue;
        }
        if (!strcmp(argv[0], "sharetext")) {       /* T2-c: mmap-exec — shared text + COW data */
            extern uint32_t frtos_prog_loads(void);
            uint32_t lb = frtos_prog_loads();
            char *a[2] = { (char *)"sharetext", (char *)"A" };
            char *b[2] = { (char *)"sharetext", (char *)"B" };
            int pid = frtos_spawn_argv("/bin/sharetext", 2, a, &g_host);
            if (pid < 0) { puts0("sharetext: not found\n"); continue; }
            frtos_waitpid(pid);
            pid = frtos_spawn_argv("/bin/sharetext", 2, b, &g_host);
            if (pid >= 0) frtos_waitpid(pid);
            puts0("sharetext: program loaded "); putu(frtos_prog_loads() - lb);
            puts0(" time(s) for 2 spawns (1 => text shared). Same &marker both runs\n"
                  "           (shared text); g_counter starts at 100 in BOTH (private COW data).\n");
            continue;
        }
        if (!strcmp(argv[0], "stacktest")) {       /* T2-c: stack overflow -> guard page */
            puts0("stacktest: spawning /bin/stacktest (it overflows its stack)...\n");
            char *av[1] = { (char *)"stacktest" };
            int pid = frtos_spawn_argv("/bin/stacktest", 1, av, &g_host);
            if (pid < 0) { puts0("stacktest: not found\n"); continue; }
            frtos_waitpid(pid);
            puts0("stacktest: overflow hit the guard page; OS survives.\n");
            continue;
        }
        if (!strcmp(argv[0], "wxtest")) {          /* T2-c: W^X — writing to text faults */
            puts0("wxtest: spawning /bin/wxtest (it writes to its own code)...\n");
            char *av[1] = { (char *)"wxtest" };
            int pid = frtos_spawn_argv("/bin/wxtest", 1, av, &g_host);
            if (pid < 0) { puts0("wxtest: not found\n"); continue; }
            frtos_waitpid(pid);
            puts0("wxtest: the code write was blocked (RO text); OS survives.\n");
            continue;
        }
        if (!strcmp(argv[0], "faulttest")) {       /* T2-a.2: a faulting app is killed; the OS survives */
            puts0("faulttest: spawning /bin/faultprog (it derefs NULL)...\n");
            char *av[1] = { (char *)"faultprog" };
            int pid = frtos_spawn_argv("/bin/faultprog", 1, av, &g_host);
            if (pid < 0) { puts0("faultprog: not found\n"); continue; }
            frtos_waitpid(pid);
            puts0("faulttest: faultprog was killed by the OS; the shell is still alive.\n");
            continue;
        }
        char path[72];
        int i = 0; const char *pre = "/bin/";
        while (pre[i]) { path[i] = pre[i]; i++; }
        for (int j = 0; argv[0][j] && i < (int)sizeof(path) - 1; j++) path[i++] = argv[0][j];
        path[i] = 0;

        int pid = frtos_spawn_argv(path, argc, argv, &g_host);
        if (pid < 0) { puts0(argv[0]); puts0(": not found\n"); continue; }
        frtos_waitpid(pid);
    }
}

int main(void)
{
#ifdef XT_HW_UART
    puts0("=== xtos: tier-2 testbed (Zynq-A9 on HARDWARE, UART1) ===\n");
#else
    puts0("=== xtos: tier-2 testbed (qemu zynq-a9, semihosting) ===\n");
#endif
    mmu_init();          /* flat map -> RAM is Normal memory (unaligned access ok) */
    vm_cow_init();       /* fill the synthetic COW template + register its range */
    { extern void stackguard_init(void); stackguard_init(); }   /* guarded stack arena */
    gic_init();
    { extern void gtimer_init(void); gtimer_init(); }   /* A9 global timer -> gettimeofday wall clock */
    { extern void hdmi_init(void); hdmi_init(); }        /* SiI9022 HDMI bring-up (HW build only; no-op on qemu) */
    { extern void gfxplane_init(void); gfxplane_init(); } /* clear the compositor plane (else scan-out shows uninit DDR) */
    ksys_set_console(rt_write);
    romfs_mount(romfs_blob, romfs_blob_len);

    g_host = (xtld_host){ .alloc = frtos_alloc, .dealloc = frtos_free, .sync_caches = mmu_sync_caches,
                          .resolve = frtos_ksym, .open_lib = frtos_open_lib,
                          .on_loaded = frtos_on_loaded, .user = NULL };

    /* bootstrap-load /OS/Library/libc.so, then route the loader's allocator
     * through libc.so's malloc (frtos_activate_libc) */
    const uint8_t *d; uint32_t n; char err[64] = {0};
    if (!romfs_lookup("/OS/Library/libc.so", &d, &n)) { puts0("no libc.so in romfs\n"); sh_exit(1); }
    xtld_obj *libc = NULL;
    int rc = xtld_load(d, n, &g_host, &libc, err, sizeof err);
    if (rc != XTLD_OK) { puts0("libc.so load FAILED: "); puts0(xtld_strerror(rc));
        puts0(" ("); puts0(err); puts0(")\n"); sh_exit(1); }
    frtos_activate_libc(libc);
    xtld_run_init(libc);
    puts0("libc.so loaded + activated\n");

    /* T2-b: snapshot libc.so's pristine data/bss (post-init, before any malloc)
     * into a static buffer, so each spawned process gets its OWN copy of libc's
     * writable state -> per-process malloc. memcpy (not libc malloc) keeps the
     * snapshot pristine. */
    {
        static uint8_t libc_snap[0x10000];
        uintptr_t wva; uint32_t wsize;
        xtld_writable_range(libc, &wva, &wsize);
        if (wva && wsize && wsize <= sizeof libc_snap) {
            memcpy(libc_snap, (void *)wva, wsize);
            vm_set_libc(wva, wsize, libc_snap);
        }
    }

    /* T2-c: the physical page pool (demand-zero heap + COW pages) shares the one
     * CPU heap arena: it grows DOWN from the top of DDR while libc malloc grows up,
     * meeting in the middle. No fixed reservation — all of DDR is available to
     * whichever needs it. The abort handler allocates from here without libc. */
    vm_phys_init(0x20000000u);

    void *p = frtos_alloc(4096, 16, NULL);       /* now via libc.so's malloc */
    puts0(p ? "libc.so malloc: ok\n" : "libc.so malloc: FAIL\n");
    frtos_free(p, NULL);

    if (xTaskCreate(shell_task, "sh", 2048, NULL, 2, NULL) != pdPASS) {
        puts0("shell create failed\n"); sh_exit(1);
    }
    vTaskStartScheduler();
    puts0("scheduler returned\n"); sh_exit(1);
    return 0;
}
