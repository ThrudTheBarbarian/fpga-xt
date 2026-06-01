# XTOS — aspirational architecture & roadmap

> **Status: north-star, not a committed spec.** This document captures the
> intended shape of XTOS and the load-bearing decisions behind it, so that
> near-term work doesn't paint us into a corner. Details will move; the
> *pillars* and the *reserve-now hooks* are the parts meant to be stable.

## 1. North Star

XTOS is the operating system of a **bespoke integrated machine** — not Linux
with a retro skin, and not an emulator collection. The ARM-A9 boots straight
into a **GEM desktop**; the FPGA hosts the Atari hardware (xt6502 + ANTIC/GTIA/
POKEY) and the 2D blitter. The line in the sand: it *feels* like one coherent
machine — a souped-up GEM/TOS box whose "modern half" happens to be a dual A9.

The desktop:

- provides keyboard / mouse support and **propagates input to clients** by focus;
- shows menus, icons, windows;
- treats the **6502 (XL)** and **m68k (ST)** as **client objects** with their
  own windows — movable, resizable, minimisable;
- provides a **network device** (FujiNet-style sockets) and a **disk device**
  (the SD card), presented to each client as it expects;
- provides an **emptyable trashcan**;
- provides a **shell window** with unix-like, busybox-style functionality.

Those are table stakes. Beyond them:

- **FreeRTOS loads and runs applications dynamically**, not just the static
  tasks built into the binary;
- an **IDE** on the A9 drives the **xtc** compiler to build for ARM, 6502 *and*
  m68k;
- a **source-level cross-core debugger** can halt the other cores, set
  breakpoints in them, and inspect their state in the IDE — with machine-level
  as an option, not a requirement.

## 2. Architecture pillars

### P1 — XTOS on FreeRTOS (we are writing an OS)

FreeRTOS is the **bottom 5%**: scheduler, synchronisation, a heap. *Everything
else is XTOS*, designed coherently rather than accreted: the loader, the VFS,
the app/launch model, the **interface/registry** (P4), the input/event bus, and
the settings/state store. Choosing FreeRTOS over Linux is the deliberate
"bespoke machine" decision — it just means the OS layer is ours to build.

**Memory protection is deferred** (§6 open decisions). The multi-CPU design
gives fault isolation for *client* apps for free — a crashing 6502/m68k program
only takes down its VM. ARM-native apps share one address space with no MMU
protection for now; the seam that lets us add it later without an ABI break is
the service-call indirection in P4.

### P2 — The compositor: four surfaces, different by nature

The fabric compositor handles **exactly four surfaces**, distinguished by their
nature, back-to-front:

| Layer | Surface | Notes |
|-------|---------|-------|
| 0 | **GEM desktop** | One surface. GEM windows are drawn *into* it immediate-mode (`WM_REDRAW` on expose) — they are **not** individual compositor planes. Classic GEM save-under handles menus *within* this layer. RGBA-8888. |
| 1 | **Atari 8-bit (XL)** | Emulation surface (ANTIC writeback → DDR). |
| 2 | **Atari 32-bit (ST)** | Emulation surface. |
| 3 | **Sprites / mouse pointer** | Small overlays. |

- **VM layer order (1 ⇄ 2) is reorderable** so either machine can be raised
  above the other; layers 0 and 3 are fixed.
- **The two "client" models coexist by construction.** A legacy program runs in
  its VM and its framebuffer is layer 1/2 (a "VM in a box"). A *native* XT
  program that calls the ARM GEM service (P3) has its windows drawn into
  layer 0 — so GEM windows from **any** CPU (ARM, 6502, m68k) are layer-0
  citizens, peers of each other.
- **What floats over emulators:** the things that *need* to (menus, modal
  dialogs, the pointer) are small **by nature**, so they ride the layer-3
  small-overlay / quarter-screen mechanism and float fine. Large GEM windows
  live in layer 0, **behind** the emulators — an accepted limitation, not a
  necessity to overcome.
- **Optional escape hatch (deferred):** a full-screen **front GEM plane** (a 5th
  surface, mostly transparent, dirty-region-cheap) would let large GEM windows
  be raised *over* emulators. Nice-to-have; do **not** build it now.
- **Bandwidth:** dirty-region compositing keeps the GEM plane(s) cheap. Free on
  the 32-bit Z-Turn; on 16-bit-DDR budget boards keep plane reads dirty-bounded
  (see the board-tier notes in the README).

### P3 — GEM: a service *and* a library, on the A9

The A9 **is** the VDI/AES engine: it executes every drawing primitive (issuing
**blitter** work where possible) and every AES request. Clients do not implement
or link GEM — they call it across an ST-trap-style ABI and ship only thin
*bindings*. The binary calling convention is specified in
[../GEM/gem-service-abi.md](../GEM/gem-service-abi.md).

- **Offscreen rendering is standard GEM**, not a bespoke concept: the compositor
  surfaces are offscreen **virtual workstations** (`v_opnvwk`) in RGBA-8888 that
  GEM draws into and the desktop composites.
- **ST array semantics are preserved**, so real ST GEM binaries can run (their
  `TRAP #2` is forwarded to the A9 service).

### P4 — Interface / registry: services and libraries are one thing

A **system service** and a **shared library** are the same abstraction: an
**interface** — a struct of function pointers ("ops table") — obtained from a
**registry** by name/UUID and called **directly in-process**. Two binding
styles, one registry:

- **Ops-table library** — direct indirect call, no task switch. The default;
  fast enough for fine-grained calls.
- **Task-as-server (RPC)** — a service with its own thread/queue, for things
  that need async behaviour or future isolation.

Rules:

- Apps reach **all** system services through this indirection — never by poking
  kernel/desktop globals. That single discipline lets MMU protection be added
  later as *enforcement*, with no ABI break (the deferral in P1 stays cheap).
- **Every interface carries a version field** — the `ABIVER` house style (see
  the GEM doorbell's `GEM_ABIVER`). Fluid until 1.0, but always *detectable*.
- This is a **public ecosystem ABI**: third parties will ship ARM-native
  services, so the interface/registry/loader contract is frozen-early work even
  though the IDE/debugger that exercise it come later.

Reserve-now to keep this open: the registry + interface-handle abstraction;
**PIC / relocatable** xtc ARM codegen; a loader that relocates code+data and
resolves a library's own imports through the service table.

### P5 — Per-app launcher, VFS, and devices

The ARM makes its rich resources *appear* to each client the way that client
expects, driven by **per-app attributes** the desktop sets up and persists.

- **Per-app profiles.** Double-click an XEX → it runs at 1× in the emulator,
  booting that file. Games with multiple drives / overlays → assign ATR images
  to drives. Specify XL/XE type and RAM size. ST equivalents: boot settings,
  accessories, AUTO-folder PRGs, drive maps (C:, D:). All persisted, so it's
  set once.
- **Two drive modes, both first-class:**
  - **opaque disk images** (ATR/ST) for compatibility, and
  - **directory-mapped drives** (a host folder presented as a client drive,
    Hatari/FujiNet-style) so a file is visible to *both* desktop and client.
    This is what makes the machine feel integrated and enables the IDE→client
    loop (build on the ARM, the binary *appears* on the Atari's drive).
- **Attributes store:** a **SQLite** database on the on-board **NAND** (state,
  not binaries — §P-storage). Files are recognised by **MD5** (content identity,
  hashed once at import) with `(name, size, mtime)` as the fast path; the disk
  file itself is **never altered**.
- **Network = FujiNet-as-sockets.** The A9 has GbE + a sockets stack; it is
  exposed to legacy clients via the FujiNet SIO protocol and to native XT apps
  via a sockets API. The "device" is a protocol bridge over one real stack.
- **Disk = SD via the VFS**, with per-app config bridging the client's native
  disk APIs (Atari CIO/SIO/DOS, TOS GEMDOS) to the SD-backed VFS.
- **Trashcan**: a trash directory + restore + empty over the VFS.
- **Shell**: a unix-like, busybox-style command window over the VFS.

#### Storage tiers

| Medium | Size | Role |
|--------|------|------|
| **NAND** | 16 MB | **Permanent state** — SQLite attributes DB, settings, config. Survives SD swaps. Not for binaries. Needs a thin wear-aware layer under SQLite (raw NAND has no controller; writes are rare). |
| **SD card** | large | Binaries (system + apps), the software library, user data, disk images. |

The "can't go away" guarantee covers **config/attributes**, not binaries.
(Card-less boot — moving the boot image to QSPI — is an optional future, §6.)

### P6 — Hardware-debuggable cores + flat-address debug

- **xt6502** gets HW debug hooks (easy on a core we own): halt, single-step
  (clock-gate one op), **breakpoint/watchpoint comparators**, and
  register/memory read-back over a debug MMIO port. Each comparator is a
  descriptor:

  ```
  bank    : 8   which bank ($D5C0 code / $D5C1 data; 0 = BRAM)
  offset  : 16  6502 logical address
  R W X   : 3   independent — break on read / write / execute
  EN      : 1   enable
  ```
  ```
  match = EN
        & (cur_addr   == offset)
        & (active_bank == bank)
        & ( (is_read  & R) | (is_write & W) | (is_fetch & X) )
  ```

  `active_bank` and `is_read/write/fetch` both fall out of signals the core
  already exposes at the access point, so the whole comparator is one
  address-equal + one bank-equal + a three-term AND-OR — cheap enough to place
  several in parallel without straining clk_sally. The three independent R/W/X
  bits give the full matrix from one comparator: `X` = code breakpoint, `W` =
  "who wrote this?", `R|W` = data watchpoint, `R|W|X` = break on any touch. This
  is the same shape real hardware debug units use (ARM CoreSight watchpoints'
  load/store/execute selects; x86 DR7 R/W bits), so the debugger-side
  abstraction maps cleanly onto it. Matching on `{bank, offset}` works because
  `$A000` exists in every bank.
- **m68k** debugging switches the **JIT off and interprets**. The JIT must be
  able to **exit to a precise m68k instruction boundary** with full
  architectural state materialised (UAE-style dual mode). You don't need speed
  while debugging.
- **Flat logical address.** Every address in debug info / breakpoints / the
  loader's flat↔physical mapping is a single 32-bit value. Only the 6502 banks,
  and its code/data banks live in disjoint windows, so `{bank}{16-bit offset}`
  is unambiguous — the offset's window implies code-vs-data; no separate `realm`
  tag is needed (the comparator's R/W/X access bits carry the
  execute-vs-read/write distinction instead). m68k and ARM use their native
  24-/32-bit addresses directly. This turns the banked machine into a flat space
  for tooling. The bespoke format is **retro-cores-only**; ARM uses stock DWARF
  (below), so this 32-bit packing never has to stretch to hold an ARM address.
- The debugger is **bespoke** (part of the IDE), **source-level** first,
  machine-level optional.

## 3. What xtc must emit (debug info)

xtc emits **none** of this today; it is net-new backend work, best designed
alongside the multi-backend re-architecture (the ARM backend doesn't exist yet —
the cheapest possible time to bake it in). The format is a **restricted profile
of standard DWARF, emitted for all three backends** in flat-address coordinates.

The flat logical address (item 1) is exactly the linear address space DWARF
assumes, so **banking** — the one feature that would otherwise fight DWARF — is
already linearized by `{bank}{offset}`. The targets' only other oddities map
onto a small, standard subset: target-defined register numbers, three location
opcodes, and a minimal line program (detailed below). We emit just that subset —
dropping DWARF's generality-driven weight by *not emitting what we don't use*,
rather than inventing a parallel format. The payoff is one parameterized emitter
and one reader instead of two of each (we build the ARM DWARF path regardless),
and the ARM side gets stock tooling — `addr2line`, libraries, even gdb — for
free. We own the debugger, so on the retro side "standard tools just work" is a
bonus, not a requirement; the reader can be a library (gimli/libdwarf) or a
small hand-rolled reader for our subset.

Per backend, xtc emits:

1. **The logical-address contract** — the flat 32-bit `{bank}{offset}` address
   (retro cores; native 24-/32-bit for m68k/ARM) that the line table, breakpoint
   comparator, and loader all share.
2. **Line table** — flat-PC ↔ `(file, line[, col])`, bidirectional
   (breakpoint-by-line *and* stop→highlight-source). *A minimal DWARF line
   program — which is itself just a delta-encoded table — emitting only the
   advance-pc/advance-line/special opcodes we need.*
3. **Symbols + types** — functions (name, flat low/high PC); globals (name, flat
   address, type); type descriptions (struct / enum / array / pointer layouts)
   so values render typed, not as raw bytes.
4. **Local-variable locations** — per local: name, type, live PC-range (scope),
   and a **location**, expressed with just three standard DWARF opcodes (not the
   full location-expression VM):
   - `static` → `DW_OP_addr` at a flat address (globals, ZP globals,
     statically-allocated locals);
   - `frame-base + offset` → `DW_AT_frame_base` + `DW_OP_fbreg` for soft-stack
     locals (the frame base is a runtime value xtc names — *which ZP/reg holds
     the soft-SP/FP* — plus a compile-time offset);
   - `register` → `DW_OP_regN` for ARM/AAPCS register-allocated locals.

   *We only ever emit these three, so the emitter is trivial and a hand-rolled
   reader stays tiny, while a stock DWARF reader handles them out of the box.*
5. **Frame/unwind info** — *optional, gated on the §6 single-frame-vs-backtrace
   fork*: per function, frame size + where the saved return-address and previous
   frame base live, so the debugger can walk the call stack.
6. **One format (DWARF), per-backend register vocabulary** — the debugger reads
   a single format; the per-target difference is just DWARF's target-defined
   register numbering (ARM AAPCS regs; 6502 A/X/Y/ZP/soft-stack; m68k regs/stack)
   — which is exactly the per-architecture extension point DWARF already has.

## 4. Reserve-now hooks (the corner-painting list)

Build these (or their seams) early even though the features that use them ship
later:

- **xt6502:** bank-aware R/W/X breakpoint+watchpoint comparators + halt/step +
  register/mem read-back debug port. Two of the seams this needs already exist
  incidentally: the **GP0 debug-register transport** (the `axi_blitter_bridge`
  diag-word read path) and an **instruction-boundary tap** (the `ST_DECODE`
  state already used for boot co-sim). The comparators/halt logic themselves are
  Phase-6 work, deferred until there's a debugger to consume them — the core's
  clk_sally timing is thin, and nothing reads these hooks yet.
- **m68k JIT:** precise-instruction-boundary exits + an interpreter fallback
  path.
- **xtc:** PIC/relocatable ARM codegen; debug-info emission (§3); the flat
  logical-address model.
- **Service-call indirection** (apps via interface tables, never globals) — so
  MMU protection is a later enforcement detail, not an ABI break.
- **Interface / registry + `ABIVER`** versioning as house style from day 1.
- **Directory-mapped drives** as a first-class VFS mode (not an images-only
  design retrofitted later).
- **The logical-address contract** shared across compiler, debugger, core, and
  loader — one definition, four consumers.

## 5. Roadmap (dependency-ordered; phases overlap)

- **Phase 0 — Foundation. DONE.** PS↔PL GP0 AXI + HDMI 1080p60 scan-out proven
  on hardware (colour bars). The whole tower stands on this; it is green.
- **Phase 1 — GEM-as-C-library → blitter** under FreeRTOS. Prove a GEM primitive
  draws via the blitter on screen.
- **Phase 2 — Compositor WM + input.** The four-surface compositor driven by the
  desktop; the input/event bus with focus-based routing to each client's input
  sink (6502 keyboard inject, m68k keyboard, ARM GEM events).
- **Phase 3 — VFS + launcher + per-app profiles.** SD VFS; directory-mapped and
  image drives; SQLite attributes on NAND; trashcan; FujiNet/sockets; shell.
- **Phase 4 — Dynamic loading + interface/registry.** PIC/ELF ARM loader; the
  registry; ops-table libraries + task services; `ABIVER`.
- **Phase 5 — IDE + on-device xtc** (builds ARM / 6502 / m68k).
- **Phase 6 — Cross-core source-level debugger.** xt6502 debug RTL + m68k
  interpreter-debug + xtc debug-info consumer + IDE integration.

## 6. Open decisions

- **Debug ambition:** single-frame locals (no unwind info) **vs** full backtrace
  (xtc emits frame/unwind info). Drives §3 item 5.
- **Full-screen front GEM plane** (large GEM windows raised over emulators):
  deferred nice-to-have; decide if/when it's worth a 5th surface.
- **Memory protection** for ARM-native apps: deferred; revisit as the ecosystem
  matures. The P4 service seam keeps the door open.
- **Debug-info DWARF profile:** the format is settled (a restricted profile of
  standard DWARF, §3); the concrete subset spec — exact attributes, the 6502/m68k
  register numbering, the DWARF version to pin — is still to be written.
- **Card-less boot:** move the boot image (FSBL + bitstream + kernel) to QSPI so
  the machine boots with no SD inserted. Optional future.

## Related

- [GEM service binary calling convention](../GEM/gem-service-abi.md) — the
  client↔A9 GEM ABI (P3).
- [Register map](../Zynq/register-map.md) — `$D5xx` XT extension incl. the GEM
  doorbell.
- [Video architecture](../video-architecture.md) — the plane compositor (P2).
- [Multitasking notes](../MultiTasking/) — banked context switching, exec
  loading (P1/P4 background).
