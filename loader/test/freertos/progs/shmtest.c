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
    /* XT_SHM_CONTIG is SUPPORTED as of stage 4 (plv_alloc), so it must now be ACCEPTED.
     * Free it immediately: leaking it would consume plv section 0 and shift every later
     * contiguous allocation, which is exactly the bug this line used to cause. */
    { int probe = sys_shm_create(4096, XT_SHM_CONTIG);
      if (probe < 0) printf("shmtest: FAIL — XT_SHM_CONTIG rejected, but plv_alloc exists\n");
      else { sys_shm_map(probe); sys_shm_unmap(probe);
             printf("shmtest: XT_SHM_CONTIG accepted OK\n"); } }
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

    /* ---- page recycling must NOT leak the previous owner's data --------------------
     * dpage_raw now guarantees a zeroed page instead of every caller memset'ing again
     * (which doubled the cost of every surface allocation and every heap demand fault).
     * The guarantee rests on: dfree_raw scrubs the whole page on free, then stores the
     * free-list link in WORD 0 — and dpage_raw clears exactly that word on reuse. Word 0
     * therefore holds a KERNEL POINTER right up until the page is handed out, so if the
     * clear is wrong this leaks one straight to userspace.
     * Write a sentinel over a whole surface, free it, allocate again (which reuses those
     * very pages, LIFO), and demand zeros. */
    int sa = sys_shm_create(1u << 20, 0);
    volatile unsigned *pa = sa >= 0 ? sys_shm_map(sa) : 0;
    if (pa) {
        for (unsigned i = 0; i < (1u << 18); i++) pa[i] = 0xDEADBEEFu;   /* 1 MB of sentinel */
        sys_shm_unmap(sa);                                               /* -> back to the pool */
        int sb = sys_shm_create(1u << 20, 0);                            /* reuses those pages */
        volatile unsigned *pb = sb >= 0 ? sys_shm_map(sb) : 0;
        if (pb) {
            unsigned dirty = 0, w0 = pb[0];
            for (unsigned i = 0; i < (1u << 18); i++) if (pb[i] != 0) dirty++;
            printf("shmtest: recycled page — %u non-zero words, word0=0x%08x %s\n",
                   dirty, w0, dirty == 0 ? "OK (no data leak, no kernel pointer)" : "FAIL — LEAK");
            sys_shm_unmap(sb);
        }
    }

    /* ---- STAGE 4: XT_SHM_CONTIG (plv_alloc) --------------------------------------
     * The blitter and compositor are DMA engines with NO MMU: they read PHYSICAL
     * addresses and accumulate base+stride, so a surface they touch must be physically
     * CONTIGUOUS. The page pool cannot give that. XT_SHM_CONTIG allocates from plv
     * (0x3800_0000, 128 MB — the memory map reserves it for exactly "GEM window
     * surfaces").
     *
     * Prove BOTH placement and contiguity from userspace, using sys_devmem to peek
     * PHYSICAL memory: write through the mapped VA, then read the raw physical address
     * and demand the same bytes. This is the first CONTIG object, so plv_alloc hands out
     * PLV_BASE. If the last word also reads back at base+size-4, the run is contiguous.  */
    unsigned csz = 1920u * 1088u * 4u;                  /* a maximised window */
    int cid = sys_shm_create(csz, XT_SHM_CONTIG);
    if (cid < 0) { printf("shmtest: FAIL — XT_SHM_CONTIG rejected (plv_alloc missing?)\n"); }
    else {
        volatile unsigned *cp = sys_shm_map(cid);
        if (!cp) printf("shmtest: FAIL — could not map a CONTIG surface\n");
        else {
            unsigned clast = csz / 4u - 1u;
            cp[0] = 0xC0117E00u; cp[clast] = 0xC0117EFFu;
            unsigned va0 = cp[0], val = cp[clast];               /* readback through the MAPPING */
            unsigned long pbase = 0x38000000ul;                  /* PLV_BASE: first contig alloc */
            long w0 = sys_devmem(pbase, 0, 0);                   /* peek PHYSICAL */
            long wl = sys_devmem(pbase + (unsigned long)clast * 4ul, 0, 0);
            printf("shmtest: CONTIG @VA %p  via-VA: first=0x%08x last=0x%08x\n", (void *)cp, va0, val);
            printf("shmtest: CONTIG phys 0x%lx: first=0x%08lx last=0x%08lx %s\n",
                   pbase, (unsigned long)w0, (unsigned long)wl,
                   (w0 == (long)0xC0117E00u && wl == (long)0xC0117EFFu)
                     ? "OK (in plv, and PHYSICALLY CONTIGUOUS)" : "FAIL");
            sys_shm_unmap(cid);
        }
    }
    /* plv is a BUDGET (128 MB): 8 MiB surfaces must run out at ~16, not forever. */
    int cn = 0; static int cids[40];
    for (int i = 0; i < 40; i++) {
        int q = sys_shm_create(csz, XT_SHM_CONTIG);
        if (q < 0) break;
        if (!sys_shm_map(q)) break;
        cids[cn++] = q;
    }
    printf("shmtest: plv held %d x 8MiB contiguous surfaces (128 MB budget -> expect ~16)\n", cn);
    int cf = 0; for (int i = 0; i < cn; i++) if (sys_shm_unmap(cids[i]) == 0) cf++;
    printf("shmtest: released %d/%d contiguous surfaces — %s\n", cf, cn, cf == cn ? "OK" : "FAIL");

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
