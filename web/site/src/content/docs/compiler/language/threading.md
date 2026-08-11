---
title: Threading
description: Thread, Mutex, Guard, Cond, Sem, Atomic and Pool on the native targets — plus the ARC refcount decision that makes them safe.
---

Threading exists on the **native targets only** — `arm64`, `x86_64`, `win64` and
`arm9`. On `xt6502` and `m68k` every one of these classes is a hard `#error`
rather than a stub, because a threading API that silently runs single-threaded is
worse than one that refuses to build.

The surface is deliberately small: `Thread`, `Mutex` (+ `Guard`), `Cond`, `Sem`,
`Atomic`, `ThreadLocal`, and `Pool.forRange`.

## The part that is not in the library

Two threads touching one object race on its **ARC refcount**. A non-atomic
increment that loses a race under-counts, and the object is freed while still in
use — which surfaces arbitrarily far from the cause.

So the back ends emit the refcount update as an atomic read-modify-write. The
decision is made **per module**, and switches on exactly when the module
references the thread-creation runtime — i.e. when the program spawns a thread.
You do not ask for it.

`-fthread-safe-arc` and `-fno-thread-safe-arc` force it either way, for the cases
where the automatic decision is wrong: a library compiled separately that will be
used by a threaded program wants the flag on.

## Spawning

A thread body is a bound method (`^`), so the thread's state is just the object
the method belongs to — no `void*` context, no cast on entry.

```c
class Worker : Object
{
    i32 id;
    i32 result;
    void run(void) { … }            // this runs on the new thread
}

Worker* a = Worker.withId((i32)2);
Thread* ta = Thread.spawn(&a.run);
ta.join();
```

| Method | Effect |
|---|---|
| `Thread.spawn(body^)` | Start a thread running `body`. Returns a `Thread*`. |
| `join()` | Block until the thread finishes. Returns `false` if it could not be joined. |
| `detach()` | Let it run unjoined; its resources are released when it exits. |
| `isValid()` | `false` if the thread failed to start. |
| `Thread.yield()` | Hint to the scheduler. |
| `Thread.sleepMs(u32)` | Sleep the calling thread. |

## Mutex and Guard

`Guard.on(m)` locks now and unlocks when the guard is released at end of scope —
including on an early `return` or a `throw`, which is what makes it worth using
over a bare `lock()`/`unlock()` pair.

```c
class Ledger : Object
{
    Mutex* lock;
    i32    balance;
    void init(void) { lock = new Mutex(); balance = (i32)0; }

    void deposit(i32 amount)
    {
        Guard* g = Guard.on(lock);
        balance = balance + amount;
    }                                    // unlocked here, whatever the exit
}
```

`Mutex` also offers `lock()`, `unlock()` and `tryLock()` directly when the scope
does not match the critical section.

## Atomics

When the shared state *is* one word, an `Atomic` is the better tool: no lock, no
scope, and no way to forget to unlock.

```c
Atomic* hits = Atomic.withValue((i32)0);
hits.add((i32)5);
hits.load();
hits.store((i32)0);
hits.compareAndSwap((i32)12, (i32)100);      // true if it was 12
```

## Cond and Sem

`Cond` is a condition variable paired with a `Mutex` — wait for a predicate to
become true without spinning. `Sem` is a counting semaphore, for bounding a
resource rather than protecting one.

## Data parallelism

`Pool.forRange(from, to, body^)` calls the body once per index, spread across the
available cores, and blocks until every index has been handled. The body is a `^`
too, so it can accumulate into the object it belongs to:

```c
class Squares : Object
{
    Atomic* total;
    void init(void) { total = Atomic.withValue((i32)0); }
    void one(i32 i) { total.add(i * i); }
}

Squares* sq = new Squares();
Pool.forRange((i32)1, (i32)11, &sq.one);     // 385
```

`Pool.forRangeWithThreads(from, to, body, n)` pins the thread count when you need
to.

## Worked example

```c
// threading.xc — Thread, Mutex, Guard, Atomic and Pool.
#import "Stdio.xc"
#import "Foundation.xc"
#import "Thread.xc"
#import "Mutex.xc"
#import "Atomic.xc"
#import "Pool.xc"

class Worker : Object
{
    i32 id;
    i32 result;
    void init(void) { id = (i32)0; result = (i32)0; }
    static Worker* withId(i32 n) { Worker* w = new Worker(); w.id = n; return w; }

    void run(void)
    {
        i32 acc = (i32)0;
        for (i32 i = (i32)1; i <= (i32)1000; i = i + (i32)1) acc = acc + i * id;
        result = acc;
    }
}

class Ledger : Object
{
    Mutex* lock;
    i32    balance;
    void init(void) { lock = new Mutex(); balance = (i32)0; }

    void deposit(i32 amount)
    {
        Guard* g = Guard.on(lock);
        balance = balance + amount;
    }
}

class Summer : Object
{
    Ledger* ledger;
    void init(void) { ledger = 0; }
    void addMany(void)
    {
        for (i32 i = (i32)0; i < (i32)500; i = i + (i32)1) ledger.deposit((i32)2);
    }
}

class Squares : Object
{
    Atomic* total;
    void init(void) { total = Atomic.withValue((i32)0); }
    void one(i32 i) { total.add(i * i); }
}

i32 main(void)
{
    // ---- spawn and join ----
    Worker* a = Worker.withId((i32)2);
    Worker* b = Worker.withId((i32)3);
    Thread* ta = Thread.spawn(&a.run);
    Thread* tb = Thread.spawn(&b.run);
    ta.join();
    tb.join();
    Stdio.printf("workers %ld %ld\n", a.result, b.result);

    // ---- a mutex around shared state ----
    Ledger* led = new Ledger();
    Summer* s1 = new Summer(); s1.ledger = led;
    Summer* s2 = new Summer(); s2.ledger = led;
    Thread* t1 = Thread.spawn(&s1.addMany);
    Thread* t2 = Thread.spawn(&s2.addMany);
    t1.join();
    t2.join();
    Stdio.printf("balance %ld\n", led.balance);

    // ---- atomics without a lock ----
    Atomic* hits = Atomic.withValue((i32)0);
    hits.add((i32)5);
    hits.add((i32)7);
    Stdio.printf("atomic %ld, cas ok %d, after %ld\n",
                 hits.load(),
                 (i16)(hits.compareAndSwap((i32)12, (i32)100) ? 1 : 0),
                 hits.load());

    // ---- data parallelism ----
    Squares* sq = new Squares();
    Pool.forRange((i32)1, (i32)11, &sq.one);
    Stdio.printf("sum of squares 1..10 = %ld\n", sq.total.load());

    return 0;
}
```

```
workers 1001000 1501500
balance 2000
atomic 12, cas ok 1, after 100
sum of squares 1..10 = 385
```

The balance is deterministic only because `deposit` takes the lock: two threads,
500 deposits of 2 each.

## Runtime

pthreads on macOS, raw `clone` + futex (Linux) or kernel32 (Windows) on the
freestanding targets, and XTOS threads on `arm9`. The macOS runtime source is
shared by both macOS runtimes so they cannot drift.

On `arm9` the kernel provides only thread lifecycle and a futex; `Mutex`, `Cond`
and `Sem` are built over it in user space, so an uncontended lock is
`ldrex`/`strex` and never enters the kernel. Two things there differ from a host,
and both are deliberate:

- **A faulting thread ends its whole process.** It was holding shared locks and
  half-mutated shared state, so a surviving sibling would run on data nobody can
  vouch for. See [XTOS threads](/os/threads/).
- **`cpuCount()` answers 1**, honestly, because XTOS owns one A9 core — so a
  bare `Pool.forRange` runs one worker. Pin the count with
  `Pool.forRangeWithThreads` when a workload wants more (the cap is 128 threads
  per process).

**Known gap:** the static-initialiser guard (`__sinit_<Class>`) is still a
check-then-act, so two threads racing to first-touch the same class's statics can
both run the initialiser.
