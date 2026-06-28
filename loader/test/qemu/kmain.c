/*
 * kmain.c — test "kernel" for the svc #1 gateway + spawn, under qemu.
 * Installs the vector table, registers a console, spawns the embedded app, and
 * reports its exit code. The app issues real svc #1 traps for write/getpid/exit.
 */
#include <stddef.h>
#include <stdint.h>
#include "xtld.h"
#include "bare_rt.h"
#include "ksys.h"
#include "app_so.h"

int main(void)
{
    puts0("=== xtos svc #1 gateway + spawn (qemu, bare metal) ===\n");

    set_vbar(vector_table);          /* route exceptions to our table */
    ksys_set_console(rt_write);      /* SYS_write -> semihosting */

    /* app.so has no imported symbols, so no resolver is needed. */
    xtld_host host = { .alloc = bump, .dealloc = NULL, .sync_caches = NULL,
                       .resolve = NULL, .user = NULL };

    int code = k_spawn(app_so, app_so_len, &host);
    puts0("kernel: app exited, code = "); putu((unsigned)code); puts0("\n");

    if (code == 42) { puts0("RESULT: PASS\n"); sh_exit(0); }
    puts0("RESULT: FAIL\n"); sh_exit(1);
    return 0;
}
