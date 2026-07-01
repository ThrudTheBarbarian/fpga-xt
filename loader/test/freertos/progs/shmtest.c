/*
 * shmtest — exercise the shared-memory primitive across two processes.
 *
 *   shmtest         (parent) create an shm, map it, write a magic word, then spawn
 *                            `shmtest <id>` and waitpid it; finally read a word the
 *                            child wrote back.
 *   shmtest <id>    (child)  map the same id, verify the parent's magic (shared READ),
 *                            write a word back (shared WRITE), exit.
 *
 * Success = the child sees the parent's magic AND the parent sees the child's write:
 * one physical page, two address spaces, both directions.
 */
#include "usys.h"
#include <stdio.h>
#include <stdlib.h>

#define MAGIC 0xC0FFEE42u

void _app_entry(int argc, char **argv)
{
    if (argc >= 2) {                                   /* ---- child ---- */
        int id = atoi(argv[1]);
        volatile unsigned *p = sys_shm_map(id);
        if (!p) { printf("shmtest[child]: shm_map(%d) FAILED\n", id); sys_exit(1); }
        printf("shmtest[child]: id %d @ %p, first word = 0x%08x %s\n",
               id, (void *)p, p[0], p[0] == MAGIC ? "OK (shared read!)" : "MISMATCH");
        p[1] = 0xBEEF;                                 /* write back for the parent to read */
        sys_exit(0);
    }

    int id = sys_shm_create(4096);                     /* ---- parent ---- */
    if (id < 0) { printf("shmtest: shm_create FAILED\n"); sys_exit(1); }
    volatile unsigned *p = sys_shm_map(id);
    if (!p) { printf("shmtest: shm_map FAILED\n"); sys_exit(1); }
    p[0] = MAGIC; p[1] = 0;
    printf("shmtest: created id %d @ %p, wrote 0x%08x\n", id, (void *)p, p[0]);

    char idbuf[12]; snprintf(idbuf, sizeof idbuf, "%d", id);
    char *av[3] = { (char *)"/System/bin/shmtest", idbuf, 0 };
    long pid = sys_spawn(av[0], 2, av);
    if (pid >= 0) sys_waitpid((int)pid);

    printf("shmtest: after child, second word = 0x%04x %s\n",
           p[1], p[1] == 0xBEEF ? "OK (child wrote it -> shared write!)" : "NOT written");
    sys_exit(0);
}
