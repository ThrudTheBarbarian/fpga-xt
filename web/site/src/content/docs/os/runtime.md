---
title: "XTOS runtime: loading & memory protection"
description: "How XTOS loads programs and protects them: the xtld ELF loader, per-process address spaces, copy-on-write, mmap'd executables and files, guard pages, W^X, a DDR page pool, and a real PL0 user/kernel boundary on the Cortex-A9."
---

XTOS is a bespoke, GEM/TOS-flavoured operating system running on the Zynq's Cortex-A9
PS, on top of the Xilinx FreeRTOS port. Beyond the scheduler it adds the two things
that make it an *operating system* rather than a single firmware image: it **loads
programs at runtime**, and it **protects them from each other and from the kernel**.

This page describes that runtime as it actually works today. Programs are relocatable
ELF shared objects loaded from a filesystem; each runs unprivileged in its own virtual
address space with a demand-paged heap, copy-on-write data, shared library text, guard
pages, and write-XOR-execute memory. A program that strays outside its own memory — or
reaches for the kernel — is faulted and killed cleanly while the rest of the system
keeps running. All of this is validated on real silicon with the caches enabled.

## The loader (`xtld`)

Programs and libraries are position-independent ELF `ET_DYN` objects (the same format
a shared library uses). The loader, `xtld`, is small and portable — the same code runs
in the on-target kernel and in a host test harness. Loading an object means:

1. **Map its segments.** Only `PT_LOAD` segments are placed in memory; non-loadable
   sections (notably DWARF debug info) stay in the file image and never consume
   runtime mapping.
2. **Apply relocations.** `R_ARM_RELATIVE`, GOT/`GLOB_DAT`, and `JUMP_SLOT` entries are
   fixed up for the load address.
3. **Resolve imports.** Undefined symbols are satisfied first from a **kernel export
   table** (the syscall and runtime surface the kernel chooses to publish), then from
   the object's `DT_NEEDED` shared libraries, which are themselves loaded recursively.
4. **Protect it** (see [W^X](#write-xor-execute-wx) and [PL0](#the-pl0-userkernel-boundary)),
   *before* any of its code runs.
5. **Run its constructors** (`DT_INIT_ARRAY`).

Shared libraries are **loaded once and shared**. A second program that needs `libc.so`
reuses the resident copy; reference counts track when an object — and transitively its
own dependencies — is no longer used, at which point destructors (`DT_FINI_ARRAY`) run,
the mapping is torn down, its instruction-cache lines are evicted, and its pages return
to the pool. Frequently-run programs are likewise kept in a small load-once cache and
evicted LRU under pressure.

Library resolution is **path-driven**, not hardcoded: the loader consults a search
path (default the system library directory) so a debug session can later prefer a
directory of debug-built libraries without rebuilding anything.

## The process model

XTOS uses **spawn**, not fork: a new process is created directly from an image rather
than by duplicating a parent. Each process is a FreeRTOS task plus:

- a **private virtual address space** (its own page tables) with a unique ASID, so
  TLB entries don't have to be flushed on every context switch;
- a **per-process file-descriptor table** (0/1/2 are the console; the rest are open
  files);
- a **demand-paged heap** at a fixed virtual address — the same address in every
  process, because each has its own space;
- arguments (`argv`) copied into the process's own memory.

The image itself is shared (loaded once); each *instance* gets its own writable data
via copy-on-write, so running the same program twice gives two independent processes
that happen to share read-only code.

## Memory protection

The Cortex-A9 MMU is load-bearing in XTOS. Each process gets a private translation
table cloned from a master, then specialised with the regions below. The caches (both
instruction and data) are enabled; the loader keeps them coherent across code loads,
and page-table walks are cacheable.

### Demand-zero heap

A process's heap starts with **no pages mapped**. The first write to a heap page takes
a fault, which the kernel services by allocating a zeroed page from the pool and
mapping it. A program can reserve a large heap cheaply and only pay for what it
touches.

### Copy-on-write

A process's writable data — its own globals, and the data segments of `libc` and every
shared library it uses — is mapped **read-only and shared** until first written. The
write faults, the kernel copies the page into a private one, remaps it writable, and
resumes. Two processes sharing `libc` see the same pristine library state and diverge
only on the pages they actually modify. This is also the mechanism a future `fork()`
would build on.

### mmap'd executables (shared text)

Program and library **code is mapped read-only and executable, and physically shared**
across every process running that image. Launching the same program many times costs
one copy of its text. This is what makes "everything links `libc`" cheap: `libc`'s
code exists once in RAM no matter how many processes use it.

### mmap'd files

A process can `mmap` a file for **zero-copy, read-only, demand-paged** access — the
file's pages (in the in-RAM root filesystem) are mapped directly into the process, a
page at a time as touched, with nothing copied. Font files, for example, are handed to
the text renderer this way instead of being read into a heap buffer.

### Guard pages

Every process stack sits above an unmapped **guard page**. A stack overflow hits the
guard, faults precisely, and the process is killed with a clear "stack overflow"
report — rather than silently corrupting whatever lies below the stack.

### Write-xor-execute (W^X)

A loaded image's text and read-only data are mapped **read-only + executable**; its
writable data is **read-write + execute-never**. No page is ever both writable and
executable, so a program cannot modify its own code or execute its data. An attempt to
write to code faults and the process is killed.

### The page pool, reclaim, and scrubbing

Backing pages come from a DDR-backed pool. When a process exits, **all** of its private
pages — heap, COW copies, stack — are returned to the pool, and each is **scrubbed
(zeroed) before** it can be handed to another process. So memory freed by one program
can never be read as stale data by the next. The pool is exercised to exhaustion and
back in the self-test with no leak.

### The PL0 user/kernel boundary

Programs run **unprivileged** (ARM User mode, PL0); the kernel runs privileged (PL1).
Syscalls cross the boundary through a single `svc` gateway; interrupts and faults are
handled at PL1. Crucially, the boundary is **enforced by the MMU**, not by convention:

- the kernel's code, data, heap, page pool, and the memory-mapped peripherals are
  **inaccessible from PL0** — a program that reads a kernel address is faulted and
  killed;
- kernel **text** is PL0 execute-but-not-readable only where it must be (the syscall
  trampoline);
- each process sees **only its own stack** — every other process's stack is
  inaccessible, closing both an information leak and, more importantly, a
  privilege-escalation path (overwriting another task's saved context).

The net guarantee: a process can reach its own text, data, heap, stack, copy-on-write
pages, and explicit file mappings — and **nothing else**. Not the kernel, not the pool,
not another process. A bug or a hostile program faults; the OS continues.

## Shared libraries

The C runtime is a real shared library, `libc.so` (PIC newlib), joined by `libm.so`
(used by the maths-heavy renderer) and `libGEM.so` (the portable GEM/VDI core with a
vendored FreeType). A program declares them as `DT_NEEDED` dependencies and the loader
resolves them automatically. Because library **text is shared** and only **data is
copy-on-write per process**, depending on the full C library is inexpensive — the code
is mapped once, and a process only pays for the handful of data pages it dirties.

## Validation

A built-in self-test exercises the whole runtime in one pass: it spawns the program
suite (per-process heaps, copy-on-write, shared text, demand paging, mmap'd files,
FreeType text rendering) and the protection tests (reading kernel memory, reading
another process's stack, writing to code, overflowing the stack, dereferencing null) —
each of which must be killed while the OS survives — and finishes by confirming every
page has been reclaimed. The same battery runs **on hardware** over the serial console
with the caches enabled, so the cache-coherency of code loading and the page-table
walks, and the MMU's enforcement of the protection boundary, are confirmed on real
silicon rather than only in emulation.

## What's next

The runtime is the foundation for several planned pieces, tracked in the project's
next-steps notes:

- **Loadable filesystems and device drivers as isolated services** — drop a binary into
  `/OS/Filesystems/` or `/OS/Devices/` and have it extend the OS, running unprivileged
  with the full C library and crash isolation, behind the same `fs_ops` abstraction the
  in-kernel root filesystem already uses.
- **A cross-core source-level debugger** — for which the path-driven library resolution
  is the first reserved hook: a debug session points a process at debug-built
  (unoptimised, symbol-rich) libraries without disturbing the shipping ones.
