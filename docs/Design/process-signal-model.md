# XTOS process + signal model — the solid foundation

Status: design, 2026-07-09. Replaces the fragile userland fake-vfork + soft-signal
layer with real-process semantics and kernel-authoritative signals. Triggered by an
ssh-exec bug (dropbear never reaches `execve`); see the root-cause trail in the
`process_signal_rework` memory.

## Ground truth (from a full read of the four layers)

- **A real child already exists.** `SYS_spawn_fd` → `proc_launch` (frtos_os.c:2617)
  builds a genuine separate process: own FreeRTOS task, L1/ASID address space, fd
  table, **per-process `proc_t.cwd[256]`**, inherited `envp`, fd wiring from
  `struct xt_spawn_aux { int fds[4]; char **envp; }`. The fake-vfork is a userland
  fiction on top of this.
- **The fake-vfork leaks.** Between `vfork()` and `exec()` the shim only intercepts a
  narrow whitelist (`dup2→{0,1,2}`, `close` of a pre-vfork fd, `fcntl(F_SETFD)`, and
  it *suppresses* `signal`/`sigaction`). Everything else with a side effect —
  `chdir`, `setenv`/`environ[]=`, `open`, `pipe`, `dup`, `dup2(≥3)`, `fcntl(F_SETFL)`,
  `ioctl` — runs its real body against the **parent**. dropbear's execchild hits the
  env + cwd ones, corrupting sshd-session mid-flight; it never reaches `execve`.
- **Signals are two flags.** `proc_t` has `killed`/`stopped` only — no disposition
  table, no mask, no pending set, no delivery, no ppid/pgid. `SYS_kill` sets flags;
  death happens at the target's next syscall/blocking-tick (frtos_os.c:2153, 2446).
- **Symbol resolution has no interposition.** xtld.c:333: a *defined* symbol binds
  local; only `SHN_UNDEF` imports hit `reg_resolve`→`host->resolve`. So shim-linked
  programs already bind `execve`/`signal`/`read`/`kill` to the shim. The libc.so
  duplicates (`read signal execve kill` — exactly 4) only bite a *shim-less* importer
  or newlib's *own* internal stdio path — a real latent inconsistency, not the ssh bug.
- **Two signal-injection handles** (ARM CA9, one task per process, PL0+PL1 on a
  shared stack): (1) a process parked in a blocking syscall has `proc_t.dctx[16]` =
  `{r0-r12, userPC@13, sp_usr@14, cpsr@15}`, kernel-writable, auto-restored to PL0 by
  `.Lsysret` (xt_vectors.S:62-79) — ideal for EINTR + sync delivery; (2) a PL0 task
  preempted by the tick resumes via `RFEIA sp!` in `portRESTORE_CONTEXT`
  (portASM.S:133) from the `SRSDB`-saved PC/CPSR — the async-delivery point. Cross-
  process stacks are PL0-none except under the owning ASID, so frame-pushes are done
  from PL1 against the resuming task.

## Part 1 — real spawn semantics (kills the fake-vfork leaks) → fixes ssh

Keep the `vfork()`/`execve()` API (no dropbear/toybox edits). Make the window
**leak-free** by capturing child intent and applying it to the *child*, restoring the
parent on the way out.

- **env:** at `vfork()`, shallow-copy `environ` into a scratch array and point
  `environ` at the copy. The child's `environ[0]=NULL` / `setenv` now mutate the copy.
  `execve` passes the copy to `SYS_spawn_fd` (kernel deep-copies into the child stack,
  as today). `vfork_return`/armed-`_exit` restore `environ = original`, free the copy
  array. (setenv's new strings leak a few bytes per exec — acceptable; can track later.)
- **cwd:** make `chdir()` armed-aware — `sys_stat` the target; if it's a dir, record
  `g_child_cwd` and return 0 (no parent `sys_chdir`); else return -1 so a caller's
  fallback (`chdir("/")`) still works. `execve` passes `g_child_cwd` to the kernel.
- **kernel:** extend `struct xt_spawn_aux` with `const char *cwd;` (offset 20).
  `proc_launch` (frtos_os.c:2670-2678): if `aux->cwd` is set and valid, use it for
  `p->cwd` instead of inheriting the parent's; else inherit as now.
- **fds:** the existing record (dup2→0-2, close-of-pre-vfork) already covers dropbear.
  For a solid foundation, also make `dup2(≥3)`, `dup`, `open`, `pipe`,
  `fcntl(F_SETFL)` armed-aware (record into the fd-action set / defer), so no fd op
  in the window ever hits the parent. Lower urgency (dropbear doesn't need it) but in
  scope.
- **verify:** `ssh root@<ip> 'echo hi'` prints `hi`; scp follows.

## Part 2 — kernel-authoritative signals (the big piece)

Add to `proc_t`: `struct sigact { void *handler; uint32_t mask; int flags; } sig[32];`
`volatile uint32_t sig_pending; uint32_t sig_mask; uint32_t sig_active;`.

New syscalls: `SYS_rt_sigaction(sig, act, old)`, `SYS_rt_sigprocmask(how, set, old)`,
`SYS_sigreturn()` (called only by the hidden trampoline).

`SYS_kill`: keep SIGKILL/SIGSTOP/SIGCONT as the uncatchable flag path; for a catchable
signal with a non-default handler set `sig_pending |= 1<<sig` (default disposition of
a catchable signal that isn't handled = the existing kill/ignore semantics).

Delivery — one `deliver_pending(proc, user_frame)` helper, invoked at the two points:
1. **syscall-return (sync + EINTR):** in `k_syscall_dispatch` after the result is
   known, if `sig_pending & ~sig_mask` has a handled signal: for an interrupted
   blocking syscall set result `-EINTR`; build a signal frame on `sp_usr` (or
   `dctx[14]`), redirect user PC (`regs->lr` / `dctx[13]`) to the trampoline, `r0 =
   signum`, mask per `sa_mask`. Blocking loops (pipe/socket/pty/waitpid) gain a
   `sig_pending` check alongside the existing `killed` check → unwind with `-EINTR`.
2. **tick/IRQ-return (async):** a C hook before `RFEIA sp!` (or in
   `exit_without_switch`) checks the resuming PL0 task; same frame-build against the
   `SRSDB` PC/CPSR. This is the hardest, riskiest bit (ARM asm) — lands last.

Userland: a hidden `__sigreturn` trampoline in the shim (the only irreducibly
user-side piece): runs `handler(signum)` on the user stack, then `SYS_sigreturn`
restores the saved context from the frame. The shim's `signal`/`sigaction` become
thin wrappers over `SYS_rt_sigaction` writing one authoritative table; the `g_sigact`
soft-dispatch (`winch_dispatch`/`sigchld_dispatch`) is deleted.

## Part 3 — symbol dedup (make it not glass)

`loader/libc-hide.map`: `{ local: read; signal; kill; execve; };` and add
`-Wl,--version-script=libc-hide.map` to the `libc.so` rule (Makefile:193-197). These
four drop out of libc.so's `.dynsym`; newlib's internal `hash.o` `read` reference
stays satisfied by the retained local def; `exit()→_exit` is untouched (`_exit` was
already a kernel import). Rebuild libc.so + libm.so. Optional robustness: add
`read/signal/kill/execve/waitpid/...` to the kernel export table (`frtos_ksym`,
frtos_os.c:2937) so any future shim-less importer resolves to one kernel-backed def.

## Part 4 — `read` = thin `SYS_read`

`read()` becomes a plain `SYS_read` wrapper; EINTR now comes from Part 2 (kernel
returns `-EINTR` when a signal interrupts the block). Deletes the `-4`/`winch_dispatch`
special-case. Dissolves the original read/signal/sigaction bind ambiguity.

## Implementation order

1. **Part 1** — smallest, independent, fixes ssh. Build + HW-verify `ssh 'echo hi'`.
2. **Part 3** — cheap version-script; removes the latent dup.
3. **Part 2** — kernel signals: rt_sigaction + sync-at-syscall-return + EINTR first
   (covers most cases), then async-on-tick delivery (the ARM-asm hook) last.
4. **Part 4** — flip `read` to the thin stub once Part 2 supplies EINTR.

## Status (2026-07-10) — Part 2 IMPLEMENTED + qemu-validated

**Kernel signals are real and working; all three delivery paths pass on qemu**
(`/bin/sigtest`, 3/3): sync self-deliver, **async into a pure CPU-bound loop**
(the tick-return hook), and **EINTR of a blocked syscall**. Frozen ABI:
`SYS_rt_sigaction 0x109`, `SYS_rt_sigprocmask 0x10A`, `SYS_sigreturn 0x10B`,
`SYS_sig_async 0x10C`; `struct xt_sigaction {handler,mask,flags,restorer,trap}`;
`struct xt_sigframe` (r0-15,cpsr,signo,saved_mask). Pieces:
- `proc_t`: `sigact[32]`, `sig_pending`, `sig_blocked`, `sig_trap`, `async_ctx[16]`.
- `deliver_signals()` builds the frame on the user stack + vectors to the handler;
  the shim's hidden `__xt_sigreturn` runs the handler then `SYS_sigreturn` restores.
- Sync: `deliver_inline` at the inline syscall-return; deferred: `deliver_deferred`
  on the `__sysret`/`.Lsysret` path (which now also restores r14 and no longer
  clobbers `dctx[0]`). EINTR (`-4`) added to the pipe/pty blocking loops; the shim's
  `read()` now returns EINTR on `-4` instead of transparently retrying.
- Async: `xt_sig_async_hook` (called from `portRESTORE_CONTEXT`) captures a preempted
  PL0 task's context and redirects its resume PC to the shim's `__xt_sig_trap`, which
  traps into `SYS_sig_async` to deliver from the captured context. Safe no-op for
  kernel tasks / nothing pending / non-PL0.
- shim `signal`/`sigaction` install the kernel disposition **and** mirror into
  `g_sigact` (dual-write) so the legacy SIGCHLD/SIGWINCH soft-dispatch keeps working.

**This fixes aesdesk-can't-kill**: aesdesk blocks in `aes_wait` (a syscall) → EINTR
delivers, so it's now signalable/killable. (docs/NextSteps.md motivating case.)

### DONE (2026-07-10, commit ed61752) — kernel SIGCHLD/SIGWINCH + soft-path removal
- `proc_t.ppid` + `sig_raise()` in `proc_exit_self`/fault-exit raise **SIGCHLD** on
  the parent; pty size-change raises **SIGWINCH** on the reader — both via the real
  async path. The `g_sigact` soft-dispatch (`winch_dispatch`/`sigchld_dispatch`, the
  poll SIGCHLD-cap, the dual-write) is deleted; `signal`/`sigaction` are thin
  wrappers over the one kernel table. `sigtest` 4/4 (adds SIGCHLD-on-exit).
- Fixed a latent numbering bug: `XT_SIGSTOP/TSTP/CONT` were Linux (19/20/18) but the
  shim passes newlib arm numbers (17/18/19) — aligned + added `XT_SIGCHLD 20`,
  `XT_SIGWINCH 28`.
- **HW-validate**: ssh/dropbear child reaping is the real SIGCHLD test (its self-pipe
  handler now runs on the kernel's async SIGCHLD).

### DONE (2026-07-10, commit fc6fe7d) — Part 3 symbol dedup
- `loader/libc-hide.map` version script localizes `read/signal/kill/execve` in the
  libc.so link (the only four newlib+shim both define). They drop from libc.so's
  `.dynsym`; shim-linked programs bind their own copies (xtld no-interposition),
  newlib's internal `read` user keeps the retained local def, `exit()->_exit` is
  a kernel import (untouched). Verified: no program imports the four from libc.so,
  dropbear keeps its own shim copies, `hello`/pipelines/sigtest all green.
- Fixed a latent build bug it surfaced: usys.h now `#include <stdint.h>` (the
  `uint16_t` in sys_xl_window/sys_overlay assumed the includer pulled stdint).

### Remaining
- **`SA_RESTART`** — today every interrupted syscall is EINTR, never auto-restart.
- Newlib provenance: no STAMP/submodule for the checked-in `newlib-pic/{libc.a,
  libm.a}` prebuilts (mystery-blob footgun class). Proposed: a STAMP recording
  version + config-hash + artifact sha256 + validated marker; submodule optional
  (no source patches today; the dedup is loader-side, not a newlib change).
  Signals work WITHOUT it (shim-linked programs bind the shim's copies locally via
  xtld's no-interposition rule); it's defensive hygiene. Deferred to avoid risking
  program-load resolution at 3am; do it with the kernel-export-table robustness
  variant + a full boot/ssh smoke test.
- `SA_RESTART` (currently every interrupted syscall is EINTR, never auto-restart).
