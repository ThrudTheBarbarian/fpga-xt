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

    /* ---- STAGE 2: variable-size objects -----------------------------------------
     * The old kernel pinned each id to a fixed 1 MB VA slot, so NOTHING could exceed
     * 1 MB — a 640x400 window backing store is already 1.02 MiB. A maximised 1920x1080
     * window is 1920x1088x4 = 7.97 MiB. Create exactly that, and touch the FIRST and
     * LAST page: spanning 8 sections proves vm_shm_map now walks one L2 per section
     * (the old code took a single perproc_l2 for va>>20, which is why 1 MB was the wall). */
    unsigned big = 1920u * 1088u * 4u;                 /* 7.97 MiB: a maximised window */
    int bid = sys_shm_create(big, 0);
    if (bid < 0) { printf("shmtest: FAIL — could not create a %u-byte surface\n", big); sys_exit(1); }
    volatile unsigned *b = sys_shm_map(bid);
    if (!b) { printf("shmtest: FAIL — could not map the big surface\n"); sys_exit(1); }
    unsigned last = big / 4u - 1u;
    b[0] = 0xF1257A6Eu; b[last] = 0x1A57FA6Eu;
    printf("shmtest: %u-byte surface @ %p — first=0x%08x last=0x%08x %s\n",
           big, (void *)b, b[0], b[last],
           (b[0] == 0xF1257A6Eu && b[last] == 0x1A57FA6Eu) ? "OK (spans 8 sections)" : "CORRUPT");

    /* how many 1 MB objects can we now create+map? old ceiling was 8 (L2), then 15 (NSHM=16). */
    static int ids[300];
    int mapped = 0;
    for (int i = 0; i < 300; i++) {
        int sid = sys_shm_create(1u << 20, 0);
        if (sid < 0) break;
        volatile unsigned *q = sys_shm_map(sid);
        if (!q) break;
        q[0] = 0x5EC00000u + (unsigned)i;
        if (q[0] != 0x5EC00000u + (unsigned)i) { printf("shmtest: FAIL readback at %d\n", i); break; }
        ids[mapped++] = sid;
    }
    printf("shmtest: mapped %d x 1MB objects (old kernel: 8, L2-capped)\n", mapped);
    /* release them, or they hoard every id + VA section and starve everything below */
    int freed = 0;
    for (int i = 0; i < mapped; i++) if (sys_shm_unmap(ids[i]) == 0) freed++;
    printf("shmtest: unmapped %d/%d — %s\n", freed, mapped, freed == mapped ? "OK" : "FAIL");

    /* ---- STAGE 3: sys_shm_unmap ---------------------------------------------------
     * Until this syscall existed the ONLY nref-- was at process DEATH, so a live process
     * could never release a surface: every resize and every window close leaked its
     * buffer and its id, forever. §11 ("refcount, do not handshake") is built on either
     * side dropping while both are alive.
     *
     * The real test is therefore a LEAK test. Churn far more surface memory than the
     * machine has: 400 iterations x 8 MiB = 3.2 GB through a 1 GB box. If unmap does not
     * genuinely free the pages, the VA sections, the page list and the id, this runs out
     * and fails long before the end. */
    int leaked = 0;
    for (int i = 0; i < 400; i++) {
        int sid = sys_shm_create(1920u * 1088u * 4u, 0);      /* a maximised window, every time */
        if (sid < 0) { printf("shmtest: LEAK — shm_create failed at iteration %d\n", i); leaked = 1; break; }
        volatile unsigned *q = sys_shm_map(sid);
        if (!q) { printf("shmtest: LEAK — shm_map failed at iteration %d\n", i); leaked = 1; break; }
        q[0] = 0xA5A50000u + (unsigned)i;
        if (q[0] != 0xA5A50000u + (unsigned)i) { printf("shmtest: FAIL readback at %d\n", i); leaked = 1; break; }
        if (sys_shm_unmap(sid) != 0) { printf("shmtest: FAIL — shm_unmap returned an error at %d\n", i); leaked = 1; break; }
    }
    if (!leaked)
        printf("shmtest: unmap churned 400 x 8MiB surfaces (3.2 GB through a 1 GB box) — NO LEAK\n");

    /* Unmapping an id this process does not HOLD must fail, not corrupt. Create one and
     * never map it: the object exists, but this space has no ref on it. */
    int unheld = sys_shm_create(4096, 0);
    if (unheld < 0) printf("shmtest: FAIL — could not create the unheld probe\n");
    else if (sys_shm_unmap(unheld) == 0)
        printf("shmtest: FAIL — unmap of an id we never mapped succeeded\n");
    else
        printf("shmtest: unmap of an unheld id rejected OK\n");

    sys_exit(0);
}
