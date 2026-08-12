# Porting xcc to the Cortex-A9 (xcc-on-arm9)

> **Status: requirements doc for the xcc ARM back-end.** Consolidates everything
> the port must satisfy so the work can be scoped against one source. Pairs with
> [dynamic-loading.md](dynamic-loading.md) (the loader/ABI it targets),
> [memory-protection.md](memory-protection.md) (the tier-2 runtime), and
> [xtos-vision.md](xtos-vision.md) §3 (debug-info). The xcc ARM back-end
> (`XTARMLowering`) is the critical-path compiler piece — it gates ARM-native apps,
> the dynamic loader, and the GEM ARM client.

## 0. Target, precisely (read this first)

The target is the **Zynq-7020 PS application core: a dual ARM Cortex-A9, ARMv7-A,
AArch32 (32-bit)**:

- **Not** *arm64* / AArch64 — that's the backend we port *from* (Apple M-series).
  AArch64 → AArch32 is a **genuine ISA change**, not a tweak (different register
  file, instruction set, and calling convention — see §1).

Decision context (settled): **xcc is the XTOS system language** (ARC by default,
unmanaged subset for the bottom — §6). Existing C dependencies stay C, cross-built
on the host; on-device C compilation is deferred (no tcc for now). So xcc-ARM is
the toolchain for *new* XTOS/app code, and must interoperate cleanly with the C
that's already in the system.

## 1. Scope: what carries over from arm64, what's net-new

**Reuse (shared with the arm64 backend):** the frontend, IR, optimisation passes,
ARC semantics, register-allocation framework, calling-convention infrastructure,
the DWARF-emission framework, and the general "ARM-family" mental model.

**Net-new (the A32 back-end proper):**

- **Instruction selection/encoding for A32** (and optionally Thumb-2 — §10). A64 and
  A32 are different ISAs; this is real codegen, not a retarget table.
- **AAPCS32 lowering** — different from AAPCS64: arg registers, return, varargs,
  struct/aggregate passing, stack layout and alignment (§2).
- **32-bit pointer/word model** — pointers, `size_t`, `long`, enum width, struct
  layout all differ from the 64-bit backend.
- **PIC model + ARM relocations** for ELF `ET_DYN` (§4).
- **DWARF ARM register vocabulary** and A32 frame/unwind (§7).
- **FP/SIMD** — VFPv3/NEON vs A64 SIMD, and the float-ABI choice (§2).

Treat this as "a new ARM backend that shares xcc's middle-end," not "a port."

## 2. ABI: AAPCS32 / ARM EABI (R-ABI)

**Requirement:** emit and consume the **ARM EABI (AAPCS32)** exactly as the
existing toolchain does, because xcc objects link directly against the
C-cross-compiled kernel and libraries.

- **Calling convention:** args in `r0–r3` then stack; return in `r0` (`r1:r0` for
  64-bit); `r0–r3,r12` caller-saved, `r4–r11` callee-saved (`r9` — see §4 warning),
  `r13`=SP (8-byte aligned at public interfaces), `r14`=LR, `r15`=PC.
- **C type layout must match the toolchain:** integer widths, `enum` size, struct
  packing/alignment, bitfield layout, `va_list` (AAPCS32 layout), `double`/`long
  long` alignment. Mismatch silently corrupts every C call.
- **Float ABI must match the kernel/newlib build.** The system is built with
  `arm-none-eabi-*` for the Cortex-A9; xcc must use the **same `-mcpu` / `-mfpu` /
  `-mfloat-abi`** (hard vs soft float, VFP/NEON variant) as that build, or FP
  arguments and the newlib it links against will not agree. Read the actual flags
  from the platform build (`create_platform.py` / the Vitis BSP) — do not assume.
- **⚠ Three INDEPENDENT knobs — do not let the ABI knob gate the codegen knob:**
  1. **FPU present** — the Cortex-A9's VFPv3+NEON is *always* there.
  2. **FPU enabled at boot** — VFP is OFF at reset; the FSBL/standalone BSP (and
     our `xt_boot.S` / the Tier-1 `crt0.s`) must enable it (CPACR CP10/CP11 +
     `FPEXC.EN`) before the first FP instruction. Confirm on the real board.
  3. **Float ABI** (`soft` / `softfp` / `hard`) — purely *how floats cross
     function boundaries* (core regs vs VFP regs); a perf/compat choice, read
     from the BSP. It is **not** a statement that the FPU is absent.
  "soft float" in the BSP means the *ABI*, NOT "no FPU". The trap to avoid: xcc
  reading `-mfloat-abi=soft` and concluding "no FPU" → emitting soft-float
  *libcalls* for compute. For an A9-hosted FPU (e.g. serving the 6502), that is
  the wrong path — **xcc must emit genuine VFP instructions for compute
  regardless of the param-passing ABI**, with the FPU enabled at boot. `softfp`
  (soft ABI + real VFP compute) is exactly what the qemu testbed runs
  (`-mfloat-abi=softfp -mfpu=neon-vfpv3`).

## 3. C interoperability (mandatory, not optional)

xcc-ARM links a system that is mostly C: **newlib, FreeRTOS, FatFs, the GEM core,
SQLite, Lua, FreeType.** So:

- **Call C and be called by C** with full AAPCS32 fidelity, including passing/
  returning C structs, arrays, function pointers, and varargs.
- **Consume C type layouts** (so xcc code can use C headers' structs/handles —
  e.g. FreeRTOS task handles, FatFs `FIL`, FreeType `FT_Face`).
- **Resolve undefined symbols** against (a) loaded libraries' `.dynsym` and (b) the
  kernel's **curated export table** (newlib-level C symbols the kernel publishes) —
  the resolution order in [dynamic-loading.md](dynamic-loading.md) §5. The
  *syscalls* themselves go through the `svc #1` gateway (§5 here), not symbol
  binding.
- The C-ABI surface is what [[gem_service_architecture]] means by "xcc↔C linking
  matters inside the A9 service" — get it right once, centrally.

## 4. Position-independent code for ELF `ET_DYN`

xcc owns codegen, so it emits the **minimal-relocation PIC model the loader was
designed around** ([dynamic-loading.md](dynamic-loading.md) §3):

- **GOT-based PIC with PC-relative GOT access.** Produce `ET_DYN` (PIE and `.so`).
- **Only three relocation types** reach the loader: `R_ARM_RELATIVE`,
  `R_ARM_GLOB_DAT`, `R_ARM_ABS32`. ARM uses **`REL`** (`Elf32_Rel`) — addends
  in-place, not `RELA`.
- **Eager binding, no lazy PLT.** Fully populate the GOT at load; emit no lazy
  resolver stub.
- **⚠ Do NOT use the `r9`/SB (static-base, RWPI/ROPI) PIC model.** `r9` is the
  platform register and is used by the FreeRTOS/BSP runtime — an `r9`-based
  position-independent-data scheme clashes with it (this is the long-standing
  "PIC register problem"). PC-relative GOT access sidesteps it entirely; that is
  the required model.

## 5. Runtime harness — `support/arm9/lib`

The per-arch harness (portable core + thin backend, per
[dynamic-loading.md](dynamic-loading.md) §10). The port must provide:

- **`crt0`** — image entry → run `DT_INIT_ARRAY` (constructors) → call `main(argc,
  argv, envp)` → `exit()` (which runs `DT_FINI_ARRAY`).
- **Syscall stubs** — the `svc #1` gateway: **number in `r7`, args `r0–r5`, return
  `r0` (`r1:r0` for 64-bit), errors as `-errno`**, via `svc #1` (note: `svc #0` is
  owned by the FreeRTOS port). One thin veneer per syscall, or a generic
  `syscall(n, …)`.
- **`setjmp`/`longjmp`**, stack-unwind primitives, and any A32 asm intrinsics.
- **The ARC runtime** — retain/release/autorelease entry points for ARM (§6), plus
  the weak-reference machinery if xcc's ARC has it.
- **TLS** — per-task state via FreeRTOS thread-local-storage pointers (no ELF TLS).

## 6. ARC + the unmanaged subset (system-language requirement)

xcc-ARM is the **system** language, so its ARC must work *and* get out of the way:

- **ARC by default** for ordinary XTOS/app code — the memory-safety win that
  motivated using xcc low in the stack.
- **An explicit unmanaged subset** for the hardware-touching bottom, where
  retain/release traffic or ARC-driven ownership is wrong:
  - the kernel allocator, the scheduler, ISR/fault handlers, the loader itself;
  - **DMA / PL-visible buffers** whose lifetime is *hardware*-driven (the blitter,
    compositor, writeback, ANTIC/sprite surfaces) — these are also the **wired**
    pages from [memory-protection.md](memory-protection.md) §4, and must not be
    subject to ARC reclamation while the PL may touch them.
- This dual mode is a thing *only owning the compiler* provides (C/tcc have no ARC
  at all; a stock compiler can't offer ARC-with-escape). It must be expressible at
  the language level and the ARC runtime must tolerate unmanaged regions calling
  in.

## 7. Debug information (DWARF) — full backtrace

Emit the restricted DWARF profile (vision §3) for ARM, and — per the settled P6
decision — **full backtrace/unwind**. ARM is the *easy* backend for this (uniform
`CFA = SP + offset`, native 32-bit addresses, standard tooling).

- **Line table** — flat-PC ↔ `(file, line[, col])`, bidirectional (minimal DWARF
  line program). ARM uses its native 32-bit address directly (no `{bank}{offset}`
  packing).
- **Symbols + types** — functions (low/high PC), globals, type layouts (struct/
  enum/array/pointer) so values render typed.
- **Local locations** — only the three opcodes: `DW_OP_addr` (statics),
  `DW_OP_fbreg` (frame-relative), `DW_OP_regN` (AAPCS register-resident).
- **Frame/unwind (CFI, `.debug_frame`)** — per-function, **per-PC-range** rules for
  CFA + saved return address + previous frame base, so the debugger walks the
  stack. Emit advance-rows through prologue/epilogue so unwinding works from an
  arbitrary stop (fault/breakpoint mid-prologue, leaf, outermost frame).
- **Debug-build frame-pointer discipline** — in debug builds keep a frame pointer /
  regular prologue so CFI stays mechanical; release builds may unwind
  approximately.
- **ARM register vocabulary** — the DWARF register numbering for AAPCS regs.
- **Standard ELF/DWARF** — so `addr2line`/gdb work on the ARM side for free, and the
  bespoke IDE debugger reads one format across all three backends. (Note: use DWARF
  `.debug_frame` CFI for *debug* unwinding; ARM EHABI `.ARM.exidx` is a separate
  C++-exception concern and not required here.)

## 8. Output format & linking

- **ELF32, little-endian, `EM_ARM`.** Emit `ET_DYN` with a populated `.dynamic`,
  `.dynsym`, `.dynstr`, hash, `DT_NEEDED`, `DT_INIT_ARRAY`/`DT_FINI_ARRAY`.
- Decide and document whether xcc-ARM **emits final ELF directly** or emits
  relocatable objects consumed by an external linker (GNU `ld`) with a project
  linker script. Either is fine; the loader only cares about the resulting
  `ET_DYN` (§4). Keep `.dynamic`/dynsym and DWARF sections un-stripped.

## 9. Build & toolchain integration

- **Host cross-build first** (on the valhalla build host), matching the platform's
  `arm-none-eabi` `-mcpu=cortex-a9` + the BSP's `-mfpu`/`-mfloat-abi`. On-device
  xcc-on-xcc self-hosting comes later (see
  [../MultiTasking/self-hosting.md](../MultiTasking/self-hosting.md)); on-device C
  is deferred.
- Produces both **libraries** (`OS/Library/*.so`, `ET_DYN`) and **apps**
  (`OS/Apps/*`, `ET_DYN` PIE) per the loader's expectations.

## 10. Validation checklist

The port is "done enough" when:

- [ ] An xcc function calls a C function (newlib `printf`, a FatFs call) and back,
      structs and varargs intact (AAPCS32 conformance).
- [ ] A trivial xcc `ET_DYN` loads via the loader, relocates (the 3 reloc types),
      and runs — including resolving a libGEM/newlib symbol.
- [ ] `svc #1` syscalls work end-to-end (`spawn`, `open`/`read`/`write`, `exit`).
- [ ] A debugger backtrace walks a mixed xcc↔C call stack with correct
      source lines and frame locals (CFI from an arbitrary stop).
- [ ] ARC retain/release is correct, and an unmanaged region (a DMA/PL buffer)
      is not reclaimed while wired.
- [ ] `r9` is never used as a PIC/SB base (no clash with the BSP).

## 11. Open / deferred sub-decisions

- **A32 vs Thumb-2** instruction set (or mixed) — Thumb-2 is denser (code size),
  A32 is simpler to emit first. Default to A32 for bring-up; revisit Thumb-2 for
  density once correct.
- **Hard vs soft float** — *gated*: must match the newlib/BSP build, so it's read
  from the platform, not chosen here. See §2 for the three-knobs nuance (the soft
  ABI is *not* "no FPU"; xcc must emit VFP for compute regardless of the ABI —
  matters for an A9-hosted FPU serving the 6502).
- **NEON usage** — opportunistic vectorisation is a later optimisation; not a
  bring-up requirement.
- **Direct-ELF vs object+linker** (§8) — implementation choice to pin during the
  port.

## Related

- [dynamic-loading.md](dynamic-loading.md) — the loader, syscall ABI, reloc model,
  symbol resolution this back-end targets.
- [memory-protection.md](memory-protection.md) — tier-2 runtime; the wired/ARC
  boundary (§6).
- [xtos-vision.md](xtos-vision.md) §3 — the DWARF debug-info contract (§7).
- [../MultiTasking/self-hosting.md](../MultiTasking/self-hosting.md) — the xcc
  self-hosting roadmap; on-device bootstrap.
- [../MultiTasking/multitasking.md](../MultiTasking/multitasking.md) §1 — earlier
  native-ARM loading notes (incl. the `r9` PIC problem, now folded into §4).
