# RESOLVED (not a bug): `dropbear.so` failed to load — `svr_opts rc=undefined symbol`

**Status: CLOSED, 2026-07-13. It was a STALE BUILD ARTEFACT.** A clean rebuild of the kernel
fixed it: `dropbear.so` loads, `sshd-session` runs, **ssh works**. There is no loader bug, and
**`-Bsymbolic` was not needed and must not be applied** — it would have "fixed" a bug that does
not exist and left everyone believing the loader could not resolve a self-defined `GLOB_DAT`.

Kept because the *diagnosis* is worth not repeating, and because the failure mode is a trap that
will recur.

## What actually happened

`$(BUILD)/dropbear.so` depends on `$(BUILD)/libc.so`, so **any** edit to `loader/kernel/xtsys.h`
relinks libc → relinks dropbear. Two syscall numbers were added to `xtsys.h` for gemd (M1). The
kernel built at that moment shipped a romfs whose `sshd-session` image would not load. Every
kernel built **afterwards, from a consistent tree, loads it fine** — same sources, same recipe,
same committed code.

**The exact mechanism is unpinned, and that is stated deliberately rather than papered over:**
the failing artefact was rebuilt before it could be dissected, so the honest answer is "an
inconsistent intermediate in that one build", not a story invented to fit. What is certain is
that it is **not** in the loader logic, **not** in the ELF, and **not** in the link flags —
each of those was measured and cleared (below).

## The lesson (this is the reusable part)

> **A `.so` that "works" only because it has not been relinked recently is not known to work.**

The Makefile already warns about exactly this at line 426 — *"a submodule bump or config edit
left stale .o's linked in… this exact staleness masked a fixed ssh-exec bug"*. It bit again, from
the other direction: this time the **stale** artefact was the working one and the **fresh** build
looked broken. If a rebuild breaks something that was fine, **rebuild again from a clean tree
before believing the symptom.**

## Measured, and now moot — do NOT re-run these

Every one of these cost real time. They were all correct, and all of them cleared the thing they
tested — which, in hindsight, was the tell: when the image, the loader, and the link flags are
each provably fine, the artefact you are holding is not the one that failed.

1. **The image was intact.** The romfs `/bin/sshd-session` in the running kernel was
   byte-identical to `build/dropbear.so` (sha1 `4d29dfa27f14`, 336484 bytes).
2. **That image cannot produce the error from its own reloc loop.** Emulating `xtld.c`'s exact
   indexing against the loaded-image layout: `symtab[598]` = `svr_opts`, `st_shndx = 16`
   (**defined**), and of the **60** relocations needing global resolution, **not one is
   `svr_opts`** — all are libc imports (`_ctype_`, `environ`, `memset`, …).
3. **It loads OK on the host through the same `xtld.c`.** Given a real `open_lib` for libc and a
   modelled kernel export table, `xtld_load(dropbear.so)` returns OK.
4. **`xtld.c:333` is correct and does fire.** A `GLOB_DAT` against a self-defined symbol resolves
   locally, with no interposition. (Load-bearing elsewhere: phase-611's `^` trampolines rely on
   it.)
5. **The strtab-offset theory is dead.** On the host the `DT_NEEDED` failure path prints
   `libc.so` — correct name, correct offset.
6. **Only dropbear was affected.** `ssh`, `scp`, `ssh-keygen` all loaded and ran throughout —
   same objects, same deps, same link recipe.
7. **No stale second copy of the loader**: the kernel compiles the same `loader/xtld.c`
   (`loader/Makefile:121`).

## One real defect found on the way, still worth fixing

**A reported symbol name need not belong to the object you asked for.** Reproduced on the host:
loading `dropbear.so` with a stub resolver reports **`_getpid`** — a *libc* symbol — because a
nested `xtld_load` **shares `errbuf`** and `return drc` passes it straight up (`xtld.c:302-305`).
The same shape bit the compiler thread the same night (a missing library reported as
`libwblib.so rc=undefined symbol`, via the `DT_NEEDED` path at `:297`, which also returns
`XTLD_E_UNDEF` but copies a *library* name).

So one error code and one buffer carry three different meanings: "this object's symbol is
missing", "a dependency's symbol is missing", and "a dependency's file is missing". **It
misdirects every future diagnosis** — including, substantially, this one. Cheap fix: distinguish
the dep-open failure (`XTLD_E_NEEDED`) from the symbol failure, and prefix the errbuf with the
soname of the object being relocated.
