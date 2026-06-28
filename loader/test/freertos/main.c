/*
 * main.c — M2: loader + syscall spine + a filesystem, on real FreeRTOS.
 * "init" mounts the embedded romfs and spawns programs BY PATH; the programs
 * issue real syscalls (incl. open/read of /etc/motd). Runs on qemu zynq-a9.
 */
#include <stdint.h>
#include "FreeRTOS.h"
#include "task.h"
#include "bare_rt.h"
#include "frtos_os.h"
#include "romfs.h"
#include "xtld.h"
#include "romfs_blob.h"

extern void gic_init(void);

static int run(const xtld_host *host, const char *path)
{
    puts0("init: spawn "); puts0(path); puts0("\n");
    int pid = frtos_spawn_path(path, host);
    if (pid < 0) { puts0("init: spawn failed: "); puts0(path); puts0("\n"); return -1; }
    int code = frtos_waitpid(pid);
    puts0("init: "); puts0(path); puts0(" exited code "); putu((unsigned)code); puts0("\n");
    return code;
}

static void init_task(void *arg)
{
    (void)arg;
    xtld_host host = { .alloc = bump, .dealloc = NULL, .sync_caches = NULL,
                       .resolve = frtos_ksym, .open_lib = frtos_open_lib, .user = NULL };

    int a = run(&host, "/bin/hello");
    int b = run(&host, "/bin/showmotd");
    int c = run(&host, "/bin/usestr");      /* imports strrev from libutil.so */

    if (a == 0 && b == 0 && c == 0) { puts0("RESULT: PASS\n"); sh_exit(0); }
    puts0("RESULT: FAIL\n"); sh_exit(1);
}

int main(void)
{
    puts0("=== xtos: programs from a filesystem on real FreeRTOS (qemu zynq-a9, M2) ===\n");
    gic_init();
    ksys_set_console(rt_write);
    romfs_mount(romfs_blob, romfs_blob_len);

    if (xTaskCreate(init_task, "init", 1024, NULL, 2, NULL) != pdPASS) {
        puts0("init create failed\n"); sh_exit(1);
    }
    vTaskStartScheduler();
    puts0("scheduler returned\n"); sh_exit(1);
    return 0;
}
