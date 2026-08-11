/*
 * libc-threads.c — make libc.so's heap safe for more than one thread.
 *
 * newlib ships `__malloc_lock` / `__malloc_unlock` as no-op stubs (`bx lr`),
 * because a port is expected to supply them if it has threads. XTOS now does, so
 * without this two threads of one process in `malloc` at the same time corrupt
 * the arena — and every xtc `new` goes through `_xtc_alloc` -> `malloc`, so that
 * is not an exotic path, it is the first thing a threaded program does.
 *
 * This is the "one heap lock" of the xtc threading design
 * (fpga-xtc/docs/Design/threading.md §4.2). Per-process arenas are the faster
 * answer and are a later question; a lock is the correct one, and contention on
 * it is not what a threaded XTOS program will be limited by.
 *
 * ── How it is installed ──────────────────────────────────────────────────
 *
 * libc.so is linked with `--whole-archive newlib-pic/libc.a`, so newlib's own
 * stubs are already in the image and a second definition would be a duplicate.
 * `-Wl,--wrap=__malloc_lock` instead redirects newlib's *references* here, which
 * needs no surgery on the validated libc.a.
 *
 * ── Why the lock word is in the right place ──────────────────────────────
 *
 * It lives in libc.so's data, which the kernel copies-on-write per process. So
 * each process gets its own lock guarding its own heap, and the threads that
 * share that heap share exactly the lock that protects it. Nothing is shared
 * between processes, which is what we want: they have separate arenas.
 *
 * ── The cost when there are no threads ───────────────────────────────────
 *
 * An uncontended lock is one `ldrex`/`strex` pair and no syscall — a handful of
 * cycles against malloc's hundreds. That is cheap enough that gating it on "does
 * this process have threads?" (which libc cannot cheaply know) would cost more
 * than it saves.
 */
#include <stdint.h>
#include "xtsys.h"

/* 0 = free, 1 = held, 2 = held and someone is waiting. The 2 state is what lets
 * unlock skip the wake syscall when nobody is waiting, which is every unlock in a
 * single-threaded program and most of them in a threaded one. */
static volatile uint32_t g_malloc_lock;
static volatile uint32_t g_malloc_owner;   /* TPIDRURO of the holder; 0 = free */
static uint32_t          g_malloc_depth;   /* only ever touched by the holder */

/* Who am I? TPIDRURO carries tid+1, written by the kernel on every context switch
 * and read-only at PL0 — one `mrc`, no syscall, and a program cannot forge it. A
 * kernel-context caller reads 0, which must not be mistaken for "I am the holder",
 * so it folds to a distinct sentinel. */
static inline uint32_t self_id(void)
{
    uint32_t v;
    __asm__ volatile("mrc p15,0,%0,c13,c0,3" : "=r"(v));
    return v ? v : 0xFFFFFFFFu;
}

static long sc3(long n, long a0, long a1, long a2)
{
    register long r7 __asm__("r7") = n;
    register long r0 __asm__("r0") = a0;
    register long r1 __asm__("r1") = a1;
    register long r2 __asm__("r2") = a2;
    __asm__ volatile("svc #1" : "+r"(r0) : "r"(r7), "r"(r1), "r"(r2) : "memory");
    return r0;
}

static uint32_t cas32(volatile uint32_t *p, uint32_t expect, uint32_t want)
{
    uint32_t old, fail;
    for (;;) {
        __asm__ volatile("ldrex %0, [%1]" : "=&r"(old) : "r"(p) : "memory");
        if (old != expect) { __asm__ volatile("clrex" ::: "memory"); return old; }
        __asm__ volatile("strex %0, %2, [%1]" : "=&r"(fail) : "r"(p), "r"(want) : "memory");
        if (!fail) break;
    }
    __asm__ volatile("dmb ish" ::: "memory");
    return old;
}

static uint32_t swap32(volatile uint32_t *p, uint32_t want)
{
    uint32_t old, fail;
    do {
        __asm__ volatile("ldrex %0, [%1]" : "=&r"(old) : "r"(p) : "memory");
        __asm__ volatile("strex %0, %2, [%1]" : "=&r"(fail) : "r"(p), "r"(want) : "memory");
    } while (fail);
    __asm__ volatile("dmb ish" ::: "memory");
    return old;
}

/* RECURSIVE, and it has to be: newlib's `realloc` and `memalign` take this lock and
 * then call `malloc` underneath it, which takes it again. A plain mutex deadlocks
 * there — not on some exotic path, but the first time a program grows a buffer.
 * (`ls` through a pipe was enough.)
 *
 * The owner is compared by TPIDRURO, so recursion is recognised only for the thread
 * that actually holds the lock. A bare depth counter — no owner — would be worse
 * than no lock at all: the SECOND thread would read depth > 0, conclude the lock was
 * already its own, and walk straight into the arena. */
void __wrap___malloc_lock(void *reent)
{
    (void)reent;
    uint32_t me = self_id();
    if (g_malloc_owner == me) { g_malloc_depth++; return; } /* already ours: recurse */
    if (cas32(&g_malloc_lock, 0, 1) != 0) {                 /* contended */
        while (swap32(&g_malloc_lock, 2) != 0)              /* mark, then sleep */
            sc3(SYS_futex_wait, (long)&g_malloc_lock, 2, -1);
    }
    g_malloc_owner = me;                                    /* only the holder writes this */
    g_malloc_depth = 1;
}

void __wrap___malloc_unlock(void *reent)
{
    (void)reent;
    if (g_malloc_depth > 1) { g_malloc_depth--; return; }   /* still nested */
    g_malloc_depth = 0;
    g_malloc_owner = 0;                                     /* release ownership BEFORE the word */
    __asm__ volatile("dmb ish" ::: "memory");
    if (swap32(&g_malloc_lock, 0) == 2)                     /* only wake if someone waited */
        sc3(SYS_futex_wake, (long)&g_malloc_lock, 1, 0);
}
