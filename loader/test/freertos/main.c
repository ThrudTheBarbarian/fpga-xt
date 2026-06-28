/*
 * main.c — Stage 2: the loader + syscall spine on the REAL FreeRTOS kernel.
 * An "init" task (pid-1-style) spawns an embedded app as a real FreeRTOS task;
 * the app issues genuine svc #1 syscalls (write/getpid/exit); init waitpid()s on
 * its semaphore and reports the exit code. Runs on qemu xilinx-zynq-a9.
 */
#include <stdint.h>
#include "FreeRTOS.h"
#include "task.h"
#include "bare_rt.h"
#include "frtos_os.h"
#include "xtld.h"
#include "app_so.h"

extern void gic_init(void);

static void init_task(void *arg)
{
    (void)arg;
    puts0("init: spawning app...\n");

    xtld_host host = { .alloc = bump, .dealloc = NULL, .sync_caches = NULL,
                       .resolve = NULL, .user = NULL };
    int pid = frtos_spawn(app_so, app_so_len, &host);
    if (pid < 0) { puts0("init: spawn failed\n"); sh_exit(1); }
    puts0("init: spawned pid "); putu((unsigned)pid); puts0(", waiting...\n");

    int code = frtos_waitpid(pid);
    puts0("init: app pid "); putu((unsigned)pid);
    puts0(" exited, code "); putu((unsigned)code); puts0("\n");

    if (code == 42) { puts0("RESULT: PASS\n"); sh_exit(0); }
    puts0("RESULT: FAIL\n"); sh_exit(1);
}

int main(void)
{
    puts0("=== xtos: spawn on real FreeRTOS (qemu zynq-a9, Stage 2) ===\n");
    gic_init();
    ksys_set_console(rt_write);

    if (xTaskCreate(init_task, "init", 1024, NULL, 2, NULL) != pdPASS) {
        puts0("init create failed\n"); sh_exit(1);
    }
    vTaskStartScheduler();
    puts0("scheduler returned\n"); sh_exit(1);
    return 0;
}
