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
        if (c == '\n') { buf[n] = 0; return n; }
        if (c == 8 || c == 127) { if (n > 0) n--; continue; } /* backspace */
        if (n < max - 1) buf[n++] = (char)c;
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

static void shell_task(void *arg)
{
    (void)arg;
    puts0("\nXTOS shell  —  try: echo hello world | hello | showmotd | usestr | libc_test | gemtext | desktop | exit\n");
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
            puts0("builtins: help, exit. programs: /bin/{hello,showmotd,usestr,echo,libc_test,gemtext}\n");
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
    puts0("=== xtos: libc.so bring-up + shell (qemu zynq-a9, M6a) ===\n");
    mmu_init();          /* flat map -> RAM is Normal memory (unaligned access ok) */
    gic_init();
    ksys_set_console(rt_write);
    romfs_mount(romfs_blob, romfs_blob_len);

    g_host = (xtld_host){ .alloc = frtos_alloc, .dealloc = frtos_free, .sync_caches = NULL,
                          .resolve = frtos_ksym, .open_lib = frtos_open_lib, .user = NULL };

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
