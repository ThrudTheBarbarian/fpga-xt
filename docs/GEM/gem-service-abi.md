# GEM service — binary calling convention (VDI + AES)

GEM runs as a **service on the ARM-A9**. The A9 *is* the VDI and AES engine:
it executes every drawing primitive (issuing blitter/compositor work in
fabric) and every AES request. Clients — the emulated 6502 (XL), the
emulated m68k (ST), and ARM-native code — do **not** implement or link GEM.
They issue calls across a doorbell interface whose payload uses the **Atari
ST array convention**, and provide only thin per-language *bindings*.

This document specifies the binary contract: dispatch, parameter blocks,
transport per client, the shared arena, and the call handshake.

## 1. Principles

- **ST-compatible payload.** The in-memory argument layout is the ST's VDI /
  AES arrays, unchanged. Existing GEM knowledge, opcode tables, and bindings
  port directly; real ST `TRAP #2` binaries can be serviced (see §3.1).
- **Transport is a doorbell, not a CPU trap.** Client and server are
  different CPUs, so a "trap" is: publish the arrays where the A9 can read
  them, then ring a hardware doorbell. The A9 services it and writes results
  back.
- **The A9 cannot see fabric-resident client RAM.** The XL's main memory is
  dual-ported BRAM (xt6502 CPU + ANTIC DMA) — both ports are taken, so the A9
  is *not* a third reader of it. The XL therefore marshals call data through
  a dedicated **shared arena** the A9 *can* reach (§3.2). The m68k, hosted on
  the A9 itself, has no such barrier (§3.1).
- **Synchronous / blocking.** A call returns to the client only after the A9
  has completed it and written the outputs. Mirrors real VDI/AES trap
  semantics; the blocking cost is invisible — the turbo'd client waits on a
  far faster A9.

## 2. Dispatch and parameter blocks

Two namespaces, selected exactly as on the ST by the dispatch code:

| Namespace | Dispatch code | Parameter block |
|-----------|---------------|-----------------|
| VDI | `115` (`$73`) | 5 pointers: `contrl, intin, ptsin, intout, ptsout` |
| AES | `200` (`$C8`) | 6 pointers: `control, global, int_in, int_out, addr_in, addr_out` |

The **parameter block** is a vector of pointers to the individual arrays. The
pointer width is the client's native pointer:

- **xt / 6502 — 3 bytes `{lo, hi, bank}`.** The xt address space is banked; a
  pointer carries its bank. For a GEM call every pointer's bank byte is the
  shared GEM bank (`$FF`, §3.2), and `{hi:lo}` is the address within the bank
  window.
- **m68k — 4 bytes**, flat.
- **ARM — 4 bytes**, flat.

Array elements are 16-bit `WORD`s. VDI `contrl[]` keeps its ST meaning:

| Index | Meaning |
|-------|---------|
| `contrl[0]` | opcode (e.g. `v_pline`=6, `v_gtext`=8, `vs_color`=14) |
| `contrl[1]` | number of input vertices (`ptsin` pairs) |
| `contrl[2]` | number of output vertices (`ptsout` pairs) — set by service |
| `contrl[3]` | length of `intin` |
| `contrl[4]` | length of `intout` — set by service |
| `contrl[5]` | sub-opcode (GDP / escape function id) |
| `contrl[6]` | workstation handle (from `v_opnwk` / `v_opnvwk`) |

AES `control[]` likewise: `control[0]`=opcode, `[1]`=#`int_in`, `[2]`=#`int_out`,
`[3]`=#`addr_in`, `[4]`=#`addr_out`. AES return value lands in `int_out[0]`.
Opcode tables are the standard GEM set; they are **not** redefined here.

## 3. Transport per client

### 3.1 m68k (ST) — genuine `TRAP #2`, binary compatible

The m68k client uses the real ST convention with no awareness of the A9:

```
    d0 = 115 ($73)   ; or 200 for AES
    d1 = address of the parameter block
    TRAP #2
```

The m68k is **hosted on the A9** (JIT m68k→ARM), so ST RAM *is* A9 memory: the
captured `TRAP #2` handler reads `d0`/`d1` and the A9 dereferences the
parameter block and arrays **directly** — no arena, no copy. **Unmodified ST
GEM binaries therefore run** — the trap they already issue *is* the call.

### 3.2 6502 (XL) — shared GEM bank + MMIO doorbell

The xt memory map provides two bank windows; the **data bank window**,
`$A000-$CFFF` (12 KB, selected by `$D5C1`), is the GEM arena:

```
$2400-$3FFF  Code entry point, system region
$4000-$5FFF  Screen RAM
$6000-$9FFF  Code bank window   (via $D5C0)
$A000-$CFFF  Data bank window   (via $D5C1)   ← bank $FF = GEM arena
$D5C0-$D5C1  Bank-select registers (code, data)
$D800-$FFF9  Unbanked region
$FFFA-$FFFF  NMI/IRQ vectors
```

Because the A9 cannot read the XL's dual-ported main RAM, the XL puts all call
data in a **shared GEM arena**: bank **`$FF`** of the data window — the 12 KB
span `$A000-$CFFF`, mapped at a known physical address on the A9 side. Both
sides reach the *same* bytes (the XL through the window, the A9 through its
fixed mapping). The 12 KB window sizes the in/out arrays exactly.

Per-call sequence on the XL:

1. Save the current data bank (`$D5C1`); map bank `$FF` into the data window
   (`$D5C1 = $FF`). `$A000-$CFFF` now addresses the shared arena.
2. Write the param block + arrays into the arena (`$A000-$CFFF`). Pointers are
   `{lo,hi,$FF}`.
3. Drive the doorbell (below); spin until done.
4. Read any outputs back from the arena.
5. Restore the saved data bank (`$D5C1 = saved`).

Because the call is blocking, surrendering the data window for its duration is
free. Code runs from the separate code bank window (`$D5C0`, `$6000-$9FFF`) or
the unbanked region throughout, untouched. (Caller args must be staged outside
`$A000-$CFFF` — e.g. ZP or unbanked RAM — since the data bank they'd otherwise
live in is unmapped during the call.)

The doorbell is a small MMIO block in the CCTL I/O gap, alongside the bank
selectors — canonical addresses in
[../Zynq/register-map.md](../Zynq/register-map.md) (`$D5xx` section):

| Addr | Acc | Name | Meaning |
|------|-----|------|---------|
| `$D5D0` | W | `GEM_DISPATCH` | `115` = VDI, `200` = AES |
| `$D5D1` | W | `GEM_PBLK_LO` | param-block address within `$A000-$CFFF`, low byte |
| `$D5D2` | W | `GEM_PBLK_HI` | param-block address within `$A000-$CFFF`, high byte |
| `$D5D3` | W | `GEM_GO` | any write rings the doorbell (strobe) |
| `$D5D3` | R | `GEM_STATUS` | bit7 = busy; bit0 = error; bits6..1 = result code |
| `$D5D4` | R | `GEM_ABIVER` | ABI version / magic (probe; `$00` = no service) |

`GEM_PBLK_*` is the in-window address of the param block (`$A000-$CFFF`); the
bank is implicitly `$FF`. The A9 resolves it as `GEM_ARENA_BASE + (pblk −
$A000)` and resolves the `{lo,hi,$FF}` array pointers inside it the same way.

### 3.3 ARM-native client

Native A9 code (e.g. an xtc-ARM desktop shell, once that backend lands) calls
the service in-process — a direct function call or the same shared mailbox —
with no marshalling. The array layout is identical, so a client can move
between transports with only its binding swapped.

## 4. Address resolution

| Client | How the A9 reaches the arrays |
|--------|------------------------------|
| m68k (ST) | Direct — ST RAM is A9 memory (JIT host). `d1` → param block. |
| 6502 (XL) | Via the shared bank `$FF` arena (data window `$A000-$CFFF`). `phys = GEM_ARENA_BASE + (winAddr − $A000)` for the param block and every `{lo,hi,$FF}` array pointer. |
| ARM | Direct — real pointers, in-process. |

The XL's call payload (param block + all arrays) **must live entirely in bank
`$FF`** (`$A000-$CFFF`) — that is the whole point of the arena. The A9 never
dereferences a pointer into XL main RAM.

## 5. Endianness

Array elements are 16-bit. The 6502/xt client is little-endian; the m68k
client is big-endian. The A9 normalises per the originating client (recorded
with the doorbell / known from the trap source), so the service core works in
one fixed endianness regardless of caller.

## 6. Call handshake

1. **Client** prepares the arrays. *XL only:* map bank `$FF` in first and
   write into the arena (§3.2 steps 1–2).
2. **Client** publishes the call: m68k sets `d0/d1` + `TRAP #2`; XL writes
   `GEM_DISPATCH`, `GEM_PBLK_{LO,HI}`, then `GEM_GO`.
3. **Doorbell** raises an interrupt to the A9; `GEM_STATUS.busy` reads 1.
4. **A9** reads the dispatch, resolves the block (§4), reads the input arrays,
   and executes the call (drawing → blitter/compositor; AES → service logic).
5. **A9** writes the output arrays back (XL: into the arena; m68k: into ST
   RAM), sets the `contrl[2]/contrl[4]` (or AES) counts, posts the result
   code, and clears busy / acks the trap.
6. **Client** observes completion (`GEM_STATUS.busy` → 0, or trap resume),
   reads the outputs, and continues. *XL only:* restore the saved data bank.

The client **must not** touch the arena / parameter block between steps 2
and 6.

## 7. Handles, versioning, errors

- **Workstation / app handles.** A client opens a (virtual) workstation with
  `v_opnvwk`; the returned handle goes in `contrl[6]` on every subsequent VDI
  call. AES `appl_init` returns an application id used likewise. The service
  keys per-client state off these handles, which also serialise concurrent
  clients (the desktop shell and a legacy machine may both be open).
- **Versioning.** `GEM_ABIVER` (XL) / an AES probe (m68k) lets a client detect
  the service and its ABI revision before use. `$00` ⇒ no service present.
- **Errors.** Transport-level failures (bad dispatch, untranslatable pointer,
  unknown opcode) surface in `GEM_STATUS` (XL) or a negative AES `int_out[0]`.
  VDI per-call status follows the standard `intout` semantics.

## 8. Bindings

A binding is the only per-client code, and it is small:

- **XL / xtc-6502.** Ship an xtc `Vdi` / `Aes` stdlib class (sibling to
  `Stdio` / `Vbi`) that owns the arena bank, lays out the arrays, exposes
  typed methods (`vdi.pline(...)`, `aes.windCreate(...)`), and inlines the
  bank-map / doorbell drive / busy-spin / bank-restore. No linking against any
  GEM library — just bank + MMIO writes.
- **m68k.** The stock ST `vdibind` / `aesbind` stubs work unchanged.
- **ARM-native.** Direct calls into the service.

## 9. Worked example — `v_pline` (polyline) from the XL

Draw a 3-point polyline on workstation handle 1. All data lives in bank `$FF`
(the data window `$A000-$CFFF`); the arrays below sit at `$A000…`:

```
contrl: [ 6, 3, 0, 0, 0, 0, 1 ]      ; op=v_pline, 3 vertices, ws handle 1
ptsin:  [ x0,y0, x1,y1, x2,y2 ]      ; 3 coordinate pairs
intin:  [ ]                          ; none
pblock: [ &contrl, &intin, &ptsin, &intout, &ptsout ]   ; 5 × {lo,hi,$FF}
```

```
    ; --- map the shared GEM bank into the data window ---
    lda $D5C1 : pha               ; save current data bank
    lda #$FF  : sta $D5C1         ; map bank $FF (GEM arena) at $A000-$CFFF
    ; --- (binding has written the arrays into the arena) ---
    lda #115           : sta $D5D0   ; VDI
    lda #<pblock       : sta $D5D1   ; in-window addr of pblock ($A000-range)
    lda #>pblock       : sta $D5D2
    sta $D5D3                        ; GO (value irrelevant)
wait:
    lda $D5D3 : bmi wait             ; spin while busy (bit7)
    ; --- read any outputs from the arena, then map the bank back ---
    pla : sta $D5C1                  ; restore saved data bank
```

The m68k form needs no arena: the same arrays anywhere in ST RAM, with
`d0=115`, `d1=&pblock`, `TRAP #2`.
```
