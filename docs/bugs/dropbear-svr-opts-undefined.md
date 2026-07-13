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

---

# Investigation so far (2026-07-13) — several theories are DEAD

Recorded because these cost real time to establish; do not re-run them.

**The contradiction is now sharp: the same bytes, through the same `xtld.c`, LOAD FINE ON THE
HOST and fail on the board.** So the question is not "is the image bad" or "is the loader
logic wrong" — it is **what the loader actually reads for `symtab[598]` on ARM**.

## Established (measured, not speculation)

1. **The failing artefact is intact.** The romfs `/bin/sshd-session` in the running kernel is
   byte-identical to `build/dropbear.so` (sha1 `4d29dfa27f14`, 336484 bytes). It was not
   corrupted by a rebuild.
2. **That image cannot produce this error from its own reloc loop.** Emulating `xtld.c`'s exact
   indexing against the loaded-image layout: `symtab[598]` = `svr_opts`, `st_shndx = 16`
   (**defined**), and of the **60** relocations needing global resolution, **not one is
   `svr_opts`** — they are all libc imports (`_ctype_`, `environ`, `memset`, `free`, …).
3. **It loads OK on the host with the same `xtld.c`.** Given a real `open_lib` for libc and a
   modelled kernel export table, `xtld_load(dropbear.so)` returns OK. Image good, loader good —
   *in isolation*.
4. **The strtab-offset theory is DEAD.** On the host the `DT_NEEDED` failure path prints
   `libc.so` — correct name, correct offset.
5. **A reported symbol name need not belong to the object you asked for.** Reproduced: loading
   `dropbear.so` with a stub resolver reported **`_getpid`** — a *libc* symbol — because the
   nested `xtld_load` **shares `errbuf`** and `return drc` passes it straight up. Worth fixing
   on its own merits (it misdirects every future diagnosis), but it is **not** the explanation
   for `svr_opts`.
6. **Only dropbear fails.** `ssh`, `scp`, `ssh-keygen` all load and run — same objects, same
   deps, same link recipe. dropbear.so is the **only** image in the tree with a `GLOB_DAT`
   against a **self-defined** symbol, i.e. the only one that exercises `xtld.c:333` at all.
7. **No stale second copy of the loader**: the kernel compiles the same `loader/xtld.c`
   (`loader/Makefile:121`).

## The next experiment (instrumentation, ready to apply)

Widen the error string to print `si` and `st_shndx` **as the loader sees them on the board**:

- **`shndx=16`** → the reloc loop is not the source at all, and the error is propagating from
  somewhere else (see (5) — suspect the shared `errbuf` in a nested load).
- **`shndx=0`** → the loaded image differs from the file, and the hunt moves to *why*: segment
  copy, alignment, or something overwriting `.dynsym`.

The patch is saved at **`docs/bugs/xtld-instr.patch`** (apply with `git apply`). It is a
temporary debug print — revert it once it has answered the question.

> ⚠ The board wedged while chasing this (JTAG lost the ARM target; needed a physical
> power-cycle). Nothing to do with gemd, which was committed and unaffected.
