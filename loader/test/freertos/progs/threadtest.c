/* /bin/threadtest — the XTOS thread + futex primitives, end to end.
 *
 * This is the kernel-side proof for xtc threading Phase 3 (fpga-xtc
 * docs/Design/threading.md §5): everything the xtc Thread/Mutex/Cond/Sem/Pool
 * classes ride on, exercised from C so a failure lands on the kernel and not on
 * the compiler's runtime.
 *
 * Six tests, each with an EXACT expected answer — "about right" would let a lost
 * wakeup or a dropped increment through, which is the whole class of bug this
 * feature can have:
 *
 *   1. spawn + join       — two workers compute, main collects both results
 *   2. shared memory      — a worker writes a global the main thread reads back
 *   3. mutex (futex)      — 4 threads x 2000 increments of ONE counter = 8000
 *   4. TLS                — each thread's TPIDRURW block stays its own
 *   5. detach             — a detached thread runs and reclaims without a join
 *   6. rendezvous         — futex wait/wake used as a condition, both directions
 *
 * Test 3 is the one that cannot be faked: with a broken mutex the total comes out
 * LOW (lost read-modify-writes), and it is nondeterministically low, so a single
 * green run of a broken build is very unlikely.
 */
#include <stdio.h>
#include "usys.h"

/* ---- a userspace mutex over one atomic word + the futex pair ---------------
 * This is deliberately the shape the xtc runtime will use (threading.md §5.3): the
 * uncontended path is ldrex/strex only — no syscall — and the kernel is entered
 * solely to block and to wake. 0 = free, 1 = held, 2 = held and someone is waiting.
 */
typedef volatile unsigned mutex_t;

static unsigned cas(volatile unsigned *p, unsigned expect, unsigned want)
{
    unsigned old, fail;
    do {
        __asm__ volatile("ldrex %0, [%1]" : "=&r"(old) : "r"(p));
        if (old != expect) { __asm__ volatile("clrex"); return old; }
        __asm__ volatile("strex %0, %2, [%1]" : "=&r"(fail) : "r"(p), "r"(want) : "memory");
    } while (fail);
    __asm__ volatile("dmb ish" ::: "memory");
    return old;
}

static unsigned swap_word(volatile unsigned *p, unsigned want)
{
    unsigned old, fail;
    do {
        __asm__ volatile("ldrex %0, [%1]" : "=&r"(old) : "r"(p));
        __asm__ volatile("strex %0, %2, [%1]" : "=&r"(fail) : "r"(p), "r"(want) : "memory");
    } while (fail);
    __asm__ volatile("dmb ish" ::: "memory");
    return old;
}

static void mutex_lock(mutex_t *m)
{
    if (cas(m, 0, 1) == 0) return;                  /* uncontended: no syscall */
    while (swap_word(m, 2) != 0)                    /* contended: mark, then sleep */
        sys_futex_wait(m, 2, -1);
}

static void mutex_unlock(mutex_t *m)
{
    __asm__ volatile("dmb ish" ::: "memory");
    if (swap_word(m, 0) == 2) sys_futex_wake(m, 1); /* only wake if someone waited */
}

/* ---- test state (shared: these ARE the shared mutable state) -------------- */
static int      g_result[4];
static int      g_shared_word;
static mutex_t  g_lock;
static int      g_counter;
static volatile unsigned g_ping, g_pong;
static volatile int g_detached_ran;
static int      g_tls_ok = 1;

static void worker_compute(void *arg)
{
    int id = (int)(long)arg;
    int acc = 0;
    for (int i = 1; i <= 1000; i++) acc += i * id;
    g_result[id] = acc;
}

static void worker_shared(void *arg)
{
    (void)arg;
    g_shared_word = 0x5EED;                          /* main reads this after the join */
}

static void worker_count(void *arg)
{
    (void)arg;
    for (int i = 0; i < 2000; i++) {
        mutex_lock(&g_lock);
        g_counter = g_counter + 1;                   /* deliberately a read-modify-write */
        mutex_unlock(&g_lock);
    }
}

static void worker_tls(void *arg)
{
    int slot = (int)(long)arg;
    static int blocks[4];                            /* one per worker, distinct addresses */
    sys_thread_tls(&blocks[slot]);
    blocks[slot] = 0xA000 + slot;
    for (int i = 0; i < 200; i++) {                  /* churn, so a shared slot shows up */
        int *mine = (int *)sys_tls_get();
        if (mine != &blocks[slot] || *mine != 0xA000 + slot) g_tls_ok = 0;
        sys_thread_self();                           /* a syscall, to force switches */
    }
}

static void worker_detached(void *arg)
{
    (void)arg;
    g_detached_ran = 1;
}

/* rendezvous: worker waits for ping, answers with pong. Proves wake reaches a
 * thread that is genuinely blocked in the kernel, in both directions. */
static void worker_rendezvous(void *arg)
{
    (void)arg;
    while (g_ping == 0) sys_futex_wait(&g_ping, 0, -1);
    g_pong = 1;
    sys_futex_wake(&g_pong, 1);
}

/* test 7 is its own run: it ENDS the process on purpose. A worker writing through a
 * null pointer must take the whole process down (xtc threading.md §5.5) — a surviving
 * main thread would be running on state a dead thread may have half-mutated, and on
 * locks it will never release. The OS must stay up. */
static void worker_fault(void *arg)
{
    (void)arg;
    *(volatile int *)0 = 1;
    g_shared_word = 0xBAD;                           /* never reached */
}

/* test 8, also its own run: recurse until the thread's stack hits its GUARD page.
 * The guard is the reason a thread stack is not just "some pages" — without it an
 * overflow would walk quietly into the thread below and corrupt it. This asks the
 * kernel to prove the page is there and unmapped: the report must say STACK
 * OVERFLOW, name the worker task, and the process must die. */
static int burn_stack(int depth)
{
    volatile char pad[1024];
    for (int i = 0; i < (int)sizeof pad; i += 256) pad[i] = (char)depth;
    if (depth > 100000) return (int)pad[0];          /* never reached; stops the optimiser */
    return burn_stack(depth + 1) + (int)pad[0];
}

static void worker_overflow(void *arg)
{
    (void)arg;
    g_shared_word = burn_stack(0);
}

void _app_entry(int argc, char **argv)
{
    int fails = 0;
    /* `threadtest N` runs test N alone — the tests share one address space, so when
     * one of them breaks the scheduler the others' output is worthless. Bisecting
     * needs to be one command, not one rebuild. */
    int only = 0;
    if (argc > 1 && argv[1] && argv[1][0] >= '1' && argv[1][0] <= '8') only = argv[1][0] - '0';
#define WANT(n) (only == 0 || only == (n))

    printf("threadtest: main tid=%ld pid=%ld\n", sys_thread_self(), sys_getpid());

    if (WANT(1) || WANT(2)) {
    /* 1 + 2 — spawn, join, and shared memory */
    long a = sys_thread_create(worker_compute, (void *)2L, 0);
    long b = sys_thread_create(worker_compute, (void *)3L, 0);
    long c = sys_thread_create(worker_shared, 0, 0);
    if (a < 0 || b < 0 || c < 0) { printf("threadtest: FAIL create (%ld %ld %ld)\n", a, b, c); return; }
    int ra = -1, rb = -1;
    sys_thread_join((int)a, &ra);
    sys_thread_join((int)b, &rb);
    sys_thread_join((int)c, 0);
    printf("  spawn/join   : %d %d (want 1001000 1501500)%s\n", g_result[2], g_result[3],
           (g_result[2] == 1001000 && g_result[3] == 1501500) ? "" : "   <-- FAIL");
    if (g_result[2] != 1001000 || g_result[3] != 1501500) fails++;
    printf("  shared state : 0x%X (want 0x5EED)%s\n", g_shared_word,
           g_shared_word == 0x5EED ? "" : "   <-- FAIL");
    if (g_shared_word != 0x5EED) fails++;
    }

    if (WANT(3)) {
    /* 3 — the mutex under real contention */
    long t[4];
    for (int i = 0; i < 4; i++) t[i] = sys_thread_create(worker_count, 0, 0);
    for (int i = 0; i < 4; i++) if (t[i] > 0) sys_thread_join((int)t[i], 0);
    printf("  mutex counter: %d (want 8000)%s\n", g_counter,
           g_counter == 8000 ? "" : "   <-- FAIL");
    if (g_counter != 8000) fails++;
    }

    if (WANT(4)) {
    /* 4 — thread-local storage */
    long t[4];
    for (int i = 0; i < 4; i++) t[i] = sys_thread_create(worker_tls, (void *)(long)i, 0);
    for (int i = 0; i < 4; i++) if (t[i] > 0) sys_thread_join((int)t[i], 0);
    printf("  tls isolation: %s\n", g_tls_ok ? "ok" : "SHARED   <-- FAIL");
    if (!g_tls_ok) fails++;
    }

    if (WANT(5)) {
    /* 5 — detach: no join, and the slot must come back on its own */
    long d = sys_thread_create(worker_detached, 0, 0);
    if (d > 0) sys_thread_detach((int)d);
    for (int i = 0; i < 100 && !g_detached_ran; i++) __syscall(SYS_nanosleep, 1000, 0, 0);
    printf("  detach       : %s\n", g_detached_ran ? "ran" : "never ran   <-- FAIL");
    if (!g_detached_ran) fails++;
    /* the detached slot must be reusable — if detach leaked it, this eventually fails */
    for (int i = 0; i < 8; i++) {
        long r = sys_thread_create(worker_detached, 0, 0);
        if (r < 0) { printf("  detach reuse : exhausted after %d   <-- FAIL\n", i); fails++; break; }
        sys_thread_join((int)r, 0);
    }
    }

    if (WANT(6)) {
    /* 6 — futex as a rendezvous, both directions */
    long rv = sys_thread_create(worker_rendezvous, 0, 0);
    g_ping = 1;
    sys_futex_wake(&g_ping, 1);
    while (g_pong == 0) sys_futex_wait(&g_pong, 0, 1000);
    if (rv > 0) sys_thread_join((int)rv, 0);
    printf("  rendezvous   : %s\n", g_pong ? "ok" : "no wake   <-- FAIL");
    if (!g_pong) fails++;
    }

    if (only == 8) {
        printf("  overflow     : worker will run off its stack into the guard page\n");
        fflush(stdout);
        long o = sys_thread_create(worker_overflow, 0, 0);
        if (o < 0) { printf("  overflow     : create failed   <-- FAIL\n"); return; }
        for (int i = 0; i < 2000; i++) __syscall(SYS_nanosleep, 1000, 0, 0);
        printf("  overflow     : STILL ALIVE after 2s   <-- FAIL\n");   /* must not print */
        fflush(stdout);
        return;
    }

    if (only == 7) {
        printf("  fault        : worker about to fault; the PROCESS must die\n");
        fflush(stdout);
        long f = sys_thread_create(worker_fault, 0, 0);
        if (f < 0) { printf("  fault        : create failed   <-- FAIL\n"); return; }
        for (int i = 0; i < 2000; i++) __syscall(SYS_nanosleep, 1000, 0, 0);
        printf("  fault        : STILL ALIVE after 2s   <-- FAIL\n");   /* must not print */
        fflush(stdout);
        return;
    }

    printf("threadtest: %s (%d failure%s)\n", fails ? "FAIL" : "PASS", fails, fails == 1 ? "" : "s");
    fflush(stdout);
}
