# The XTOS DWARF subset — emitter/reader contract

> **Status: spec.** The precise, restricted DWARF profile xcc emits for **all three
> backends** (ARM / m68k / 6502) and the bespoke IDE debugger reads. It makes
> concrete the conceptual profile in [xtos-vision.md](xtos-vision.md) §3, with the
> settled **full-backtrace** decision folded in. Goal: emit *only* what we use, so a
> hand-rolled reader stays tiny — while staying **valid DWARF 5**, so stock tools
> (`addr2line`, gdb, gimli/libdwarf) work on the ARM side for free.

## 1. Philosophy

One parameterised emitter, one reader, three backends. We do **not** invent a
parallel format; we emit a small subset of standard DWARF and simply *don't emit
what we don't use*. The per-backend difference is exactly DWARF's built-in
extension point — target-defined **register numbers** (§7) and the
**flat-address** contract (§3) — not new structure.

**DWARF version: 5.** Little-endian, 32-bit DWARF format. The subset is small
enough to be version-portable, but we target v5 (current, clean line-program
header, `.debug_line_str`).

**Sections emitted:** `.debug_info`, `.debug_abbrev`, `.debug_line`,
`.debug_str` (+ `.debug_line_str`), and **`.debug_frame`** (CFI / unwind). Nothing
else (see §9 for the explicit *not-emitted* list).

## 2. Compilation unit

One `DW_TAG_compile_unit` per translation unit:

| Attribute | Value |
|-----------|-------|
| `DW_AT_producer` | `"xcc <version> <backend>"` |
| `DW_AT_language` | a `DW_LANG_*` (xcc's own once registered; `DW_LANG_C11` as a stand-in until then) |
| `DW_AT_name` / `DW_AT_comp_dir` | source path / compile dir |
| `DW_AT_low_pc` / `DW_AT_high_pc` | unit flat-PC span (§3) |
| `DW_AT_stmt_list` | offset into `.debug_line` |

## 3. The flat logical-address contract

Every address in DWARF — line table, symbol PCs, CFI `initial_location`, location
expressions — is a **single linear value** in the same flat space the loader,
breakpoint comparators, and the debugger share (vision §3, item 1).

- **ARM / m68k** — native 32-/24-bit addresses, used directly.
- **6502** — the packed **`flat32 = (bank << 16) | offset`**: `offset` = the 16-bit
  6502 logical address, `bank` = the 8-bit bank selector (`$D5C0` code / `$D5C1`
  data; `0` = BRAM). Code and data banks occupy **disjoint** windows, so the
  offset's window already implies code-vs-data — **no `realm` tag**. The top 8 bits
  are reserved (zero).

Because `{bank}{offset}` linearises the banked machine, DWARF — which assumes a
linear address space — needs no banking awareness. The debugger maps flat↔physical
at access time.

## 4. Symbols & types

DIEs we emit (and *only* these):

| Tag | Purpose | Key attributes |
|-----|---------|----------------|
| `DW_TAG_subprogram` | function | `name`, `low_pc`, `high_pc`, `frame_base` (§6), `type` (return), `external`, `prototyped`, `decl_file/line` |
| `DW_TAG_formal_parameter` | parameter | `name`, `type`, `location` (§5) |
| `DW_TAG_variable` | local / global | `name`, `type`, `location` (§5); globals add `external` |
| `DW_TAG_lexical_block` | nested scope | `low_pc`/`high_pc` (scopes a variable's live range) |
| `DW_TAG_base_type` | int/char/float/bool | `name`, `byte_size`, `encoding` |
| `DW_TAG_pointer_type` | pointer | `byte_size`, `type` |
| `DW_TAG_structure_type` / `union_type` | aggregate | `name`, `byte_size` + `DW_TAG_member` children |
| `DW_TAG_member` | field | `name`, `type`, `data_member_location`, (`bit_size`/`data_bit_offset` for bitfields) |
| `DW_TAG_array_type` + `DW_TAG_subrange_type` | array | element `type`; `upper_bound`/`count` |
| `DW_TAG_enumeration_type` + `DW_TAG_enumerator` | enum | `name`, `byte_size`; enumerators carry `const_value` |
| `DW_TAG_typedef` | alias | `name`, `type` |
| `DW_TAG_const_type` / `DW_TAG_volatile_type` | qualifiers | `type` |
| `DW_TAG_subroutine_type` | function-pointer target | `type` + `formal_parameter`s |

Type DIEs are shared/deduplicated within a CU (reference by offset). Scopes nest
(`lexical_block`) so a variable's validity is bounded by its block's PC range —
this is how "live PC-range" is expressed without location lists (§5, §9).

## 5. Variable locations

Only **three** location forms (the rest of DWARF's expression VM is not used):

| Form | Expression | Used for |
|------|-----------|----------|
| **static** | `DW_OP_addr <flat-addr>` | globals, statically-allocated locals, ZP globals (6502) |
| **frame-relative** | `DW_OP_fbreg <offset>` | stack/frame locals — offset is relative to `DW_AT_frame_base` |
| **register** | `DW_OP_regN` (value in reg) / `DW_OP_bregN <off>` (at reg+off) | register-resident locals; the **6502 SSP** spill base (§8) |

**One location per variable** (a single expression, valid over its scope's PC
range). We do **not** emit location lists — debug-build codegen keeps a variable in
one place for its whole scope (frame-relative is the default), so a single
expression suffices. A register-resident local is emitted only when it lives in one
register for the whole scope.

**6502 dual-base:** in-frame locals are `DW_OP_fbreg` (frame base = CFA, on the
hardware/call stack); spilled locals are `DW_OP_bregN(SSP)+offset` against the
software stack pointer. See §8.

## 6. Frame base = the CFA

Every `DW_TAG_subprogram` sets:

```
DW_AT_frame_base = DW_OP_call_frame_cfa
```

i.e. the frame base *is* the Canonical Frame Address computed from CFI (§7). So
`DW_OP_fbreg` offsets are CFA-relative and therefore **stable regardless of where
in the function execution stopped** (the SP may move mid-function; the CFA does
not). This couples locals to the unwind tables and is what lets us avoid location
lists for stack locals.

## 7. Line program & CFI

### 7a. Line table (`.debug_line`)

A minimal DWARF line program — itself just a delta-encoded `flat-PC ↔ (file,
line[, column])` table, **bidirectional** (breakpoint-by-line *and*
stop→highlight-source). Opcodes used: `DW_LNS_copy`, `DW_LNS_advance_pc`,
`DW_LNS_advance_line`, `DW_LNS_set_file`, `DW_LNS_set_column`,
`DW_LNS_negate_stmt`, the special opcodes (combined pc+line advance), and
`DW_LNE_end_sequence`. No `DW_LNE_set_discriminator`, no VLIW ops.

### 7b. Unwind / backtrace (`.debug_frame`)

**Full backtrace is in scope for all three backends** (settled P6 decision). Use
`.debug_frame` (DWARF CFI), not `.eh_frame` (we don't need C++ runtime unwinding;
ARM `.ARM.exidx` is likewise out of scope).

- **CIE** (one per backend, augmentation as needed): version, code/data alignment
  factors, **return-address register** (§7c table), initial CFA rule.
- **FDE** per function: `initial_location` (flat PC), `address_range`, and CFI
  instructions: `DW_CFA_advance_loc*` (per-PC-range rows through prologue/epilogue),
  `DW_CFA_def_cfa` / `def_cfa_register` / `def_cfa_offset` (CFA = reg + offset),
  `DW_CFA_offset` (a saved reg at CFA-relative slot), `DW_CFA_val_offset` (a reg
  whose *value* is CFA+k — used for the 6502 SSP, §8), `DW_CFA_restore`.

**Per-PC-range accuracy is required:** emit advance rows through the prologue and
epilogue so unwinding works from an *arbitrary* stop (fault/breakpoint mid-prologue,
in a leaf, at the outermost frame). **Debug builds keep a frame pointer / regular
prologue** so this stays mechanical; release builds may unwind approximately.

### 7c. Per-backend register vocabulary

DWARF register numbers (the per-target extension point). ARM/m68k use the
standard, published numbering; **6502 is bespoke — xcc defines it here**:

| Backend | Registers (DWARF numbers) | Return-address reg | CFA (typical) |
|---------|---------------------------|--------------------|---------------|
| **ARM** (AAPCS32) | standard ARM: `r0–r15` = 0–15, VFP/NEON above | `r14` (LR) | `SP/FP + offset` |
| **m68k** | standard: `d0–d7` = 0–7, `a0–a7` = 8–15, PC | return addr at `a6` frame (LINK/UNLK) | `a6/a7 + offset` |
| **6502** (xcc-defined) | `A`=0, `X`=1, `Y`=2, `P`=3, **ext-SP**=4 (12-bit hw stack), **SSP**=5 (soft stack), `PC`=6; register-allocated ZP slots numbered from 16 | a synthetic RA column off the hardware stack (§8) | ext-SP `+ offset` |

The 6502 numbering (0–6 for architectural state, 16+ for ZP-allocated soft
registers) is published *here* so the emitter and the debugger's 6502 reader agree;
it never has to encode an ARM-sized address (ARM uses native DWARF, this packing is
retro-only).

## 8. The 6502 specials

The 6502 is the only backend needing per-target unwind rules beyond "CFA = SP +
offset":

1. **`JSR` pushes PC−1.** The return-address column recovers the saved bytes; the
   reader applies **+1** and the high/low byte order to get the real return PC.
   Recommended encoding: a `DW_CFA_val_expression` computing `value+1`
   (self-describing); acceptable alternative: the debugger's 6502 backend applies
   the fixup (we own the reader). Document whichever in the CIE augmentation.
2. **Interrupt frames are signal frames.** `IRQ`/`NMI`/`BRK` push the status
   register `P` and the **true** PC (not PC−1), a different layout from a `JSR`
   frame. Mark those FDEs as **signal frames** (CIE augmentation `S`-equivalent) so
   the unwinder switches to the interrupt-frame format when crossing an ISR.
3. **Dual stack → SSP as a tracked register.** The call frame (return address, args,
   in-window locals) lives on the **extended hardware stack** (`CFA = ext-SP +
   offset`); spills that overflow the signed-8-bit ±~119-byte SP reach, or must
   survive nested calls, live on the **software stack (SSP)** in flat RAM. So:
   - in-frame locals → `DW_OP_fbreg` (CFA-relative);
   - spilled locals → `DW_OP_bregN(SSP)+offset`;
   - to inspect **outer**-frame spills, the SSP must be recovered per frame —
     modelled as a CFI-tracked register: **fixed-size spill frames** →
     `DW_CFA_val_offset` (`caller_SSP = callee_SSP + spill_size`, a per-function
     constant); **dynamically-sized** → a saved soft-frame-pointer.
   - Graceful degradation: the **current** frame reads the live SSP over the debug
     port, so backtrace + current-frame locals work even before outer-frame SSP
     recovery is implemented (same format — no flag day).

## 9. Explicitly NOT emitted

Keeping the reader tiny — the debug-build codegen guarantees make these
unnecessary:

- **Location lists** (`.debug_loclists`) — one stable location per variable (§5).
- **`DW_TAG_inlined_subroutine`** — debug builds suppress aggressive inlining, so no
  inline-frame reconstruction. (If a release build inlines, it does so without
  debug fidelity.)
- **The general DWARF expression VM** — only the ops in §5/§6/§8 appear.
- **`.debug_ranges`/`rnglists`** — functions/scopes are contiguous `low/high_pc`.
- **`.debug_aranges`, `.debug_pubnames`/`pubtypes`, `.debug_names`** — accelerators;
  the reader indexes the CU directly. (May add `.debug_names` later purely as a
  speed optimisation; not required for correctness.)
- **Macro info, split DWARF, type units.**

## 10. Validation checklist

- [ ] `addr2line` and gdb resolve and unwind an **ARM** `ET_DYN` (stock-tool
      conformance — the canary that the subset is valid DWARF, not just ours).
- [ ] Bidirectional line lookup (line→flat-PC for breakpoints; flat-PC→line for
      stop-highlight) on all three backends.
- [ ] Typed value rendering (struct/enum/array/pointer) from the type DIEs.
- [ ] Backtrace from an arbitrary stop (mid-prologue, leaf, outermost) on ARM and
      m68k; 6502 backtrace + current-frame locals; 6502 outer-frame spill recovery.
- [ ] 6502 `JSR` PC+1 fixup and an ISR-frame crossing unwind correctly.

## Related

- [xtos-vision.md](xtos-vision.md) §3 — the conceptual profile this realises; P6
  the debugger that consumes it.
- [xcc-on-arm9.md](xcc-on-arm9.md) §7 — the ARM emitter's slice of this contract.
- [dynamic-loading.md](dynamic-loading.md) — the flat-address space and `ET_DYN`
  the addresses live in.
