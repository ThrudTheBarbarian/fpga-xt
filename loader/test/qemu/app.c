/*
 * app.c — a spawnable program, built as an arm32 ET_DYN. It reaches the kernel
 * only through syscalls (svc #1), so it has no imported symbols to resolve.
 * The kernel runs it via xtld_sym("_app_entry").
 */
#include "usys.h"

static const char msg[] = "hello from a spawned program (svc #1)\n";

void _app_entry(void)
{
    sys_write(1, msg, sizeof(msg) - 1);
    long pid = sys_getpid();
    /* exit 42 iff we were given pid 1 — proves getpid round-trips too */
    sys_exit(pid == 1 ? 42 : 99);
}
