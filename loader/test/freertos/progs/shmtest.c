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

    /* Stage 0: the flag word must be VALIDATED, not ignored. A kernel that quietly
     * masked off XT_SHM_CONTIG would hand the PL a scattered page list and render
     * garbage; a clean -1 is the whole point. Prove both directions before anything
     * relies on it. */
    if (sys_shm_create(4096, XT_SHM_CONTIG) >= 0)
        printf("shmtest: FAIL — XT_SHM_CONTIG accepted but plv_alloc does not exist yet\n");
    else
        printf("shmtest: unsupported flag rejected OK\n");
    if (sys_shm_create(4096, 0x8000u) >= 0)
        printf("shmtest: FAIL — unknown flag bit accepted\n");
    else
        printf("shmtest: unknown flag rejected OK\n");

    int id = sys_shm_create(4096, 0);                  /* ---- parent ---- */ /* flags=0: classic pool-backed */
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

    /* ---- STAGE 1: the per-space L2 ceiling ---------------------------------------
     * vm_shm_map burns ONE per-space L2 slot per 1 MB of surface mapped, and the old
     * static space_l2pool capped EVERY space at MAXSEC=12 overridden sections — slots
     * already shared with libc and each shared lib's data. gemd maps a backing store
     * per window, so it would have failed to map its third window.
     * Map as many 1 MB objects as the shm table allows: on the old kernel this stops
     * dead once the space runs out of L2 slots. It must now run to NSHM. */
    int mapped = 0;
    for (int i = 0; i < 64; i++) {
        int sid = sys_shm_create(1u << 20, 0);         /* 1 MB -> exactly one section */
        if (sid < 0) break;                            /* shm table exhausted (expected end) */
        volatile unsigned *q = sys_shm_map(sid);
        if (!q) { printf("shmtest: L2 CEILING HIT after %d mappings\n", mapped); break; }
        q[0] = 0x5EC00000u + (unsigned)i;              /* touch it: the mapping must be live */
        if (q[0] != 0x5EC00000u + (unsigned)i) { printf("shmtest: FAIL readback at %d\n", i); break; }
        mapped++;
    }
    printf("shmtest: mapped %d x 1MB shm objects — old MAXSEC=12 ceiling %s\n",
           mapped, mapped > 12 ? "GONE" : "STILL THERE");
    sys_exit(0);
}
