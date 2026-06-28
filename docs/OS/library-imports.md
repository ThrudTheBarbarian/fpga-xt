# Shared-library imports — the self-describing `.so`

> **Status: decided (2026-06-28).** xtc imports symbols from shared libraries by
> reading the target `.so`'s own **`.dynsym` ∩ DWARF** — the export set plus
> ABI-accurate types and struct layouts. Libraries are *self-describing*; there
> are no separate per-library interface files to author or keep in sync. A small
> hand-written `libc.xi` is a bootstrap only, until xtc can read DWARF directly.
> See [dynamic-loading.md](dynamic-loading.md), [dwarf-subset.md](dwarf-subset.md),
> [xtc-on-arm9.md](xtc-on-arm9.md).

## 1. The gap

The loader and linker already cover the **resolution** half of using a shared
library: the compiler emits an undefined-global reference, `ld` pairs it with the
exporting `.so`'s `.dynsym`, writes the `R_ARM_GLOB_DAT`/`JUMP_SLOT` relocation,
and records `DT_NEEDED`. At load time the XTOS loader resolves it across the
registry of loaded objects (dynamic-loading.md §5). That path is proven — libc.so,
libm.so, libGEM.so all load and link this way.

What is missing is the **front-end** half: a way for xtc *source* to say "I want
what `libGEM.so` provides" and have the compiler pull that library's exported
names and types into scope — so it can type-check the calls and emit them as
undefined references. This is the **module-import** model (Go/Rust/Python): the
`.so` is the sole *declarer*, the source is a pure *consumer*. It is deliberately
**not** the C-header model, where the consumer re-declares the interface in a
separate file that can drift from the library — that drift is the whole thing we
are designing out.

And it cannot be auto-derived from the obvious place: **`.dynsym` carries names,
not types.** It records that `printf` exists and is a `FUNC`; it says nothing about
`(const char *, ...) -> int`, and nothing about the layout of a `struct` a function
takes by pointer. A type source the compiler can read is fundamentally required.

## 2. The two halves

The fix is two separable things:

1. **A language feature** — an `import "libGEM"` statement: the source names a
   library; the compiler loads it, reads its exported interface, and brings those
   names + types into scope (qualified, e.g. `gem.v_opnvwk`, or flat — an xtc
   naming choice). The source writes **no** signatures. Codegen emits the used
   symbols as undefined-global references (default visibility) and records
   `DT_NEEDED`. This is the compiler work, and it's a *module import*, not
   per-symbol declarations.
2. **The interface data** — the names + types + struct layouts the import reads.
   This is content; §3 is where it comes from. Because of (1), it is owned by the
   library, never restated by the consumer.

Consequence: the library must be present at compile time (you compile against the
actual binary's interface — which is *why* it cannot drift), and the bootstrap
`libc.xi` (§7) is just a temporary hand-transcription of what the `.so` would
declare, not a consumer-side re-declaration.

## 3. Decision: the library describes itself

The interface is **derived from the `.so` itself**, on demand, from two things it
already carries:

- **`.dynsym`** — *which* symbols are exported (the export set, the names).
- **DWARF** — *their types*, including full `struct`/`union`/`enum` layouts.

Their intersection is the complete, importable interface. `import "libGEM"` →
locate `libGEM.so` → read its `.dynsym` for the export names → read its DWARF for
those symbols' types → synthesise typed declarations → type-check the client,
lay out any shared structs to the DWARF-given offsets, emit the undefined
references, and record `DT_NEEDED libGEM.so` (soname from `DT_SONAME`).

There is **no separate interface file** in the steady state. The `.so` is the
single source of truth for both its code and its interface.

### One file, by invariant

This is literally **one file**: both `.dynsym` and DWARF are ELF *sections inside*
the `.so` (`.dynsym` reached via `PT_DYNAMIC`/`DT_SYMTAB`; DWARF in `.debug_*`).
Nothing can drift out of sync because there is nothing else to sync — the property
we want. `.dynsym` is mandatory for dynamic linking and cannot be stripped from a
shared object, so the export-set half is always present.

The single thing that would break the invariant is a deliberate toolchain step:
**splitting debug info out** (`objcopy --only-keep-debug` + `.gnu_debuglink`, or
`strip`) moves DWARF into a separate `foo.debug` — the two-files-that-drift
anti-pattern. **Policy: ship `.so`s unstripped, DWARF embedded.** The cost is
larger `.so`s; the mitigation, if it ever bites, keeps the single-file property —
embed a *trimmed* DWARF (exported types only, per dwarf-subset.md), not full
line-tables/locals.

## 4. Why DWARF (and not the alternatives)

- **ABI-accurate by construction.** DWARF is literally what the compiler laid the
  types out as — field offsets, alignment, padding, aggregate rules. The importer
  reads the answer rather than re-deriving it. A wrong padding byte is a silent
  memory corruption, not a link error, so "compute it yourself" is unacceptable.
- **`.dynsym` alone is insufficient** — names without types (§1).
- **C headers are the wrong source** — they would force xtc to embed a C parser
  *and* re-implement C's layout rules exactly, and they drift from the built
  binary. DWARF is downstream of all of that.
- **Uniform across source languages.** The same path works for C-built
  `libc.so`/`libm.so`/`libGEM.so` and for a future xtc-authored `libfoo.so` — each
  just describes itself. No per-library special-casing.
- **It dovetails a decision already made** — *real DWARF for all three backends*
  (dwarf-subset.md). Every `.so` carries DWARF anyway; this reuses it.

## 5. The forcing function: libGEM, not libc

libc is the *easy* case and would mislead the design: nearly all of its surface is
opaque-handle (`FILE *`, `malloc`'s `void *`) — you need the name and signature,
never the layout. You could almost hand-write it.

**libGEM is the case that proves the mechanism.** Its API *shares structs* the
client dereferences — `gfx_surface { w, h, stride, px }`, `gem_window`, `MFDB`,
the VDI parameter arrays. xtc must lay those out **byte-identically** to the C
ABI or `surf->px` lands at the wrong offset. Opaque pointers do not help here;
only an ABI-accurate layout source does. So the validating test for this whole
design is not "call `printf`" — it is **construct a `gfx_surface` in xtc, pass it
to `v_opnvwk`, and have `px`/`stride` read at the correct offsets**.

## 6. ABI fidelity — the parts that bite

- **Struct layout** — must match the DWARF offsets exactly (§5). This is the
  reason DWARF, not headers, is the source.
- **Opaque vs shared types** — `FILE *` is an opaque handle (name only, never
  dereferenced in client code); `gfx_surface` is shared (full layout needed). The
  importer treats a pointer-to-incomplete-type as opaque and a
  pointer-to-laid-out-type as shared.
- **Varargs** — `printf(const char *, ...)`. xtc needs varargs-ABI lowering, or
  the interface exposes only the fixed-arg forms actually used. This is the one
  genuinely hard signature in the libc surface.
- **soname + versioning** — `DT_NEEDED` must name the soname (`DT_SONAME`), which
  is also the loader's dedup/registry key. The import records the soname, not the
  file path.
- **C → xtc type mapping** — integer widths, pointer/`const` qualifiers, enums,
  unions, function-pointer types. A bounded, mechanical mapping, but it must be
  total over the libc/libGEM surface.

## 7. Bootstrap and validation

- **Bootstrap:** a hand-written `libc.xi` declaring the dozen symbols the first
  libc-using programs need (`printf`, `malloc`, `free`, `memcpy`, …) unblocks the
  `DT_NEEDED libc.so` rung before the DWARF reader exists. It is a stopgap, not
  the model — it does not scale past opaque-handle libc, and explicitly cannot do
  libGEM's structs.
- **Validation:** the milestone that proves the real mechanism is the libGEM
  struct test in §5 — `gfx_surface` fields at the correct offsets, driven from
  `import "libGEM"` reading the `.so`'s DWARF. libc working only proves the easy
  half.

## Related

- [dynamic-loading.md](dynamic-loading.md) — the loader, `.dynsym`/`DT_NEEDED`
  resolution, and the registry this import path emits into.
- [dwarf-subset.md](dwarf-subset.md) — the DWARF every backend emits, which is the
  type source here.
- [xtc-on-arm9.md](xtc-on-arm9.md) — the xtc backend that gains the
  `extern`/import construct (§2.1) and the DWARF-reading importer.
