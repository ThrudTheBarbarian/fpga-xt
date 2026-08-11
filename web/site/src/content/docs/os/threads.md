---
title: "XTOS threads"
description: "Threads inside one XTOS process: the thread lifecycle and futex syscalls, guarded per-thread stacks in a globally-addressed window, TPIDRURW thread-local storage, and process-wide death when a thread faults."
---


XTOS runs several flows of control inside one process. A process is an **address
space**; a thread is a **flow of control in it**. Spawn gives isolation, threads
give shared-memory parallelism, and the two compose — a GUI app can keep a worker
painting into a back buffer while its main thread pumps events, without giving up
the MMU isolation that keeps it from touching anything else.

This is threading Phase 3 of the xtc design (`fpga-xtc/docs/Design/threading.md`
§5): the kernel side of the `Thread` / `Mutex` / `Cond` / `Sem` / `Atomic` /
`ThreadLocal` / `Pool` classes the compiler already ships on the host targets.

## What the kernel provides, and what it does not

Two things: thread **lifecycle**, and a **futex** to block on.

That is a deliberate split. `Mutex`, `Cond` and `Sem` are built in *user space*
over one atomic word plus futex wait/wake, so:

* an uncontended lock or unlock is `ldrex`/`strex` and nothing else — no syscall,
  no ring transition, no scheduler involvement;
* the kernel is entered only to block and to wake, which is exactly when the cost
  of a syscall is irrelevant next to what it is replacing;
* the kernel grows **one** well-understood mechanism instead of a mutex/cond/sem
  zoo, each with its own lifecycle, its own leak and its own teardown path.

The A9's exclusive monitor is unprivileged, so every atomic in that user-space
half runs at PL0 with no kernel help — the same property that let the ARC
refcount be `ldrexh`/`strexh` rather than an interrupt-disable bracket.

## The syscalls

Block `0x100` (process/task), continuing from the existing calls. Numbers are
frozen, as everything in `loader/kernel/xtsys.h` is.

| Number | Call | Effect |
|---|---|---|
| `0x10E` | `thread_create(entry, arg, stack_bytes)` | start `entry(arg)` at PL0 on a fresh guarded stack → tid |
| `0x10F` | `thread_exit(retval)` | end **this** thread only |
| `0x110` | `thread_join(tid, int *retval)` | block until `tid` exits, collect its value |
| `0x111` | `thread_detach(tid)` | nobody will join: reclaim at exit |
| `0x112` | `thread_self()` | this thread's tid (0 = the main thread) |
| `0x113` | `thread_tls(ptr)` | set this thread's TLS block pointer |
| `0x114` | `futex_wait(uaddr, val, timeout_ms)` | block while `*uaddr == val` |
| `0x115` | `futex_wake(uaddr, n)` | wake up to `n` waiters (`n < 0` = all) |

`thread_create` runs the new thread at the **creator's own priority**, so a
compute thread cannot starve the process's main thread — they round-robin.

`futex_wait`'s compare and enqueue are **one atomic step** against `futex_wake`.
That is the whole point of the primitive: if they were separate, a waker that
lands in between would write the new value and wake an empty queue, and the
waiter would then sleep forever on a condition that has already happened. The
wait queue is keyed on **(process, address)** — a VA means different memory in
different spaces, so keying on the address alone would let unrelated processes
wake, or fail to wake, each other.

## What a thread owns, and what it shares

Shared: the L1 translation table and ASID, the fd table, the cwd, the signal
dispositions, the heap, and every global. Private: the **stack**, the
**TPIDRURW** TLS pointer, and the saved PL0 context the blocking-syscall
deferral parks in.

That last one was a correctness fix, not tidying. The deferral context
(`dctx`/`dnum`/`da*`) lived in `proc_t` because a process had exactly one flow;
two threads deferring at once would have overwritten each other's return frame.
It now lives in `thread_t`, and `proc->cur` — maintained by the context-switch
hook — is how the deferral and signal paths reach the right one.

## Thread stacks: the rule that shapes the design

A thread's stack is private pages with an unmapped **guard page** below it, so an
overflow aborts precisely instead of walking into the thread below. It is carved
from pool pages by `vm.c` rather than from a static arena, so it costs nothing
until a thread exists.

But the addresses are **global**, and that is not an accident:

> A task stack must be PL1-reachable in *every* address space, not just its
> owner's.

FreeRTOS's SWI path runs `vTaskSwitchContext` — and therefore the TTBR0 swap in
`traceTASK_SWITCHED_IN` — **on the outgoing task's own stack**. A stack mapped
only in its owner's space disappears from under the switch, and `vm_switch`'s
epilogue pops garbage into PC. It does exactly that, and the symptom is a jump to
address 0 out of `vm_switch` with the scheduler's ready lists then asserting.

So process slot *S* owns section `XTOS_TSTK_VA + S * 1 MB`; no two processes
share a stack VA. What is private is the **permissions**: every space maps every
thread stack PL1-RW / PL0-none, and only the owning space flips its own threads'
pages to PL0-RW. A process can read and write its own thread stacks and nothing
else's, while the kernel can always reach the one it is standing on.

That is the same contract `stackguard.c` has always given main-thread stacks —
this is that model generalised onto pool pages, which is what makes it the
template main-thread stacks can migrate to. The window sits at `0x6000_0000`,
above the shm window and outside DDR, so it costs no DDR, needs no entry in the
per-process window band (`XTOS_POOL_FLOOR`), and cannot collide with an
identity-mapped pool page.

## Thread-local storage

`TPIDRURW`, saved and restored per thread on every context switch. A TLS read
from PL0 is therefore one `mrc` and an index — no syscall, no table walk, no
lock.

`TPIDRURW` is **PL0-writable**, so it is saved on switch-*out* as well as loaded
on switch-*in*: a runtime that set its own block directly would otherwise lose it
at the next switch, which is the kind of bug that only shows up under load.
`SYS_thread_tls` exists so a runtime can set it and have the kernel own the
save/restore; either route works.

Its read-only sibling **`TPIDRURO`** carries the thread's **tid + 1**, written by
the kernel on switch-in. PL0 can read it but *not* write it, which is what makes
it an identity rather than a hint — libc's recursive malloc lock asks "is this
lock already mine?" on every allocation, and a syscall for that would cost more
than the lock it guards.

## The heap

newlib ships `__malloc_lock` / `__malloc_unlock` as no-op stubs — a port supplies
them if it has threads. XTOS now does, so `libc.so` carries a real one
(`loader/libc-threads.c`), futex-backed like everything else. Without it two
threads of one process in `malloc` corrupt the arena, and since every xtc `new`
bottoms out in `malloc`, that is the first thing a threaded program would hit
rather than an exotic path.

It is installed with `-Wl,--wrap=__malloc_lock`, because `libc.so` is linked
`--whole-archive` over the validated `newlib-pic/libc.a` and a second definition
would be a duplicate; wrapping redirects newlib's *references* without touching
the archive.

The lock word lives in libc's data, which is copy-on-write per process — so each
process gets its own lock guarding its own arena, and the threads that share that
heap share exactly the lock that protects it.

It is **recursive**, and it has to be: newlib's `realloc` and `memalign` take the
lock and then call `malloc` underneath it. A plain mutex deadlocks there — not on
some exotic path, but the first time a program grows a buffer (`ls` through a
pipe was enough to hang it).

Recursion is recognised by **owner**, not by a bare depth count. A depth counter
with no owner would be worse than no lock at all: the second thread would read
depth > 0, conclude the lock was already its own, and walk straight into the
arena. The owner is read from **`TPIDRURO`**, which the kernel writes with the
thread's tid on every context switch and which PL0 cannot write — so "is this
lock mine?" is one `mrc`, no syscall, and unforgeable.

This is the xtc design's §4.2 "one heap lock". Per-thread arenas are the faster
answer and a later question.

## Death is process-wide

A thread that faults takes its **whole process** down. This is deliberate: it was
holding shared locks and half-mutated shared state, so a surviving sibling would
be running on data nobody can vouch for. There is no "one thread crashed, carry
on" here — that is a promise a shared address space cannot keep.

`exit(2)` from any thread likewise ends the process. `SYS_thread_exit` is the
only way to end one flow alone, and the main thread returning is process exit,
which is what `return from main` has always meant.

The teardown is **cooperative, then bounded**. A sibling parked inside the kernel
may hold the fs mutex or an fd's page, and deleting it there would leak exactly
the resource nobody is left to release. So process death raises the same `killed`
flag `SYS_kill` uses, and each sibling unwinds at its next syscall boundary or
blocking-loop tick — where the kernel already knows how to die safely. The reaper
waits up to 500 ms for that, then takes what is left: a sibling still running at
PL0 holds no kernel state, and nothing the process owns is freed until reap.

## Reclaiming a thread

A thread cannot free the stack it is standing on, nor delete its own TCB — a
self-`vTaskDelete` only marks the TCB for deferred teardown, so a waiter that
reuses the static TCB immediately cross-links it into two scheduler lists at
once. So a dying thread marks itself, hands its exit value to whoever is joining,
and parks; the **joiner** does the `vTaskDelete` and the `vm_stack_release` from
a context that is not on that stack.

A **detached** thread has no joiner, so its slot and stack are reclaimed by a
sweep run from the next `thread_create` / `thread_join` / `thread_detach` in that
process. Without it, a fire-and-forget worker would hold its slot and its stack
for the life of the process, and a pool that detaches would run the process out
of threads.

## Limits

* **128 threads per process**, including the main thread — `MAXTHREAD`.
* **128 worker threads system-wide** — `NTHREAD`, one global pool. Threads are
  rare and bursty (a pool spins up N for one loop and drops them), so a
  per-process array would reserve `MAXPROC × MAXTHREAD` TCBs to serve a handful
  of live ones.
* **32 concurrent futex waiters** — `NFUTEX`. A full queue returns `-EAGAIN`, so
  the caller spins rather than losing a wakeup.
* Default stack **48 KB**; up to 60 KB per thread, set at `thread_create`. (The
  main thread keeps its 64 KB arena slot.)

These are array bounds, not design limits. They are sized so a program can do
what a host program does — the xtc `threads_tls_many` fixture spawns a hundred
concurrent threads before joining any of them, and passes — rather than to any
belief about what is reasonable.

## The userland side

`/bin/threadtest` is the kernel-side proof, written in C so a failure lands on the
kernel and not on a compiler runtime. Seven tests, each with an exact expected
answer — "about right" would let a lost wakeup or a dropped increment through,
which is the whole class of bug this feature can have. `threadtest N` runs test
*N* alone.

1. spawn + join — two workers compute, main collects both results
2. shared memory — a worker writes a global the main thread reads back
3. mutex — 4 threads × 2000 increments of one counter = exactly 8000
4. TLS — each thread's block stays its own across 200 syscalls
5. detach — a detached thread runs, and its slot comes back
6. rendezvous — futex wait/wake as a condition, both directions
7. fault (opt-in; it ends the process) — a faulting worker takes the process
   down and the OS stays up

Test 3 is the one that cannot be faked: with a broken mutex the total comes out
*low*, and nondeterministically low.

For xtc programs the same primitives arrive through the language surface —
`Thread.spawn(&worker.run)`, `Guard.on(mutex)`, `Pool.forRange(…)` — backed by
`support/arm9/runtime/xt-threads-xtos.c` in the compiler tree.

## Related

- **[Runtime: loading & memory protection](/os/runtime/)** — the per-process
  address spaces thread stacks are carved from, and the loader they run under.
- **[Compiler: threading](/compiler/language/threading/)** — the language surface
  these primitives back: `Thread`, `Mutex`, `Guard`, `Cond`, `Sem`, `Atomic`,
  `Pool`.
- **[ARM Cortex-A9: dynamic loading](/os/multitasking/arm/)** — the ELF loading
  and syscall ABI the thread calls extend.
