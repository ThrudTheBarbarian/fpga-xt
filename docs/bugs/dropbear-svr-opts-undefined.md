# BUG: `dropbear.so` fails to load — `svr_opts rc=undefined symbol` (ssh is down)

**Status: OPEN. For the compiler/loader thread.** Independent of gemd — reproduces with a bare
`sshd-session` load, no window system involved.

**Impact: ssh is down on the board.** `sshd` accepts, spawns the session, the session fails to
load, and the connection resets. Workaround for now: the **netcon console** (`telnet <board> 23`).

## Reproduce

On the board: `/System/bin/sshd-session` →
```
xtld_load err: svr_opts rc=undefined symbol
```

## The facts (measured, not inferred)

- `dropbear.so` **defines** `svr_opts`: `.dynsym[598]`, `OBJECT GLOBAL DEFAULT`,
  **`st_shndx = 16` (`.bss`)**, value `0x000787f4`, size 184.
- It has **exactly one** relocation against it: **`R_ARM_GLOB_DAT` at `0x0005d780`**, symbol
  index `0x256` = 598.
- **No other object in the tree imports `svr_opts`** (checked every `build/*.so`).
- `xtld.c:333` already has the "defined here" branch —
  `if (s->st_shndx != SHN_UNDEF) S = bias + s->st_value;` — so on the face of it this
  `GLOB_DAT` should resolve **locally** and never reach the `XTLD_E_UNDEF` path at `:341`.
  **It evidently does reach it.** So either that branch is not seeing the `st_shndx` that
  `readelf` reports, or `symtab[si]` is not landing where we think. It is **not** a bounds
  issue: `DT_HASH` `nchain` is 747, so index 598 is in range.

## What triggered it: a RELINK, not a source change

`$(BUILD)/dropbear.so` depends on `$(BUILD)/libc.so`, and **any** edit to
`loader/kernel/xtsys.h` relinks libc → relinks dropbear. Two syscall numbers were added to
`xtsys.h` for gemd, so dropbear was relinked **from the same objects** against a fresh libc,
and the result no longer loads. The dropbear `.o`s were *not* recompiled (their deps did not
change).

**So the breakage was LATENT in the tree and the relink merely exposed it.** This is the same
staleness trap the Makefile already warns about at line 426 ("a submodule bump or config edit
left stale .o's linked in… this exact staleness masked a fixed ssh-exec bug"). Anything that
"works" only because it has not been relinked recently is in the same position.

## Two ways to go — they are NOT equivalent

1. **It is a loader bug.** Most likely, and the more valuable answer. **Start by asking why
   `xtld.c:333` did not fire for a symbol whose `st_shndx` is 16.** If a self-referencing
   `GLOB_DAT` cannot resolve against its own definition, this affects **any** `.so` with one —
   dropbear is just the first to hit it.
2. **It is loader policy** (every GOT entry must resolve through the global namespace —
   registry + kernel export table — with no self-preemption). Then the object must not emit a
   GOT entry for its own definition, and the fix is at the link: add **`-Bsymbolic`** to the
   `dropbear.so` / `ssh.so` / `scp.so` / `dropbearkey.so` link lines, so self-defined globals
   bind locally and come out as `R_ARM_RELATIVE` instead of `R_ARM_GLOB_DAT`. One line, and it
   makes the policy explicit.

> ⚠ **`-Bsymbolic` would restore ssh immediately — and if (1) is true, it HIDES the bug**
> rather than fixing it, leaving every other self-referencing `.so` quietly broken. Answer the
> `xtld.c:333` question first.
