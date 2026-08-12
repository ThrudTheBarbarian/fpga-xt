# Improving the 6502 for xcc

## Motivation

The stock 6502's 256-byte hardware stack (page-1, `$0100–$01FF`) has two problems:

1. **Too shallow** for C-style function call trees with non-trivial frames.
2. **No random access** — you can only PUSH and PULL. Accessing a parameter
   or local variable requires `TSX` + `LDA $0100,X`, which is slow, only
   reaches the low 256 bytes of the stack, and ties up X.

The enhancements below fix both while staying backward-compatible with
existing 6502 code (the Atari OS, ROM routines, etc.).

---

## 1. Large Page-1 — 4 KB hidden stack RAM

### Architecture

The CPU gains an internal 4 KB synchronous SRAM for the hardware stack.
This memory is **not** mapped into the 16-bit address space — normal
`LDA`/`STA` cannot reach it.  Only stack operations (PHA, PLA, JSR, RTS,
RTI, BRK) and the new SP-relative instructions access it.

The stack pointer is widened from 8 bits to **12 bits**, giving:

    SP[11:0]  — offset into the internal 4 KB stack RAM (0–4095)

### Aliased compatibility window

The **top** 256 bytes of the internal stack RAM (addresses `$F00–$FFF`)
are aliased into the 6502's normal address space at `$0100–$01FF`.
Since the stack grows downward, after reset `SP = $FFF`:

    PHA            stores to stack address $FFF  →  visible at $01FF
    next PHA       stores to stack address $FFE  →  visible at $01FE
    ...
    256th PHA      stores to stack address $F00  →  visible at $0100
    257th PHA      stores to stack address $EFF  →  hidden, no alias

This means: **existing code that uses TSX + LDA $0100,X works perfectly
for the first 256 bytes of stack depth** — exactly the range the original
6502 supported.  Code that never pushes deeper than 256 bytes sees no
difference.

For depths >256 bytes, `TSX` still returns `SP[7:0]` (the low 8 bits),
but `LDA $0100,X` now reads the stale first-256-byte window rather than
the current stack position.  New code targeting the 'xt' model avoids
TSX/TXS entirely and uses SP-relative addressing instead (see below).

### Reset behaviour

    SP[11:8]  = $0F              →  initial SP = $FFF
    SP[7:0]   = $FF

`LDX #$FF : TXS` after reset gives `SP = $FFF` (TXS writes X into
`SP[7:0]`, `SP[11:8]` are unchanged).  This matches the traditional
6502 init sequence and lands at the top of the 4 KB region.

### TSX / TXS

    TSX  —  X ← SP[7:0]           ; high 4 bits lost
    TXS  —  SP[7:0] ← X            ; high 4 bits unchanged

The top 4 bits of SP are unaffected by TSX/TXS.  This preserves code
that uses TXS for stack-pointer setup (common pattern: `LDX #$FF : TXS`)
while allowing PHA/PLA/JSR/RTS to use the full 12-bit depth.


---

## 2. SP-relative addressing mode

### Format

All SP-relative instructions are **2 bytes, 2 clock cycles**:

    Cycle 1:  fetch opcode from main memory
    Cycle 2:  fetch signed offset from main memory,
              simultaneously compute SP + offset (12-bit signed),
              and read/write the internal stack RAM on a separate port

The offset is an **8-bit signed** value (`d`, range −128 .. +127`).
This covers a ±128-byte window around the current SP, sufficient for
any function-call frame.

Addressing within the 4 KB stack RAM **clamps** rather than wrapping:
an address below `$000` saturates to `$000`; above `$FFF` saturates to
`$FFF`.  (A clamped access is a programming error; the clamp prevents
silent corruption of unrelated memory.)

### Register loads and stores

All read/write the internal stack RAM, never main memory.

| Opcode | Mnemonic | Operation | JAM? |
|--------|----------|-----------|------|
| `$B2` | `LDA d,SP` | `A ← stack8(SP + d)` | ✓ |
| `$92` | `STA d,SP` | `stack8(SP + d) ← A` | ✓ |
| `$42` | `LDX d,SP` | `X ← stack8(SP + d)` | ✓ |
| `$52` | `LDY d,SP` | `Y ← stack8(SP + d)` | ✓ |
| `$02` | `STX d,SP` | `stack8(SP + d) ← X` | ✓ |
| `$12` | `STY d,SP` | `stack8(SP + d) ← Y` | ✓ |

Adding `STX` / `STY` avoids having to move X/Y through A first
(`TXA : STA d,SP : ...`), which clobbers A and costs extra cycles.
Since these are common in function prologues/epilogues and context
switches, the hardware cost (two more opcode decodes, same datapath)
is negligible.

### Arithmetic and comparison

| Opcode | Mnemonic | Operation | JAM? |
|--------|----------|-----------|------|
| `$72` | `ADC d,SP` | `A ← A + stack8(SP + d) + C` | ✓ |
| `$F2` | `SBC d,SP` | `A ← A − stack8(SP + d) − ¬C` | ✓ |
| `$D2` | `CMP d,SP` | `flags ← A − stack8(SP + d)` | ✓ |

These use the same ALU as the normal ADC/SBC/CMP; the operand is just
sourced from the stack RAM instead of the main data bus.  Hardware cost
is near zero.

### Stack adjustment

| Opcode | Mnemonic | Operation | JAM? |
|--------|----------|-----------|------|
| `$22` | `ADD SP, #signed8` | `SP ← clamp(SP + signed8, $000, $FFF)` | ✓ |

This is used by the caller after a function call, and saves a whole dance where A needs to be preserved but the stack needs to be adjusted.  The result is clamped to the 12-bit range, mirroring the SP-relative load/store path, so a too-large displacement does not silently wrap the SP into an unrelated area.  No flags are modified.

### Encoding note

All the above opcodes are in the `$x2` column of the NMOS 6502 opcode
matrix.  On the original 6502 these are all JAM (halt) instructions.
No shipping 6502 binary will ever execute them, so they are safe to
repurpose.

Spare JAM slots still available: `$82` (and `$C2`, `$E2` on
variants where those are JAMs rather than NOPs).

### Push and pop X and Y directly

| Opcode | Mnemonic | Operation | JAM? |
|--------|----------|-----------|------|
| `$44` | `PUSH X` | `SP ← X; SP --` | no, NOP |
| `$54` | `PUSH Y` | `SP ← Y; SP --` | no, NOP |
| `$64` | `POP X` | `X ← SP; SP ++` | no, NOP |
| `$64` | `POP Y` | `Y ← SP; SP ++` | no, NOP |

These allow direct store to/restore from the stack pointer, without having
to go through A, and doing the increment/decrement operation of the stack
pointer itself

### 65C02 additions

The 65C02 already has BRA at this location, make $80 be BRA #imm with an 8-bit signed offset to the location to branch to. Should be fairly trivial to implement, and would be a harmless 2-byte NOP on NMOS

| Opcode | Mnemonic | Operation | JAM? |
|--------|----------|-----------|------|
| `$80` | `BRA #imm` | `PC += imm` | no, but NOP |

Equally, the 65C02 has the ability to do an immediate bit-test, at `$89`

| Opcode | Mnemonic | Operation | JAM? |
|--------|----------|-----------|------|
| `$89` | `BIT #imm8` | `Z = (A & imm)==0`; N,V unchanged | no, but NOP |

Note the immediate `BIT` affects **only Z** — unlike the memory-operand
`BIT` modes, there are no memory bits 7/6 to copy into N/V, so the 65C02
leaves them alone.


---

## 2b. Stack-pointer indirect & indexed addressing

### Motivation

`d,SP` (§2) covers *scalar* in-frame access, but a C compiler still
falls back to a software stack (an `FP`-based frame in main RAM, indexed
with `(FP),Y`) for two cases the deeper 4 KB hidden stack can't reach:

1. **Dereferencing a pointer that lives on the stack.**  With only `d,SP`
   you can load the pointer's bytes but not follow them — so pointer
   locals/temps get pinned in zero page, and the ZP ceiling is what
   blocks `printf` and friends.
2. **Indexed access into an in-frame aggregate** (arrays/structs whose
   base is at `SP+d`, indexed by a runtime value).

Two new modes close both, so the software FP-frame can retire except for
the genuinely address-taken (escaping) arena:

| Mnemonic | Operation | Use |
|----------|-----------|-----|
| `LDA/STA (d,SP),Y` | `addr = stack8(SP+d) ∣ stack8(SP+d+1)<<8; mem[addr + Y]` | deref a stacked pointer in place |
| `LDA/STA d,SP,X`   | `stack8(SP + d + X)` | indexed in-frame aggregate access |

`(d,SP),Y` is exactly `(zp),Y` with the 16-bit pointer fetched from the
hidden stack instead of zero page; the post-index by `Y` and the
resulting access hit **main memory**.  `d,SP,X` is `d,SP` with `X` added
into the (clamped, 12-bit) stack address — the access stays in the
hidden stack.

### Encoding

These are addressing *modes* spanning load+store, so they don't fit the
near-full `$x2` column.  They land in the **`$x3` column** — the cc=11
(low-two-bits `11`) quadrant, which is the SLO/RLA/SRE/RRA combo-illegal
group on NMOS.  A documented-only core (Arlet) decodes *none* of it, and
SALLY's other embellishments all live in cc=00 (`$x4`: PUSH/POP) and
cc=10 (`$x2`: `d,SP`), so the whole `$x3` column is free.  Anchored at
the bottom for an orthogonal decode:

| Opcode | bits | Mnemonic | `IR[5]` mode | `IR[4]` ld/st |
|--------|------|----------|--------------|---------------|
| `$03` | `0000_0011` | `LDA (d,SP),Y` | 0 = `(),Y` | 0 = load |
| `$13` | `0001_0011` | `STA (d,SP),Y` | 0 = `(),Y` | 1 = store |
| `$23` | `0010_0011` | `LDA d,SP,X`   | 1 = `,X`   | 0 = load |
| `$33` | `0011_0011` | `STA d,SP,X`   | 1 = `,X`   | 1 = store |

Decode is two single-bit tests: `mode_x = IR[5]`, `store = IR[4]` — no
four-way match.  Verified (2026-05-22) that no `casex(IR)` arm in
`cpu.v` matches these (all decode patterns need bits[3:2]∈{01,11} or
bits[7:5]=101; `$x3` has bits[3:2]=00, bits[7:5]∈{000,001}), so they
currently fall through to the `default` arms (treated as no-ops).  The
remaining twelve `$x3` slots are reserved for future SP-indirect
variants (`ADC (d,SP),Y`, `CMP d,SP,X`, …).

### FSM states and datapath

`(d,SP),Y` reuses the back half of Arlet's existing `(zp),Y` flow
(`INDY2`/`INDY3`, where the 16-bit `ptr+Y` add already happens via the
ALU).  Only the pointer fetch changes — from the stack BRAM instead of
zero page:

```
SPINDY0:  AB = {4'h0, sp_eff_clamped};  stack_op=1     ; DI→ ptr LSB
SPINDY1:  AB = {ABH,ABL} + 1;           stack_op=1     ; ALU: LSB + Y
   →  INDY2 (existing): AB = {DIMUX(=ptr MSB), ADD(=LSB+Y)} ; ALU: MSB+carry  (main mem)
   →  INDY3 (existing): page-cross fixup
```

The high-byte stack address is `(SP+d)+1`, formed by incrementing the
already-latched `{ABH,ABL}` — no second `sp_eff` adder.

`d,SP,X` is a single stack access with the index folded in:

```
SP0X_A:  AB = {4'h0, sp_eff_clamped};   (= SP+d, latched into ABH:ABL)
SP0X_B:  AB = {ABH,ABL} + {4'h0,X};     stack_op=1     ; stack read/write
```

The `+X` is done as a **second 2-input add** on the already-computed
`SP+d`, *not* as a single 3-input `SP+d+X`.  This keeps every cycle's
stack-address path at the existing 2-input adder depth, which matters:
post-place `clk_sally` WNS is thin (+0.039 ns after the sally pblock),
and the stack-address path is in that critical family.  A single-cycle
3-input add would add ~1 carry-save level (~0.3-0.5 ns) and erode that
margin; the pipelined form costs one extra cycle instead and is
fMax-neutral.

### fMax

Both modes are **fMax-neutral**.  `(d,SP),Y` adds only FSM states — it
reuses `sp_eff_clamped` (2-input) and the existing INDY `ptr+Y` ALU add,
introducing no new combinational depth.  `d,SP,X` is fMax-neutral *as
specified* (pipelined `+X`); the ALU carry chain remains the
`clk_sally` fmax ceiling (~107 MHz).

### Cycle counts

| Instruction | Cycles | Breakdown |
|-------------|--------|-----------|
| `LDA/STA (d,SP),Y` | 5 (+1 on page cross) | DECODE / fetch d / SPINDY0 (LSB) / SPINDY1 (MSB, +Y) / INDY2 (data) |
| `LDA/STA d,SP,X`   | 3 | DECODE / SP0X_A (SP+d) / SP0X_B (+X, stack access) |

These match the shape of the equivalent NMOS modes (`(zp),Y` = 5-6,
`zp,X` = 4) given the hidden stack's single-port BRAM.

---

## 3. Housekeeping — PSH / PLL

### Design rationale

A function prologue needs to:
1. Save the caller's registers.
2. Allocate space for local variables.

These must happen atomically — an interrupt must never see a partially
constructed frame where SP points into the saved-register area.

**Reversed order** (allocate first, then save) guarantees this: after
`SP -= N` the stack pointer is already below the entire frame.  Any
interrupt that fires during the subsequent register pushes will push
its data even further below the frame, never corrupting it.

### Why save 12-bit SP as 2 bytes?

The stack pointer is 12 bits.  Saving only `SP[7:0]` (1 byte) is
insufficient: after deep nesting, `SP[11:8]` may differ between the
PSH and PLL of the same function (e.g. entry SP = `$F0F`, PSH #200
subtracts 205 → SP = `$E42`; `SP[11:8]` has changed from $F to $E).
PLL would restore `SP[7:0] = $0F` but preserve `SP[11:8] = $E`,
giving `$E0F` instead of the correct `$F0F`.

Therefore PSH saves the **full 12-bit SP as two bytes**: `SP[7:0]`
and `SP[11:8]` (zero-padded to 8 bits).  The register save area
grows from 5 to 6 bytes; with the one-byte guard slot (below) the
allocation is `frame_size = N + 7`.

### Guard byte (interrupt / push safety)

This machine pushes **post-decrement** (write at SP, then `SP--`), so the
byte at `SP+0` is always the *next* push target.  PSH therefore leaves SP
pointing one byte **below** the lowest saved-register slot: `SP+0` is a
reserved guard byte, and the saved registers occupy `SP+1..SP+6`.  This keeps
the invariant "everything above SP is occupied, SP+0 is free", so the first
push inside a live frame — `PHA`/`PHP`, `PUSH X/Y`, `JSR`, or a hardware
IRQ/NMI/BRK — lands on the guard byte, never on the saved registers.  Without
it, a single push would clobber saved P (and a JSR/IRQ would clobber saved
SP_lo/SP_hi too), defeating the interrupt-safety guarantee.  See
`docs/Issues/0001-psh-pll-guard-byte.md`.

### Instruction formats

    PSH  #N      ; (opcode $32, 2 bytes, 5 cycles)
    PLL  #N      ; (opcode $62, 2 bytes, 5 cycles)

`N` is an unsigned 8-bit immediate (0–255), giving a usable local
space of 0–255 bytes per call.  Larger frames must chain multiple
PSH/PLL.

### PSH #N

**Mechanism** — PSH does **not** use the "store at SP, then decrement"
semantics of PHA.  Instead it allocates the full frame (reg save area +
locals) in a single SP adjustment, then writes the registers into fixed
slots **below** the local area.  This avoids any overlap between saved
registers and locals, and keeps the saved registers at known offsets
from SP regardless of `N`.

**Operation** (executed atomically, no interrupt can split it):

```
frame_size = N + 7                     ; guard (1) + reg save (6) + locals (N)
SP = SP − frame_size                   ; 1. allocate full frame

stack8(SP + 6) = A                     ; 2. write saved A
stack8(SP + 5) = X                     ; 3. write saved X
stack8(SP + 4) = Y                     ; 4. write saved Y
stack8(SP + 3) = SP_hi_entry           ; 5. write saved SP[11:8] (entry value)
stack8(SP + 2) = SP_lo_entry           ; 6. write saved SP[7:0]  (entry value)
stack8(SP + 1) = P                     ; 7. write saved P
; stack8(SP + 0) is the guard byte — left unwritten, free for the next push
; SP unchanged by writes — still points at the guard byte
```

`SP_lo_entry` / `SP_hi_entry` are `SP[7:0]` and `SP[11:8]` as they
were **before** the SP adjustment in step 1.  `SP_hi_entry` occupies
one full byte; bits [7:4] are zero, bits [3:0] carry the saved
`SP[11:8]`.

**Stack layout after PSH #N**

```
higher addresses
         ┌─────────────────────┐
         │    caller's params  │  ← pushed by caller before JSR
         ├─────────────────────┤
         │    return address   │  ← pushed by JSR (2 bytes)
         ├─────────────────────┤
         │    local[N-1]       │
         │       ...           │  ← N bytes
         │    local[0]         │
         ├─────────────────────┤
         │    saved A          │  ← at SP + 6
         │    saved X          │  ← at SP + 5
         │    saved Y          │  ← at SP + 4
         │    saved SP[11:8]   │  ← at SP + 3
         │    saved SP[7:0]    │  ← at SP + 2
         │    saved P          │  ← at SP + 1
         ├─────────────────────┤
         │    guard byte       │  ← at SP + 0 (free / interrupt safe)
    SP → └─────────────────────┘
lower addresses
```

All offsets from SP are fixed, independent of `N`:

| Value       | Offset from SP |
|-------------|---------------:|
| guard byte  | `+0`           |
| saved P     | `+1`           |
| saved SP_lo | `+2`           |
| saved SP_hi | `+3`           |
| saved Y     | `+4`           |
| saved X     | `+5`           |
| saved A     | `+6`           |
| local[0]    | `+7`           |
| local[k]    | `+7 + k`       |
| (gap)       | `+N + 7`       |
| ret_lo      | `+N + 8`       |
| ret_hi      | `+N + 9`       |
| param[0]    | `+N + 10`      |

The gap byte at `+N + 7` exists because the 6502's `JSR` pushes two bytes
(PC‑hi then PC‑lo) and decrements SP by 2, leaving the entry SP position
unwritten.  It can be used as an extra local if needed, but the canonical
local area is the N bytes at `+7..+N+6`.

**Example with concrete addresses** (params + JSR + PSH #12):

Initial SP before pushing params = `$FFF`:

```
    PHA           ; param_lo  → $FFF,   SP = $FFE
    PHA           ; param_hi  → $FFE,   SP = $FFD
    JSR  func     ; ret_hi    → $FFD,   SP = $FFC
                  ; ret_lo    → $FFC,   SP = $FFB  ← entry SP
    PSH  #12
```

After `PSH #12`:

```
SP after PSH = $FFB − 12 − 7 = $FE8

$FE8:  guard byte        ← SP + 0  (free / interrupt safe)
$FE9:  saved P           ← SP + 1
$FEA:  saved SP_lo       ← SP + 2
$FEB:  saved SP_hi       ← SP + 3  (holds $0F = SP[11:8] of entry $FFB)
$FEC:  saved Y           ← SP + 4
$FED:  saved X           ← SP + 5
$FEE:  saved A           ← SP + 6
$FEF:  local[0]          ← SP + 7
 ...
$FFA:  local[11]         ← SP + 18  = SP + 7 + 11
$FFB:  (gap)             ← SP + 19  = SP + N + 7
$FFC:  ret_lo            ← SP + 20  = SP + N + 8
$FFD:  ret_hi            ← SP + 21  = SP + N + 9
$FFE:  param_hi          ← SP + 22  = SP + N + 10
$FFF:  param_lo          ← SP + 23  = SP + N + 11
```

### PLL #N

**Operation** (atomic):

```
P     = stack8(SP + 1)                 ; 1. read saved P
SP_lo = stack8(SP + 2)                 ; 2. read saved SP[7:0]  (see note)
SP_hi = stack8(SP + 3) & $0F           ; 3. read saved SP[11:8] (see note)
Y     = stack8(SP + 4)                 ; 4. read saved Y
X     = stack8(SP + 5)                 ; 5. read saved X
A     = stack8(SP + 6)                 ; 6. read saved A
SP    = SP + (N + 7)                   ; 7. deallocate full frame (incl. guard)
```

**Note on SP restore:** the saved `SP_lo` / `SP_hi` on the stack are
the *entry* SP values, placed there by PSH for diagnostic use
(debugger backtrace, context-switch frame inspection).  PLL does
**not** write them back into SP — instead it relies on SP having
remained at the post-PSH value throughout the function body (which
holds if pushes and pops are balanced).  The final `SP += (N + 7)`
then restores SP to the entry value.

After PLL #N, SP points at `ret_lo`.  A subsequent `RTS` pops the
return address and the caller is re-entered with SP pointing at the
first parameter byte.

### Interrupt safety

PSH/PLL are single multi-cycle instructions — the 6502 does not check
for interrupts mid-instruction.  Even if it did, the reversed order
(SP adjusted *first*, before any register writes) means SP always
points below the allocated frame.  Any interrupt push would land
strictly below the frame, never corrupting register saves or locals.

### Scope-bounded critical sections

Because PSH saves `P` (including the I-flag) at function entry and
PLL restores it at exit, an `SEI` inside the function body does not
need a matching `CLI` before `RTS` — `PLL` puts the I-flag back to
whatever the caller had on entry.  Critical sections inside a
normal-prologue/epilogue function are therefore scope-bounded by
construction: a library routine can `SEI; STA lo; STA hi` for an
atomic 16-bit store and let the epilogue restore the caller's
interrupt-enable state.  This is the canonical atomicity primitive
on this CPU; no LL/SC or CAS instruction is required.

---

## 4. Calling convention sketch

### Register usage

| Register | Role |
|----------|------|
| A        | return value, primary workhorse |
| X, Y     | temporaries (callee-save via PSH) |
| SP       | 12-bit stack pointer |
| P        | condition codes |

### Prologue / epilogue

```
my_func:
    PSH  #locals_size     ; save regs + alloc locals
    ... function body ...
    PLL  #locals_size     ; restore regs + deallocate locals
    RTS
```

### Parameter access

From the callee's perspective after `PSH #N`:

```
    LDA  +(N + 8),SP      ; load low byte of first param
    LDA  +(N + 9),SP      ; load high byte of first param
```

`N` = locals_size.  The return address occupies 2 bytes above the
locals, and the gap byte at `+N+7` is unused by JSR.

### Local variable access

```
    STA  +7,SP            ; store to local[0]
    LDA  +8,SP            ; load from local[1]
    STX  +5,SP            ; save X to its register slot (e.g. before a nested call)
```

### Call site

The caller pushes parameters with PHA (right-to-left convention),
then JSRs.  After return, A holds the return value and the caller
must discard the parameter bytes without clobbering A:

```
    LDA  param_hi
    PHA                   ; push high byte first
    LDA  param_lo
    PHA
    JSR  my_func
    ; A = return value
    STA  -1,SP            ; save return value below SP
    PLA                   ; discard param_lo
    PLA                   ; discard param_hi
    LDA  +1,SP            ; restore A (SP has moved up by 2)
```

This is the standard cdecl-style caller cleanup.  A future
`ADD SP, #N` instruction (using one of the spare `$x2` opcodes)
would replace the four-instruction dance with a single opcode.

### Leaf function (no saved registers)

For a leaf that doesn't use PSH/PLL, SP-relative addressing works
directly:

```
    LDA  +3,SP           ; access param (if caller pushed it)
    STA  -1,SP           ; store temporary below SP
    ; WARNING: interrupts can overwrite SP‑1 — use only in SEI
    ; sections or very shallow leafs.
```

For leafs that need locals but no register save, use `PSH #N` with a
dummy PLL (the saved registers are restored from wherever PLL finds
them — which is the same slots PSH wrote them to):

```
    PSH  #4        ; save A/X/Y/SP_H/SP_L/P and alloc 4 bytes locals
    ... use +7..+10 for locals, +1..+6 for saved regs (read-only), +0 guard ...
    PLL  #4        ; restore everything, dealloc locals
    RTS
```

---

## 5. Implementation notes for sally_core

### Hardware additions

1. **Stack RAM**: 4 KB synchronous dual-port RAM (one RAMB36E1 or two
   RAMB18E1s).  Port A: stack reads/writes (PHA/PLA/JSR/RTS/RTI/BRK +
   SP-relative).  Port B: aliased window reads at `$0100–$01FF` (so
   legacy `LDA $0100,X` sees stack bytes $F00–$FFF).

2. **SP register**: widened from 8 to 12 bits.  Separate
   4-bit register for `SP[11:8]` (preserved on TXS/TSX, cleared on
   reset to $0F).

3. **Signed adder**: 12-bit signed adder for `SP + d` (d is
   8-bit signed, sign-extended to 12).  Clamp logic: if result
   > $FFF, force $FFF; if result < $000, force $000.

4. **Opcode decode**: new instructions in the `$x2` column.
   Decode tree:
   ```
   if opcode[3:0] == 2:
       case opcode[7:4]:
           0: STX d,SP          ; $02
           1: STY d,SP          ; $12
           3: PSH #imm          ; $32
           4: LDX d,SP          ; $42
           5: LDY d,SP          ; $52
           6: PLL #imm          ; $62
           7: ADC d,SP          ; $72
           9: STA d,SP          ; $92
          11: LDA d,SP          ; $B2
          13: CMP d,SP          ; $D2
          15: SBC d,SP          ; $F2
          2,8,10,12,14: reserved
   ```

5. **PSH/PLL sequencer**: a micro‑sequence that reads/writes the 6
   register slots at fixed offsets from SP (saved P at SP+1 .. saved A
   at SP+6, guard byte at SP+0), then adjusts SP by `N + 7` in a single
   step.  No intermediate bus states are exposed.  Shared adder for the
   `SP ±= frame_size` adjustment.

### Critical paths

- The signed adder `SP + d` → clamp → stack RAM address must settle
  within one clock cycle.  With a 12-bit signed add + two comparators
  (clamp), this should be well under 4 ns at 100 MHz (SALLY clock
  domain).  No timing concern.
- PSH/PLL's `SP ±= frame_size` uses the same adder; the 8-bit
  immediate is zero-extended to 12 bits for the `+ N + 7` / `- N - 7`
  calculation (6 saved bytes + 1 guard byte).

### Cycle counts

All SP-relative load / store / arithmetic instructions are 2 bytes,
2 cycles — `ADD SP, #signed8` is the same shape (2 bytes, 2 cycles)
since the SP write bypasses the stack BRAM entirely.

PSH/PLL are multi-cycle but fixed-cost regardless of N:

| Instruction      | Cycles | Breakdown |
|------------------|--------|-----------|
| `LDA d,SP`       | 2 | DECODE / SP0+FETCH (read stack and consume in ALU) |
| `STA d,SP`       | 2 | DECODE / SP0 (write stack) |
| `LDX d,SP`       | 2 | |
| `LDY d,SP`       | 2 | |
| `STX d,SP`       | 2 | |
| `STY d,SP`       | 2 | |
| `ADC d,SP`       | 2 | DECODE / SP0+FETCH (read stack into ALU) |
| `SBC d,SP`       | 2 | |
| `CMP d,SP`       | 2 | |
| `ADD SP, #signed8` | 2 | DECODE / SP_ADJ (SP write, no stack-BRAM access) |
| `LDA/STA (d,SP),Y` | 5 (+1) | DECODE / SPIY0 (ptr LSB) / SPIY1 (ptr MSB, LSB+Y) / INDY2 (data) / FETCH; +1 cycle on page cross (INDY3) — see §2b |
| `LDA/STA d,SP,X`   | 3 | DECODE / SPIX0 (SP+d) / SPIX1 (+X, stack access) — see §2b |
| `PSH #N`         | 8 | fetch opcode + fetch imm/compute sp_new + 6×1-byte BRAM writes + next-opcode fetch |
| `PLL #N`         | 8 | fetch opcode + fetch imm/compute sp_new + 6×1-byte BRAM reads + final commit/next-opcode fetch |

**Current implementation: single-port stack BRAM.**
The stack RAM in `sally_mem` is a single-port synchronous BRAM (one
byte read or written per cycle), so PSH/PLL serialise the 6-byte
frame transfer.  Cycle breakdown (PSH) — note: the offsets below
predate the guard byte and the `PSH_CALC` split; the normative layout
is §3 (saved P at `sp_new+1`, slots `+2..+6`, guard at `+0`), and
xt6502 adds a `PSH_CALC` cycle that registers `sp_new = SP − (N+7)`
ahead of the writes (so PSH is 9 cycles there).  Illustrative:

```
Cycle 1: DECODE     fetch $32 opcode
Cycle 2: PSH0       DIMUX = N; latch sp_new = SP − (N+6); write P  at sp_new+0
Cycle 3: PSH_RUN/1                                        write SP_lo at sp_new+1
Cycle 4: PSH_RUN/2                                        write SP_hi at sp_new+2
Cycle 5: PSH_RUN/3                                        write Y     at sp_new+3
Cycle 6: PSH_RUN/4                                        write X     at sp_new+4
Cycle 7: PSH_RUN/5  write A at sp_new+5, commit SP
Cycle 8: FETCH      AB = PC = next-opcode addr
```

PLL is symmetric: addresses present in cycles 2..7, BRAM data
arrives 1 cycle later, so P is consumed at the start of PSH_RUN/1,
the saved Y/X latch at PSH_RUN/4 and PSH_RUN/5, and A lands in the
PLL_FIN cycle alongside the PC=next-opcode fetch and SP commit.

**Theoretical 5-cycle target.**  A dual-port BRAM (or 16-bit-wide
data path) could write/read two bytes per cycle, dropping PSH/PLL
to 5 cycles each.  This is a future-work optimisation in
`sally_mem` — see Issues docs.  No code currently relies on the
faster timing.

PSH #N micro‑architecture:

```
Cycle 1:  fetch opcode $32 from main memory (PC → addr bus)
Cycle 2:  fetch immediate N from main memory (PC+1 → addr bus)
          simultaneously: compute SP_new = SP − (N+6)
                          no bus contention — internal adder
Cycle 3:  port A ←{P, SP_lo}  → stack_ram[SP_new + 0, +1]
          port B ←{SP_hi, Y}  → stack_ram[SP_new + 2, +3]
Cycle 4:  port A ←{X, A}      → stack_ram[SP_new + 4, +5]
          (port B idle or servicing alias-window read)
```

PLL #N micro‑architecture:

```
Cycle 1:  fetch opcode $62
Cycle 2:  fetch immediate N
Cycle 3:  port A →{P, SP_lo}  ← stack_ram[SP + 0, +1]
          port B →{SP_hi, Y}  ← stack_ram[SP + 2, +3]
Cycle 4:  port A →{X, A}      ← stack_ram[SP + 4, +5]
Cycle 5:  SP = SP + (N+6)     (combinatorial add, registered at end of cycle)
```

All new instructions fetch the opcode byte from main memory normally.
The operand byte (immediate or signed offset) is fetched from PC+1.
The stack RAM access happens on the internal stack port, which does
not use the main address bus; hence no bus contention.

### Tie-off for OOC synthesis

For out-of-context synthesis (Vivado standalone PL build), the stack
RAM is instantiated as a simple 4096×8 synchronous RAM.  The alias
mux (mapping `$F00–$FFF` to `$0100–$01FF`) is a mux on the sally_mem
read-data path: when `cpu_addr[15:8] == $01`, redirect the read to
`stack_ram[addr[7:0] | 12'hF00]`.

---

## 6. Opcode map summary

```
$x2 column (all JAM on original NMOS 6502):

  $02: STX d,SP        $42: LDX d,SP        $82: (reserved)     $C2: (reserved)
  $12: STY d,SP        $52: LDY d,SP        $92: STA d,SP       $D2: CMP d,SP
  $22: ADD SP, #imm    $62: PLL #N          $A2: *LDX #imm*     $E2: (reserved)
  $32: PSH #N          $72: ADC d,SP        $B2: LDA d,SP       $F2: SBC d,SP

* $A2 is LDX #imm on the original 6502 (NOT a JAM) — do not reassign.

$x4 column (PUSH/POP — see §2):
  $44: PUSH X   $54: PUSH Y   $64: POP X   $74: POP Y

$x3 column (cc=11 combo-illegals on NMOS; whole column free in SALLY):

  $03: LDA (d,SP),Y    $13: STA (d,SP),Y    $23: LDA d,SP,X    $33: STA d,SP,X
  ($43..$F3 reserved for future SP-indirect variants: ADC/CMP/AND/…)

  decode: mode_x = IR[5]  (0 = (),Y ; 1 = ,X) ;  store = IR[4]
```

Spare `$x2` slots: `$82`, `$C2`, `$E2` (e.g. `AND d,SP`, `ORA d,SP`,
`EOR d,SP`).  The `$x3` column has twelve free slots beyond the four
above for the SP-indirect/indexed family.

---

## 7. Policy

- **New code** targeting the 'xt' model should not use `TSX`/`TXS`.
  Use SP-relative addressing (`LDA d,SP`, `STA d,SP`, etc.) instead.
- **Old code** (Atari OS, ROM routines) is unaffected — it runs within
  the 256-byte-compatible aliased window and never hits the new
  opcodes.
- PSH/PLL are the only supported way to adjust SP in new code.
  Direct manipulation of SP via TXS breaks the alias-model invariant
  and may confuse the frame layout.