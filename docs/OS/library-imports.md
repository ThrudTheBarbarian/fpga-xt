# Shared-library imports — the self-describing `.so`

> **Status: decided (2026-06-28).** xcc imports symbols from shared libraries by
> reading the target `.so`'s own **`.dynsym` ∩ DWARF** — the export set plus
> ABI-accurate types and struct layouts. Libraries are *self-describing*; there
> are no separate per-library interface files to author or keep in sync. A small
> hand-written `libc.xi` is a bootstrap only, until xcc can read DWARF directly.
> See [dynamic-loading.md](dynamic-loading.md), [dwarf-subset.md](dwarf-subset.md),
> [xcc-on-arm9.md](xcc-on-arm9.md).

## 1. The gap

The loader and linker already cover the **resolution** half of using a shared
library: the compiler emits an undefined-global reference, `ld` pairs it with the
exporting `.so`'s `.dynsym`, writes the `R_ARM_GLOB_DAT`/`JUMP_SLOT` relocation,
and records `DT_NEEDED`. At load time the XTOS loader resolves it across the
registry of loaded objects (dynamic-loading.md §5). That path is proven — libc.so,
libm.so, libGEM.so all load and link this way.

> **`libxtos.so` — the XT syscall half of the ABI.** POSIX ships as real symbols
> in `libc.so`, but the XT-specific syscalls (framebuffer `sys_fb_info` /
> `sys_fb_present` / `sys_fb_wallpaper`, input `sys_input` / `sys_kbd_6502`,
> `sys_xtos_recv`, `sys_overlay`, …) existed only as `static inline` wrappers in
> `usys.h` — a C-only, compile-time interface, so any language that can't inline
> the `svc #1` was locked out of the machine's own display and input.
> `/OS/Library/libxtos.so` closes that gap: every `usys.h` wrapper (58 of them,
> POSIX and XT alike) as a real exported `sys_*` symbol, importable by exactly the
> mechanism this doc describes. It is derived wholesale from `usys.h` (included
> with the `static inline` storage-class stripped), so it can never drift from the
> frozen ABI. The names are the raw `sys_*`, so they never collide with libc.so's
> POSIX `write`/`open`/… Source: `loader/test/freertos/libs/libxtos.c`.

What is missing is the **front-end** half: a way for xcc *source* to say "I want
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

1. **A language feature** — spelled with the existing **`#import`** directive
   (which is `#include` + include-once, à la Objective-C). The existing
   bracket distinction is unchanged: **`<…>` searches the system locations,
   `"…"` the local path** (as in C) — that selects *where* to look, not *what
   kind* of thing is found. The directive is *extended* so the searched system
   locations also include the **library paths** (`$libDir`), not just
   source-include paths:
   - in a **library path**, `<GEM>` resolves to `libGEM.so` — the `-lGEM`
     convention: `lib` prefix + `.so` suffix implied, stem verbatim
     (`<c>`→`libc.so`, `<m>`→`libm.so`). Found a `.so` → **metadata import** (read
     its interface).
   - in a **source-include path**, the name resolves to an xcc module → **textual
     include**, as today.

   So the **dispatch (library vs source module) is by what the resolver finds**,
   not by the bracket; the bracket only chooses system-vs-local, exactly as now.
   Precedence is the search order across the configured paths. (So `#import <GEM>`
   finds `$libDir/libGEM.so` because that's what lives there.)

   For a library import it brings the exported names **and types** into scope
   (qualified, e.g. `gem.v_opnvwk`, or flat — an xcc naming choice); the source
   writes **no** signatures. Codegen emits the used symbols as undefined-global
   references (default visibility) and records `DT_NEEDED` (soname from the `.so`).
   `#import`'s include-once nature matches a `.so` import being idempotent.

   The `lib*.so` naming also separates *importable libraries* from *spawnable
   programs* (`desktop.so`) — you `#import` the former, `spawn` the latter.
   Note the SD is FAT (case-insensitive): pick one casing per library; never let
   two libraries differ only by case.
2. **The interface data** — the names + types + struct layouts the import reads.
   This is content; §3 is where it comes from. Because of (1), it is owned by the
   library, never restated by the consumer.

Consequence: the library must be present at compile time (you compile against the
actual binary's interface — which is *why* it cannot drift), and the bootstrap
`libc.xi` (§7) is just a temporary hand-transcription of what the `.so` would
declare, not a consumer-side re-declaration.

### The sysroot, until self-hosted

While xcc cross-compiles on a dev host, "present at compile time" means a host copy
of the target's `.so`s in `$libDir` — a **sysroot**. Because the interface *is*
the `.so`, the SDK is just that copy of `$libDir`; there is no separate headers or
import-library package to assemble. The discipline is lighter than "same exact
file": dynamic linking binds **by name at runtime**, so only the **interface**
(signatures + layouts) must agree between the sysroot copy the client compiled
against and the device `.so` it runs against. Implementation drift is fine — a
device `.so` recompiled with the same API still binds correctly (that is the whole
value of shared libraries). What must not drift unversioned is the *interface* — a
signature change or a struct-layout morph — and **`DT_SONAME` is the guard**: bump
it on an incompatible change and the loader refuses a mismatched version rather
than binding it. (The only route to silent struct-offset corruption is changing a
layout while keeping the old soname *and* running an old client.) Shipping the same
artifact to both places is just the trivially-safe case of that rule. No bootstrap circularity: the base libs (`libc.so`,
`libm.so`) are C/newlib built by gcc, so they populate the sysroot without xcc.
**Self-hosting dissolves the sysroot** — on-device, `#import` reads the `.so`s in
place. (In this tree, `loader/build/*.so` already serve runtime + the `xtcrun`
harness; they are the sysroot too — one artifact, three uses.)

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

The anti-pattern to avoid is **`objcopy --only-keep-debug` + `.gnu_debuglink`**:
one `.so` split into a stripped binary plus a separate *incomplete* `.debug` that
pair by build-id and drift. That is *not* what the runtime/debug split below is.

### Runtime vs debug builds

Two **complete** builds of one source, by directory:

- **`/OS/Library/libGEM.so`** — runtime: optimised, stripped (no DWARF). The
  device only *runs* it; lean to load and on RAM/SD.
- **`/OS/Library/Debug/libGEM.so`** — a complete DWARF-carrying build: the
  compiler's `#import` source (the cross-build sysroot points here) *and* the
  debugger's.

Both are whole self-describing `.so`s with the same `DT_SONAME` — not a
stripped-binary-plus-separate-`.debug` pair — so the single-file invariant holds
for the debug build, and (binding is by soname/interface, §"The sysroot") it does
not matter that the device runs the stripped sibling. Result: efficient runtime,
full DWARF exactly where it is used (compile + debug), and the DWARF bulk lives
only under `Debug/`.

### Types materialise as native xcc types

Importing a library brings in more than function symbols: the DWARF type DIEs for
the exported API become **first-class xcc types**. `#import`ing libGEM makes
`MFDB`, `gfx_surface`, `gem_window` declarable, nestable, and field-accessible in
xcc source — a local `MFDB m`, `surf.px`, a `gem_window *`. The interface is types
*and* symbols, not just symbols.

The rule that makes it safe: synthesise each type **honouring the DWARF layout
verbatim** — take `DW_AT_data_member_location` per member and `DW_AT_byte_size`
for the whole — rather than re-running xcc's own struct-layout pass on the field
types. The imported type is *layout-pinned* to what the library was actually built
as: byte-identical by construction even if xcc's default packing ever differs from
C's, and bitfield/alignment corner cases are *read*, not re-derived.

Coverage: `DW_TAG_{structure,union,enumeration,typedef,pointer,array,base,
subroutine}_type` map to the matching xcc constructs; a pointer to an incomplete
type stays opaque (a handle, §6), a pointer to a laid-out type is shared. Type
identity is by name + layout, so the same struct seen via two libraries (or via
the program and a library) is **one** xcc type, not two.

## 4. Why DWARF (and not the alternatives)

- **ABI-accurate by construction.** DWARF is literally what the compiler laid the
  types out as — field offsets, alignment, padding, aggregate rules. The importer
  reads the answer rather than re-deriving it. A wrong padding byte is a silent
  memory corruption, not a link error, so "compute it yourself" is unacceptable.
- **`.dynsym` alone is insufficient** — names without types (§1).
- **C headers are the wrong source** — they would force xcc to embed a C parser
  *and* re-implement C's layout rules exactly, and they drift from the built
  binary. DWARF is downstream of all of that.
- **Uniform across source languages.** The same path works for C-built
  `libc.so`/`libm.so`/`libGEM.so` and for a future xcc-authored `libfoo.so` — each
  just describes itself. No per-library special-casing.
- **It dovetails a decision already made** — *real DWARF for all three backends*
  (dwarf-subset.md). Every `.so` carries DWARF anyway; this reuses it.

## 5. The forcing function: libGEM, not libc

libc is the *easy* case and would mislead the design: nearly all of its surface is
opaque-handle (`FILE *`, `malloc`'s `void *`) — you need the name and signature,
never the layout. You could almost hand-write it.

**libGEM is the case that proves the mechanism.** Its API *shares structs* the
client dereferences — `gfx_surface { w, h, stride, px }`, `gem_window`, `MFDB`,
the VDI parameter arrays. xcc must lay those out **byte-identically** to the C
ABI or `surf->px` lands at the wrong offset. Opaque pointers do not help here;
only an ABI-accurate layout source does. So the validating test for this whole
design is not "call `printf`" — it is **construct a `gfx_surface` in xcc, pass it
to `v_opnvwk`, and have `px`/`stride` read at the correct offsets**.

## 6. ABI fidelity — the parts that bite

- **Struct layout** — must match the DWARF offsets exactly (§5). This is the
  reason DWARF, not headers, is the source.
- **Opaque vs shared types** — `FILE *` is an opaque handle (name only, never
  dereferenced in client code); `gfx_surface` is shared (full layout needed). The
  importer treats a pointer-to-incomplete-type as opaque and a
  pointer-to-laid-out-type as shared.
- **Varargs** — `printf(const char *, ...)`. xcc needs varargs-ABI lowering, or
  the interface exposes only the fixed-arg forms actually used. This is the one
  genuinely hard signature in the libc surface.
- **soname + versioning** — `DT_NEEDED` must name the soname (`DT_SONAME`), which
  is also the loader's dedup/registry key. The import records the soname, not the
  file path.
- **C → xcc type mapping** — integer widths, pointer/`const` qualifiers, enums,
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

## 8. One `#import`, per-backend lowering

xcc is multi-backend (6502, m68k, A9/ARM). **`#import <GEM>` is the same source
construct on every backend; the backend chooses how a call is *lowered*:**

- **A9 (native, in-process)** → a direct PIC call into the loaded `libGEM.so`
  (the `DT_NEEDED` path, §1–§3).
- **6502 / m68k (guests)** → they cannot run ARM code; `libGEM` runs as the A9
  **GEM service** ([[gem_service_architecture]]), so the call lowers to marshalling
  args into the shared param block (the VDI `contrl`/`intin`/`ptsin` convention)
  and ringing the **doorbell**; the A9 service executes it and returns results.

Same import, same types (`MFDB`, `gfx_surface`), same signatures — different
codegen.

**The interface is one source for all backends.** `libGEM.so`'s `.dynsym` ∩ DWARF
is read by every backend: the A9 reads it *and executes* it; the 6502 reads it
*purely as a description* — it can't run libGEM, but it reads the self-description
to learn the signatures + `MFDB` layout, hence how to marshal. One interface, N
lowerings, **all generated** — the GEM-service "thin bindings" stop being
hand-written per call/per backend; they are derived from the same DWARF.

**This is what unblocks native-A9 direct linking.** The service design deferred
A9 client-linking only because there was no way to hand xcc the C interface — the
DWARF import *is* that mechanism, so the blocker dissolves: native A9 can
direct-call; guests keep the doorbell.

**Stateful vs stateless.** Authoritative GEM state (the WM window list, AES) must
live in one place ([memory-protection.md](memory-protection.md): behind the
service, not per-process library globals). So even on the A9, the *stateful* parts
(WM/AES) may lower to a doorbell-to-the-service while *stateless* per-workstation
VDI drawing lowers to a direct call. Lowering can be **per-subsystem, not just
per-backend** — `#import` stays uniform; the binding generator knows which symbols
are service-routed.

## Related

- [dynamic-loading.md](dynamic-loading.md) — the loader, `.dynsym`/`DT_NEEDED`
  resolution, and the registry this import path emits into.
- [dwarf-subset.md](dwarf-subset.md) — the DWARF every backend emits, which is the
  type source here.
- [xcc-on-arm9.md](xcc-on-arm9.md) — the xcc backend that gains the
  `extern`/import construct (§2.1) and the DWARF-reading importer.
